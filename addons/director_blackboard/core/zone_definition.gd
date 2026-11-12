@tool
class_name ZoneDefinition extends Resource
## Authored data shared by the runtime and the Rule Board.

@export var zone_script: GDScript
@export var external_events := PackedStringArray(["arrive"])
@export var external_vars := PackedStringArray()
@export var variables: Array = []
@export var rules: Array = []
@export var groups: Array = []

func instantiate() -> Zone:
	if zone_script == null or not zone_script.can_instantiate():
		return null
	var instance: Variant = zone_script.new()
	if instance is Zone:
		instance.definition = self
		return instance
	if instance is Node:
		instance.free()
	return null

func apply_blackboard(zone: Zone) -> void:
	zone.external_events.assign(external_events)
	zone.external_vars.assign(external_vars)
	for variable in variables:
		var key := StringName(variable["key"])
		if variable["scope"] == "saved":
			zone.define_saved(key, variable["default"])
		else:
			zone.define_local(key, variable["default"])

func apply_graph(zone: Zone) -> Array[String]:
	var problems: Array[String] = []
	var built: Array[Rule] = []
	var catalog := VerbCatalog.from_zone(zone)
	var constants := {}
	var script: Script = zone.get_script()
	while script:
		constants.merge(script.get_script_constant_map())
		script = script.get_base_script()
	for entry in rules:
		var rule := Rule.new(StringName(entry["id"]), StringName(entry["trigger"]))
		rule.requires.assign(entry["requires"])
		rule.forbids.assign(entry["forbids"])
		rule.cancel_if.assign(entry["cancel_if"])
		rule.once = entry["once"]
		rule.emits = StringName(entry["emit"])
		for spec in entry["steps"]:
			var step := _build_step(zone, spec, catalog, constants)
			if step == null:
				problems.append("rule '%s' has an invalid step: %s" % [rule.id, ZoneSource.step_text(spec)])
			else:
				rule.steps.append(step)
		built.append(rule)
	if problems.is_empty():
		zone.rules.append_array(built)
	return problems

func _build_step(zone: Zone, spec: Dictionary, catalog: Array, constants: Dictionary) -> Step:
	var verb: String = spec["verb"]
	if VerbCatalog.find(catalog, verb).is_empty():
		return null
	# One evaluation preserves prop references, literal arguments and script constants.
	var expression := Expression.new()
	# Expression accepts the StringName constructor, while GDScript also has &"..." literals.
	var tokens := RegEx.create_from_string('(&?)("(?:[^"\\\\]|\\\\.)*")')
	var source := ZoneSource.step_text(spec)
	var matches := tokens.search_all(source)
	matches.reverse()
	for token in matches:
		if token.get_string(1) != "":
			source = source.left(token.get_start()) + "StringName(%s)" % token.get_string(2) + source.substr(token.get_end())
	if expression.parse(source, PackedStringArray(constants.keys())) != OK:
		return null
	var result: Variant = expression.execute(constants.values(), zone, false)
	return result as Step if not expression.has_execute_failed() and result is Step else null
