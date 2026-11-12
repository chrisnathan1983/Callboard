@tool
class_name RuleGraphReader extends RefCounted
## Assembles the editable data the Callboard works on.
##
## Steps carry relay and Blackboard metadata copied from built Step objects.

static func read(stage: Stage) -> Dictionary:
	var definition := stage.definition
	if definition == null:
		return {"error": "This stage has no StageDefinition assigned."}
	var data := {
		"path": definition.resource_path, "definition": definition,
		"vars": definition.variables.duplicate(true),
		"rules": definition.rules.duplicate(true), "groups": definition.groups.duplicate(true),
		"catalog": VerbCatalog.from_factory(stage.verbs), "props": VerbCatalog.props_of(stage),
		"external_calls": Array(stage.external_calls).map(func(e): return String(e)),
	}
	_read_results(data, stage, stage.graph_errors.is_empty(), stage.graph_errors + stage.check())
	return data

## Builds and validates a draft stage, then copies step metadata back onto the model.
static func analyze(data: Dictionary) -> void:
	var draft := make_definition(data)
	var instance := draft.instantiate()
	if instance == null:
		_read_results(data, null, false, ["Stage Script must extend Stage."])
		return
	instance.build()
	_read_results(data, instance, instance.graph_errors.is_empty(), instance.graph_errors + instance.check())
	instance.engine.rules.clear()
	instance.free()

static func make_definition(data: Dictionary) -> StageDefinition:
	var original: StageDefinition = data["definition"]
	var draft := StageDefinition.new()
	draft.stage_script = original.stage_script
	draft.external_calls = PackedStringArray(data["external_calls"])
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
	var definition := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StageDefinition
	if definition == null:
		return {"error": "Cannot load StageDefinition from %s" % path}
	var instance := definition.instantiate()
	if instance == null:
		return {"error": "Assign a Stage script to %s" % path.get_file()}
	instance.build()
	var data := read(instance)
	instance.engine.rules.clear()
	instance.free()
	return data

static func _read_results(data: Dictionary, stage: Stage, ok: bool, problems: Array) -> void:
	data["compiles"] = ok
	data["notes"] = problems
	for rd in data["rules"]:
		for s in rd["steps"]:
			s["emits"] = ""
			s.erase("emit_arg")
			s["sets"] = []
	if stage == null:
		return
	for pr in stage.engine.rules:
		for rd in data["rules"]:
			if rd["id"] == String(pr.id) and rd["steps"].size() == pr.steps.size():
				for i in pr.steps.size():
					rd["steps"][i]["emits"] = String(pr.steps[i].emits)
					if pr.steps[i].emit_arg >= 0:
						rd["steps"][i]["emit_arg"] = pr.steps[i].emit_arg
					rd["steps"][i]["sets"] = pr.steps[i].sets.map(func(k: StringName) -> String: return String(k))
				break
