@tool
class_name RuleGraphReader extends RefCounted
## Assembles the editable data the Rule Board works on.
##
## data = ZoneSource model (vars, rules, groups) plus:
##   path, definition    the authored resource (legacy scripts supply source instead)
##   catalog, props      verbs and props discovered from a built zone instance
##   external_events     events the zone declares as coming from outside its rules
##   parse_error         non-empty if the owned functions use syntax the board cannot edit
##   compiles, problems  result of building and validating the draft
## Steps carry `emits` / `sets` copied from the runtime Step objects, so the graph knows
## which relays a verb fires without hard-coding any verb.

## Inspect a zone script without running it: build it on an unparented instance, read it, free it.
static func inspect_script(path: String) -> Dictionary:
	var script := load(path) as GDScript
	if script == null or not script.can_instantiate():
		return {"error": "Cannot load %s" % path}
	var zone = script.new()
	if not zone is Zone:
		if zone is Node:
			zone.free()
		return {"error": "%s is not a Zone" % path}
	zone.build()
	var data := read(zone, path)
	zone.free()
	return data

static func read(zone: Zone, path: String) -> Dictionary:
	if zone.definition:
		var definition := zone.definition
		var resource_data := {
			"path": definition.resource_path, "definition": definition,
			"vars": definition.variables.duplicate(true),
			"rules": definition.rules.duplicate(true), "groups": definition.groups.duplicate(true),
			"catalog": VerbCatalog.from_zone(zone), "props": VerbCatalog.props_of(zone),
			"external_events": Array(zone.external_events).map(func(e): return String(e)),
			"parse_error": "",
		}
		_read_results(resource_data, zone, zone.graph_errors.is_empty(), zone.graph_errors + zone.validate())
		return resource_data
	var source := FileAccess.get_file_as_string(path)
	var parsed := ZoneSource.parse(source)
	var events: Array = []
	for e in zone.external_events:
		events.append(String(e))
	var data := {
		"path": path, "source": source,
		"vars": parsed["vars"], "rules": parsed["rules"], "groups": parsed["groups"],
		"catalog": VerbCatalog.from_zone(zone), "props": VerbCatalog.props_of(zone),
		"external_events": events, "parse_error": parsed["error"],
		"compiles": parsed["ok"], "problems": [],
	}
	if parsed["ok"]:
		analyze(data)
	else:
		data["problems"] = ["This zone cannot be edited on the board: %s" % parsed["error"]]
	return data

## Builds and validates a draft zone, then copies each step's
## runtime `emits` / `sets` back onto the model. Call after every edit.
static func analyze(data: Dictionary) -> void:
	if data.has("definition"):
		var draft := make_definition(data)
		var instance := draft.instantiate()
		if instance == null:
			_read_results(data, null, false, ["Zone Script must extend Zone."])
			return
		instance.build()
		_read_results(data, instance, instance.graph_errors.is_empty(), instance.graph_errors + instance.validate())
		instance.rules.clear()
		instance.free()
		return
	var res := ZonePreview.run(ZoneSource.generate(data["source"], data))
	_read_results(data, res["zone"], res["ok"], res["problems"])
	ZonePreview.dispose(res)

static func make_definition(data: Dictionary) -> ZoneDefinition:
	var original: ZoneDefinition = data["definition"]
	var draft := ZoneDefinition.new()
	draft.zone_script = original.zone_script
	draft.external_events = PackedStringArray(data["external_events"])
	draft.external_vars = original.external_vars
	draft.variables = data["vars"].duplicate(true)
	draft.rules = data["rules"].duplicate(true)
	draft.groups = data["groups"].duplicate(true)
	for variable in draft.variables:
		variable.erase("default_expr")
		variable.erase("note_pad")
	for rule in draft.rules:
		for step in rule["steps"]:
			step.erase("emits")
			step.erase("sets")
	return draft

static func inspect_definition(path: String) -> Dictionary:
	var definition := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ZoneDefinition
	if definition == null:
		return {"error": "Cannot load ZoneDefinition from %s" % path}
	var instance := definition.instantiate()
	if instance == null:
		return {"error": "Assign a Zone script to %s" % path.get_file()}
	instance.build()
	var data := read(instance, path)
	instance.rules.clear()
	instance.free()
	return data

static func _read_results(data: Dictionary, zone: Zone, ok: bool, problems: Array) -> void:
	data["compiles"] = ok
	data["problems"] = problems
	for rd in data["rules"]:
		for s in rd["steps"]:
			s["emits"] = ""
			s["sets"] = []
	if zone == null:
		return
	for pr in zone.rules:
		for rd in data["rules"]:
			if rd["id"] == String(pr.id) and rd["steps"].size() == pr.steps.size():
				for i in pr.steps.size():
					rd["steps"][i]["emits"] = String(pr.steps[i].emits)
					rd["steps"][i]["sets"] = pr.steps[i].sets.map(func(k: StringName) -> String: return String(k))
				break
