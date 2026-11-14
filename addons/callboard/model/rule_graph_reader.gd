@tool
class_name RuleGraphReader extends RefCounted
## Loads and analyzes typed graph drafts for the editor and live board.

static func read(stage: Stage) -> GraphDraft:
	var definition := stage.definition
	if definition == null:
		return GraphDraft.load_error("This stage has no StageDefinition assigned.")
	var data := GraphDraft.new()
	data.definition = definition
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
	_read_results(data, stage)
	return data

## Builds and validates a draft stage, then copies step metadata back onto the model.
## A retained instance can be passed by an editor session to avoid rebuilding scene props.
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
