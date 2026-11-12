@tool
class_name StageDefinition extends Resource
## Authored data shared by the runtime and the Callboard.

const CURRENT_FORMAT_VERSION := 2

@export var stage_script: GDScript
@export var external_calls := PackedStringArray()
@export var external_vars := PackedStringArray()
@export var variables: Array = []
var _rules: Array = []
@export var rules: Array:
	get:
		return _rules
	set(value):
		_rules = _normalize_rules(value)
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
	_rules = _normalize_rules(_rules)
	format_version = maxi(format_version, CURRENT_FORMAT_VERSION)

static func _normalize_rules(source: Array) -> Array:
	var normalized: Array = source
	for entry in normalized:
		if not entry is Dictionary:
			continue
		if not entry.has("one_shot"):
			entry["one_shot"] = entry.get("once", false)
		entry.erase("once")
		entry["emit"] = entry.get("emit", "")
		entry["state_key"] = entry.get("state_key", entry.get("id", ""))
		entry["requires"] = entry.get("requires", [])
		entry["forbids"] = entry.get("forbids", [])
		entry["cancel_if"] = entry.get("cancel_if", [])
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

func apply_blackboard(stage: Stage) -> void:
	_migrate()
	stage.external_calls.assign(external_calls)
	stage.external_vars.assign(external_vars)
	for variable in variables:
		var key := StringName(variable["key"])
		var state_key := StringName(variable.get("state_key", ""))
		if variable["scope"] == "saved":
			stage.define_saved(key, variable["default"], state_key)
		else:
			stage.define_local(key, variable["default"], state_key)

func apply_graph(stage: Stage) -> Array[String]:
	_migrate()
	var problems: Array[String] = []
	var built: Array[Rule] = []
	var catalog := VerbCatalog.from_factory(stage.verbs)
	var inputs := {}
	var script: Script = stage.get_script()
	while script:
		inputs.merge(script.get_script_constant_map())
		script = script.get_base_script()
	for prop in VerbCatalog.props_of(stage):
		inputs[prop["name"]] = stage.get(prop["name"])
	for entry in rules:
		var rule := Rule.new(StringName(entry["id"]), StringName(entry["trigger"]))
		rule.state_key = StringName(entry.get("state_key", ""))
		rule.requires.assign(entry["requires"])
		rule.forbids.assign(entry["forbids"])
		rule.cancel_if.assign(entry["cancel_if"])
		rule.one_shot = entry["one_shot"]
		var reentry: Variant = entry.get("reentry", Rule.ReentryPolicy.IGNORE)
		if not (reentry is int and Rule.ReentryPolicy.values().has(reentry)):
			problems.append("rule '%s' has an invalid re-entry policy: %s" % [rule.id, reentry])
			continue
		rule.reentry = reentry as Rule.ReentryPolicy
		rule.emits = StringName(entry["emit"])
		for spec in entry["steps"]:
			var step := _build_step(stage.verbs, spec, catalog, inputs)
			if step == null:
				problems.append("rule '%s' has an invalid step: %s" % [rule.id, ExprText.step_text(spec)])
			else:
				rule.steps.append(step)
		built.append(rule)
	if problems.is_empty():
		stage.engine.rules.append_array(built)
	return problems

func _build_step(factory: CoreVerbs, spec: Dictionary, catalog: Array, inputs: Dictionary) -> Step:
	var verb: String = spec["verb"]
	if VerbCatalog.find(catalog, verb).is_empty():
		return null
	var delay: String = spec.get("delay", "")
	var source := "[[%s], %s]" % [", ".join(spec["args"]), delay if not delay.is_empty() else "0.0"]
	# Expression accepts the StringName constructor in place of GDScript's &"..." literals.
	var tokens := RegEx.create_from_string('(&?)("(?:[^"\\\\]|\\\\.)*")')
	var matches := tokens.search_all(source)
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
