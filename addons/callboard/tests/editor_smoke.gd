extends SceneTree
## Headless authoring integration tests using addon-only fixtures.

const TMP_PATH := "res://.godot/addon_stage_tmp.tres"
const TMP_TYPED_DEFAULTS_PATH := "res://.godot/addon_typed_defaults_tmp.tres"
const TMP_RESTORATION_SCENE_PATH := "res://.godot/addon_restoration_picker_tmp.tscn"
const ExportFilter := preload("res://addons/callboard/editor/export_plugin.gd")

func _initialize() -> void:
	await process_frame
	var ok := _test_scene_assigned_props()
	ok = _test_add_var_editor() and ok
	ok = _test_shared_key_authoring() and ok
	ok = _test_stage_authoring_controls() and ok
	ok = _test_restoration_picker_options() and ok
	ok = _test_parallel_group_authoring() and ok
	ok = _test_conditional_group_authoring() and ok
	ok = _test_guard_expression_authoring() and ok
	ok = _test_random_group_authoring() and ok
	ok = _test_staging_verb_catalog_and_validation() and ok
	ok = await _test_overlapping_flash_restores_surface_colors() and ok
	ok = _test_layer_export_filter() and ok
	ok = _test_factory() and ok
	ok = _test_debug_panel() and ok
	ok = await _test_connection_focus() and ok
	ok = _test_on_change_authoring() and ok
	ok = _test_live_payload_form() and ok
	ok = _test_emit_relay_authoring() and ok
	ok = _test_project_settings() and ok
	print("ADDON EDITOR: ", "PASS" if ok else "FAIL")
	# Let controls removed with queue_free() during the synchronous smoke tests
	# finish teardown before the SceneTree reports leaked CanvasItems.
	await process_frame
	await process_frame
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
	root.add_child(inspector)
	inspector._data = draft
	var entry := VerbCatalog.find(draft.catalog, "add_var")
	var step := StepData.new()
	step.verb = &"add_var"
	step.args = PackedStringArray(['&"counter"', "1.0"])
	var key_picker := inspector._arg_widget(step, 0, entry["args"][0]) as OptionButton
	var integer_delta := inspector._arg_widget(step, 1, entry["args"][1]) as SpinBox
	step.args[0] = '&"ratio"'
	var float_delta := inspector._arg_widget(step, 1, entry["args"][1]) as SpinBox
	var toggle_entry := VerbCatalog.find(draft.catalog, "toggle_var")
	var toggle_step := StepData.new()
	toggle_step.verb = &"toggle_var"
	toggle_step.args = PackedStringArray(['&"enabled"'])
	var toggle_picker := inspector._arg_widget(toggle_step, 0, toggle_entry["args"][0]) as OptionButton
	var reset_entry := VerbCatalog.find(draft.catalog, "reset_var")
	var reset_step := StepData.new()
	reset_step.verb = &"reset_var"
	reset_step.args = PackedStringArray(['&"counter"'])
	var reset_picker := inspector._arg_widget(reset_step, 0, reset_entry["args"][0]) as OptionButton
	var ok := _check("add_var step editor offers only numeric keys and matches delta precision to the selected key",
		key_picker != null and key_picker.item_count == 2
		and key_picker.get_item_text(0) == "counter" and key_picker.get_item_text(1) == "ratio"
		and integer_delta != null and integer_delta.step == 1.0
		and float_delta != null and float_delta.step == 0.05) \
		and _check("toggle_var key picker limits choices to Boolean defaults while reset_var offers every declared key",
			toggle_picker != null and toggle_picker.item_count == 1
			and toggle_picker.get_item_text(0) == "enabled"
			and reset_picker != null and reset_picker.item_count == 3)
	key_picker.free()
	integer_delta.free()
	float_delta.free()
	toggle_picker.free()
	reset_picker.free()
	inspector.free()
	return ok

func _test_shared_key_authoring() -> bool:
	var preserved := VariableData.new()
	preserved.key = &"local_value"
	preserved.state_key = &"original_storage_id"
	var linked := VariableData.new()
	linked.key = &"shared_value"
	linked.scope = "shared"
	linked.state_key = &"canonical_town_value"
	var draft := GraphDraft.new()
	draft.variables = [preserved, linked]
	var panel := BlackboardPanel.new()
	root.add_child(panel)
	panel.show_data(draft)
	var find_card := func(display_key: String) -> VBoxContainer:
		for control: Node in panel.find_children("*", "LineEdit", true, false):
			var edit := control as LineEdit
			if edit != null and edit.accessibility_name == "Variable name" and edit.text == display_key:
				return edit.get_parent().get_parent() as VBoxContainer
		return null
	var preserved_card := find_card.call("local_value") as VBoxContainer
	var scope_control: OptionButton
	if preserved_card != null:
		for control: Node in preserved_card.find_children("*", "OptionButton", true, false):
			var option := control as OptionButton
			if option != null and option.accessibility_name == "Variable scope":
				scope_control = option
				break
	if scope_control == null:
		panel.free()
		return _check("Shared scope exposes a storage-key editor and picker", false)
	scope_control.item_selected.emit(2)
	var shared_key_edit: LineEdit
	var shared_key_picker: OptionButton
	preserved_card = find_card.call("local_value") as VBoxContainer
	if preserved_card != null:
		for control: Node in preserved_card.find_children("*", "LineEdit", true, false):
			var edit := control as LineEdit
			if edit != null and edit.accessibility_name == "Shared storage key":
				shared_key_edit = edit
		for control: Node in preserved_card.find_children("*", "OptionButton", true, false):
			var option := control as OptionButton
			if option != null and option.accessibility_name == "Existing shared storage keys":
				shared_key_picker = option
	if shared_key_edit == null or shared_key_picker == null:
		panel.free()
		return _check("Shared scope exposes a storage-key editor and picker", false)
	var picker_has_existing_key := false
	for i in range(shared_key_picker.item_count):
		if shared_key_picker.get_item_text(i) == "canonical_town_value":
			picker_has_existing_key = true
	shared_key_edit.text = "canonical_town_value"
	shared_key_edit.text_submitted.emit(shared_key_edit.text)
	var identity_linked := preserved.scope == "shared" and preserved.state_key == &"canonical_town_value"
	preserved_card = find_card.call("local_value") as VBoxContainer
	if preserved_card != null:
		for control: Node in preserved_card.find_children("*", "OptionButton", true, false):
			var option := control as OptionButton
			if option != null and option.accessibility_name == "Variable scope":
				option.item_selected.emit(1)
				break
	var scope_change_preserved_identity := preserved.scope == "saved" \
		and preserved.state_key == &"canonical_town_value"
	var ok := _check("Shared key picker exposes existing identities and edits the explicit storage key",
		picker_has_existing_key and identity_linked and linked.state_key == &"canonical_town_value") \
		and _check("changing scope preserves the persisted storage identity",
			scope_change_preserved_identity)
	panel.free()
	return ok

func _test_stage_authoring_controls() -> bool:
	var draft := GraphDraft.new()
	draft.definition = StageDefinition.new()
	var state := VariableData.new()
	state.key = &"resolved"
	state.scope = "saved"
	state.default_value = Transform3D(Basis.IDENTITY, Vector3(1, 2, 3))
	draft.variables.append(state)
	var panel := BlackboardPanel.new()
	root.add_child(panel)
	panel.show_data(draft, true)
	var settings := panel._make_stage_settings()
	var lifecycle := settings.get_child(1) as CheckButton
	lifecycle.toggled.emit(true)
	var writers := settings.get_child(2) as VBoxContainer
	(writers.get_child(0).get_child(1) as Button).pressed.emit()
	var bindings := settings.get_child(3) as VBoxContainer
	(bindings.get_child(0).get_child(1) as Button).pressed.emit()
	var editor := panel._default_editor(state) as LineEdit
	var changed_transform := Transform3D(Basis.from_euler(Vector3(0.2, 0.3, 0.4)), Vector3(4, 5, 6))
	editor.text = var_to_str(changed_transform)
	editor.text_submitted.emit(editor.text)
	var typed_transform_preserved: bool = typeof(state.default_value) == TYPE_TRANSFORM3D \
		and state.default_value.origin == changed_transform.origin \
		and state.default_value.basis == changed_transform.basis
	var complex_values: Array = [Color(0.2, 0.4, 0.6, 0.8), Vector3(7, 8, 9), {"nested": [1, &"two"]}]
	var complex_types_preserved := true
	for index in complex_values.size():
		var variable := VariableData.new()
		variable.key = StringName("complex_%d" % index)
		variable.default_value = complex_values[index]
		draft.variables.append(variable)
		var value_editor := panel._default_editor(variable) as LineEdit
		value_editor.text = var_to_str(complex_values[index])
		value_editor.text_submitted.emit(value_editor.text)
		complex_types_preserved = complex_types_preserved and typeof(variable.default_value) == typeof(complex_values[index]) \
			and variable.default_value == complex_values[index]
	var ok := _check("board exposes lifecycle, external-writer, and restoration controls",
		draft.managed_lifecycle and draft.external_writers.size() == 1
		and draft.restoration_bindings.size() == 1
		and draft.restoration_bindings[0].key == &"resolved")
	ok = _check("complex Blackboard defaults round-trip as their original Variant type",
		typed_transform_preserved and complex_types_preserved) and ok
	var snapshot := draft.snapshot()
	var restored := GraphDraft.new()
	restored.restore(snapshot)
	ok = _check("typed defaults and board-authored settings survive draft undo snapshots",
		typeof(restored.variables[0].default_value) == TYPE_TRANSFORM3D
		and restored.managed_lifecycle and restored.external_writers.size() == 1
		and restored.restoration_bindings.size() == 1) and ok
	var migrated_definition := StageDefinition.new()
	migrated_definition.variables = [{"key": "legacy_transform", "scope": "saved", "default": changed_transform}]
	migrated_definition._migrate()
	ok = _check("legacy variable migration keeps serialized Transform3D defaults typed",
		migrated_definition.variables[0].default_value is Transform3D) and ok
	var saved_definition := RuleGraphReader.make_definition(draft)
	var save_error := ResourceSaver.save(saved_definition, TMP_TYPED_DEFAULTS_PATH)
	var reloaded_definition := ResourceLoader.load(TMP_TYPED_DEFAULTS_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as StageDefinition
	ok = _check("typed defaults survive StageDefinition save and reload",
		save_error == OK and reloaded_definition != null
		and typeof(reloaded_definition.variables[0].default_value) == TYPE_TRANSFORM3D
		and reloaded_definition.variables[0].default_value.origin == changed_transform.origin) and ok
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_TYPED_DEFAULTS_PATH))
	panel.free()
	return ok

func _test_restoration_picker_options() -> bool:
	var scene_root := Node3D.new()
	scene_root.name = "AuthoringFixture"
	var target := Node3D.new()
	target.name = "Target"
	scene_root.add_child(target)
	target.owner = scene_root
	var marker := Marker3D.new()
	marker.name = "Resolved"
	scene_root.add_child(marker)
	marker.owner = scene_root
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	scene_root.add_child(player)
	player.owner = scene_root
	var library := AnimationLibrary.new()
	library.add_animation(&"resolved_pose", Animation.new())
	player.add_animation_library(&"", library)
	var packed := PackedScene.new()
	var pack_result := packed.pack(scene_root)
	var save_result := ResourceSaver.save(packed, TMP_RESTORATION_SCENE_PATH) if pack_result == OK else FAILED
	scene_root.free()
	if save_result != OK:
		return _check("restoration picker fixture scene saves", false)
	var draft := GraphDraft.new()
	draft.definition = StageDefinition.new()
	draft.definition.preview_scene_path = TMP_RESTORATION_SCENE_PATH
	var panel := BlackboardPanel.new()
	panel._data = draft
	var marker_paths := panel._scene_node_paths(["Marker3D"])
	var animations := panel._scene_animations(NodePath("./AnimationPlayer"))
	var properties := panel._scene_property_names(NodePath("./Target"))
	var binding := StageRestorationBinding.new()
	binding.animation_name = &""
	var fields := VBoxContainer.new()
	panel._add_path_field(fields, "Marker", binding, "marker_path", ["Marker3D"])
	var path_picker := (fields.get_child(0) as HBoxContainer).get_child(1) as OptionButton
	var marker_option := marker_paths.find("./Resolved")
	if marker_option >= 0:
		path_picker.select(marker_option + 1)
		path_picker.item_selected.emit(marker_option + 1)
	var ok := _check("restoration node pickers filter preview paths by class",
		marker_paths.has("./Resolved") and binding.marker_path == NodePath("./Resolved"))
	var animation_fields := VBoxContainer.new()
	panel._add_name_field(animation_fields, "Animation", binding, "animation_name", animations)
	var animation_picker := (animation_fields.get_child(0) as HBoxContainer).get_child(1) as OptionButton
	var animation_option := animations.find("resolved_pose")
	if animation_option >= 0:
		animation_picker.select(animation_option + 1)
		animation_picker.item_selected.emit(animation_option + 1)
	ok = _check("restoration animation and property suggestions come from the preview scene",
		animations.has("resolved_pose") and binding.animation_name == &"resolved_pose"
		and properties.has("position")) and ok
	fields.free()
	animation_fields.free()
	panel.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_RESTORATION_SCENE_PATH))
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
	root.add_child(inspector)
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

func _test_conditional_group_authoring() -> bool:
	var draft := GraphDraft.new()
	draft.catalog = VerbCatalog.from_factory(CoreVerbs.new(
		StepContext.new(Blackboard.new(), null, null, Callable())))
	var rule := RuleData.new()
	rule.id = &"conditional_authoring"
	rule.trigger = &"start"
	var group := StepData.new()
	group.verb = &"conditional"
	group.parallel_branches = [[], []]
	group.branch_conditions = [&"ready", &""]
	group.default_branch_index = 1
	rule.steps = [group]
	draft.rules = [rule]
	var inspector := RuleInspector.new()
	root.add_child(inspector)
	inspector._data = draft
	inspector._rule = rule
	var panel := inspector._conditional_panel(group, 1)
	var otherwise_visible := false
	for control: Node in panel.find_children("*", "CheckBox", true, false):
		var check := control as CheckBox
		if check != null and check.text == "Otherwise":
			otherwise_visible = true
	var add_condition: Button
	for control: Node in panel.find_children("*", "Button", true, false):
		var button := control as Button
		if button != null and button.text == "+ Add condition":
			add_condition = button
			break
	if add_condition != null:
		add_condition.pressed.emit()
	var added_before_default := group.parallel_branches.size() == 3 and group.default_branch_index == 2
	panel.free()
	inspector.free()
	return _check("conditional group inspector exposes Otherwise and inserts new guarded branches before it",
		otherwise_visible and added_before_default)

func _test_random_group_authoring() -> bool:
	var draft := GraphDraft.new()
	draft.catalog = VerbCatalog.from_factory(CoreVerbs.new(
		StepContext.new(Blackboard.new(), null, null, Callable())))
	var rule := RuleData.new()
	rule.id = &"random_authoring"
	rule.trigger = &"start"
	var group := StepData.new()
	group.verb = &"random"
	group.group_id = &"stable_group"
	group.random_selection = 1
	group.random_seed = 42
	group.parallel_branches = [[], []]
	group.branch_weights = PackedFloat32Array([2.0, 1.0])
	rule.steps = [group]
	draft.rules = [rule]
	var inspector := RuleInspector.new()
	root.add_child(inspector)
	inspector._data = draft
	inspector._rule = rule
	var panel := inspector._random_panel(group, 1)
	var has_seed := false
	var weight_count := 0
	for control: Node in panel.find_children("*", "SpinBox", true, false):
		var spin := control as SpinBox
		if spin != null and spin.value == 42.0:
			has_seed = true
		elif spin != null:
			weight_count += 1
	var has_selection := false
	for control: Node in panel.find_children("*", "OptionButton", true, false):
		var option := control as OptionButton
		if option != null and option.selected == 1:
			has_selection = true
	panel.free()
	inspector.free()
	return _check("random group inspector exposes weighted mode, an authored seed, and branch weights",
		has_seed and has_selection and weight_count == 2)

func _test_guard_expression_authoring() -> bool:
	var draft := GraphDraft.new()
	draft.catalog = VerbCatalog.from_factory(CoreVerbs.new(
		StepContext.new(Blackboard.new(), null, null, Callable())))
	draft.external_calls = [&"start"]
	for spec in [[&"sensor_active", false], [&"override_enabled", false],
		[&"completed_count", 0], [&"required_count", 0], [&"named_mode", &"standby"]]:
		var variable := VariableData.new()
		variable.key = spec[0]
		variable.default_value = spec[1]
		draft.variables.append(variable)
	var rule := RuleData.new()
	rule.id = &"guard_authoring"
	rule.trigger = &"start"
	rule.requires = PackedStringArray(["any(sensor_active, override_enabled)",
		"(completed_count >= required_count) and named_mode == &\"standby\""])
	var step := StepData.new()
	step.verb = &"score"
	step.args = PackedStringArray(["1"])
	rule.steps = [step]
	draft.rules = [rule]
	RuleGraphReader.validate_resources(draft)
	var inspector := RuleInspector.new()
	root.add_child(inspector)
	inspector._data = draft
	inspector._rule = rule
	var valid_key_pair := inspector._guard_expression_issue("completed_count >= required_count").is_empty()
	var valid_string_name := inspector._guard_expression_issue("named_mode == &\"standby\"").is_empty()
	var rejects_bad_order := not inspector._guard_expression_issue("named_mode > \"standby\"").is_empty()
	var menu := inspector._guard_menu("requires")
	var edit: LineEdit
	var add: Button
	for control: Node in menu.find_children("*", "LineEdit", true, false):
		edit = control as LineEdit
	for control: Node in menu.find_children("*", "Button", true, false):
		var button := control as Button
		if button.text == "Add":
			add = button
			break
	if edit != null and add != null:
		edit.text = "(sensor_active or override_enabled) and completed_count >= required_count"
		add.pressed.emit()
	var added_group := rule.requires.has("(sensor_active or override_enabled) and completed_count >= required_count")
	var resource_accepts := draft.errors.is_empty() and draft.warnings.is_empty()
	menu.free()
	inspector.free()
	return _check("guard editor accepts grouped formulas and typed key comparisons while rejecting invalid operators",
		valid_key_pair and valid_string_name and rejects_bad_order and added_group and resource_accepts)

func _test_staging_verb_catalog_and_validation() -> bool:
	var bb := Blackboard.new()
	bb.define(&"light_on", &"local", false)
	bb.define(&"wrong_type", &"local", 0)
	var factory := StagingVerbs.new(StepContext.new(bb, null, null, Callable()))
	var catalog := VerbCatalog.from_factory(factory)
	var expected_verbs := ["light", "play_audio", "rotate_to", "play_animation", "pose_animation", "gameplay_event", "emit_cross_stage"]
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
	var bad_audio_target := Node.new()
	var bad_audio_argument := Node.new()
	var bad_audio := factory.play_audio(bad_audio_target)
	bad_audio.verb = &"play_audio"
	bad_audio.args = [bad_audio_argument, false]
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
	bad_audio_target.free()
	bad_audio_argument.free()
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

func _test_live_payload_form() -> bool:
	var data := GraphDraft.new()
	data.external_calls.assign(["test_payload"])
	data.payload_fields = [
		PayloadFieldData.from_dictionary({"event_id": "test_payload", "key": "name", "type": "String"}),
		PayloadFieldData.from_dictionary({"event_id": "test_payload", "key": "count", "type": "int"}),
		PayloadFieldData.from_dictionary({"event_id": "test_payload", "key": "ratio", "type": "float"}),
		PayloadFieldData.from_dictionary({"event_id": "test_payload", "key": "enabled", "type": "bool"}),
	]
	var parent := Control.new()
	root.add_child(parent)
	var sent := {}
	var connections := CallboardConnections.new()
	connections.setup(parent, Button.new(), func() -> void: pass,
		func(_id: String, _new_name: String) -> String: return "",
		func(_id: String) -> String: return "",
		func(_message: String) -> void: pass,
		func(id: String, payload: Dictionary) -> void:
			sent["id"] = id
			sent["payload"] = payload.duplicate(true))
	parent.add_child(connections.panel)
	connections.refresh(data, false, "test_payload")
	var card: Control = connections.cards.get("test_payload")
	var payload_button := card.find_child("TestPayload", true, false) as Button if card != null else null
	var fire_button := card.find_child("FireCall", true, false) as Button if card != null else null
	if payload_button == null or fire_button == null:
		parent.free()
		return _check("live Call tester creates a schema-backed payload form", false)
	payload_button.button_pressed = true
	payload_button.toggled.emit(true)
	var form := card.find_child("TestPayloadForm", true, false) as VBoxContainer
	var name_edit := form.find_child("Payload_name", true, false) as LineEdit
	var count_edit := form.find_child("Payload_count", true, false) as SpinBox
	var ratio_edit := form.find_child("Payload_ratio", true, false) as SpinBox
	var enabled_edit := form.find_child("Payload_enabled", true, false) as CheckBox
	var enabled_include := form.find_child("Include_enabled", true, false) as CheckBox
	var inputs_found := form != null and form.visible and name_edit != null and count_edit != null \
		and ratio_edit != null and enabled_edit != null and enabled_include != null
	if inputs_found:
		name_edit.text = "door"
		count_edit.value = 4
		ratio_edit.value = 1.25
		enabled_edit.button_pressed = true
		enabled_include.button_pressed = false
		fire_button.pressed.emit()
	var sent_payload: Dictionary = sent.get("payload", {})
	var ok := _check("live Call tester sends typed values and omits unchecked schema fields",
		inputs_found and sent.get("id") == "test_payload" and sent_payload.get("name") == "door"
		and typeof(sent_payload.get("count")) == TYPE_INT and sent_payload.get("count") == 4
		and typeof(sent_payload.get("ratio")) == TYPE_FLOAT
		and is_equal_approx(sent_payload.get("ratio", 0.0), 1.25)
		and not sent_payload.has("enabled"))
	parent.free()
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
	root.add_child(inspector)
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

