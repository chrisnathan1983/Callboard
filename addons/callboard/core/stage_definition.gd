@tool
class_name StageDefinition extends Resource
## Authored data shared by the runtime and the Callboard.

const CURRENT_FORMAT_VERSION := 7
const ANALYSIS_SCENE_SOURCE_META := &"_analysis_scene_source"
const RuntimeInputRefScript := preload("res://addons/callboard/core/runtime_input_ref.gd")
const TriggerRoutingData = preload("res://addons/callboard/core/trigger_routing_data.gd")
static var _string_token_pattern: RegEx

@export var stage_script: GDScript
## Optional scene for Callboard validation. A path avoids a resource cycle
## when the scene itself references this StageDefinition.
@export_file("*.tscn") var preview_scene_path := ""
@export var external_calls := PackedStringArray()
## Runtime Stage instance IDs this definition may be loaded under. The Callboard
## uses these declarations to validate cross-Stage targets without loading scenes.
@export var cross_stage_instance_ids := PackedStringArray()
## Optional typed payload schema. Call IDs and relay IDs use the same namespace.
@export var payload_fields: Array[PayloadFieldData] = []
## Canvas positions for external event nodes, keyed by event ID.
@export var call_positions: Dictionary = {}
@export var external_vars := PackedStringArray()
## Typed external Blackboard producers. `external_vars` remains supported as an anonymous declaration.
@export var external_writers: Array[BlackboardWriterData] = []
## Optional, editor-analyzed completion conditions. Stages do not dispatch these.
@export var objectives: Array[ObjectiveData] = []
## When enabled, the Stage ignores Calls until activate() and only activates once per entry.
@export var managed_lifecycle := false
## Resolved state is applied after load and before the Stage is activated.
@export var restoration_bindings: Array[StageRestorationBinding] = []
@export var variables: Array = []
@export var rules: Array = []
## Optional dispatch policies keyed by trigger. Rule array order is authored routing order.
@export var trigger_routing: Array = []
@export var groups: Array = []
@export var format_version := 0

func _set(property: StringName, value: Variant) -> bool:
	match property:
		&"zone_script":
			if stage_script == null:
				stage_script = value as GDScript
			return true
		&"external_events":
			if external_calls.is_empty():
				external_calls = PackedStringArray(value)
			return true
	return false

## Normalize data at load and before any consumer can read it. Older `.tres`
## resources used `zone_script`, `external_events`, and `once` rule keys.
func _migrate() -> void:
	if external_calls.is_empty():
		external_calls = PackedStringArray(["arrive"])
	var unique_instance_ids := PackedStringArray()
	for value: String in cross_stage_instance_ids:
		var instance_id := value.strip_edges()
		if not instance_id.is_empty() and not unique_instance_ids.has(instance_id):
			unique_instance_ids.append(instance_id)
	cross_stage_instance_ids = unique_instance_ids
	rules = _normalize_rules(rules)
	trigger_routing = _normalize_trigger_routing(trigger_routing)
	variables = _normalize_variables(variables)
	groups = _normalize_groups(groups)
	payload_fields = _normalize_payload_fields(payload_fields)
	format_version = maxi(format_version, CURRENT_FORMAT_VERSION)

static func _normalize_rules(source: Array) -> Array:
	var normalized: Array = []
	for entry in source:
		if entry is RuleData:
			normalized.append(entry)
		elif entry is Dictionary:
			normalized.append(RuleData.from_dictionary(entry))
	return normalized

static func _normalize_trigger_routing(source: Array) -> Array[TriggerRoutingData]:
	var normalized: Array[TriggerRoutingData] = []
	for entry in source:
		if entry is TriggerRoutingData:
			normalized.append(entry)
		elif entry is Dictionary:
			normalized.append(TriggerRoutingData.from_dictionary(entry))
	return normalized

static func _normalize_variables(source: Array) -> Array:
	var normalized: Array = []
	for entry in source:
		if entry is VariableData:
			normalized.append(entry)
		elif entry is Dictionary:
			normalized.append(VariableData.from_dictionary(entry))
	return normalized

static func _normalize_groups(source: Array) -> Array:
	var normalized: Array = []
	for entry in source:
		if entry is GroupData:
			normalized.append(entry)
		elif entry is Dictionary:
			normalized.append(GroupData.from_dictionary(entry))
	return normalized

static func _normalize_payload_fields(source: Array) -> Array[PayloadFieldData]:
	var normalized: Array[PayloadFieldData] = []
	for entry in source:
		if entry is PayloadFieldData:
			normalized.append(entry)
		elif entry is Dictionary:
			normalized.append(PayloadFieldData.from_dictionary(entry))
	return normalized

func instantiate() -> Stage:
	_migrate()
	if stage_script == null or not stage_script.can_instantiate():
		return null
	var instance: Variant = stage_script.new()
	if instance is Stage:
		instance.definition = self
		return instance
	if instance is Node:
		instance.free()
	return null

func analysis_scene_path() -> String:
	if not preview_scene_path.is_empty():
		return preview_scene_path
	var source_path := analysis_source_path()
	return source_path.get_basename() + ".tscn" if not source_path.is_empty() else ""

func analysis_source_path() -> String:
	# Saved definitions use their current path even if an older save included draft metadata.
	return resource_path if not resource_path.is_empty() else get_meta(ANALYSIS_SCENE_SOURCE_META, "")

## Build a validation instance with scene-assigned props and @onready references.
func instantiate_for_analysis(parent: Node) -> Stage:
	var scene_path := analysis_scene_path()
	if not scene_path.is_empty() and ResourceLoader.exists(scene_path):
		var scene := ResourceLoader.load(scene_path) as PackedScene
		if scene:
			var scene_instance := scene.instantiate()
			if scene_instance is Stage:
				var stage := scene_instance as Stage
				stage.definition = self
				parent.add_child(stage)
				return stage
			if scene_instance != null:
				scene_instance.free()
	if not preview_scene_path.is_empty():
		return null
	var fallback := instantiate()
	if fallback:
		parent.add_child(fallback)
	return fallback

func apply_blackboard(stage: Stage) -> void:
	_migrate()
	stage.external_calls.assign(external_calls)
	stage.external_vars.assign(external_vars)
	stage.external_writers.clear()
	for writer: BlackboardWriterData in external_writers:
		if writer != null:
			var copy := writer.duplicate_data()
			if copy.source.is_empty():
				copy.source = &"gameplay"
			stage.external_writers.append(copy)
	stage.payload_schema = payload_schema()
	if stage.engine != null:
		stage.engine.payload_schema = stage.payload_schema
	for variable: VariableData in variables:
		match variable.scope:
			"saved": stage.define_saved(variable.key, variable.default_value, variable.state_key)
			"shared": stage.define_shared(variable.key, variable.default_value, variable.state_key)
			"session": stage.define_session(variable.key, variable.default_value, variable.state_key)
			_: stage.define_local(variable.key, variable.default_value, variable.state_key)
		for alias in variable.aliases:
			stage.bb.alias(alias, variable.key)
	stage.collect_scene_blackboard_writers()

func payload_schema() -> Dictionary:
	_migrate()
	var schema := {}
	# Built-in change notifications have a fixed envelope. The transition values
	# remain Variant-typed because each Blackboard key may declare a different type.
	schema["on_change"] = {
		&"key": TYPE_STRING,
		&"previous": TYPE_NIL,
		&"value": TYPE_NIL,
		&"scope": TYPE_STRING,
		&"writer": TYPE_STRING,
	}
	for field: PayloadFieldData in payload_fields:
		if field.event_id.is_empty() or field.key.is_empty():
			continue
		if field.event_id == "on_change":
			continue # This built-in event has a fixed runtime payload envelope.
		if not schema.has(field.event_id):
			schema[field.event_id] = {}
		schema[field.event_id][field.key] = field.value_type()
	return schema

func apply_graph(stage: Stage) -> Array[String]:
	_migrate()
	var problems: Array[String] = []
	var built: Array[Rule] = []
	var catalog := RuntimeVerbCatalog.from_factory(stage.verbs)
	var inputs := {}
	var script: Script = stage.get_script()
	while script:
		inputs.merge(script.get_script_constant_map())
		script = script.get_base_script()
	for prop in RuntimeVerbCatalog.props_of(stage):
		inputs[prop["name"]] = stage.get(prop["name"])
	for entry: RuleData in rules:
		var rule := Rule.new(entry.id, entry.trigger)
		rule.state_key = entry.state_key
		rule.requires.assign(entry.requires)
		rule.forbids.assign(entry.forbids)
		rule.cancel_if.assign(entry.cancel_if)
		rule.one_shot = entry.one_shot
		rule.allow_overlap = entry.allow_overlap
		var reentry: Variant = entry.reentry
		if not (reentry is int and Rule.ReentryPolicy.values().has(reentry)):
			problems.append("rule '%s' has an invalid re-entry policy: %s" % [rule.id, reentry])
		else:
			rule.reentry = reentry as Rule.ReentryPolicy
		if rule.one_shot and rule.reentry != Rule.ReentryPolicy.IGNORE:
			problems.append("rule '%s' is one-shot and must use Ignore re-entry" % rule.id)
		rule.emits = entry.emit
		for spec: StepData in entry.steps:
			var step := _build_step(stage, entry.trigger, stage.verbs, spec, catalog, inputs)
			if step == null:
				problems.append("rule '%s' has an invalid step: %s" % [rule.id, ExprText.step_text(spec.to_dictionary())])
				# Keep an inert placeholder so following steps retain their metadata indices.
				step = Step.new(func(_context: Dictionary) -> void: pass)
				step.verb = spec.verb
			rule.steps.append(step)
		built.append(rule)
	stage.verbs.runtime_input_event = &""
	stage.engine.rules.append_array(built)
	stage.engine.trigger_routing.clear()
	for route: TriggerRoutingData in trigger_routing:
		if route != null and route.mode == TriggerRoutingData.Mode.FIRST_MATCH:
			stage.engine.trigger_routing[route.trigger] = {
				"mode": route.mode, "fallback_rule_id": route.fallback_rule_id}
	return problems

func _build_step(stage: Stage, event: StringName, factory: CoreVerbs, spec: StepData,
		catalog: Array, inputs: Dictionary) -> Step:
	if spec.verb in [&"parallel", &"conditional", &"random"]:
		var branches: Array[Array] = []
		for branch_data: Array in spec.parallel_branches:
			var branch: Array[Step] = []
			for child: StepData in branch_data:
				var child_step := _build_step(stage, event, factory, child, catalog, inputs)
				if child_step == null:
					return null
				branch.append(child_step)
			branches.append(branch)
		var group: Step
		if spec.verb == &"conditional":
			var conditions: Array[StringName] = []
			for expression in spec.branch_conditions:
				conditions.append(StringName(expression))
			group = Step.conditional(conditions, branches, spec.default_branch_index)
		elif spec.verb == &"random":
			group = Step.random_choice(branches, spec.branch_weights, spec.random_seed,
				spec.group_id, spec.random_selection)
		else:
			group = Step.parallel(branches, spec.join_parallel)
		group.group_id = spec.group_id
		var group_delay := _evaluate_step_delay(spec.delay, inputs, factory)
		if group_delay == null or float(group_delay) < 0.0:
			return null
		group.delay = float(group_delay)
		return group
	var verb := String(spec.verb)
	var signature := RuntimeVerbCatalog.find(catalog, verb)
	if signature.is_empty():
		return null
	var delay := spec.delay
	var source := "[[%s], %s]" % [", ".join(spec.args), delay if not delay.is_empty() else "0.0"]
	factory.runtime_input_event = event
	# Expression accepts the StringName constructor in place of GDScript's &"..." literals.
	if _string_token_pattern == null:
		_string_token_pattern = RegEx.create_from_string('(&?)("(?:[^"\\\\]|\\\\.)*")')
	var matches := _string_token_pattern.search_all(source)
	matches.reverse()
	for token in matches:
		if token.get_string(1) != "":
			source = source.left(token.get_start()) + "StringName(%s)" % token.get_string(2) + source.substr(token.get_end())
	var expression := Expression.new()
	if expression.parse(source, PackedStringArray(inputs.keys())) != OK:
		return null
	var values: Variant = expression.execute(inputs.values(), factory, false)
	if expression.has_execute_failed() or not values is Array or values.size() != 2:
		return null
	if not (values[1] is float or values[1] is int):
		return null

	# Invoke the factory with the evaluated arguments. Expression reports argument
	# and type errors without invoking the verb twice or logging a script error.
	var authored_args: Array = values[0]
	if verb in ["wait_for_call", "wait_until"] and not RuleValidator.wait_argument_error(spec.verb, authored_args).is_empty():
		return null
	if not _runtime_references_fit_known_schema(stage, verb, authored_args):
		return null
	var args: Array = []
	var has_runtime_inputs := false
	var parameters: Array = signature.get("args", [])
	for i in authored_args.size():
		var argument_type: int = parameters[i]["type"] if i < parameters.size() else TYPE_NIL
		var prepared := _prepare_runtime_inputs(authored_args[i], argument_type)
		if not prepared["ok"]:
			return null
		if prepared["dynamic"] and not _supports_runtime_input(verb, i):
			return null
		has_runtime_inputs = has_runtime_inputs or prepared["dynamic"]
		args.append(prepared["value"])
	var names := PackedStringArray()
	for i in args.size():
		names.append("arg_%d" % i)
	if expression.parse("%s(%s)" % [verb, ", ".join(names)], names) != OK:
		return null
	var result: Variant = expression.execute(args, factory, false)
	if expression.has_execute_failed() or not result is Step:
		return null
	var step := result as Step
	step.verb = StringName(verb)
	step.args = authored_args if verb == "emit_relay" and has_runtime_inputs else args
	var runtime_reads: Array[StringName] = []
	for argument: Variant in authored_args:
		_collect_runtime_blackboard_reads(argument, runtime_reads)
	for key: StringName in runtime_reads:
		if not step.reads.has(key):
			step.reads.append(key)
	if has_runtime_inputs:
		var verb_callable := Callable(factory, verb)
		var authored_runtime_args: Array = authored_args.duplicate()
		var expected_types: Array[int] = []
		for param: Dictionary in parameters:
			expected_types.append(param["type"])
		step.fn = func(run_context: Dictionary) -> Variant:
			var resolved_args: Array = []
			for i in authored_runtime_args.size():
				var expected_type: int = expected_types[i] if i < expected_types.size() else TYPE_NIL
				var resolved := {"ok": true, "value": authored_runtime_args[i]}
				if not (verb == "emit_relay" and i == 1):
					resolved = _resolve_runtime_inputs(authored_runtime_args[i], run_context, stage.bb, expected_type)
				if not resolved["ok"]:
					push_warning("Callboard skipped step '%s': %s" % [verb, resolved["error"]])
					return null
				resolved_args.append(resolved["value"])
			if not _resolved_values_fit_blackboard(stage.bb, verb, resolved_args):
				push_warning("Callboard skipped step '%s': resolved values do not match the Blackboard schema." % verb)
				return null
			var live_step: Variant = verb_callable.callv(resolved_args)
			if not live_step is Step:
				push_warning("Callboard skipped '%s': its runtime arguments did not produce a valid Step." % verb)
				return null
			return live_step.fn.call(run_context)
	if not delay.is_empty():
		step.after(float(values[1]))
	return step

func _evaluate_step_delay(source: String, inputs: Dictionary, base: Object) -> Variant:
	if source.is_empty():
		return 0.0
	var expression := Expression.new()
	if expression.parse(source, PackedStringArray(inputs.keys())) != OK:
		return null
	var value: Variant = expression.execute(inputs.values(), base, false)
	if expression.has_execute_failed() or not (value is int or value is float):
		return null
	return value

func _supports_runtime_input(verb: String, index: int) -> bool:
	return ((verb in ["set_var", "add_var", "say", "say_key"] and index == 1)
		or (verb == "say_key" and index == 2)
		or (verb == "score" and index == 0)
		or (verb in ["gameplay_event", "emit_relay", "emit_cross_stage"] and index == 1))

func _collect_runtime_blackboard_reads(value: Variant, reads: Array[StringName]) -> void:
	if value is RuntimeInputRefScript:
		var input = value as RuntimeInputRefScript
		if input.source == RuntimeInputRefScript.Source.BLACKBOARD and not reads.has(input.key):
			reads.append(input.key)
	elif value is Dictionary:
		for key: Variant in value:
			_collect_runtime_blackboard_reads(value[key], reads)
	elif value is Array:
		for item: Variant in value:
			_collect_runtime_blackboard_reads(item, reads)

func _runtime_references_fit_known_schema(stage: Stage, verb: String, args: Array) -> bool:
	if verb == "set_var" and args.size() > 1 and args[0] is StringName:
		var value: Variant = args[1]
		if value is RuntimeInputRefScript:
			var key: StringName = stage.bb.resolve_key(args[0])
			var target_type: int = stage.bb.schema.get(key, {}).get("type", TYPE_NIL)
			if value.value_type != TYPE_NIL and not _runtime_types_compatible(value.value_type, target_type):
				return false
	if verb == "add_var" and args.size() > 1 and args[0] is StringName:
		var delta: Variant = args[1]
		var key: StringName = stage.bb.resolve_key(args[0])
		var target_type: int = stage.bb.schema.get(key, {}).get("type", TYPE_NIL)
		if delta is RuntimeInputRefScript:
			if delta.value_type != TYPE_NIL and delta.value_type not in [TYPE_INT, TYPE_FLOAT]:
				return false
			if target_type == TYPE_INT and delta.value_type == TYPE_FLOAT:
				return false
	if verb == "emit_relay" and args.size() > 1 and args[0] is StringName and args[1] is Dictionary:
		var relay_event := StringName("relay:" + String(args[0]))
		var relay_schema: Dictionary = stage.payload_schema.get(relay_event, {})
		for output_field: Variant in args[1]:
			var source: Variant = args[1][output_field]
			if stage.payload_schema.has(relay_event) and not relay_schema.has(StringName(String(output_field))):
				return false
			if source is RuntimeInputRefScript and relay_schema.has(StringName(String(output_field))):
				var target_type: int = relay_schema[StringName(String(output_field))]
				if source.value_type != TYPE_NIL and not _runtime_types_compatible(source.value_type, target_type):
					return false
	return true

func _resolved_values_fit_blackboard(bb: Blackboard, verb: String, args: Array) -> bool:
	if verb not in ["set_var", "add_var"] or args.size() < 2 or not args[0] is StringName:
		return true
	var key: StringName = bb.resolve_key(args[0])
	if not bb.schema.has(key):
		return false
	var expected: int = bb.schema[key].get("type", TYPE_NIL)
	var actual: int = typeof(args[1])
	if verb == "add_var" and expected not in [TYPE_INT, TYPE_FLOAT]:
		return false
	if verb == "add_var" and expected == TYPE_INT and actual == TYPE_FLOAT:
		return is_equal_approx(float(args[1]), roundf(float(args[1])))
	if expected == TYPE_FLOAT and actual == TYPE_INT:
		return true
	return actual == expected and (verb != "add_var" or actual in [TYPE_INT, TYPE_FLOAT])

func _prepare_runtime_inputs(value: Variant, expected_type: int) -> Dictionary:
	if value is RuntimeInputRefScript:
		var input = value as RuntimeInputRefScript
		if not input.valid:
			return {"ok": false, "error": input.issue}
		if input.value_type != TYPE_NIL and not _runtime_types_compatible(input.value_type, expected_type):
			return {"ok": false, "error": "source '%s' has type %s, which is incompatible with argument type %s" % [
				input.key, type_string(input.value_type), type_string(expected_type)]}
		var placeholder_type: int = input.value_type if input.value_type != TYPE_NIL else expected_type
		return {"ok": true, "dynamic": true, "value": _runtime_placeholder(placeholder_type)}
	if value is Dictionary:
		var output := {}
		var dynamic := false
		for key: Variant in value:
			var child := _prepare_runtime_inputs(value[key], TYPE_NIL)
			if not child["ok"]:
				return child
			output[key] = child["value"]
			if child["dynamic"]:
				dynamic = true
		return {"ok": true, "dynamic": dynamic, "value": output}
	if value is Array:
		var output: Array = []
		var dynamic := false
		for item: Variant in value:
			var child := _prepare_runtime_inputs(item, TYPE_NIL)
			if not child["ok"]:
				return child
			output.append(child["value"])
			if child["dynamic"]:
				dynamic = true
		return {"ok": true, "dynamic": dynamic, "value": output}
	return {"ok": true, "dynamic": false, "value": value}

func _resolve_runtime_inputs(value: Variant, run_context: Dictionary, bb: Blackboard,
		expected_type := TYPE_NIL) -> Dictionary:
	if value is RuntimeInputRefScript:
		var input = value as RuntimeInputRefScript
		var resolved: Variant
		if input.source == RuntimeInputRefScript.Source.PAYLOAD:
			var payload: Dictionary = run_context.get("payload", {})
			if payload.has(input.key):
				resolved = payload[input.key]
			elif payload.has(String(input.key)):
				resolved = payload[String(input.key)]
			else:
				return {"ok": false, "error": "payload field '%s' is missing" % input.key}
		else:
			if not bb.has(input.key):
				return {"ok": false, "error": "Blackboard key '%s' is no longer declared" % input.key}
			resolved = bb.get_var(input.key)
		if input.value_type != TYPE_NIL and typeof(resolved) != input.value_type:
			return {"ok": false, "error": "source '%s' has runtime type %s, expected %s" % [
				input.key, type_string(typeof(resolved)), type_string(input.value_type)]}
		if not _runtime_types_compatible(typeof(resolved), expected_type):
			return {"ok": false, "error": "source '%s' has type %s, incompatible with argument type %s" % [
				input.key, type_string(typeof(resolved)), type_string(expected_type)]}
		if expected_type == TYPE_FLOAT and resolved is int:
			resolved = float(resolved)
		return {"ok": true, "value": resolved}
	if value is Dictionary:
		var output := {}
		for key: Variant in value:
			var child := _resolve_runtime_inputs(value[key], run_context, bb)
			if not child["ok"]:
				return child
			output[key] = child["value"]
		return {"ok": true, "value": output}
	if value is Array:
		var output: Array = []
		for item: Variant in value:
			var child := _resolve_runtime_inputs(item, run_context, bb)
			if not child["ok"]:
				return child
			output.append(child["value"])
		return {"ok": true, "value": output}
	return {"ok": true, "value": value}

func _runtime_types_compatible(source_type: int, target_type: int) -> bool:
	if target_type == TYPE_NIL or source_type == TYPE_NIL or source_type == target_type:
		return true
	return target_type == TYPE_FLOAT and source_type == TYPE_INT

func _runtime_placeholder(value_type: int) -> Variant:
	match value_type:
		TYPE_BOOL: return false
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_STRING: return ""
		TYPE_STRING_NAME: return &""
		TYPE_DICTIONARY: return {}
		TYPE_ARRAY: return []
		_: return null
