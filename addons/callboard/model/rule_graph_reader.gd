@tool
class_name RuleGraphReader extends RefCounted
## Loads and analyzes typed graph drafts for the editor and live board.

static func read(stage: Stage) -> GraphDraft:
	var definition := stage.definition
	if definition == null:
		return GraphDraft.load_error("This stage has no StageDefinition assigned.")
	var data := GraphDraft.new()
	data.definition = definition
	data.managed_lifecycle = definition.managed_lifecycle
	for binding: StageRestorationBinding in definition.restoration_bindings:
		data.restoration_bindings.append(binding.duplicate())
	for rule: RuleData in definition.rules:
		data.rules.append(rule.duplicate_deep(Resource.DEEP_DUPLICATE_ALL))
	for variable: VariableData in definition.variables:
		data.variables.append(variable.duplicate_deep(Resource.DEEP_DUPLICATE_ALL))
	for group: GroupData in definition.groups:
		data.groups.append(group.duplicate())
	data.catalog = VerbCatalog.from_factory(stage.verbs)
	data.props = VerbCatalog.props_of(stage)
	data.external_calls.assign(stage.external_calls)
	data.external_vars.assign(stage.external_vars)
	for writer: BlackboardWriterData in definition.external_writers:
		data.external_writers.append(writer.duplicate_data())
	for field: PayloadFieldData in definition.payload_fields:
		data.payload_fields.append(field.duplicate(true))
	data.call_positions = definition.call_positions.duplicate(true)
	data.scene_analysis_current = true
	_read_results(data, stage)
	return data

## Load authored resources and run checks that do not instantiate a Stage,
## execute Stage hooks, invoke custom verb factories, or evaluate step arguments.
static func inspect_definition_resources(path: String) -> GraphDraft:
	var definition := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StageDefinition
	if definition == null:
		return GraphDraft.load_error("Cannot load StageDefinition from %s" % path)
	definition._migrate()
	var data := GraphDraft.new()
	data.definition = definition
	data.managed_lifecycle = definition.managed_lifecycle
	for binding: StageRestorationBinding in definition.restoration_bindings:
		data.restoration_bindings.append(binding.duplicate())
	for rule: RuleData in definition.rules:
		data.rules.append(rule.duplicate_deep(Resource.DEEP_DUPLICATE_ALL))
	for variable: VariableData in definition.variables:
		data.variables.append(variable.duplicate_deep(Resource.DEEP_DUPLICATE_ALL))
	for group: GroupData in definition.groups:
		data.groups.append(group.duplicate())
	data.external_calls.assign(definition.external_calls)
	data.external_vars.assign(definition.external_vars)
	for writer: BlackboardWriterData in definition.external_writers:
		data.external_writers.append(writer.duplicate_data())
	for field: PayloadFieldData in definition.payload_fields:
		data.payload_fields.append(field.duplicate(true))
	data.call_positions = definition.call_positions.duplicate(true)
	var bb := Blackboard.new()
	data.catalog = RuntimeVerbCatalog.from_factory(StagingVerbs.new(StepContext.new(bb, null, null, Callable())))
	validate_resources(data)
	return data

## Validate authored structure without invoking project code. Checks that need
## scene props, custom verbs, or expression values are left for `analyze()`.
static func validate_resources(data: GraphDraft) -> void:
	data.errors.clear()
	data.warnings.clear()
	data.scene_analysis_current = false
	data.step_metadata.clear()
	var keys := {}
	for variable: VariableData in data.variables:
		if variable.key.is_empty() or not variable.key.is_valid_identifier():
			data.errors.append("Blackboard key '%s' is not a valid identifier" % variable.key)
		if keys.has(variable.key):
			data.errors.append("duplicate Blackboard key '%s'" % variable.key)
		keys[variable.key] = variable.default_value
		for alias in variable.aliases:
			keys[alias] = variable.default_value
	for key: StringName in data.external_vars:
		keys[key] = null
	for writer: BlackboardWriterData in data.external_writers:
		if writer != null:
			keys[writer.key] = null
	var payloads := {}
	for field: PayloadFieldData in data.payload_fields:
		if field.key.is_empty() or not field.key.is_valid_identifier() or field.key in [&"payload", &"_callboard"]:
			data.errors.append("payload field '%s' has an invalid name" % field.key)
		if field.type_name not in ["bool", "int", "float", "String"]:
			data.errors.append("payload field '%s' has an unsupported type '%s'" % [field.key, field.type_name])
		if not payloads.has(field.event_id):
			payloads[field.event_id] = {}
		if payloads[field.event_id].has(field.key):
			data.errors.append("payload field '%s' is declared more than once for '%s'" % [field.key, field.event_id])
		payloads[field.event_id][field.key] = field.value_type()
	var seen_rules := {}
	var custom_verbs := {}
	var emitted := {}
	var listening := {}
	for rule: RuleData in data.rules:
		if rule.id.is_empty() or not rule.id.is_valid_identifier():
			data.errors.append("rule ID '%s' is not a valid identifier" % rule.id)
		if seen_rules.has(rule.id):
			data.errors.append("duplicate rule id '%s'" % rule.id)
		seen_rules[rule.id] = true
		if rule.trigger.is_empty():
			data.warnings.append("rule '%s' has no trigger" % rule.id)
		else:
			listening[rule.trigger] = true
		if rule.one_shot and rule.reentry != Rule.ReentryPolicy.IGNORE:
			data.errors.append("rule '%s' is one-shot and must use Ignore re-entry" % rule.id)
		if rule.reentry not in Rule.ReentryPolicy.values():
			data.errors.append("rule '%s' has an invalid re-entry policy" % rule.id)
		if rule.steps.is_empty() and rule.emit.is_empty():
			data.warnings.append("rule '%s' has no steps or completion relay" % rule.id)
		if not rule.emit.is_empty():
			emitted[StringName("relay:" + String(rule.emit))] = true
		for guard: StringName in rule.requires + rule.forbids + rule.cancel_if:
			var parsed := GuardExpression.parse(String(guard))
			if not parsed["ok"]:
				data.errors.append("rule '%s' has an invalid guard '%s'" % [rule.id, guard])
			elif parsed["payload"] and payloads.has(rule.trigger):
				if not parsed.get("presence", "").is_empty() or parsed["comparison"]:
					if not payloads[rule.trigger].has(parsed["key"]):
						data.errors.append("rule '%s' checks undeclared payload field '%s' for trigger '%s'" % [rule.id, parsed["key"], rule.trigger])
			elif not parsed["payload"] and not keys.has(parsed["key"]):
				data.warnings.append("rule '%s' checks key '%s', which is not declared in the StageDefinition; scene analysis will check script-defined keys" % [rule.id, parsed["key"]])
		for step: StepData in rule.steps:
			if step.verb.is_empty():
				data.errors.append("rule '%s' has a step with no verb" % rule.id)
			elif RuntimeVerbCatalog.find(data.catalog, String(step.verb)).is_empty():
				custom_verbs[step.verb] = true
			if step.verb in [&"wait_for_call", &"wait_until"]:
				_analyze_wait(data, rule, step, emitted, listening)
			if step.verb == &"repeat_emit" and step.args.size() > 1:
				var relay := ExprText.parse_literal(step.args[1])
				if relay.ok and relay.value is StringName and not relay.value.is_empty():
					emitted[StringName("relay:" + String(relay.value))] = true
					var metadata := GraphDraft.StepAnalysis.new()
					metadata.relay = String(relay.value)
					metadata.relay_argument = 1
					data.step_metadata[step] = metadata
			if step.verb == &"emit_relay":
				if step.args.is_empty():
					data.errors.append("rule '%s' emit_relay step is missing its relay name" % rule.id)
				else:
					var relay_result := ExprText.parse_literal(step.args[0])
					if relay_result.ok and (relay_result.value is StringName or relay_result.value is String):
						var relay_name := String(relay_result.value)
						if relay_name.is_empty() or not relay_name.is_valid_identifier():
							data.errors.append("rule '%s' emit_relay relay name must be a non-empty identifier" % rule.id)
						else:
							emitted[StringName("relay:" + relay_name)] = true
							var metadata := GraphDraft.StepAnalysis.new()
							metadata.relay = relay_name
							metadata.relay_argument = 0
							data.step_metadata[step] = metadata
							if step.args.size() > 1:
								var mapping := ExprText.parse_literal(step.args[1])
								if mapping.ok and mapping.value is Dictionary:
									_validate_resource_relay_mapping(rule, relay_name, mapping.value, payloads, data.errors)
								elif mapping.ok:
									data.errors.append("rule '%s' emit_relay field_map must be a Dictionary" % rule.id)
								else:
									data.warnings.append("rule '%s' emit_relay field_map needs scene analysis for static type checks" % rule.id)
					else:
						data.warnings.append("rule '%s' emit_relay relay name needs scene analysis before its connection can be identified" % rule.id)
			if not step.delay.is_empty():
				var delay := ExprText.parse_literal(step.delay)
				if delay.ok and not (delay.value is int or delay.value is float):
					data.errors.append("rule '%s' step delay must be numeric" % rule.id)
				elif delay.ok and float(delay.value) < 0.0:
					data.errors.append("rule '%s' step delay must be zero or greater" % rule.id)
	for event_id in emitted:
		if not listening.has(event_id):
			data.warnings.append("'%s' is emitted but no rule listens to it" % event_id)
	if not custom_verbs.is_empty():
		var names: Array = custom_verbs.keys()
		names.sort()
		data.warnings.append("Custom verbs require scene analysis: %s" % ", ".join(names))

static func _analyze_wait(data: GraphDraft, rule: RuleData, step: StepData,
		emitted: Dictionary, listening: Dictionary) -> void:
	var args: Array = []
	for source in step.args:
		var literal := ExprText.parse_literal(source)
		if not literal.ok:
			data.warnings.append("rule '%s' %s arguments need scene analysis" % [rule.id, step.verb])
			return
		args.append(literal.value)
	var issue := RuleValidator.wait_argument_error(step.verb, args)
	if not issue.is_empty():
		data.errors.append("rule '%s' %s %s" % [rule.id, step.verb, issue])
		return
	if step.verb == &"wait_for_call":
		listening[StringName(args[0])] = true
	var relay_arg := 3 if step.verb == &"wait_for_call" else 2
	if args.size() > relay_arg and not String(args[relay_arg]).is_empty():
		var metadata := GraphDraft.StepAnalysis.new()
		metadata.relay = String(args[relay_arg])
		metadata.relay_argument = relay_arg
		data.step_metadata[step] = metadata
		emitted[StringName("relay:" + metadata.relay)] = true

static func _validate_resource_relay_mapping(rule: RuleData, relay_name: String,
		field_map: Dictionary, payloads: Dictionary, errors: Array[String]) -> void:
	var input_schema: Dictionary = payloads.get(rule.trigger, {})
	var relay_event := StringName("relay:" + relay_name)
	var output_schema: Dictionary = payloads.get(relay_event, {})
	for output_field: Variant in field_map:
		var input_field: Variant = field_map[output_field]
		if not (output_field is String or output_field is StringName) or not (input_field is String or input_field is StringName):
			errors.append("rule '%s' emit_relay field mappings must use String or StringName field names" % rule.id)
			continue
		var output_name := StringName(String(output_field))
		var input_name := StringName(String(input_field))
		if not output_name.is_valid_identifier() or not input_name.is_valid_identifier():
			errors.append("rule '%s' emit_relay maps invalid field name '%s' to '%s'" % [rule.id, output_name, input_name])
			continue
		if payloads.has(rule.trigger) and not input_schema.has(input_name):
			errors.append("rule '%s' emit_relay reads undeclared input field '%s' for '%s'" % [rule.id, input_name, rule.trigger])
			continue
		if payloads.has(relay_event) and not output_schema.has(output_name):
			errors.append("rule '%s' emit_relay writes undeclared output field '%s' for '%s'" % [rule.id, output_name, relay_event])
			continue
		var input_type: int = input_schema.get(input_name, TYPE_NIL)
		var output_type: int = output_schema.get(output_name, TYPE_NIL)
		if input_schema.has(input_name) and output_schema.has(output_name) and input_type != TYPE_NIL \
				and input_type != output_type and not (output_type == TYPE_FLOAT and input_type == TYPE_INT):
			errors.append("rule '%s' emit_relay maps '%s' (%s) to '%s' (%s) with incompatible types" % [
				rule.id, input_name, type_string(input_type),
				output_name, type_string(output_type)])

## Scene-backed analysis. This instantiates the preview and executes Stage build
## hooks, the verb factory, and authored argument expressions. Call explicitly
## from Analyze Scene or Save; ordinary editing should use validate_resources().
## A retained reusable instance avoids rebuilding props on repeated analyses.
static func analyze(data: GraphDraft, cached_stage: Stage = null, retain_instance := false) -> Stage:
	var draft := make_definition(data)
	var tree := Engine.get_main_loop() as SceneTree
	var instance: Stage
	var reused := false
	if cached_stage != null and is_instance_valid(cached_stage):
		if cached_stage.can_reuse_analysis_props():
			instance = cached_stage
			if tree and instance.get_parent() != tree.root:
				if instance.get_parent():
					instance.get_parent().remove_child(instance)
				tree.root.add_child(instance)
			reused = instance.rebuild_for_analysis(draft)
		if not reused:
			if cached_stage.get_parent():
				cached_stage.get_parent().remove_child(cached_stage)
			cached_stage.free()
	if not reused:
		instance = draft.instantiate_for_analysis(tree.root) if tree else draft.instantiate()
	if instance == null:
		data.errors.assign([_analysis_error(draft)])
		data.warnings.clear()
		data.step_metadata.clear()
		return null
	if instance.bb == null:
		instance.build()
	_read_results(data, instance)
	instance.engine.rules.clear()
	if instance.get_parent():
		instance.get_parent().remove_child(instance)
	if retain_instance and instance.can_reuse_analysis_props():
		return instance
	instance.free()
	return null

static func make_definition(data: GraphDraft) -> StageDefinition:
	var original := data.definition
	var draft := StageDefinition.new()
	draft.stage_script = original.stage_script
	draft.preview_scene_path = original.preview_scene_path
	draft.managed_lifecycle = data.managed_lifecycle
	for binding: StageRestorationBinding in data.restoration_bindings:
		draft.restoration_bindings.append(binding.duplicate())
	draft.set_meta(StageDefinition.ANALYSIS_SCENE_SOURCE_META, original.analysis_source_path())
	draft.external_calls = PackedStringArray(data.external_calls)
	draft.external_vars = PackedStringArray(data.external_vars)
	for writer: BlackboardWriterData in data.external_writers:
		draft.external_writers.append(writer.duplicate_data())
	draft.payload_fields = data.payload_fields.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	draft.call_positions = data.call_positions.duplicate(true)
	# The analysis scene and resource saver each get an independent copy.
	draft.variables = data.variables.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	draft.rules = data.rules.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	draft.groups = data.groups.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	draft._migrate()
	return draft

## Scene-backed inspection for runtime/editor tests and explicit preview analysis.
static func inspect_definition(path: String) -> GraphDraft:
	var definition := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StageDefinition
	if definition == null:
		return GraphDraft.load_error("Cannot load StageDefinition from %s" % path)
	var tree := Engine.get_main_loop() as SceneTree
	var instance := definition.instantiate_for_analysis(tree.root) if tree else definition.instantiate()
	if instance == null:
		return GraphDraft.load_error(_analysis_error(definition))
	if instance.bb == null:
		instance.build()
	var data := read(instance)
	instance.engine.rules.clear()
	if instance.get_parent():
		instance.get_parent().remove_child(instance)
	instance.free()
	return data

static func _analysis_error(definition: StageDefinition) -> String:
	if not definition.preview_scene_path.is_empty():
		return "Preview scene '%s' must load and have a Stage root." % definition.preview_scene_path
	return "Assign a script extending Stage to the StageDefinition."

static func _read_results(data: GraphDraft, stage: Stage) -> void:
	data.scene_analysis_current = true
	data.catalog = RuntimeVerbCatalog.from_factory(stage.verbs)
	data.props = RuntimeVerbCatalog.props_of(stage)
	data.errors.assign(stage.graph_errors)
	data.warnings.assign(stage.check())
	data.step_metadata.clear()
	# Match by ID because a live Stage may have added or removed runtime rules.
	var compiled_by_id: Dictionary[StringName, Rule] = {}
	for rule in stage.engine.rules:
		if not compiled_by_id.has(rule.id):
			compiled_by_id[rule.id] = rule
	for authored in data.rules:
		var compiled := compiled_by_id.get(authored.id) as Rule
		if compiled == null or compiled.steps.size() != authored.steps.size():
			continue
		for step_index in authored.steps.size():
			var runtime_step := compiled.steps[step_index]
			# Copy analysis metadata only. The callable may capture scene nodes.
			var metadata := GraphDraft.StepAnalysis.new()
			metadata.relay = String(runtime_step.emits)
			metadata.relay_argument = runtime_step.emit_arg
			data.step_metadata[authored.steps[step_index]] = metadata
