@tool
class_name StageDefinition extends Resource
## Authored data shared by the runtime and the Callboard.

const CURRENT_FORMAT_VERSION := 4
const ANALYSIS_SCENE_SOURCE_META := &"_analysis_scene_source"
static var _string_token_pattern: RegEx

@export var stage_script: GDScript
## Optional scene for Callboard validation. A path avoids a resource cycle
## when the scene itself references this StageDefinition.
@export_file("*.tscn") var preview_scene_path := ""
@export var external_calls := PackedStringArray()
## Canvas positions for external event nodes, keyed by event ID.
@export var call_positions: Dictionary = {}
@export var external_vars := PackedStringArray()
@export var variables: Array = []
@export var rules: Array = []
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
	rules = _normalize_rules(rules)
	variables = _normalize_variables(variables)
	groups = _normalize_groups(groups)
	format_version = maxi(format_version, CURRENT_FORMAT_VERSION)

static func _normalize_rules(source: Array) -> Array:
	var normalized: Array = []
	for entry in source:
		if entry is RuleData:
			normalized.append(entry)
		elif entry is Dictionary:
			normalized.append(RuleData.from_dictionary(entry))
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
	for variable: VariableData in variables:
		if variable.scope == "saved":
			stage.define_saved(variable.key, variable.default_value, variable.state_key)
		else:
			stage.define_local(variable.key, variable.default_value, variable.state_key)
		for alias in variable.aliases:
			stage.bb.alias(alias, variable.key)

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
			var step := _build_step(stage.verbs, spec, catalog, inputs)
			if step == null:
				problems.append("rule '%s' has an invalid step: %s" % [rule.id, ExprText.step_text(spec.to_dictionary())])
				# Keep an inert placeholder so following steps retain their metadata indices.
				step = Step.new(func(_context: Dictionary) -> void: pass)
				step.verb = spec.verb
			rule.steps.append(step)
		built.append(rule)
	stage.engine.rules.append_array(built)
	return problems

func _build_step(factory: CoreVerbs, spec: StepData, catalog: Array, inputs: Dictionary) -> Step:
	var verb := String(spec.verb)
	if RuntimeVerbCatalog.find(catalog, verb).is_empty():
		return null
	var delay := spec.delay
	var source := "[[%s], %s]" % [", ".join(spec.args), delay if not delay.is_empty() else "0.0"]
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
	var args: Array = values[0]
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
	step.args = args
	if not delay.is_empty():
		step.after(float(values[1]))
	return step
