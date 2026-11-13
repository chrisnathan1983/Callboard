@tool
class_name CallboardLiveDebugPanel extends RefCounted
## Live call trigger, recent rule trace, and pending wait monitor.

const Style := preload("res://addons/callboard/editor/board_style.gd")
const MAX_TRACE_ROWS := 48

var panel: PanelContainer
var _stage: Stage
var _calls := OptionButton.new()
var _fire_button := Button.new()
var _trace_rows := VBoxContainer.new()
var _active_rows := VBoxContainer.new()
var _pending_rows := VBoxContainer.new()

func setup() -> PanelContainer:
	var fields := VBoxContainer.new()
	fields.custom_minimum_size = Vector2(Style.LIST_WIDTH, 340)
	fields.add_theme_constant_override("separation", Style.ENTRY_GAP)
	var title := Style.label("Live debugging", Style.TEXT, 16)
	fields.add_child(title)
	var fire_row := HBoxContainer.new()
	_calls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_calls.tooltip_text = "Choose a declared external Call"
	_fire_button.text = "Fire"
	_fire_button.tooltip_text = "Fire this Call on the live Stage"
	_fire_button.pressed.connect(fire_selected)
	fire_row.add_child(_calls)
	fire_row.add_child(_fire_button)
	fields.add_child(fire_row)
	fields.add_child(Style.label("Running rules", Style.RELAY, 13))
	_active_rows.add_theme_constant_override("separation", 2)
	fields.add_child(_active_rows)
	fields.add_child(Style.label("Pending waits and loops", Style.RELAY, 13))
	_pending_rows.add_theme_constant_override("separation", 2)
	var pending_scroll := ScrollContainer.new()
	pending_scroll.custom_minimum_size.y = 68
	pending_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pending_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pending_scroll.add_child(_pending_rows)
	fields.add_child(pending_scroll)
	fields.add_child(Style.label("Recent rule trace", Style.RELAY, 13))
	_trace_rows.add_theme_constant_override("separation", 2)
	var trace_scroll := ScrollContainer.new()
	trace_scroll.custom_minimum_size.y = 128
	trace_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trace_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	trace_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	trace_scroll.add_child(_trace_rows)
	fields.add_child(trace_scroll)
	panel = Style.panel(fields, Style.SURFACE, Vector2(12, 10), true)
	panel.custom_minimum_size.x = Style.LIST_WIDTH
	return panel

func bind_stage(stage: Stage) -> void:
	if _stage != null and is_instance_valid(_stage) and _stage.engine:
		if _stage.engine.trace_event.is_connected(_on_trace):
			_stage.engine.trace_event.disconnect(_on_trace)
		if _stage.engine.pending_changed.is_connected(_on_pending_changed):
			_stage.engine.pending_changed.disconnect(_on_pending_changed)
	_stage = stage
	_calls.clear()
	_clear_rows(_active_rows)
	_clear_rows(_pending_rows)
	_clear_rows(_trace_rows)
	if _stage == null or not is_instance_valid(_stage) or _stage.engine == null:
		_fire_button.disabled = true
		return
	for event_id in _stage.external_calls:
		_calls.add_item(String(event_id))
	_fire_button.disabled = _calls.item_count == 0
	_stage.engine.trace_event.connect(_on_trace)
	_stage.engine.pending_changed.connect(_on_pending_changed)
	_on_pending_changed(_stage.engine.pending_snapshot())
	_refresh_active()

func unbind_stage() -> void:
	bind_stage(null)

func refresh_runtime() -> void:
	if _stage == null or not is_instance_valid(_stage) or _stage.engine == null:
		unbind_stage()
		return
	_refresh_active()
	_on_pending_changed(_stage.engine.pending_snapshot())

func fire_selected() -> void:
	if _stage == null or not is_instance_valid(_stage) or _stage.engine == null or _calls.item_count == 0 or _calls.selected < 0:
		return
	_stage.fire(StringName(_calls.get_item_text(_calls.selected)))

func _on_trace(entry: Dictionary) -> void:
	var label := Style.label(_format_trace(entry), Style.TEXT, 12)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trace_rows.add_child(label)
	while _trace_rows.get_child_count() > MAX_TRACE_ROWS:
		var oldest := _trace_rows.get_child(0)
		_trace_rows.remove_child(oldest)
		oldest.queue_free()
	_refresh_active()

func _on_pending_changed(entries: Array) -> void:
	_clear_rows(_pending_rows)
	if entries.is_empty():
		_pending_rows.add_child(Style.label("Nothing pending.", Style.MUTED, 12))
		return
	for entry in entries:
		var remaining: float = entry["remaining"]
		var time_text := "" if remaining < 0.0 else " · %.1fs" % remaining
		_pending_rows.add_child(Style.label("%s · %s%s" % [entry["rule"], entry["label"], time_text], Style.TEXT, 12))

func _refresh_active() -> void:
	_clear_rows(_active_rows)
	if _stage == null or not is_instance_valid(_stage) or _stage.engine == null:
		return
	var active := _stage.engine.active_snapshot()
	if active.is_empty():
		_active_rows.add_child(Style.label("No running rules.", Style.MUTED, 12))
		return
	for entry in active:
		var suffix := " · %d queued" % entry["queued"] if entry["queued"] > 0 else ""
		if entry["restarting"]:
			suffix += " · restarting"
		_active_rows.add_child(Style.label("%s%s" % [entry["rule"], suffix], Style.TEXT, 12))

func _format_trace(entry: Dictionary) -> String:
	var kind: String = entry["kind"]
	var event: String = entry["event"]
	var rule: String = entry["rule"]
	var step: int = entry["step"]
	var verb: String = entry["verb"]
	var label := kind.replace("_", " ").capitalize()
	if kind == "event_fired":
		label += " · " + event
	elif not rule.is_empty():
		label += " · " + rule
		if step > 0:
			label += " · step %d" % step
		if not verb.is_empty():
			label += " · " + verb
	if not entry["detail"].is_empty():
		label += " · " + entry["detail"]
	return label

func _clear_rows(rows: VBoxContainer) -> void:
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
