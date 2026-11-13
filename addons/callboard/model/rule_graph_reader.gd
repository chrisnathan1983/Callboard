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
		"external_vars": Array(stage.external_vars).map(func(k): return String(k)),
	}
	_read_results(data, stage, stage.graph_errors.is_empty(), stage.graph_errors + stage.check())
	return data

## Builds and validates a draft stage, then copies step metadata back onto the model.
## A retained instance can be passed by an editor session to avoid rebuilding scene props.
static func analyze(data: Dictionary, cached_stage: Stage = null, retain_instance := false) -> Stage:
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
		_read_results(data, null, false, [_analysis_error(draft)])
		return null
	if instance.bb == null:
		instance.build()
	_read_results(data, instance, instance.graph_errors.is_empty(), instance.graph_errors + instance.check())
	instance.engine.rules.clear()
	if instance.get_parent():
		instance.get_parent().remove_child(instance)
	if retain_instance and instance.can_reuse_analysis_props():
		return instance
	instance.free()
	return null

static func make_definition(data: Dictionary) -> StageDefinition:
	var original: StageDefinition = data["definition"]
	var draft := StageDefinition.new()
	draft.stage_script = original.stage_script
	draft.preview_scene_path = original.preview_scene_path
	draft.set_meta(StageDefinition.ANALYSIS_SCENE_SOURCE_META, original.analysis_source_path())
	draft.external_calls = PackedStringArray(data["external_calls"])
	draft.external_vars = PackedStringArray(data.get("external_vars", Array(original.external_vars)))
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
		return {"error": _analysis_error(definition)}
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
