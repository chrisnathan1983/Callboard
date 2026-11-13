@tool
class_name Callboard extends Control
## Full-viewport rule graph with floating authoring controls.
##
## Editor mode edits a StageDefinition and saves its resource after validation.
## Live mode shows a running stage's values and rule pulses.

signal layout_saved(path: String)

const STAGES_DIR := "res://stages"
const EDIT_FIELDS := ["external_calls", "external_vars", "vars", "rules", "groups"]
const Style := preload("res://addons/callboard/editor/board_style.gd")
enum CreateAction { EVENT, RULE, GROUP }
enum ContextAction { EDIT = 10, DUPLICATE, DELETE }

var view := RuleGraphView.new()
var blackboard := BlackboardPanel.new()
var inspector := RuleInspector.new()
var _history := CallboardHistory.new()
var _overlay_layout := CallboardOverlayLayout.new()
var _picker := OptionButton.new()
var _status := Label.new()
var _status_note_cursor := 0
var _edit_buttons: Array[Button] = []
var _data := {}
var _path := ""
var _selected := ""
var _selected_group := ""
var _dirty := false
var _editable := true
var _live: Stage
var _analysis_stage: Stage
var _analysis_source_key := ""
var _analysis_debounce := Timer.new()
var _debounce_edits := Engine.is_editor_hint()
var _pending_selection := ""
var _accum := 0.0
var _save_button: Button
var _reload_button: Button
var _undo_button: Button
var _redo_button: Button
var _event_button: Button
var _event_dialog := ConfirmationDialog.new()
var _event_name := LineEdit.new()
var _event_error := Label.new()
var _blackboard_button: Button
var _connections_button: Button
var _debug_button: Button
var _connections_ui := CallboardConnections.new()
var _live_debug_ui := CallboardLiveDebugPanel.new()
var _connections_panel: PanelContainer
var _live_debug_panel: PanelContainer
var _connection_rows: VBoxContainer = _connections_ui.rows
var _connection_cards: Dictionary = _connections_ui.cards
var _expanded_connections: Dictionary = _connections_ui.expanded
var _delete_connection_dialog: ConfirmationDialog = _connections_ui.delete_dialog
var _restoring := false
var _spin_drag_active := false
var _spin_refresh_pending := false
var _selecting_after_edit := false
var _reveal_pending := false
var _file_tools: PanelContainer
var _create_tools: PanelContainer
var _left_tools: VBoxContainer
var _blackboard_panel: PanelContainer
var _settings_window: PanelContainer
var _context_menu := CallboardContextMenu.new()
var _create_menu: PopupMenu = _context_menu
var _create_position: Vector2:
	get:
		return _context_menu.create_position
	set(value):
		_context_menu.create_position = value
var _context_target: Dictionary:
	get:
		return _context_menu.context_target
	set(value):
		_context_menu.context_target = value

func _init() -> void:
	add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_analysis_debounce.one_shot = true
	_analysis_debounce.wait_time = 0.075
	_analysis_debounce.timeout.connect(_flush_debounced_change)
	add_child(_analysis_debounce)
	var stage_tools := HBoxContainer.new()
	_picker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_picker.fit_to_longest_item = false
	_picker.custom_minimum_size.x = 212
	_picker.ready.connect(func() -> void:
		if Engine.is_editor_hint():
			_picker.custom_minimum_size.x *= _picker.get_theme_default_base_scale())
	_picker.item_selected.connect(_on_picker)
	stage_tools.add_child(_picker)
	_save_button = _file_button(&"Save", "Save", "Save stage", save)
	_reload_button = _file_button(&"Reload", "↻", "Reload stage from disk", refresh)
	stage_tools.add_child(_save_button)
	stage_tools.add_child(_reload_button)
	_undo_button = _button("↶", undo)
	_undo_button.accessibility_name = "Undo"
	_undo_button.tooltip_text = "Undo (Ctrl/Cmd+Z)"
	_redo_button = _button("↷", redo)
	_redo_button.accessibility_name = "Redo"
	_redo_button.tooltip_text = "Redo (Ctrl/Cmd+Shift+Z or Ctrl/Cmd+Y)"
	stage_tools.add_child(_undo_button)
	stage_tools.add_child(_redo_button)
	var file_tools := VBoxContainer.new()
	file_tools.add_child(stage_tools)
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	Style.fallback_font_size(_status, 13)
	_status.custom_minimum_size.x = 320
	_status.mouse_filter = Control.MOUSE_FILTER_PASS
	_status.gui_input.connect(_on_status_gui_input)
	file_tools.add_child(_status)
	_file_tools = _floating_toolbar(file_tools)

	var create_tools := HBoxContainer.new()
	_event_button = _button("+ Call", _open_event_dialog)
	create_tools.add_child(_event_button)
	create_tools.add_child(_button("+ Rule", add_rule))
	create_tools.add_child(_button("+ Group", add_group))
	_create_tools = _floating_toolbar(create_tools)

	_setup_event_dialog()
	_setup_create_menu()

	view.rule_selected.connect(_on_rule_selected)
	view.group_selected.connect(_on_group_selected)
	view.selection_cleared.connect(_clear_selection)
	view.popup_request.connect(_open_create_menu)
	view.wire_added.connect(func(src: Dictionary, to: String) -> void: connect_wire(src, to))
	view.wire_removed.connect(func(to: String) -> void: disconnect_wire(to))
	view.rules_delete_requested.connect(_delete_rules)
	view.rules_linked_to_group.connect(func(ids: Array, g: String) -> void:
		for rd in _data["rules"]:
			if ids.has(rd["id"]):
				rd["group"] = g
		_changed(_selected))
	view.layout_changed.connect(_layout_changed)
	blackboard.changed.connect(func() -> void: _schedule_change(_selected))
	blackboard.numeric_changed.connect(func(spin: SpinBox) -> void: _changed(_selected, spin))
	inspector.changed.connect(_schedule_change)
	inspector.numeric_changed.connect(_changed)
	inspector.delete_requested.connect(delete_rule)
	inspector.duplicate_requested.connect(duplicate_rule)
	inspector.group_edited.connect(func(group_name: String) -> void:
		_selected_group = group_name
		_changed(""))
	inspector.group_delete_requested.connect(delete_group)
	inspector.content_size_changed.connect(_layout_overlays, CONNECT_DEFERRED)
	_make_left_tools()
	blackboard.content_size_changed.connect(_layout_overlays, CONNECT_DEFERRED)
	var settings := VBoxContainer.new()
	settings.add_theme_constant_override("separation", 10)
	settings.add_child(Style.label("Rule settings", Style.TEXT, 16))
	inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings.add_child(inspector)
	_settings_window = Style.panel(settings, Style.SURFACE, Vector2(12, 10), true)
	_settings_window.hide()
	add_child(_settings_window)
	_overlay_layout.setup(self, _file_tools, _create_tools, _left_tools, _blackboard_panel,
		_connections_panel, _live_debug_panel, _debug_button, _connection_rows, _settings_window,
		blackboard, inspector, view)

	resized.connect(_layout_overlays)
	_layout_overlays.call_deferred()

func _floating_toolbar(content: Control) -> PanelContainer:
	var panel := Style.panel(content, Style.SURFACE, Vector2(6, 5))
	panel.minimum_size_changed.connect(_layout_overlays, CONNECT_DEFERRED)
	add_child(panel)
	return panel

func _make_left_tools() -> void:
	_left_tools = VBoxContainer.new()
	_left_tools.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left_tools.add_theme_constant_override("separation", 6)
	var launchers := HBoxContainer.new()
	launchers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left_tools.add_child(launchers)
	var buttons := ButtonGroup.new()
	buttons.allow_unpress = true
	_blackboard_panel = Style.panel(blackboard, Style.SURFACE, Vector2(12, 10), true)
	_setup_connections_panel()
	_live_debug_panel = _live_debug_ui.setup()
	_live_debug_panel.hide()
	_blackboard_button = _panel_launcher("Blackboard", "▤", _blackboard_panel, buttons)
	_connections_button = _panel_launcher("Calls & relays", "⇄", _connections_panel, buttons)
	_debug_button = Button.new()
	_debug_button.toggle_mode = true
	_debug_button.text = "DEBUG"
	_debug_button.custom_minimum_size = Vector2(78, 32)
	_debug_button.accessibility_name = "Toggle live debugging"
	_debug_button.tooltip_text = "Show or hide live debugging"
	_debug_button.visible = false
	if not Engine.is_editor_hint():
		_debug_button.add_theme_stylebox_override("normal", Style.surface(Style.SURFACE, Style.BORDER, Vector2(9, 4)))
		_debug_button.add_theme_stylebox_override("pressed", Style.surface(Color("#26394c"), Style.BORDER, Vector2(9, 4)))
	_debug_button.toggled.connect(func(open: bool) -> void:
		_live_debug_panel.visible = open
		_layout_overlays.call_deferred())
	_connections_button.toggled.connect(func(open: bool) -> void:
		if open:
			_refresh_connections())
	launchers.add_child(_blackboard_button)
	launchers.add_child(_connections_button)
	_left_tools.add_child(_blackboard_panel)
	_left_tools.add_child(_connections_panel)
	_left_tools.minimum_size_changed.connect(_layout_overlays, CONNECT_DEFERRED)
	add_child(_left_tools)
	_live_debug_panel.minimum_size_changed.connect(_layout_overlays, CONNECT_DEFERRED)
	add_child(_live_debug_panel)
	add_child(_debug_button)

func _panel_launcher(title: String, glyph: String, panel: PanelContainer, buttons: ButtonGroup) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.button_group = buttons
	button.custom_minimum_size = Vector2(36, 32)
	button.text = glyph
	button.accessibility_name = title
	button.tooltip_text = title
	if not Engine.is_editor_hint():
		button.add_theme_stylebox_override("normal", Style.surface(Style.SURFACE, Style.BORDER, Vector2(9, 4)))
		button.add_theme_stylebox_override("pressed", Style.surface(Color("#26394c"), Style.BORDER, Vector2(9, 4)))
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.hide()
	button.toggled.connect(func(open: bool) -> void:
		panel.visible = open
		_layout_overlays.call_deferred())
	return button

func _layout_overlays() -> void:
	_overlay_layout.layout()

func _button(text: String, cb: Callable, edit_only := true) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	if edit_only:
		_edit_buttons.append(b)
	return b

func _file_button(icon_name: StringName, fallback: String, title: String, action: Callable) -> Button:
	var button := _button(fallback, action, false)
	button.accessibility_name = title
	button.tooltip_text = title
	if Engine.is_editor_hint():
		var refresh_icon := func() -> void:
			button.icon = button.get_theme_icon(icon_name, &"EditorIcons") if button.has_theme_icon(icon_name, &"EditorIcons") else null
			button.text = "" if button.icon != null else fallback
		button.ready.connect(refresh_icon)
		button.theme_changed.connect(refresh_icon, CONNECT_DEFERRED)
	return button

# --- Loading ----------------------------------------------------------------------

func refresh() -> void:
	if _live:
		return
	var keep := _path
	_picker.clear()
	for path in _collect_stage_definition_paths():
		_picker.add_item(path.trim_prefix(STAGES_DIR + "/"))
		_picker.set_item_metadata(_picker.item_count - 1, path)
		_picker.get_popup().set_item_tooltip(_picker.item_count - 1, path)
	if _picker.item_count == 0:
		_path = ""
		_show({"error": "No stage definitions in " + STAGES_DIR}, false)
		return
	var idx := 0
	for i in _picker.item_count:
		if _picker.get_item_metadata(i) == keep:
			idx = i
	_picker.select(idx)
	open_script(_picker.get_item_metadata(idx))

func _collect_stage_definition_paths(dir_path := STAGES_DIR) -> Array[String]:
	var paths: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("Could not open stage directory '%s': %s" % [dir_path, error_string(DirAccess.get_open_error())])
		return paths
	var err := dir.list_dir_begin()
	if err != OK:
		push_error("Could not list stage directory '%s': %s" % [dir_path, error_string(err)])
		return paths
	var entry := dir.get_next()
	while entry != "":
		var path := dir_path.path_join(entry)
		if dir.current_is_dir():
			if entry != "." and entry != "..":
				paths.append_array(_collect_stage_definition_paths(path))
		elif entry.ends_with(".tres"):
			# The stages directory can also contain materials and other resources.
			if ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) is StageDefinition:
				paths.append(path)
		entry = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths

func open_script(path: String) -> void:
	_clear_analysis_stage()
	_path = path
	_picker.tooltip_text = path
	_dirty = false
	_selected = ""
	_show(RuleGraphReader.inspect_definition(path), true)

func _on_picker(i: int) -> void:
	if _dirty:
		for k in _picker.item_count:
			if _picker.get_item_metadata(k) == _path:
				_picker.select(k)
		_status.text = "Unsaved changes: Save or press Reload first."
		return
	open_script(_picker.get_item_metadata(i))

func bind_live(stage: Stage) -> void:
	_clear_analysis_stage()
	if _live and is_instance_valid(_live) and _live.rule_fired.is_connected(_on_live_rule_fired):
		_live.rule_fired.disconnect(_on_live_rule_fired)
	_live = stage
	_path = stage.definition.resource_path if stage.definition else ""
	_picker.visible = false
	_save_button.hide()
	_reload_button.hide()
	stage.rule_fired.connect(_on_live_rule_fired)
	_live_debug_ui.bind_stage(stage)
	_selected = ""
	_dirty = false
	_show(RuleGraphReader.read(stage), false, true)

func _on_live_rule_fired(rule_id: StringName, event: StringName) -> void:
	view.pulse(String(rule_id))
	view.pulse_event(String(event))

func _process(delta: float) -> void:
	if _live == null or not is_instance_valid(_live) or not is_visible_in_tree():
		return
	_accum += delta
	if _accum >= 0.2:
		_accum = 0.0
		blackboard.refresh_live(_live)
		if _live_debug_panel.visible:
			_live_debug_ui.refresh_runtime()

func _exit_tree() -> void:
	_clear_analysis_stage()
	_live_debug_ui.unbind_stage()
	if _live != null and is_instance_valid(_live) and _live.rule_fired.is_connected(_on_live_rule_fired):
		_live.rule_fired.disconnect(_on_live_rule_fired)

func _analyze_data() -> void:
	_analysis_debounce.stop()
	_pending_selection = ""
	var definition: StageDefinition = _data["definition"]
	var scene_source := definition.analysis_scene_path()
	var script_path := definition.stage_script.resource_path if definition.stage_script else ""
	var source_key := scene_source + "|" + script_path
	if not _analysis_source_key.is_empty() and _analysis_source_key != source_key:
		_clear_analysis_stage()
	_analysis_stage = RuleGraphReader.analyze(_data, _analysis_stage, true)
	_analysis_source_key = source_key if _analysis_stage != null else ""

func _clear_analysis_stage() -> void:
	if _analysis_stage != null and is_instance_valid(_analysis_stage):
		if _analysis_stage.engine:
			_analysis_stage.engine.cancel_all()
		if _analysis_stage.get_parent():
			_analysis_stage.get_parent().remove_child(_analysis_stage)
		_analysis_stage.free()
	_analysis_stage = null
	_analysis_source_key = ""

func _show(data: Dictionary, editable: bool, live := false) -> void:
	if data.has("error"):
		_show({"rules": [], "groups": [], "vars": [], "external_calls": [],
			"external_vars": [], "notes": [data["error"]]}, false)
		_status.text = data["error"]
		return
	_data = data
	_analysis_debounce.stop()
	_pending_selection = ""
	_expanded_connections.clear()
	_clear_selection()
	_editable = editable
	for b in _edit_buttons:
		b.visible = editable
	_create_tools.visible = editable
	_connections_button.visible = true
	if not _editable:
		_connections_button.button_pressed = false
	_debug_button.visible = live
	_debug_button.set_pressed_no_signal(live)
	_live_debug_panel.visible = live
	view.set_editable(_editable)
	blackboard.show_data(data, _editable, live)
	view.show_data(data)
	_layout_overlays()
	view.request_fit()
	_reset_history()
	_update_status()

func _update_status() -> void:
	_save_button.disabled = not _editable or _path.is_empty()
	_undo_button.disabled = not _editable or not _history.can_undo()
	_redo_button.disabled = not _editable or not _history.can_redo()
	_event_button.disabled = not _editable
	_connections_button.disabled = false
	var variable_count: int = _data["vars"].size()
	var connection_count := RuleConnections.ids(_data).size()
	_blackboard_button.text = "▤ %d" % variable_count
	_blackboard_button.tooltip_text = "Blackboard (%d)" % variable_count
	_connections_button.text = "⇄ %d" % connection_count
	_connections_button.tooltip_text = "Calls & relays (%d)" % connection_count
	if _connections_panel.visible:
		_refresh_connections()
	var n: int = _data["notes"].size()
	var t := "%d rules · %d variables · " % [_data["rules"].size(), _data["vars"].size()]
	t += "No notes" if n == 0 else "%d %s" % [n, "note" if n == 1 else "notes"]
	if _dirty:
		t = "Unsaved · " + t
	if is_instance_valid(_live):
		t = "Live · " + t
	_status.text = t
	_status.tooltip_text = t + ("\nClick to select affected rules.\n" + "\n".join(_data["notes"]) if n > 0 else "")
	Style.tint(_status, Style.WARNING if n > 0 or _dirty else Style.SUCCESS)

func _on_status_gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var affected: Array[String] = []
	for rule in _data.get("rules", []):
		var id: String = rule.get("id", "")
		if not id.is_empty() and _data.get("notes", []).any(func(note: String) -> bool:
			return ("'%s'" % id) in note):
			affected.append(id)
	if affected.is_empty():
		return
	var target := affected[_status_note_cursor % affected.size()]
	_status_note_cursor += 1
	view.select_rule(target)
	accept_event()

# --- History ----------------------------------------------------------------------

func _snapshot() -> Dictionary:
	var state := {}
	for field in EDIT_FIELDS:
		state[field] = _data[field].duplicate(true)
	# Analysis rebuilds this metadata from the authored step arguments.
	for rule in state["rules"]:
		for step in rule["steps"]:
			step.erase("emits")
			step.erase("emit_arg")
			step.erase("sets")
	return state

func _reset_history() -> void:
	if _editable:
		_sync_layout()
	_history.reset(_snapshot())
	_dirty = false
	_update_status()

func _record_edit(spin: SpinBox = null) -> void:
	var spin_id := spin.get_instance_id() if spin and _spin_drag_active else 0
	_dirty = _history.record(_snapshot(), spin_id)
	_update_status()

func _layout_changed() -> void:
	if _editable and not _restoring:
		_sync_layout()
		_record_edit()

func undo() -> void:
	if not _editable or not _history.can_undo():
		return
	_restore_edit(_history.undo(_snapshot()))

func redo() -> void:
	if not _editable or not _history.can_redo():
		return
	_restore_edit(_history.redo(_snapshot()))

func _restore_edit(state: Dictionary) -> void:
	_analysis_debounce.stop()
	_pending_selection = ""
	_restoring = true
	# Release the old inspector controls before swapping in new model dictionaries.
	inspector.clear()
	for field in EDIT_FIELDS:
		_data[field] = state[field].duplicate(true)
	_analyze_data()
	blackboard.show_data(_data, true, false)
	view.update_data(_data)
	if not _find_rule(_selected).is_empty():
		view.select_rule(_selected)
		_on_rule_selected(_selected)
	elif view.select_group(_selected_group):
		_on_group_selected(_selected_group)
	else:
		_clear_selection()
	_restoring = false
	_history.restore(state)
	_dirty = _history.is_dirty()
	_update_status()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_spin_drag_active = event.pressed
			if not event.pressed and _spin_refresh_pending:
				_spin_refresh_pending = false
				_changed(_selected)
			if not event.pressed and _reveal_pending:
				_reveal_selected_rule.call_deferred()

func is_dirty() -> bool:
	return _history.is_dirty()

func _shortcut_input(event: InputEvent) -> void:
	if not _editable or not is_visible_in_tree() or _event_dialog.visible or _delete_connection_dialog.visible or _create_menu.visible:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus and (not is_ancestor_of(focus) or focus is LineEdit or focus is TextEdit):
		return
	if event is InputEventKey and event.pressed and not event.echo and event.is_command_or_control_pressed():
		if event.keycode == KEY_Y or (event.keycode == KEY_Z and event.shift_pressed):
			redo()
		elif event.keycode == KEY_Z:
			undo()
		elif event.keycode == KEY_S:
			save()
		else:
			return
		get_viewport().set_input_as_handled()

# --- Events -----------------------------------------------------------------------

func _setup_create_menu() -> void:
	_create_menu.id_pressed.connect(_on_context_action)
	add_child(_create_menu)

func _open_create_menu(pointer: Vector2) -> void:
	if not _editable:
		return
	_context_menu.open_for(_data, view, pointer, _event_button.disabled,
		CreateAction.EVENT, CreateAction.RULE, CreateAction.GROUP,
		ContextAction.EDIT, ContextAction.DUPLICATE, ContextAction.DELETE)

func _on_context_action(action: int) -> void:
	if not _editable:
		return
	if _context_target.is_empty():
		_create_at_pointer(action)
		return
	var kind: String = _context_target["kind"]
	var id: String = _context_target["id"]
	match action:
		ContextAction.EDIT:
			match kind:
				"event":
					_connections_button.button_pressed = true
					_refresh_connections(id)
				"rule":
					view.select_rule(id)
				"group":
					view.select_rule("")
					view.select_group(id)
		ContextAction.DUPLICATE:
			duplicate_rule(id)
		ContextAction.DELETE:
			match kind:
				"event":
					_confirm_connection_delete(id)
				"rule":
					delete_rule(id)
				"group":
					delete_group(id)

func _create_at_pointer(id: int) -> void:
	match id:
		CreateAction.EVENT:
			_open_event_dialog()
		CreateAction.RULE:
			add_rule(_create_position)
		CreateAction.GROUP:
			add_group(_create_position)

func _setup_event_dialog() -> void:
	_event_dialog.title = "New Call"
	_event_dialog.ok_button_text = "Create"
	_event_dialog.dialog_hide_on_ok = false
	var fields := VBoxContainer.new()
	_event_name.placeholder_text = "Call ID"
	fields.add_child(_event_name)
	fields.add_child(_event_error)
	_event_dialog.add_child(fields)
	add_child(_event_dialog)
	_event_dialog.confirmed.connect(_confirm_event)
	_event_name.text_submitted.connect(func(_value: String) -> void: _confirm_event())
	_event_name.text_changed.connect(func(_value: String) -> void: _event_error.text = "")

func _open_event_dialog() -> void:
	if _event_button.disabled:
		return
	_event_name.clear()
	_event_error.text = ""
	_event_dialog.popup_centered(Vector2i(350, 110))
	_event_name.grab_focus()

func _confirm_event() -> void:
	var event_id := _event_name.text.strip_edges()
	if add_call_name(event_id):
		_event_dialog.hide()
	else:
		_event_error.text = "Enter a Call ID." if event_id.is_empty() else "That Call already exists."

func add_call_name(event_id: String) -> bool:
	event_id = event_id.strip_edges()
	if not _editable or event_id.is_empty() or _data["external_calls"].has(event_id):
		return false
	_data["external_calls"].append(event_id)
	_changed(_selected)
	_on_rule_selected(_selected)
	return true

func _setup_connections_panel() -> void:
	_connections_panel = _connections_ui.setup(self, _button("+ Call", _open_event_dialog),
		_layout_overlays, rename_connection, delete_connection, _show_connection_error, fire_live_call)

func fire_live_call(event_id: String) -> void:
	if _live == null or not is_instance_valid(_live) or _live.engine == null:
		return
	_live.fire(StringName(event_id))

func _refresh_connections(preferred := "") -> void:
	_connections_ui.refresh(_data, _editable, preferred)

func _confirm_connection_delete(id: String) -> void:
	_connections_ui.confirm_delete(_data, _editable, id)

func _show_connection_error(message: String) -> void:
	_status.text = message
	_status.tooltip_text = message
	Style.tint(_status, Style.WARNING)
func rename_connection(id: String, new_name: String) -> String:
	if not _editable:
		return "The graph is read-only."
	var error := RuleConnections.rename(_data, id, new_name)
	if error.is_empty():
		_changed(_selected)
		_on_rule_selected(_selected)
	return error

func delete_connection(id: String) -> String:
	if not _editable:
		return "The graph is read-only."
	var error := RuleConnections.remove(_data, id)
	if error.is_empty():
		_changed(_selected)
		_on_rule_selected(_selected)
	return error

# --- Edits (all go through the model) ----------------------------------------------

## Pull card positions and frame rects off the canvas into the model.
func _sync_layout() -> void:
	var pos := view.get_positions()
	for rd in _data["rules"]:
		if pos.has(rd["id"]):
			rd["pos"] = pos[rd["id"]].round()
			rd[AuthoredData.FIELD_HAS_POS] = true
	var rects := view.get_group_rects()
	for g in _data["groups"]:
		if rects.has(g["name"]):
			var rect: Rect2 = rects[g["name"]]
			g["rect"] = Rect2(rect.position.round(), rect.size.round())

func _changed(select_id: String, spin: SpinBox = null) -> void:
	_analysis_debounce.stop()
	_pending_selection = ""
	if not _editable or _restoring:
		return
	_sync_layout()
	if spin and _spin_drag_active:
		_record_edit(spin)
		_spin_refresh_pending = true
		return
	_analyze_data()
	view.update_data(_data)
	_selected = select_id
	if _find_rule(select_id).is_empty():
		_selected = ""
		if not _selected_group.is_empty():
			_selecting_after_edit = true
			var restored := view.select_group(_selected_group)
			_selecting_after_edit = false
			if not restored:
				_clear_selection()
		else:
			_clear_selection()
	else:
		_selected_group = ""
		_selecting_after_edit = spin != null
		view.select_rule(_selected)
		_selecting_after_edit = false
	_record_edit(spin)

func _schedule_change(select_id: String) -> void:
	if not _editable or _restoring:
		return
	if not _debounce_edits:
		_changed(select_id)
		return
	_sync_layout()
	_record_edit()
	_pending_selection = select_id
	_analysis_debounce.start()

func _flush_debounced_change() -> void:
	var select_id := _pending_selection
	_pending_selection = ""
	_changed(select_id)

func _find_rule(id: String) -> Dictionary:
	for rd in _data["rules"]:
		if rd["id"] == id:
			return rd
	return {}

func add_rule(at := Vector2.INF) -> Dictionary:
	if not _editable:
		return {}
	_sync_layout()
	var id := AuthoredData.unique_name(AuthoredData.rule_ids(_data), "new_rule")
	var trigger: String = _data["external_calls"][0] if not _data["external_calls"].is_empty() else "arrive"
	var rd := AuthoredData.new_rule(id, trigger)
	rd[AuthoredData.FIELD_STATE_KEY] = AuthoredData.new_state_key()
	rd["pos"] = (view.view_center() - Vector2(125, 60) if at == Vector2.INF else at).round()
	rd[AuthoredData.FIELD_HAS_POS] = true
	_data["rules"].append(rd)
	_changed(rd["id"])
	_on_rule_selected(rd["id"])
	return rd

func duplicate_rule(id: String) -> void:
	if not _editable:
		return
	_sync_layout()
	var src := _find_rule(id)
	if src.is_empty():
		return
	var rd: Dictionary = src.duplicate(true)
	rd["id"] = AuthoredData.unique_name(AuthoredData.rule_ids(_data), id + "_copy")
	rd[AuthoredData.FIELD_STATE_KEY] = AuthoredData.new_state_key()
	rd["pos"] = src["pos"] + Vector2(30, 30)
	rd[AuthoredData.FIELD_HAS_POS] = true
	_data["rules"].append(rd)
	_changed(rd["id"])
	_on_rule_selected(rd["id"])

func delete_rule(id: String) -> void:
	_delete_rules([id])

func _delete_rules(ids: Array) -> void:
	if not _editable:
		return
	_sync_layout()
	var previous_count: int = _data["rules"].size()
	_data["rules"] = _data["rules"].filter(func(rd: Dictionary) -> bool: return not ids.has(rd["id"]))
	if _data["rules"].size() == previous_count:
		return
	_changed("")

func add_group(at := Vector2.INF) -> void:
	if not _editable:
		return
	_sync_layout()
	var names: Array = _data["groups"].map(func(g: Dictionary) -> String: return g["name"])
	var origin := view.view_center() - Vector2(150, 100) if at == Vector2.INF else at
	_data["groups"].append({"name": AuthoredData.unique_name(names, "Group"), "rect": Rect2(origin.round(), Vector2(300, 200))})
	_changed(_selected)

func delete_group(group_name: String) -> void:
	if not _editable:
		return
	_sync_layout()
	for g in _data["groups"]:
		if g["name"] == group_name:
			_data["groups"].erase(g)
			break
	for rd in _data["rules"]:
		if rd["group"] == group_name:
			rd["group"] = ""
	_changed("")

## Dragging output -> input makes the target rule listen to what the source fires.
## `source` is {"event": name} or {"rule": id, "port": index}.
func connect_wire(source: Dictionary, to_id: String) -> void:
	if not _editable:
		return
	var target := _find_rule(to_id)
	if target.is_empty():
		return
	if source.has("event"):
		target["trigger"] = source["event"]
	else:
		var from := _find_rule(source["rule"])
		if from.is_empty():
			return
		var relays := RuleGraphView.output_relays(from)
		var relay: String = relays[clampi(source["port"], 0, relays.size() - 1)]
		if relay == "":
			# The unnamed rule-level port: name it after the rule.
			relay = AuthoredData.unique_name(_all_relays(), from["id"] + "_done")
			from["emit"] = relay
		target["trigger"] = "relay:" + relay
	_changed(to_id)
	_on_rule_selected(to_id)

func disconnect_wire(to_id: String) -> void:
	if not _editable:
		return
	var target := _find_rule(to_id)
	if target.is_empty():
		return
	target["trigger"] = ""
	_changed(to_id)
	_on_rule_selected(to_id)

func _all_relays() -> Array:
	var out: Array = []
	for id in RuleConnections.ids(_data):
		if id.begins_with(RuleConnections.RELAY_PREFIX):
			out.append(id.trim_prefix(RuleConnections.RELAY_PREFIX))
	return out

func save() -> void:
	if not _editable or _path == "":
		return
	if not _analysis_debounce.is_stopped():
		_flush_debounced_change()
	else:
		_sync_layout()
		_analyze_data()
	if not _data["compiles"]:
		_status.text = "Not saved: check invalid steps or script errors."
		Style.tint(_status, Style.WARNING)
		return
	var draft := RuleGraphReader.make_definition(_data)
	var previous_uid := ResourceLoader.get_resource_uid(_path)
	draft.remove_meta(StageDefinition.ANALYSIS_SCENE_SOURCE_META)
	var error := ResourceSaver.save(draft, _path)
	if error != OK:
		_status.text = "Save failed (error %d)" % error
		Style.tint(_status, Style.WARNING)
		return
	if previous_uid != ResourceUID.INVALID_ID:
		var uid_error := ResourceSaver.set_uid(_path, previous_uid)
		if uid_error != OK:
			push_warning("Saved %s but could not preserve its resource UID (error %d)." % [_path, uid_error])
	# CACHE_MODE_REPLACE refreshes cached resources in place when their types match.
	var reloaded := ResourceLoader.load(_path, "", ResourceLoader.CACHE_MODE_REPLACE) as StageDefinition
	_data["definition"] = reloaded if reloaded != null else draft
	_record_edit()
	_history.mark_saved(_snapshot())
	_dirty = false
	_update_status()
	_status.text = "Saved %s.  %s" % [_path.get_file(), _status.text]
	layout_saved.emit(_path)

# --- Selection --------------------------------------------------------------------

func _on_rule_selected(rule_id: String) -> void:
	if _selecting_after_edit or not _editable:
		return
	var rd := _find_rule(rule_id)
	if rd.is_empty():
		return
	_selected = rule_id
	_selected_group = ""
	inspector.show_rule(rd, _data, not _editable)
	_settings_window.show()
	_layout_overlays()
	_reveal_pending = true
	_reveal_selected_rule.call_deferred()

func _reveal_selected_rule() -> void:
	if not _reveal_pending or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	_reveal_pending = false
	if not _selected.is_empty() and _settings_window.is_visible_in_tree():
		view.reveal_rule(_selected, _settings_window.get_rect())

func _on_group_selected(group_name: String) -> void:
	if _selecting_after_edit or not _editable:
		return
	for g in _data["groups"]:
		if g["name"] == group_name:
			_selected = ""
			_selected_group = group_name
			inspector.show_group(g, _data, not _editable)
			_settings_window.show()
			_layout_overlays()
			return

func _clear_selection() -> void:
	_selected = ""
	_reveal_pending = false
	_selected_group = ""
	inspector.clear()
	_settings_window.hide()
	_layout_overlays()
