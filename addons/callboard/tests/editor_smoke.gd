extends SceneTree
## Headless authoring integration tests using addon-only fixtures.

const TMP_PATH := "res://.godot/addon_stage_tmp.tres"
const ExportFilter := preload("res://addons/callboard/editor/export_plugin.gd")

func _initialize() -> void:
	await process_frame
	var ok := _test_scene_assigned_props()
	ok = _test_add_var_editor() and ok
	ok = _test_parallel_group_authoring() and ok
	ok = _test_staging_verb_catalog_and_validation() and ok
	ok = await _test_overlapping_flash_restores_surface_colors() and ok
	ok = _test_layer_export_filter() and ok
	ok = _test_factory() and ok
	ok = _test_debug_panel() and ok
	ok = await _test_connection_focus() and ok
	ok = _test_on_change_authoring() and ok
	ok = _test_emit_relay_authoring() and ok
	ok = _test_project_settings() and ok
	print("ADDON EDITOR: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_scene_assigned_props() -> bool:
	var definition := StageDefinition.new()
	definition.stage_script = load("res://addons/callboard/tests/fixtures/assigned_prop_stage.gd")
	definition.preview_scene_path = "res://addons/callboard/tests/fixtures/assigned_prop_stage.tscn"
	definition.external_calls = PackedStringArray(["go"])
	definition.rules = [{
		"id": "use_scene_prop", "trigger": "go", "requires": [], "forbids": [],
		"cancel_if": [], "one_shot": false, "reentry": Rule.ReentryPolicy.IGNORE,
		"emit": "", "state_key": "use_scene_prop", "group": "", "steps": [{
			"verb": "show_node", "args": ["target", "true"],
		}, {
			"verb": "show_node", "args": ["assigned_target", "true"],
		}],
	}]
	if not _check("explicit preview fixture saved", ResourceSaver.save(definition, TMP_PATH) == OK):
		return false
	var board := Callboard.new()
	root.add_child(board)
	board.open_script(TMP_PATH)
	var opened_without_scene := board._analysis_stage == null and not board._data.scene_analysis_current
	board._changed("use_scene_prop")
	var edit_did_not_instantiate := board._analysis_stage == null
	board.analyze_scene()
	var ok := _check("Callboard resolves exported and @onready props from a differently named preview scene",
		board._data.errors.is_empty() and board._data.warnings.is_empty()
		and board._analysis_stage.get_meta(&"fixture_build_props_count", 0) == 1)
	ok = _check("opening and ordinary edits run resource-only validation without creating a preview Stage",
		opened_without_scene and edit_did_not_instantiate) and ok
	var analyzed_stage := board._analysis_stage
	board._changed("use_scene_prop")
	ok = _check("ordinary edits do not rerun Stage setup after explicit scene analysis",
		board._analysis_stage == analyzed_stage
		and board._analysis_stage.get_meta(&"fixture_build_props_count", 0) == 1) and ok
	if ok:
		board.add_call_name("preview_fixture_call")
		board.save()
		ok = _check("Callboard saves omit the transient analysis source",
			not "metadata/_analysis_scene_source" in FileAccess.get_file_as_string(TMP_PATH)) and ok
		board.open_script(TMP_PATH)
		board.analyze_scene()
		var reloaded: StageDefinition = board._data.definition
		ok = _check("Callboard save preserves the explicit preview scene",
			reloaded != null and reloaded.preview_scene_path == definition.preview_scene_path
			and reloaded.external_calls.has("preview_fixture_call")
			and board._data.errors.is_empty() and board._data.warnings.is_empty()) and ok
	board.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	return ok

func _test_add_var_editor() -> bool:
	var bb := Blackboard.new()
	bb.define(&"counter", &"local", 0)
	bb.define(&"ratio", &"local", 0.0)
	bb.define(&"enabled", &"local", false)
	var factory := CoreVerbs.new(StepContext.new(bb, null, null, Callable()))
	var draft := GraphDraft.new()
	draft.variables = [
		VariableData.new(), VariableData.new(), VariableData.new(),
	]
	draft.variables[0].key = &"counter"
	draft.variables[0].default_value = 0
	draft.variables[1].key = &"ratio"
	draft.variables[1].default_value = 0.0
	draft.variables[2].key = &"enabled"
	draft.variables[2].default_value = false
	draft.catalog = VerbCatalog.from_factory(factory)
	var inspector := RuleInspector.new()
	inspector._data = draft
	var entry := VerbCatalog.find(draft.catalog, "add_var")
	var step := StepData.new()
	step.verb = &"add_var"
	step.args = PackedStringArray(['&"counter"', "1.0"])
	var key_picker := inspector._arg_widget(step, 0, entry["args"][0]) as OptionButton
	var integer_delta := inspector._arg_widget(step, 1, entry["args"][1]) as SpinBox
	step.args[0] = '&"ratio"'
	var float_delta := inspector._arg_widget(step, 1, entry["args"][1]) as SpinBox
	var ok := _check("add_var step editor offers only numeric keys and matches delta precision to the selected key",
		key_picker != null and key_picker.item_count == 2
		and key_picker.get_item_text(0) == "counter" and key_picker.get_item_text(1) == "ratio"
		and integer_delta != null and integer_delta.step == 1.0
		and float_delta != null and float_delta.step == 0.05)
	inspector.free()
	return ok

func _test_parallel_group_authoring() -> bool:
	var draft := GraphDraft.new()
	draft.catalog = VerbCatalog.from_factory(CoreVerbs.new(
		StepContext.new(Blackboard.new(), null, null, Callable())))
	var rule := RuleData.new()
	rule.id = &"parallel_authoring"
	rule.trigger = &"start"
	var group := StepData.new()
	group.verb = &"parallel"
	rule.steps = [group]
	draft.rules = [rule]
	var inspector := RuleInspector.new()
	inspector.show_rule(rule, draft)
	var add_branch: Button
	for control: Node in inspector.find_children("*", "Button", true, false):
		var button := control as Button
		if button != null and button.text == "+ Add branch":
			add_branch = button
			break
	if add_branch == null:
		inspector.free()
		return _check("parallel group inspector exposes branch creation", false)
	add_branch.pressed.emit()
	var branch_created := group.parallel_branches.size() == 1
	var group_panel := inspector._parallel_panel(group, 1)
	var add_step: MenuButton
	for control: Node in group_panel.find_children("*", "MenuButton", true, false):
		var menu := control as MenuButton
		if menu != null and menu.text == "+ Add branch step":
			add_step = menu
			break
	if add_step != null and not draft.catalog.is_empty():
		add_step.get_popup().index_pressed.emit(0)
	var step_created := not group.parallel_branches.is_empty() \
		and group.parallel_branches[0].size() == 1
	var first_branch: Array = group.parallel_branches[0]
	group.parallel_branches.append([inspector._new_step_data("score")])
	var join_visible := false
	for control: Node in group_panel.find_children("*", "CheckBox", true, false):
		var check := control as CheckBox
		if check != null and check.text == "Wait for every branch":
			join_visible = true
			break
	group_panel.free()
	group_panel = inspector._parallel_panel(group, 1)
	var move_down: Button
	for control: Node in group_panel.find_children("*", "Button", true, false):
		var button := control as Button
		if button != null and button.text == "↓":
			move_down = button
			break
	if move_down != null:
		move_down.pressed.emit()
	var reordered := group.parallel_branches.size() == 2 and group.parallel_branches[1] == first_branch
	group_panel.free()
	group_panel = inspector._parallel_panel(group, 1)
	var remove_branch: Button
	for control: Node in group_panel.find_children("*", "Button", true, false):
		var button := control as Button
		if button != null and button.text == "Remove":
			remove_branch = button
			break
	if remove_branch != null:
		remove_branch.pressed.emit()
	var removed := group.parallel_branches.size() == 1
	group_panel.free()
	inspector.free()
	return _check("parallel inspector adds editable branches and child steps with join control",
		branch_created and step_created and join_visible and reordered and removed)

func _test_staging_verb_catalog_and_validation() -> bool:
	var bb := Blackboard.new()
	bb.define(&"light_on", &"local", false)
	bb.define(&"wrong_type", &"local", 0)
	var factory := StagingVerbs.new(StepContext.new(bb, null, null, Callable()))
	var catalog := VerbCatalog.from_factory(factory)
	var expected_verbs := ["light", "play_audio", "rotate_to", "play_animation", "pose_animation", "gameplay_event"]
	var listed := expected_verbs.all(func(name: String) -> bool: return not VerbCatalog.find(catalog, name).is_empty())
	var target := Node3D.new()
	var light := factory.light(target, true, 1.0, &"light_on")
	light.verb = &"light"
	light.args = [target, true, 1.0, &"light_on"]
	var valid_light := factory.validate_step(&"valid_light", light, bb).is_empty()
	var optional_light := factory.light(target, true)
	optional_light.verb = &"light"
	optional_light.args = [target, true, 0.0, &""]
	var empty_key_is_allowed := factory.validate_step(&"optional_light", optional_light, bb).is_empty()
	var invalid_light := factory.light(target, true, 1.0, &"missing")
	invalid_light.verb = &"light"
	invalid_light.args = [target, true, 1.0, &"missing"]
	var missing_key_is_reported := factory.validate_step(&"invalid_light", invalid_light, bb).any(
		func(problem: String) -> bool: return "light key 'missing' is not declared" in problem)
	invalid_light.args[3] = &"wrong_type"
	var wrong_key_type_is_reported := factory.validate_step(&"invalid_light", invalid_light, bb).any(
		func(problem: String) -> bool: return "must be Boolean" in problem)
	var bad_audio := factory.play_audio(Node.new())
	bad_audio.verb = &"play_audio"
	bad_audio.args = [Node.new(), false]
	var bad_target_is_reported := factory.validate_step(&"invalid_audio", bad_audio, bb).any(
		func(problem: String) -> bool: return "play_audio target must" in problem)
	var validation_stage := Stage.new()
	validation_stage.build()
	var invalid_audio_rule := Rule.new(&"invalid_audio", &"arrive")
	invalid_audio_rule.steps.append(bad_audio)
	validation_stage.engine.rules.append(invalid_audio_rule)
	var stage_reports_bad_audio := validation_stage.check().any(
		func(problem: String) -> bool: return "play_audio target must" in problem)
	validation_stage.free()
	target.free()
	return _check("staging verbs appear in the picker and validate required targets and the optional Boolean light key",
		listed and valid_light and empty_key_is_allowed and missing_key_is_reported
		and wrong_key_type_is_reported and bad_target_is_reported and stage_reports_bad_audio)

func _test_overlapping_flash_restores_surface_colors() -> bool:
	var host := Node3D.new()
	root.add_child(host)
	var mesh_data := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3.ZERO, Vector3.RIGHT, Vector3.UP,
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD,
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var surface_colors := [Color(0.2, 0.4, 0.8), Color(0.7, 0.3, 0.1)]
	for color: Color in surface_colors:
		mesh_data.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var source_material := StandardMaterial3D.new()
		source_material.albedo_color = color
		mesh_data.surface_set_material(mesh_data.get_surface_count() - 1, source_material)
	var target := MeshInstance3D.new()
	target.mesh = mesh_data
	host.add_child(target)
	var unrelated := MeshInstance3D.new()
	unrelated.mesh = mesh_data
	host.add_child(unrelated)
	var bb := Blackboard.new()
	var factory := StagingVerbs.new(StepContext.new(bb, null, host, Callable()))
	var flash_step := factory.flash(target)
	var first_completion: Signal = flash_step.fn.call({})
	await process_frame
	var second_completion: Signal = flash_step.fn.call({})
	await first_completion
	await second_completion
	var restored := true
	for surface in surface_colors.size():
		var material := target.get_active_material(surface) as BaseMaterial3D
		restored = restored and material != null and material.albedo_color.is_equal_approx(surface_colors[surface])
	var sibling_untouched := true
	for surface in surface_colors.size():
		var material := unrelated.get_active_material(surface) as BaseMaterial3D
		sibling_untouched = sibling_untouched and material != null \
			and material.albedo_color.is_equal_approx(surface_colors[surface])
	host.free()
	await process_frame
	return (_check("overlapping flash restores distinct base colors on every mesh surface", restored)
		and _check("flash material isolation leaves another instance using the source mesh untouched", sibling_untouched))

func _test_layer_export_filter() -> bool:
	var test_path := "res://addons/callboard/tests/fixtures/assigned_prop_stage.tscn"
	return _check("exports omit addon tests and keep authoring scripts for debug builds",
		ExportFilter.should_strip("res://addons/callboard/editor/callboard.gd", false)
		and ExportFilter.should_strip("res://addons/callboard/model/rule_graph_reader.gd", false)
		and ExportFilter.should_strip("res://addons/callboard/plugin.gd", false)
		and not ExportFilter.should_strip("res://addons/callboard/core/stage.gd", false)
		and not ExportFilter.should_strip("res://addons/callboard/core/callboard_debug_panel.gd", false)
		and ExportFilter.should_strip(test_path, false)
		and ExportFilter.should_strip(test_path, true)
		and not ExportFilter.should_strip("res://addons/callboard/editor/callboard.gd", true))

func _test_factory() -> bool:
	# Build an unparented resource-backed stage with its own verb factory.
	var script := GDScript.new()
	script.source_code = """@tool
extends Stage

const MESSAGE := 'A, "B"'
var target: Node3D

class CustomVerbs extends StagingVerbs:
	func stamp(prop: Node3D, label: String) -> Step:
		return Step.new(func(_c: Dictionary) -> void: prop.set_meta(&"label", label))

func _make_verbs(ctx: StepContext) -> CoreVerbs:
	return CustomVerbs.new(ctx)

func _build_props() -> void:
	target = Node3D.new()
	add_child(target)

func _build_blackboard() -> void:
	write_var(&"ready", true)
"""
	if not _check("custom factory fixture compiles", script.reload() == OK):
		return false
	var definition := StageDefinition.new()
	definition.stage_script = script
	definition.variables = [{"key": "ready", "scope": "local", "default": false}]
	var spec := {"verb": "stamp", "args": ["target", "MESSAGE"], "delay": "0.25"}
	definition.rules = [{
		"id": "custom", "trigger": "arrive", "requires": [], "forbids": [],
		"cancel_if": [], "one_shot": false, "emit": "", "steps": [spec],
	}]
	var stage := definition.instantiate()
	stage.build()
	var catalog := VerbCatalog.from_factory(stage.verbs)
	var ok := _check("factory discovers its custom verb and the inherited verbs",
		VerbCatalog.find(catalog, "stamp").size() > 0
		and VerbCatalog.find(catalog, "show_node").size() > 0
		and VerbCatalog.find(catalog, "repeat_emit").size() > 0)
	ok = _check("stage runs the blackboard hook after resource defaults", stage.is_set(&"ready")) and ok
	if _check("custom resource compiles", stage.graph_errors.is_empty()):
		var step := stage.engine.rules[0].steps[0]
		ok = _check("resource compiler supplies verb, prop, constant and delay metadata",
			step.verb == &"stamp" and step.args == [stage.get("target"), 'A, "B"']
			and step.delay == 0.25) and ok
		step.fn.call({})
		ok = _check("compiled custom step runs with the supplied arguments",
			stage.get("target").get_meta(&"label") == 'A, "B"') and ok
	else:
		ok = false
	stage.engine.rules.clear()
	stage.free()

	definition.rules[0].steps[0].args = PackedStringArray(["null", "MESSAGE"])
	stage = definition.instantiate()
	stage.build()
	ok = _check("validator still reports null props with compiler-generated metadata",
		stage.check().any(func(problem): return "'stamp' step with an unset prop" in problem)) and ok
	stage.engine.rules.clear()
	stage.free()

	return ok

func _test_debug_panel() -> bool:
	var panel := CallboardDebugPanel.create()
	if not _check("debug panel factory creates an unparented panel",
			panel != null and panel.get_parent() == null):
		return false
	root.add_child(panel)
	var first := Stage.new()
	first.definition = StageDefinition.new()
	root.add_child(first)
	var second := Stage.new()
	second.definition = StageDefinition.new()
	root.add_child(second)
	panel.bind_stage(first)
	var board := panel.get_child(0) as Callboard
	var ok := _check("debug panel binds the live board to the stage", board._live == first)
	panel.bind_stage(second)
	ok = _check("debug panel rebinds the board and disconnects the previous stage",
		board._live == second
		and not first.rule_fired.is_connected(board._on_live_rule_fired)) and ok
	panel.free()
	first.free()
	second.free()
	return ok

func _test_connection_focus() -> bool:
	var board := Callboard.new()
	root.add_child(board)
	var data := GraphDraft.new()
	data.external_calls.assign(["go", "unused"])
	data.rules.assign([
		RuleData.from_dictionary({"id": "producer", "trigger": "go", "emit": "other", "steps": [{"verb": "fire"}]}),
		RuleData.from_dictionary({"id": "listener", "trigger": "relay:ready"}),
		RuleData.from_dictionary({"id": "other_listener", "trigger": "relay:other"}),
		RuleData.from_dictionary({"id": "completion_producer", "trigger": "go", "emit": "ready"}),
	])
	var step := data.rules[0].steps[0]
	var analysis := GraphDraft.StepAnalysis.new()
	analysis.relay = "ready"
	data.step_metadata[step] = analysis
	board._show(data, true)
	var graph := board.view
	var positions := graph.get_positions()
	var call_positions := graph.get_call_positions()
	graph._fill_focus_results("GO")
	graph._focus_search.text_submitted.emit("GO")
	var ok := _check("search focuses a Call and dims unrelated rules without hiding them",
		graph._focused_connection == "go" and graph._event_nodes["go"].modulate == Color.WHITE
		and graph._rule_nodes["producer"].modulate == Color.WHITE
		and graph._rule_nodes["listener"].modulate.a < 1.0 and graph._rule_nodes["listener"].visible
		and graph.get_connection_list().size() == 5)
	graph._fill_focus_results("ready")
	graph._focus_results.item_clicked.emit(0, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	graph._focus_mode.select(1)
	graph._focus_mode.item_selected.emit(1)
	await process_frame
	ok = _check("Isolate keeps step and completion emitters and only the selected relay's wires",
		graph._rule_nodes["producer"].visible and graph._rule_nodes["completion_producer"].visible
		and graph._rule_nodes["listener"].visible and not graph._rule_nodes["other_listener"].visible
		and not graph._event_nodes["go"].visible and graph.get_connection_list().size() == 2) and ok
	graph.set_minimized(true)
	await process_frame
	ok = _check("Compact preserves focus and the isolated wires",
		graph._focused_connection == "relay:ready" and graph.get_connection_list().size() == 2) and ok
	graph._clear_focus_button.pressed.emit()
	ok = _check("clearing focus restores connections and leaves the authored layout and history intact",
		graph._rule_nodes["other_listener"].visible and graph._event_nodes["go"].visible
		and graph.get_connection_list().size() == 5 and graph.get_positions() == positions
		and graph.get_call_positions() == call_positions and not board.is_dirty()
		and not board._history.can_undo()) and ok
	graph.set_connection_focus("unused")
	ok = _check("an unused Call remains visible by itself in Isolate",
		graph._event_nodes["unused"].visible and not graph._rule_nodes["producer"].visible
		and graph.get_connection_list().is_empty()) and ok
	data.external_calls.erase("unused")
	graph.update_data(data)
	ok = _check("removing a focused Call restores the full view",
		graph._focused_connection.is_empty() and graph.get_connection_list().size() == 5) and ok
	board._show(data, false, true)
	graph.set_connection_focus("relay:ready")
	graph.pulse("other_listener")
	graph.pulse("producer")
	ok = _check("live activity highlights focused rules without changing isolation",
		not graph._rule_nodes["other_listener"].visible
		and graph._rule_nodes["producer"].self_modulate != Color.WHITE
		and graph.get_connection_list().size() == 2) and ok
	board.free()
	return ok

func _test_on_change_authoring() -> bool:
	var data := GraphDraft.new()
	var listener := RuleData.new()
	listener.id = &"watch_blackboard"
	listener.trigger = &"on_change"
	var step := StepData.new()
	step.verb = &"score"
	step.args = PackedStringArray(["1"])
	listener.steps.append(step)
	data.rules = [listener]
	var graph := RuleGraphView.new()
	root.add_child(graph)
	graph.show_data(data)
	var graph_input_visible: bool = graph._event_nodes.has("on_change") \
		and graph._event_nodes["on_change"].title == "Blackboard Change" \
		and graph.get_connection_list().size() == 1
	var inspector := RuleInspector.new()
	root.add_child(inspector)
	inspector.show_rule(listener, data)
	var trigger_selectable := inspector._trigger_options().has("on_change")
	var immutable_builtin := not RuleConnections.edit_error(data, "on_change").is_empty() \
		and not RuleConnections.new_call_error(data, "on_change").is_empty()
	var ok := _check("on_change is selectable and shown as a built-in incoming graph event",
		graph_input_visible and trigger_selectable)
	ok = _check("the built-in on_change trigger cannot be renamed, removed, or redeclared as a Call",
		immutable_builtin and RuleConnections.remove(data, "on_change") != "") and ok
	inspector.free()
	graph.free()
	return ok

func _test_emit_relay_authoring() -> bool:
	var data := GraphDraft.new()
	data.external_calls.assign(["start"])
	data.payload_fields = [
		PayloadFieldData.from_dictionary({"event_id": "start", "key": "action", "type": "String"}),
		PayloadFieldData.from_dictionary({"event_id": "relay:mapped", "key": "result", "type": "String"}),
	]
	var producer := RuleData.new()
	producer.id = &"map_payload"
	producer.trigger = &"start"
	var emit_step := StepData.new()
	emit_step.verb = &"emit_relay"
	emit_step.args = PackedStringArray(['&"mapped"', '{"result": "action"}'])
	producer.steps.append(emit_step)
	var listener := RuleData.new()
	listener.id = &"receive_mapped"
	listener.trigger = &"relay:mapped"
	var listener_step := StepData.new()
	listener_step.verb = &"score"
	listener_step.args = PackedStringArray(["1"])
	listener.steps.append(listener_step)
	data.rules = [producer, listener]
	var bb := Blackboard.new()
	data.catalog = RuntimeVerbCatalog.from_factory(CoreVerbs.new(StepContext.new(bb, null, null, Callable())))
	RuleGraphReader.validate_resources(data)
	var metadata := data.step_metadata.get(emit_step) as GraphDraft.StepAnalysis
	var inspector := RuleInspector.new()
	inspector._data = data
	inspector._rule = producer
	inspector.show_rule(producer, data)
	var emit_params: Array = VerbCatalog.find(data.catalog, "emit_relay")["args"]
	var runtime_options := inspector._runtime_input_options(emit_step, 1, emit_params[1])
	var graph := RuleGraphView.new()
	root.add_child(graph)
	graph.show_data(data)
	var has_emitter_wire := false
	for connection: Dictionary in graph.get_connection_list():
		if connection.get("to_node") == "receive_mapped":
			has_emitter_wire = true
	var ok := _check("emit_relay resource analysis exposes a typed emitter and graph connection",
		data.errors.is_empty() and data.relay_for(emit_step) == "mapped"
		and metadata != null and metadata.relay_argument == 0 and has_emitter_wire
		and RuleConnections.ids(data).has("relay:mapped"))
	var offers_payload_picker := false
	for option: Dictionary in runtime_options:
		if option["label"] == "result <- payload.action" and option["expression"] == '{"result": callboard_payload(&"action")}':
			offers_payload_picker = true
	ok = _check("step argument picker offers schema-compatible payload and Blackboard sources",
		offers_payload_picker) and ok
	ok = _check("renaming an emitted relay updates the step argument and its listener",
		RuleConnections.rename(data, "relay:mapped", "renamed").is_empty()
		and data.rules[0].steps[0].args[0] == '&"renamed"'
		and data.rules[1].trigger == "relay:renamed"
		and data.rules[0].steps[0].args[1] == '{"result": "action"}') and ok
	graph.free()
	inspector.free()
	return ok

func _test_project_settings() -> bool:
	const Settings := preload("res://addons/callboard/core/callboard_settings.gd")
	var saved_folder: Variant = ProjectSettings.get_setting(Settings.DEFAULT_STAGE_FOLDER, null)
	var scan_folders: Variant = ProjectSettings.get_setting(Settings.STAGE_SCAN_FOLDERS, null)
	ProjectSettings.set_setting(Settings.DEFAULT_STAGE_FOLDER, null)
	ProjectSettings.set_setting(Settings.STAGE_SCAN_FOLDERS, null)
	ProjectSettings.set_setting(Settings.LEGACY_DEFAULT_FOLDER, "res://custom_stages/")
	ProjectSettings.set_setting(Settings.LEGACY_SCAN_FOLDERS, PackedStringArray(["res://extra_stages/"]))
	Settings.register_project_settings()
	var ok := _check("legacy stage folder settings migrate to the new fields",
		Settings.stage_directories() == ["res://custom_stages", "res://extra_stages"]
		and not ProjectSettings.has_setting(Settings.LEGACY_DEFAULT_FOLDER)
		and not ProjectSettings.has_setting(Settings.LEGACY_SCAN_FOLDERS))
	ProjectSettings.set_setting(Settings.DEFAULT_STAGE_FOLDER, saved_folder)
	ProjectSettings.set_setting(Settings.STAGE_SCAN_FOLDERS, scan_folders)
	return ok

func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond

