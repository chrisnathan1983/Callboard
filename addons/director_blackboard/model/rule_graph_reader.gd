@tool
class_name RuleGraphReader extends RefCounted
## Assembles the editable data the Rule Board works on.
##
## Steps carry relay and Blackboard metadata copied from built Step objects.

static func read(zone: Zone) -> Dictionary:
	var definition := zone.definition
	if definition == null:
		return {"error": "This zone has no ZoneDefinition assigned."}
	var data := {
		"path": definition.resource_path, "definition": definition,
		"vars": definition.variables.duplicate(true),
		"rules": definition.rules.duplicate(true), "groups": definition.groups.duplicate(true),
		"catalog": VerbCatalog.from_factory(zone.verbs), "props": VerbCatalog.props_of(zone),
		"external_events": Array(zone.external_events).map(func(e): return String(e)),
	}
	_read_results(data, zone, zone.graph_errors.is_empty(), zone.graph_errors + zone.validate())
	return data

## Builds and validates a draft zone, then copies step metadata back onto the model.
static func analyze(data: Dictionary) -> void:
	var draft := make_definition(data)
	var instance := draft.instantiate()
	if instance == null:
		_read_results(data, null, false, ["Zone Script must extend Zone."])
		return
	instance.build()
	_read_results(data, instance, instance.graph_errors.is_empty(), instance.graph_errors + instance.validate())
	instance.engine.rules.clear()
	instance.free()

static func make_definition(data: Dictionary) -> ZoneDefinition:
	var original: ZoneDefinition = data["definition"]
	var draft := ZoneDefinition.new()
	draft.zone_script = original.zone_script
	draft.external_events = PackedStringArray(data["external_events"])
	draft.external_vars = original.external_vars
	draft.variables = data["vars"].duplicate(true)
	draft.rules = data["rules"].duplicate(true)
	draft.groups = data["groups"].duplicate(true)
	for rule in draft.rules:
		for step in rule["steps"]:
			step.erase("emits")
			step.erase("emit_arg")
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
	var data := read(instance)
	instance.engine.rules.clear()
	instance.free()
	return data

static func _read_results(data: Dictionary, zone: Zone, ok: bool, problems: Array) -> void:
	data["compiles"] = ok
	data["problems"] = problems
	for rd in data["rules"]:
		for s in rd["steps"]:
			s["emits"] = ""
			s.erase("emit_arg")
			s["sets"] = []
	if zone == null:
		return
	for pr in zone.engine.rules:
		for rd in data["rules"]:
			if rd["id"] == String(pr.id) and rd["steps"].size() == pr.steps.size():
				for i in pr.steps.size():
					rd["steps"][i]["emits"] = String(pr.steps[i].emits)
					if pr.steps[i].emit_arg >= 0:
						rd["steps"][i]["emit_arg"] = pr.steps[i].emit_arg
					rd["steps"][i]["sets"] = pr.steps[i].sets.map(func(k: StringName) -> String: return String(k))
				break
