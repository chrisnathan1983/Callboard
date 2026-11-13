extends SceneTree
## Headless authoring integration tests using the demo's Stage 01 graph.

const STAGE_PATH := "res://demo/stages/stage_01/stage_01.gd"
const DEFINITION_PATH := "res://demo/stages/stage_01/stage_01.tres"
const TMP_PATH := "res://.godot/stage_tmp.tres"
const Settings := preload("res://addons/callboard/core/callboard_settings.gd")

func _initialize() -> void:
	await process_frame
	var ok := _test_authored_resource_graph()
	ok = _test_board_editing() and ok
	ok = _test_additional_stage_locations() and ok
	ok = (await _test_save_and_history()) and ok
	ok = (await _test_debounced_history()) and ok
	ok = (await _test_numeric_undo()) and ok
	ok = (await _test_event_and_relay_edits()) and ok
	ok = (await _test_canvas_actions()) and ok
	ok = _test_live_debug() and ok
	ok = _test_rename_saved_state() and ok
	print("DEMO EDITOR: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_authored_resource_graph() -> bool:
	var ok := true
	# --- Authored resource ----------------------------------------------------------
	var definition := load(DEFINITION_PATH) as StageDefinition
	var data := RuleGraphReader.inspect_definition(DEFINITION_PATH)
	ok = _check("resource stores events, variables, rules and groups",
		definition.external_calls.size() == 4 and definition.variables.size() == 3
		and not definition.rules.is_empty() and definition.rules.size() == data.rules.size()
		and definition.groups.size() == 3 and definition.variables[0] is VariableData
		and definition.rules[0] is RuleData and definition.rules[0].steps[0] is StepData
		and definition.groups[0] is GroupData) and ok
	ok = _check("reader: compiles with no problems", data.errors.is_empty() and data.warnings.is_empty()) and ok
	ok = _check("reader: every rule has a saved position", data.rules.all(func(rule: RuleData) -> bool: return rule.has_pos)) and ok
	ok = _check("reader: step text keeps source expressions", ExprText.step_text(data.rules[1].steps[1].to_dictionary()) == "light(lamp, true, 3.5).after(0.25)") and ok
	ok = _check("reader: step emits come from runtime Steps", data.relay_for(data.rules[0].steps[0]) == "standoff_tick") and ok
	ok = _check("catalog: 12 verbs incl. typed params", data.catalog.size() == 12 and VerbCatalog.find(data.catalog, "move_to")["args"][2]["type"] == TYPE_VECTOR3) and ok
	var prop_names: Array = data.props.map(func(prop: Dictionary) -> String: return prop["name"])
	ok = _check("Callboard discovers exported, onready, and scripted props",
		["guard", "lamp", "window", "shelter", "reward", "treat", "decoy"].all(
			func(prop: String) -> bool: return prop in prop_names)) and ok

	var gv := RuleGraphView.new()
	root.add_child(gv)
	gv.show_data(data)
	ok = _check("graph: rule nodes and wires built",
		gv._rule_nodes.size() == data.rules.size() and not gv.get_connection_list().is_empty()) and ok
	var min_rule_x: float = INF
	for rule in data.rules:
		min_rule_x = minf(min_rule_x, rule.pos.x)
	ok = _check("external Calls are arranged close to the rule column",
		is_equal_approx(gv._event_nodes["deliver"].position_offset.x + RuleGraphView.CALL_WIDTH,
			min_rule_x - RuleGraphView.CALL_GAP)) and ok
	var fresh_data := _copy_draft(data)
	fresh_data.call_positions = {}
	for rule in fresh_data.rules:
		rule.has_pos = false
	var fresh_graph := RuleGraphView.new()
	root.add_child(fresh_graph)
	fresh_graph.show_data(fresh_data)
	ok = _check("a resource with no node positions gets an initial automatic layout",
		fresh_graph._rule_nodes.values().all(func(node: GraphNode) -> bool:
			return node.position_offset != Vector2.ZERO)) and ok
	fresh_graph.queue_free()
	var kept_rule_node: GraphNode = gv._rule_nodes["z1_caught"]
	var updated_rule_node: GraphNode = gv._rule_nodes["z1_bark"]
	var kept_event_node: GraphNode = gv._event_nodes["deliver"]
	var graph_edit := _copy_draft(data)
	var edited_rule := graph_edit.find_rule("z1_bark")
	edited_rule.one_shot = true
	edited_rule.pos = Vector2(555, 77)
	edited_rule.has_pos = false
	gv.update_data(graph_edit)
	ok = _check("incremental graph refresh replaces only the changed rule card",
		gv._rule_nodes["z1_bark"] != updated_rule_node and gv._rule_nodes["z1_caught"] == kept_rule_node
		and gv._event_nodes["deliver"] == kept_event_node and not gv.get_connection_list().is_empty()) and ok
	ok = _check("incremental refresh does not auto-arrange nodes when position data exists",
		gv._rule_nodes["z1_bark"].position_offset == Vector2(555, 77)) and ok
	gv.set_minimized(true)
	var compact_rule: GraphNode = gv._rule_nodes["z1_bark"]
	var compact_treat: GraphNode = gv._rule_nodes["z1_treat"]
	var compact_call: GraphNode = gv._event_nodes["deliver"]
	var compact_treat_row := compact_treat.get_child(0) as HBoxContainer
	var compact_relay_label := compact_treat_row.get_child(compact_treat_row.get_child_count() - 1) as Label
	ok = _check("compact cards keep the title, collapse details and retain connections",
		compact_rule.title == "z1_bark" and compact_rule.get_child_count() == 1
		and not gv.get_connection_list().is_empty()) and ok
	ok = _check("compact cards show emitted relay names beside the summary icons",
		compact_relay_label != null and compact_relay_label.text == "calm_guard") and ok
	ok = _check("compact mode keeps external Call nodes at their normal size and layout",
		compact_call.title == "Call" and compact_call.custom_minimum_size.x == 174.0
		and compact_call.get_child_count() == 1
		and (compact_call.get_child(0) as Label).text == "deliver") and ok
	gv.set_minimized(false)
	gv._rule_nodes["z1_bark"].position_offset = Vector2(999, 777)
	gv.auto_arrange()
	var arranged_pos: Vector2 = gv._rule_nodes["z1_bark"].position_offset
	ok = _check("the Arrange command explicitly repositions saved rules",
		arranged_pos != Vector2(999, 777)) and ok
	gv.pulse("z1_bark")
	gv.queue_free()


	return ok

func _test_additional_stage_locations() -> bool:
	var previous: Variant = ProjectSettings.get_setting(
		Settings.STAGE_SCAN_FOLDERS, PackedStringArray())
	ProjectSettings.set_setting(Settings.STAGE_SCAN_FOLDERS,
		PackedStringArray(["res://demo/stages/", "res://demo/stages/stage_01/", "res://stages"]))
	var directories := Settings.stage_directories()
	var board := Callboard.new()
	root.add_child(board)
	var paths := board._collect_all_stage_definition_paths()
	var ok := _check("additional stage directories are normalized and deduplicated",
		directories == ["res://stages", "res://demo/stages", "res://demo/stages/stage_01"]
		and paths.count(DEFINITION_PATH) == 1)
	ok = _check("stage picker labels entries relative to their selected root",
		Callboard._path_relative_to(DEFINITION_PATH, "res://demo/stages") == "stage_01/stage_01.tres") and ok
	board.queue_free()
	ProjectSettings.set_setting(Settings.STAGE_SCAN_FOLDERS, previous)
	return ok

func _test_board_editing() -> bool:
	var ok := true
	var definition := load(DEFINITION_PATH) as StageDefinition
	# --- D. Editing through the board ------------------------------------------------
	var board := Callboard.new()
	root.add_child(board)
	var stage_paths := board._collect_all_stage_definition_paths()
	ok = _check("board: discovers the demo stage from the project settings",
		stage_paths.has(DEFINITION_PATH)) and ok
	board.open_script(DEFINITION_PATH)
	var d := board._data
	board.view._rule_nodes["z1_bark"].position_offset = Vector2(555, 77)

	var nr: RuleData = board.add_rule()
	ok = _check("adding an empty rule creates a unique ID and reports its missing steps and relay",
		d.rules.size() == definition.rules.size() + 1
		and d.warnings.any(func(note): return "'new_rule' has no steps or completion relay" in note)) and ok
	ok = _check("card move synced into model", d.rules[1].pos == Vector2(555, 77)) and ok
	nr.requires = PackedStringArray(["guard_calmed"])
	nr.steps.append(VerbCatalog.new_step(d, "score"))
	nr.steps.append(VerbCatalog.new_step(d, "show_node"))
	ok = _check("new_step fills required args with a compatible prop", nr.steps[1].args == PackedStringArray(["guard"])) and ok
	board._changed("new_rule")
	ok = _check("add steps: clean again", d.warnings.is_empty() and d.errors.is_empty()) and ok
	var retained_stage: Stage = board._analysis_stage
	var retained_prop_count := retained_stage.get_child_count()
	board._changed("new_rule")
	ok = _check("analysis reuses the built scene props between edits",
		board._analysis_stage == retained_stage and retained_stage.get_child_count() == retained_prop_count) and ok

	board.connect_wire({"rule": "z1_bark", "port": 0}, "new_rule")
	ok = _check("wire: names the unnamed port and sets trigger", _rule(d, "z1_bark").emit == "z1_bark_done" and nr.trigger == "relay:z1_bark_done") and ok
	ok = _check("wire: no problems after wiring", d.warnings.is_empty()) and ok
	board.connect_wire({"event": "deliver"}, "new_rule")
	ok = _check("wire from event node", nr.trigger == "deliver") and ok
	board.disconnect_wire("new_rule")
	ok = _check("disconnect: trigger cleared and flagged", nr.trigger == "" and d.warnings.any(func(p): return "'new_rule' has no trigger" in p)) and ok
	ok = _check("advisory findings mark the rule and menu as warnings",
		d.errors.is_empty() and board.view._rule_nodes["new_rule"].title.begins_with("Warning · ")
		and board._notes_button.get_popup().get_item_text(0).begins_with("Warning: ")) and ok

	board.duplicate_rule("new_rule")
	ok = _check("duplicate: unique id", AuthoredData.rule_ids(d).has("new_rule_copy")) and ok
	board.delete_rule("new_rule_copy")
	board.delete_rule("new_rule")
	ok = _check("delete: original count restored; unheard relay is flagged",
		d.rules.size() == definition.rules.size() and d.warnings.size() == 1 and "z1_bark_done" in d.warnings[0]) and ok
	_rule(d, "z1_bark").emit = ""
	board._changed("")
	ok = _check("clearing the emit makes it clean again", d.warnings.is_empty()) and ok

	# Blackboard editing
	board.blackboard._on_add(0)
	ok = _check("add variable (bool, local)", d.variables.size() == 4 and d.variables[3].key == "new_var" and d.variables[3].scope == "local") and ok
	ok = _check("added variable is generated", RuleGraphReader.make_definition(d).variables[3].default_value == false) and ok
	AuthoredData.rename_key(d, "lamp_on", "alarm_on")
	board._changed("")
	ok = _check("rename key updates guards", _rule(d, "z1_caught").requires == PackedStringArray(["alarm_on"])) and ok
	ok = _check("rename key makes implicit `light` key explicit", _rule(d, "z1_bark").steps[1].args == PackedStringArray(["lamp", "true", "3.5", '&"alarm_on"'])) and ok
	ok = _check("rename key: still compiles with no problems", d.errors.is_empty() and d.warnings.is_empty()) and ok
	d.variables = d.variables.filter(func(v): return v.key != "guard_calmed")
	board._changed("")
	ok = _check("delete variable: references are flagged", d.warnings.any(func(p): return "'guard_calmed'" in p and "not declared" in p)) and ok

	# Groups
	board.add_group()
	ok = _check("add group", d.groups.size() == 4) and ok
	_rule(d, "z1_standoff").group = "Group"
	board._changed("z1_standoff")
	board.delete_group("Group")
	ok = _check("delete group clears membership", d.groups.size() == 3 and _rule(d, "z1_standoff").group == "") and ok
	board.queue_free()


	return ok

func _test_save_and_history() -> bool:
	var ok := true
	var src := FileAccess.get_file_as_string(STAGE_PATH)
	var definition := load(DEFINITION_PATH) as StageDefinition
	definition.call_positions = {"deliver": Vector2(-600, 150)}
	# --- E. Save: refuses broken output, writes good output ----------------------------
	ok = _check("temporary resource saved", ResourceSaver.save(definition, TMP_PATH) == OK) and ok
	var original := FileAccess.get_file_as_string(TMP_PATH)
	var b2 := Callboard.new()
	root.add_child(b2)
	b2.open_script(TMP_PATH)
	await process_frame
	var d2 := b2._data
	ok = _check("adding an event creates a wireable event card",
		b2.add_call_name("  doorbell  ") and b2.view._event_nodes.has("doorbell")) and ok
	ok = _check("invalid Call IDs are rejected without editing the graph",
		not b2.add_call_name("doorbell") and not b2.add_call_name(" ")
		and not b2.add_call_name("relay:doorbell") and not b2.add_call_name('door"bell')
		and not b2.view._event_nodes.has("relay:doorbell")) and ok
	b2._undo_button.pressed.emit()
	ok = _check("undo event returns to clean state", not b2.view._event_nodes.has("doorbell") and not b2._dirty) and ok
	b2._redo_button.pressed.emit()
	ok = _check("redo restores event", b2.view._event_nodes.has("doorbell") and b2._dirty) and ok

	var old_pos: Vector2 = _rule(d2, "z1_bark").pos
	b2.view._rule_nodes["z1_bark"].position_offset = old_pos + Vector2(42, 0)
	b2.view.end_node_move.emit()
	b2.undo()
	ok = _check("undo restores card position", b2.view.get_positions()["z1_bark"] == old_pos) and ok
	b2.redo()
	ok = _check("redo restores card move", b2.view.get_positions()["z1_bark"] == old_pos + Vector2(42, 0)) and ok
	b2.undo()
	var frame: GraphFrame = b2.view._frames["Delivery"]
	var frame_size := frame.size
	frame.resize_request.emit(frame_size.round() + Vector2(30.0002, 29.9998))
	b2.undo()
	ok = _check("undo restores frame size", b2.view.get_group_rects()["Delivery"].size == frame_size) and ok
	b2.redo()
	ok = _check("redo restores frame resize",
		b2.view.get_group_rects()["Delivery"].size == frame_size.round() + Vector2(30, 30)) and ok
	b2.undo()
	b2.blackboard._on_add(0)
	ok = _check("new edit clears redo", b2._redo_button.disabled and d2.variables.size() == 4) and ok
	b2.undo()
	ok = _check("undo restores blackboard rows", d2.variables.size() == 3) and ok

	b2.connect_wire({"event": "doorbell"}, "z1_decoy")
	ok = _check("wire uses new event", _rule(d2, "z1_decoy").trigger == "doorbell") and ok
	b2.undo()
	ok = _check("undo restores previous wire", _rule(d2, "z1_decoy").trigger == "offer:decoy") and ok
	b2.redo()
	ok = _check("redo reconnects event wire", _rule(d2, "z1_decoy").trigger == "doorbell") and ok
	_rule(d2, "z1_standoff").steps[0].args[0] = "@@"
	b2._changed("z1_standoff")
	ok = _check("broken edit: compile failure detected", not d2.errors.is_empty()) and ok
	b2._on_rule_selected("z1_calm")
	var note_index: int = d2.errors.find_custom(func(note: String) -> bool: return "'z1_standoff'" in note)
	if note_index >= 0:
		b2._notes_button.get_popup().index_pressed.emit(note_index)
	ok = _check("choosing a validation note selects the affected rule",
		b2._notes_button.visible and note_index >= 0 and b2._selected == "z1_standoff") and ok
	ok = _check("compile errors are labeled on the graph and in the diagnostics menu",
		note_index >= 0 and b2.view._rule_nodes["z1_standoff"].title.begins_with("Error · ")
		and b2._notes_button.get_popup().get_item_text(note_index).begins_with("Error: ")) and ok
	b2.save()
	ok = _check("broken edit: save refused, file untouched", FileAccess.get_file_as_string(TMP_PATH) == original) and ok
	b2._request_reload()
	ok = _check("reload prompts before discarding unsaved edits",
		b2._reload_dialog.visible and b2.is_dirty()) and ok
	b2._reload_dialog.hide()
	ok = _check("canceling reload leaves the draft intact",
		_rule(d2, "z1_standoff").steps[0].args[0] == "@@") and ok
	_rule(d2, "z1_standoff").steps[0].args[0] = "4.0"
	var added: RuleData = b2.add_rule()
	added.steps.append(VerbCatalog.new_step(d2, "score"))
	b2.connect_wire({"rule": "z1_calm", "port": 0}, added.id)
	var saved_frame: GraphFrame = b2.view._frames["Delivery"]
	saved_frame.size += Vector2(10.0002, 0)
	var expected_size := saved_frame.size.round()
	b2.view.select_rule("z1_standoff")
	var policy := b2.inspector.find_child("ReentryPolicy", true, false) as OptionButton
	ok = _check("existing rules show Ignore by default",
		policy != null and policy.get_selected_id() == Rule.ReentryPolicy.IGNORE) and ok
	if policy:
		policy.select(policy.get_item_index(Rule.ReentryPolicy.RESTART))
		policy.item_selected.emit(policy.selected)
	ok = _check("changing the dropdown updates the rule",
		_rule(d2, "z1_standoff").get("reentry") == Rule.ReentryPolicy.RESTART) and ok
	var saved_rule_pos := Vector2(712, 286)
	var saved_call_pos := Vector2(-580, 174)
	b2.view._rule_nodes["z1_bark"].position_offset = saved_rule_pos
	b2.view._event_nodes["deliver"].position_offset = saved_call_pos
	b2.view.end_node_move.emit()
	b2.save()
	var re := RuleGraphReader.inspect_definition(TMP_PATH)
	ok = _check("save: script unchanged", FileAccess.get_file_as_string(STAGE_PATH) == src) and ok
	ok = _check("save: rule, relay and interval persisted",
		_rule(re, "new_rule").trigger == "relay:z1_calm_done"
		and _rule(re, "z1_standoff").steps[0].args[0] == "4.0") and ok
	ok = _check("save: the re-entry policy persists",
		_rule(re, "z1_standoff").get("reentry") == Rule.ReentryPolicy.RESTART) and ok
	ok = _check("save: frame size is rounded on disk",
		re.groups.any(func(g: GroupData) -> bool: return g.name == "Delivery" and g.rect.size == expected_size)) and ok
	ok = _check("save: moved rule position is preserved",
		_rule(re, "z1_bark").has_pos and _rule(re, "z1_bark").pos == saved_rule_pos) and ok
	ok = _check("save: moved Call position is preserved",
		re.call_positions.get("deliver") == saved_call_pos) and ok
	ok = _check("save: reloaded stage builds with no problems", re.errors.is_empty() and re.warnings.is_empty()) and ok
	ok = _check("new event and wire persist",
		re.external_calls.has("doorbell") and _rule(re, "z1_decoy").trigger == "doorbell") and ok
	b2.undo()
	ok = _check("undo after saving is an unsaved edit", b2._dirty) and ok
	b2.redo()
	ok = _check("redo to saved state clears unsaved indicator", not b2._dirty) and ok
	b2.open_script(TMP_PATH)
	ok = _check("reopening resource restores moved rule position",
		b2.view.get_positions()["z1_bark"] == saved_rule_pos) and ok
	ok = _check("reopening resource restores moved Call position",
		b2.view.get_call_positions()["deliver"] == saved_call_pos) and ok
	ok = _check("reopening resource starts a fresh history", b2._undo_button.disabled and b2._redo_button.disabled) and ok
	b2.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))

	return ok


func _test_debounced_history() -> bool:
	var definition := load(DEFINITION_PATH) as StageDefinition
	if not _check("debounce fixture saved", ResourceSaver.save(definition, TMP_PATH) == OK):
		return false
	var board := Callboard.new()
	board._debounce_edits = true
	root.add_child(board)
	await process_frame
	board.open_script(TMP_PATH)
	var id := "z1_standoff"
	var step: StepData = _rule(board._data, id).steps[0]
	step.args[1] = '&"updated_tick"'
	board.inspector.changed.emit(id)
	var ok := _check("scheduled edit records immediately and defers analysis",
		board.is_dirty() and board._data.relay_for(step) == "standoff_tick" and not board._analysis_debounce.is_stopped())
	await create_timer(0.15).timeout
	ok = _check("debounced analysis updates relay metadata", board._data.relay_for(step) == "updated_tick") and ok
	board.undo()
	step = _rule(board._data, id).steps[0]
	ok = _check("one undo restores the authored relay and its metadata",
		step.args[1] == '&"standoff_tick"' and board._data.relay_for(step) == "standoff_tick"
		and not board.is_dirty() and not board._history.can_undo()) and ok
	board.redo()
	step = _rule(board._data, id).steps[0]
	ok = _check("one redo reapplies the authored relay and its metadata",
		step.args[1] == '&"updated_tick"' and board._data.relay_for(step) == "updated_tick") and ok

	var previous_card: GraphNode = board.view._rule_nodes[id]
	step.args[1] = '&"standoff_tick"'
	board.inspector.changed.emit(id)
	board.save()
	ok = _check("saving during debounce refreshes the changed graph card",
		board._analysis_debounce.is_stopped() and board._data.relay_for(step) == "standoff_tick"
		and board.view._rule_nodes[id] != previous_card and not board.is_dirty()) and ok
	board.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	return ok

func _test_canvas_actions() -> bool:
	var board := Callboard.new()
	board.size = Vector2(1280, 720)
	root.add_child(board)
	board.open_script(DEFINITION_PATH)
	await process_frame
	var view := board.view
	var ok := _check("rule settings starts hidden", not board._settings_window.visible)
	var overview := view._minimap_control
	var overview_right := overview.get_rect().end.x if overview != null else 0.0
	view.select_rule("z1_bark")
	var rule: GraphNode = view._rule_nodes["z1_bark"]
	ok = _check("canvas selection opens rule settings",
		board._settings_window.visible and board.inspector._rule.get("id") == "z1_bark") and ok
	ok = _check("the minimap moves clear of the settings panel",
		overview != null and overview.get_rect().end.x < overview_right
		and overview.get_rect().end.x <= board._settings_window.position.x) and ok
	var other_rule: GraphNode = view._rule_nodes["z1_calm"]
	other_rule.selected = true
	other_rule.selected = false
	await process_frame
	ok = _check("rule settings follows a remaining selected rule",
		board._settings_window.visible and board.inspector._rule.get("id") == "z1_bark") and ok
	rule.selected = false
	await process_frame
	ok = _check("canvas deselection clears and hides rule settings",
		board._selected.is_empty() and board.inspector._rule == null and not board._settings_window.visible) and ok
	view.select_rule("z1_bark")
	board._debounce_edits = true
	board._schedule_change("z1_bark")
	board._close_settings()
	board._flush_debounced_change()
	ok = _check("close clears graph selection and stays closed after pending analysis",
		not rule.selected and board._selected.is_empty() and not board._settings_window.visible) and ok
	board._debounce_edits = false

	view.zoom = 0.75
	view.scroll_offset = Vector2(80, -40)
	var pointer := Vector2(-40, -40)
	var origin := ((pointer + view.scroll_offset) / view.zoom).round()
	view.popup_request.emit(pointer)
	ok = _check("canvas popup offers all three creation actions",
		board._create_menu.visible and board._create_menu.item_count == 3) and ok
	board._create_menu.id_pressed.emit(Callboard.CreateAction.RULE)
	board._create_menu.hide()
	ok = _check("context-created rule uses the clicked graph coordinates",
		_rule(board._data, "new_rule").get("pos") == origin) and ok
	board.undo()
	view.popup_request.emit(pointer)
	board._create_menu.id_pressed.emit(Callboard.CreateAction.GROUP)
	board._create_menu.hide()
	ok = _check("context-created group uses the clicked graph coordinates",
		board._data.groups.back().rect.position == origin) and ok
	board.undo()
	await process_frame
	rule = view._rule_nodes["z1_bark"]
	view.popup_request.emit(rule.position + rule.size * view.zoom * 0.5)
	ok = _check("right-click on a rule inside a frame targets the rule",
		board._context_target.get("id") == "z1_bark"
		and board._create_menu.get_item_index(Callboard.ContextAction.DELETE) >= 0) and ok
	board._create_menu.id_pressed.emit(Callboard.ContextAction.DELETE)
	board._create_menu.hide()
	ok = _check("context delete removes the targeted rule", not view._rule_nodes.has("z1_bark")) and ok
	board.undo()
	await process_frame
	var frame: GraphFrame = view._frames["Delivery"]
	view.popup_request.emit(frame.position + Vector2(6, 6))
	board._create_menu.id_pressed.emit(Callboard.ContextAction.DELETE)
	board._create_menu.hide()
	ok = _check("context delete removes a group and keeps its rules",
		not view._frames.has("Delivery") and view._rule_nodes.has("z1_delivered")) and ok
	board.undo()
	await process_frame
	var event: GraphNode = view._event_nodes["offer:decoy"]
	view.popup_request.emit(event.position + event.size * view.zoom * 0.5)
	board._create_menu.id_pressed.emit(Callboard.ContextAction.DELETE)
	board._create_menu.hide()
	ok = _check("event context delete confirms the targeted event",
		board._delete_connection_dialog.visible and "offer:decoy" in board._delete_connection_dialog.dialog_text) and ok
	board._delete_connection_dialog.confirmed.emit()
	ok = _check("event context delete removes the targeted event", not view._event_nodes.has("offer:decoy")) and ok
	board.queue_free()
	return ok

func _test_event_and_relay_edits() -> bool:
	var definition := load(DEFINITION_PATH) as StageDefinition
	if not _check("connection fixture saved", ResourceSaver.save(definition, TMP_PATH) == OK):
		return false
	var board := Callboard.new()
	root.add_child(board)
	board.open_script(TMP_PATH)
	await process_frame
	board._connections_button.button_pressed = true
	board._refresh_connections("offer:decoy")
	var card: Control = board._connection_cards["offer:decoy"]
	var details := card.find_child("ConnectionDetails", true, false) as Label
	var ok := _check("connection window lists affected rules and external callers",
		board._connections_panel.visible and details.visible and "z1_decoy — trigger" in details.text
		and "gameplay code" in details.text)
	var edit := card.find_child("ConnectionName", true, false) as LineEdit
	var renamed_call_pos := Vector2(-640, 202)
	board.view._event_nodes["offer:decoy"].position_offset = renamed_call_pos
	board.view.end_node_move.emit()
	edit.text = "offer:parcel"
	edit.text_changed.emit(edit.text)
	edit.text_submitted.emit(edit.text)
	ok = _check("event rename updates its card and rule trigger",
		board.view._event_nodes.has("offer:parcel")
		and not board.view._event_nodes.has("offer:decoy")
		and _rule(board._data, "z1_decoy").trigger == "offer:parcel"
		and board.view.get_call_positions()["offer:parcel"] == renamed_call_pos) and ok
	ok = _check("event name collision leaves connections alone",
		not board.rename_connection("offer:parcel", "deliver").is_empty()
		and _rule(board._data, "z1_decoy").trigger == "offer:parcel") and ok
	card = board._connection_cards["offer:parcel"]
	var delete := card.find_child("DeleteConnection", true, false) as Button
	delete.pressed.emit()
	ok = _check("delete confirmation names the affected trigger",
		board._delete_connection_dialog.visible
		and "z1_decoy — trigger" in board._delete_connection_dialog.dialog_text) and ok
	board._delete_connection_dialog.confirmed.emit()
	ok = _check("deleting an event clears its dependent trigger",
		not board.view._event_nodes.has("offer:parcel")
		and _rule(board._data, "z1_decoy").trigger == "") and ok
	board.undo()
	ok = _check("undo restores the event and its wire",
		board.view._event_nodes.has("offer:parcel")
		and _rule(board._data, "z1_decoy").trigger == "offer:parcel") and ok

	ok = _check("relay rename updates every rule emitter and the listener",
		board.rename_connection("relay:calm_guard", "guard_calm").is_empty()
		and _rule(board._data, "z1_treat").emit == "guard_calm"
		and _rule(board._data, "z1_decoy").emit == "guard_calm"
		and _rule(board._data, "z1_calm").trigger == "relay:guard_calm") and ok
	ok = _check("relay rename updates the authored argument of a step emitter",
		board.rename_connection("relay:standoff_tick", "guard_tick").is_empty()
		and _rule(board._data, "z1_standoff").steps[0].args == PackedStringArray(["3.5", '&"guard_tick"'])
		and _rule(board._data, "z1_bark").trigger == "relay:guard_tick") and ok
	ok = _check("an external relay rename updates its declaration and listener",
		board.rename_connection("relay:treat_out", "treat_ready").is_empty()
		and board._data.external_calls.has("relay:treat_ready")
		and _rule(board._data, "z1_treat").trigger == "relay:treat_ready") and ok

	board.save()
	var reloaded := RuleGraphReader.inspect_definition(TMP_PATH)
	var tick := _rule(reloaded, "z1_standoff").steps[0]
	var saved: StageDefinition = reloaded.definition
	ok = _check("save and reload preserve typed data and rederive step metadata",
		reloaded.errors.is_empty() and reloaded.relay_for(tick) == "guard_tick"
		and reloaded.step_metadata[tick].relay_argument == 1
		and saved.rules[0] is RuleData and saved.rules[0].steps[0] is StepData) and ok

	var affected := RuleConnections.impact(board._data, "relay:guard_tick")
	ok = _check("relay deletion lists its emitting step and receiving trigger",
		affected.has("z1_standoff — step 1 (repeat_emit)") and affected.has("z1_bark — trigger")) and ok
	ok = _check("deleting a step relay removes the emitting step and disconnects its listener",
		board.delete_connection("relay:guard_tick").is_empty()
		and _rule(board._data, "z1_standoff").steps.is_empty()
		and _rule(board._data, "z1_bark").trigger == "") and ok
	board.undo()
	ok = _check("undo restores the emitting step and relay connection",
		board._data.relay_for(_rule(board._data, "z1_standoff").steps[0]) == "guard_tick"
		and _rule(board._data, "z1_bark").trigger == "relay:guard_tick") and ok
	ok = _check("deleting a rule relay clears all its outputs and listeners",
		board.delete_connection("relay:guard_calm").is_empty()
		and _rule(board._data, "z1_treat").emit == ""
		and _rule(board._data, "z1_decoy").emit == ""
		and _rule(board._data, "z1_calm").trigger == "") and ok
	board.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	return ok

func _test_rename_saved_state() -> bool:
	var definition := load(DEFINITION_PATH) as StageDefinition
	if not _check("rename fixture saved", ResourceSaver.save(definition, TMP_PATH) == OK):
		return false
	var board := Callboard.new()
	root.add_child(board)
	board.open_script(TMP_PATH)
	board._on_rule_selected("z1_delivered")
	board.inspector._set_id("delivered")
	board.undo()
	var ok := _check("undo restores the rule ID", _rule(board._data, "z1_delivered") != null)
	board.redo()
	board._on_rule_selected("delivered")
	board.inspector._set_id("parcel_delivered")
	var key_edit := board.blackboard._rows.get_child(0).find_children("*", "LineEdit", true, false).front() as LineEdit
	key_edit.text = "guard_relaxed"
	key_edit.text_submitted.emit(key_edit.text)
	board.save()

	var data := RuleGraphReader.inspect_definition(TMP_PATH)
	var renamed: StageDefinition = data.definition
	var stage := (load(renamed.preview_scene_path) as PackedScene).instantiate() as Stage
	stage.definition = renamed
	stage.fired = {&"z1_delivered": true}
	stage.saved_vars = {&"guard_calmed": true}
	root.add_child(stage)
	var delivered: Rule
	for rule in stage.engine.rules:
		if rule.id == &"parcel_delivered":
			delivered = rule
			break
	ok = _check("an existing latch survives repeated rule renames and reload",
		delivered != null and delivered.latch_key() == &"z1_delivered"
		and not stage.engine.passes(delivered)) and ok
	ok = _check("the renamed Blackboard key reads an existing saved value",
		stage.get_var(&"guard_relaxed") == true and stage.get_var(&"guard_calmed") == true
		and not stage.saved_vars.has(&"guard_relaxed")) and ok
	stage.write_var(&"guard_relaxed", false)
	ok = _check("writes still use the original saved storage key",
		stage.saved_vars == {&"guard_calmed": false}) and ok
	stage.free()

	board.duplicate_rule("parcel_delivered")
	board.inspector._set_id("z1_delivered")
	var original := _rule(board._data, "parcel_delivered")
	var copy := _rule(board._data, "z1_delivered")
	ok = _check("a duplicate can reuse the old rule name without inheriting its latch",
		original.state_key != copy.state_key) and ok
	board.blackboard._on_add(0)
	var rows := board.blackboard._rows
	var reused_key := rows.get_child(rows.get_child_count() - 1).find_children("*", "LineEdit", true, false).front() as LineEdit
	reused_key.text = "guard_calmed"
	reused_key.text_submitted.emit(reused_key.text)
	board._data.variables.back().scope = "saved"
	var reused_stage := (load(renamed.preview_scene_path) as PackedScene).instantiate() as Stage
	reused_stage.definition = RuleGraphReader.make_definition(board._data)
	reused_stage.saved_vars = {&"guard_calmed": true}
	reused_stage.fired = {&"z1_delivered": true}
	root.add_child(reused_stage)
	ok = _check("has_fired checks each current rule's own latch after an ID is reused",
		reused_stage.has_fired(&"parcel_delivered") and not reused_stage.has_fired(&"z1_delivered")) and ok
	ok = _check("a new saved variable can reuse the old name with its own default",
		reused_stage.get_var(&"guard_relaxed") == true and reused_stage.get_var(&"guard_calmed") == false) and ok
	reused_stage.free()
	board.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	return ok

func _test_numeric_undo() -> bool:
	var board := Callboard.new()
	root.add_child(board)
	board.open_script(DEFINITION_PATH)
	await process_frame
	board.blackboard._on_add(1)
	var row := board.blackboard._rows.get_child(board.blackboard._rows.get_child_count() - 1)
	var spin := row.find_children("*", "SpinBox", true, false).front() as SpinBox
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	board._input(mouse)
	spin.value = 1.0
	spin.value = 2.0
	mouse.pressed = false
	board._input(mouse)
	mouse.pressed = true
	board._input(mouse)
	spin.value = 3.0
	spin.value = 4.0
	mouse.pressed = false
	board._input(mouse)
	board.undo()
	var ok := _check("a second SpinBox gesture undoes independently",
		board._data.variables.back().default_value == 2)
	board.undo()
	ok = _check("one undo restores the value before the first SpinBox gesture",
		board._data.variables.back().default_value == 0) and ok
	board.redo()
	board.redo()
	ok = _check("redo restores the final value of each gesture",
		board._data.variables.back().default_value == 4) and ok

	board._on_rule_selected("z1_standoff")
	var interval := board.inspector.find_children("*", "SpinBox", true, false).front() as SpinBox
	mouse.pressed = true
	board._input(mouse)
	interval.value = 4.0
	interval.value = 5.0
	mouse.pressed = false
	board._input(mouse)
	ok = _check("the numeric step field stays active throughout a gesture",
		_rule(board._data, "z1_standoff").steps[0].args[0] == "5.0") and ok
	board.undo()
	ok = _check("one undo restores the step argument before the drag",
		_rule(board._data, "z1_standoff").steps[0].args[0] == "3.5") and ok
	board.queue_free()
	return ok

func _test_live_debug() -> bool:
	var definition := load(DEFINITION_PATH) as StageDefinition
	var stage := definition.instantiate_for_analysis(root)
	var board := Callboard.new()
	root.add_child(board)
	board._show(GraphDraft.load_error("No stage definitions"), false)
	var load_error_hides_debug := not board._debug_button.visible and not board._live_debug_panel.visible
	board.bind_live(stage)
	stage.engine.rules.clear()
	var panel: CallboardLiveDebugPanel = board._live_debug_ui
	var live_controls := board._debug_button.visible and board._connections_button.visible
	board._connections_button.button_pressed = true
	var panels_open := board._connections_panel.visible and panel.panel.visible
	var call_card: Control = board._connection_cards.get("offer:decoy")
	var relay_card: Control = board._connection_cards.get("relay:treat_out")
	var fire_button := call_card.find_child("FireCall", true, false) as Button if call_card else null
	var call_can_fire := fire_button != null and not fire_button.disabled
	var traced_call := false
	if call_can_fire:
		fire_button.pressed.emit()
		if panel._trace_rows.get_child_count() == 1:
			var trace_row := panel._trace_rows.get_child(0)
			for label in trace_row.find_children("*", "Label", true, false):
				traced_call = traced_call or "offer:decoy" in label.text
	var relay_has_no_fire := relay_card != null and relay_card.find_child("FireCall", true, false) == null
	board._blackboard_button.button_pressed = true
	var debug_still_open := panel.panel.visible and not board._connections_panel.visible
	board._debug_button.button_pressed = false
	var active_row := panel._active_rows.get_child(0)
	var trace_count := panel._trace_rows.get_child_count()
	stage.fire(&"deliver")
	var hidden_rows_unchanged := panel._active_rows.get_child(0) == active_row \
		and panel._trace_rows.get_child_count() == trace_count
	board._debug_button.button_pressed = true
	var buffered_trace_rendered := panel._trace_rows.get_child_count() == trace_count + 1
	for i in CallboardLiveDebugPanel.MAX_TRACE_ROWS + 1:
		stage.fire(&"deliver")
	var trace_is_bounded := panel._trace_rows.get_child_count() == CallboardLiveDebugPanel.MAX_TRACE_ROWS
	board.free()
	stage.free()
	var ok := _check("live debug and connections launchers are shown", live_controls)
	ok = _check("editor load errors keep the live debug controls hidden", load_error_hides_debug) and ok
	ok = _check("hidden debug buffers traces without rebuilding rows", hidden_rows_unchanged and buffered_trace_rendered) and ok
	ok = _check("visible debug keeps only the latest trace rows", trace_is_bounded) and ok
	ok = _check("debug stays open when switching between connections and Blackboard", panels_open and debug_still_open) and ok
	ok = _check("live connections can fire Calls but not relays", call_can_fire and relay_has_no_fire) and ok
	return _check("live debug records Calls fired from the connections panel", traced_call) and ok

func _rule(draft: GraphDraft, id: String) -> RuleData:
	return draft.find_rule(id)

func _copy_draft(source: GraphDraft) -> GraphDraft:
	var draft := GraphDraft.new()
	draft.definition = source.definition
	draft.catalog = source.catalog
	draft.props = source.props
	draft.restore(source.snapshot())
	RuleGraphReader.analyze(draft)
	return draft

func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond

