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
		"vars": definition.variables.map(func(v: VariableData) -> Dictionary: return v.to_dictionary()),
		"rules": definition.rules.map(func(r: RuleData) -> Dictionary: return r.to_dictionary()),
		"groups": definition.groups.map(func(g: GroupData) -> Dictionary: return g.to_dictionary()),
		"catalog": VerbCatalog.from_factory(stage.verbs), "props": VerbCatalog.props_of(stage),
		"external_calls": Array(stage.external_calls).map(func(e): return String(e)),
	}
	_read_results(data, stage, stage.graph_errors.is_empty(), stage.graph_errors + stage.check())
	return data

## Builds and validates a draft stage, then copies step metadata back onto the model.
static func analyze(data: Dictionary) -> void:
	var draft := make_definition(data)
	var tree := Engine.get_main_loop() as SceneTree
	var instance := draft.instantiate_for_analysis(tree.root) if tree else draft.instantiate()
	if instance == null:
		_read_results(data, null, false, ["Stage Script must extend Stage."])
		return
	if instance.bb == null:
		instance.build()
	_read_results(data, instance, instance.graph_errors.is_empty(), instance.graph_errors + instance.check())
	instance.engine.rules.clear()
	if instance.get_parent():
		instance.get_parent().remove_child(instance)
	instance.free()

static func make_definition(data: Dictionary) -> StageDefinition:
	var original: StageDefinition = data["definition"]
	var draft := StageDefinition.new()
	draft.stage_script = original.stage_script
	draft.set_meta("_analysis_scene_source", original.get_meta("_analysis_scene_source", original.resource_path))
	draft.external_calls = PackedStringArray(data["external_calls"])
	draft.external_vars = original.external_vars
	draft.variables = data["vars"].map(func(v: Dictionary) -> VariableData: return VariableData.from_dictionary(v))
	draft.rules = data["rules"].map(func(r: Dictionary) -> RuleData: return RuleData.from_dictionary(r))
	draft.groups = data["groups"].map(func(g: Dictionary) -> GroupData: return GroupData.from_dictionary(g))
	draft._migrate()
	return draft

static func inspect_definition(path: String) -> Dictionary:
	var definition := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StageDefinition
	if definition == null:
		return {"error": "Cannot load StageDefinition from %s" % path}
	var tree := Engine.get_main_loop() as SceneTree
	var instance := definition.instantiate_for_analysis(tree.root) if tree else definition.instantiate()
	if instance == null:
		return {"error": "Assign a Stage script to %s" % path.get_file()}
	if instance.bb == null:
		instance.build()
	var data := read(instance)
	instance.engine.rules.clear()
	if instance.get_parent():
		instance.get_parent().remove_child(instance)
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
