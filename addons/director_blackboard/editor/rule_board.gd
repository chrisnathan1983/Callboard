@tool
class_name RuleBoard extends VBoxContainer
## Blackboard sidebar + Rule Graph + inspector in one control.
##
## Editor mode edits a ZoneDefinition and saves its resource after validation.
## Live mode shows a running zone's values and rule pulses.

signal layout_saved(path: String)

const ZONES_DIR := "res://zones"
const HISTORY_LIMIT := 100
const EDIT_FIELDS := ["external_events", "vars", "rules", "groups"]

var view := RuleGraphView.new()
var blackboard := BlackboardPanel.new()
var inspector := RuleInspector.new()
var _picker := OptionButton.new()
var _status := Label.new()
var _edit_buttons: Array[Button] = []
var _data := {}
var _path := ""
var _selected := ""
var _dirty := false
var _editable := true
var _live: Zone
var _accum := 0.0
var _undo_button: Button
var _redo_button: Button
var _event_button: Button
var _event_dialog := ConfirmationDialog.new()
var _event_name := LineEdit.new()
var _event_error := Label.new()
var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
var _current_edit := {}
var _saved_edit := {}
var _restoring := false

func _init() -> void:
	var bar := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "Zone:"
	bar.add_child(lbl)
	_picker.item_selected.connect(_on_picker)
	bar.add_child(_picker)
	bar.add_child(_button("Reload", refresh, false))
	_event_button = _button("+ Event", _open_event_dialog)
	bar.add_child(_event_button)
	bar.add_child(_button("+ Rule", add_rule))
	bar.add_child(_button("+ Group", add_group))
	_undo_button = _button("Undo", undo)
	_undo_button.tooltip_text = "Ctrl/Cmd+Z"
	_redo_button = _button("Redo", redo)
	_redo_button.tooltip_text = "Ctrl/Cmd+Shift+Z or Ctrl/Cmd+Y"
	bar.add_child(_undo_button)
	bar.add_child(_redo_button)
	bar.add_child(_button("Save", save))
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_status)
	add_child(bar)
	_setup_event_dialog()

	var outer := HSplitContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var inner := HSplitContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.rule_selected.connect(_on_rule_selected)
	view.group_selected.connect(_on_group_selected)
	view.wire_added.connect(func(src: Dictionary, to: String) -> void: connect_wire(src, to))
	view.wire_removed.connect(func(to: String) -> void: disconnect_wire(to))
	view.rules_delete_requested.connect(_delete_rules)
	view.rules_linked_to_group.connect(func(ids: Array, g: String) -> void:
		for rd in _data["rules"]:
			if ids.has(rd["id"]):
				rd["group"] = g
		_changed(_selected))
	view.layout_changed.connect(_layout_changed)
	blackboard.changed.connect(func() -> void: _changed(_selected))
	inspector.changed.connect(func(id: String) -> void: _changed(id))
	inspector.delete_requested.connect(delete_rule)
	inspector.duplicate_requested.connect(duplicate_rule)
	inspector.group_edited.connect(func() -> void: _changed(_selected))
	inspector.group_delete_requested.connect(delete_group)
	inner.add_child(view)
	inner.add_child(inspector)
	outer.add_child(blackboard)
	outer.add_child(inner)
	add_child(outer)

func _button(text: String, cb: Callable, edit_only := true) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	if edit_only:
		_edit_buttons.append(b)
	return b

# --- Loading ----------------------------------------------------------------------

func refresh() -> void:
	if _live:
		return
	var keep := _path
	_picker.clear()
	for path in _collect_zone_definition_paths():
		_picker.add_item(path.trim_prefix(ZONES_DIR + "/"))
		_picker.set_item_metadata(_picker.item_count - 1, path)
	if _picker.item_count == 0:
		_path = ""
		_show({"error": "No zone definitions in " + ZONES_DIR}, false)
		return
	var idx := 0
	for i in _picker.item_count:
		if _picker.get_item_metadata(i) == keep:
			idx = i
	_picker.select(idx)
	open_script(_picker.get_item_metadata(idx))

func _collect_zone_definition_paths(dir_path := ZONES_DIR) -> Array[String]:
	var paths: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("Could not open zone directory '%s': %s" % [dir_path, error_string(DirAccess.get_open_error())])
		return paths
	var err := dir.list_dir_begin()
	if err != OK:
		push_error("Could not list zone directory '%s': %s" % [dir_path, error_string(err)])
		return paths
	var entry := dir.get_next()
	while entry != "":
		var path := dir_path.path_join(entry)
		if dir.current_is_dir():
			if entry != "." and entry != "..":
				paths.append_array(_collect_zone_definition_paths(path))
		elif entry.ends_with(".tres"):
			paths.append(path)
		entry = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths

func open_script(path: String) -> void:
	_path = path
	_dirty = false
	_selected = ""
	_show(RuleGraphReader.inspect_definition(path) if path.ends_with(".tres") else RuleGraphReader.inspect_script(path), true)

func _on_picker(i: int) -> void:
	if _dirty:
		for k in _picker.item_count:
			if _picker.get_item_metadata(k) == _path:
				_picker.select(k)
		_status.text = "Unsaved changes: Save or press Reload first."
		return
	open_script(_picker.get_item_metadata(i))

func bind_live(zone: Zone) -> void:
	if _live and is_instance_valid(_live) and _live.rule_fired.is_connected(_on_live_rule_fired):
		_live.rule_fired.disconnect(_on_live_rule_fired)
	_live = zone
	_path = zone.definition.resource_path if zone.definition else (zone.get_script() as Script).resource_path
	_picker.visible = false
	zone.rule_fired.connect(_on_live_rule_fired)
	_selected = ""
	_dirty = false
	_show(RuleGraphReader.read(zone, _path), false)

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

func _show(data: Dictionary, editable: bool) -> void:
	if data.has("error"):
		_show({"rules": [], "groups": [], "vars": [], "external_events": [], "problems": [data["error"]], "parse_error": data["error"]}, false)
		_status.text = data["error"]
		return
	_data = data
	_editable = editable and data["parse_error"] == ""
	for b in _edit_buttons:
		b.visible = editable
	view.set_editable(_editable)
	blackboard.show_data(data, _editable, not editable)
	view.show_data(data)
	_reset_history()
	_update_status()
	inspector.show_message("Select a rule or group.\n\n" + "\n".join(data["problems"]) if not data["problems"].is_empty() else "Select a rule or group.")

func _update_status() -> void:
	_undo_button.disabled = not _editable or _undo_stack.is_empty()
	_redo_button.disabled = not _editable or _redo_stack.is_empty()
	_event_button.disabled = not _editable or not _data.has("definition")
	var n: int = _data["problems"].size()
	var t := "%d rules, %d variables, " % [_data["rules"].size(), _data["vars"].size()]
	t += "no validation problems" if n == 0 else "%d validation problem(s)" % n
	if _dirty:
		t = "● unsaved   " + t
	_status.text = t

# --- History ----------------------------------------------------------------------

func _snapshot() -> Dictionary:
	var state := {}
	for field in EDIT_FIELDS:
		state[field] = _data[field].duplicate(true)
	return state

func _reset_history() -> void:
	_undo_stack.clear()
	_redo_stack.clear()
	if _editable:
		_sync_layout()
	_current_edit = _snapshot()
	_saved_edit = _current_edit
	_dirty = false

func _record_edit() -> void:
	var state := _snapshot()
	if state != _current_edit:
		_undo_stack.append(_current_edit)
		if _undo_stack.size() > HISTORY_LIMIT:
			_undo_stack.pop_front()
		_redo_stack.clear()
		_current_edit = state
	_dirty = _current_edit != _saved_edit
	_update_status()

func _layout_changed() -> void:
	if _editable and not _restoring:
		_sync_layout()
		_record_edit()

func undo() -> void:
	if not _editable or _undo_stack.is_empty():
		return
	_redo_stack.append(_current_edit)
	_restore_edit(_undo_stack.pop_back())

func redo() -> void:
	if not _editable or _redo_stack.is_empty():
		return
	_undo_stack.append(_current_edit)
	_restore_edit(_redo_stack.pop_back())

func _restore_edit(state: Dictionary) -> void:
	_restoring = true
	# Release the old inspector controls before swapping in new model dictionaries.
	inspector.show_message("Select a rule or group.")
	for field in EDIT_FIELDS:
		_data[field] = state[field].duplicate(true)
	RuleGraphReader.analyze(_data)
	blackboard.show_data(_data, true, false)
	view.show_data(_data)
	if not _find_rule(_selected).is_empty():
		view.select_rule(_selected)
		_on_rule_selected(_selected)
	else:
		_selected = ""
	_restoring = false
	_current_edit = state
	_dirty = state != _saved_edit
	_update_status()

func _shortcut_input(event: InputEvent) -> void:
	if not _editable or not is_visible_in_tree() or _event_dialog.visible:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus and (not is_ancestor_of(focus) or focus is LineEdit or focus is TextEdit):
		return
	if event is InputEventKey and event.pressed and not event.echo and event.is_command_or_control_pressed():
		if event.keycode == KEY_Y or (event.keycode == KEY_Z and event.shift_pressed):
			redo()
		elif event.keycode == KEY_Z:
			undo()
		else:
			return
		get_viewport().set_input_as_handled()

# --- Events -----------------------------------------------------------------------

func _setup_event_dialog() -> void:
	_event_dialog.title = "New event"
	_event_dialog.ok_button_text = "Create"
	_event_dialog.dialog_hide_on_ok = false
	var fields := VBoxContainer.new()
	_event_name.placeholder_text = "Event ID"
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
	if add_event(event_id):
		_event_dialog.hide()
	else:
		_event_error.text = "Enter an event ID." if event_id.is_empty() else "That event already exists."

func add_event(event_id: String) -> bool:
	event_id = event_id.strip_edges()
	if not _editable or not _data.has("definition") or event_id.is_empty() or _data["external_events"].has(event_id):
		return false
	_data["external_events"].append(event_id)
	_changed(_selected)
	_on_rule_selected(_selected)
	return true

# --- Edits (all go through the model) ----------------------------------------------

## Pull card positions and frame rects off the canvas into the model.
func _sync_layout() -> void:
	var pos := view.get_positions()
	for rd in _data["rules"]:
		if pos.has(rd["id"]):
			rd["pos"] = pos[rd["id"]].round()
			rd["has_pos"] = true
	var rects := view.get_group_rects()
	for g in _data["groups"]:
		if rects.has(g["name"]):
			var rect: Rect2 = rects[g["name"]]
			g["rect"] = Rect2(rect.position.round(), rect.size.round())

func _changed(select_id: String) -> void:
	if not _editable or _restoring:
		return
	_sync_layout()
	RuleGraphReader.analyze(_data)
	view.show_data(_data)
	_selected = select_id
	if _find_rule(select_id).is_empty():
		_selected = ""
	else:
		view.select_rule(_selected)
	_record_edit()

func _find_rule(id: String) -> Dictionary:
	for rd in _data["rules"]:
		if rd["id"] == id:
			return rd
	return {}

func add_rule() -> Dictionary:
	if not _editable:
		return {}
	_sync_layout()
	var rd := {
		"id": ZoneSource.unique_name(ZoneSource.rule_ids(_data), "new_rule"),
		"trigger": _data["external_events"][0] if not _data["external_events"].is_empty() else "arrive",
		"requires": [], "forbids": [], "cancel_if": [], "once": false, "emit": "", "steps": [],
		"has_pos": true, "pos": view.view_center() - Vector2(125, 60), "group": "",
	}
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
	rd["id"] = ZoneSource.unique_name(ZoneSource.rule_ids(_data), id + "_copy")
	rd["pos"] = src["pos"] + Vector2(30, 30)
	rd["has_pos"] = true
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
	inspector.show_message("Select a rule or group.")

func add_group() -> void:
	if not _editable:
		return
	_sync_layout()
	var names: Array = _data["groups"].map(func(g: Dictionary) -> String: return g["name"])
	var c := view.view_center()
	_data["groups"].append({"name": ZoneSource.unique_name(names, "Group"), "rect": Rect2(c - Vector2(150, 100), Vector2(300, 200))})
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
	inspector.show_message("Group '%s' deleted." % group_name)

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
			relay = ZoneSource.unique_name(_all_relays(), from["id"] + "_done")
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
	for rd in _data["rules"]:
		for r in RuleGraphView.output_relays(rd):
			if r != "":
				out.append(r)
	return out

func save() -> void:
	if not _editable or _path == "":
		return
	_sync_layout()
	RuleGraphReader.analyze(_data)
	if not _data["compiles"]:
		_status.text = "Not saved: check invalid steps or script errors."
		return
	if _data.has("definition"):
		var draft := RuleGraphReader.make_definition(_data)
		var error := ResourceSaver.save(draft, _path)
		if error != OK:
			_status.text = "Save failed (error %d)" % error
			return
		_data["definition"] = draft
	else:
		var updated := ZoneSource.generate(_data["source"], _data)
		var f := FileAccess.open(_path, FileAccess.WRITE)
		if f == null:
			_status.text = "Save failed (error %d)" % FileAccess.get_open_error()
			return
		f.store_string(updated)
		f.close()
		_data["source"] = updated
	_record_edit()
	_saved_edit = _current_edit
	_dirty = false
	_update_status()
	_status.text = "Saved %s.  %s" % [_path.get_file(), _status.text]
	layout_saved.emit(_path)

# --- Selection --------------------------------------------------------------------

func _on_rule_selected(rule_id: String) -> void:
	var rd := _find_rule(rule_id)
	if rd.is_empty():
		return
	_selected = rule_id
	inspector.show_rule(rd, _data, not _editable)

func _on_group_selected(group_name: String) -> void:
	for g in _data["groups"]:
		if g["name"] == group_name:
			inspector.show_group(g, _data, not _editable)
			return
