@tool
class_name CallboardLiveDebugPanel extends RefCounted
## Live rule state, pending waits, and recent execution trace.

const Style := preload("res://addons/callboard/editor/board_style.gd")
const MAX_TRACE_ROWS := 48

var panel: PanelContainer
var _stage: Stage
var _trace_rows := VBoxContainer.new()
var _active_rows := VBoxContainer.new()
var _pending_rows := VBoxContainer.new()
var _content_scroll: ScrollContainer
var _trace_buffer: Array[Dictionary] = []

func setup() -> PanelContainer:
	var fields := VBoxContainer.new()
	fields.custom_minimum_size.x = Style.LIST_WIDTH + 90
	fields.add_theme_constant_override("separation", 6)
	var header := HBoxContainer.new()
	var title := Style.label("Live debugging", Style.TEXT, 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(Style.entry(Style.label("LIVE", Style.SUCCESS, 11)))
	var clear_button := Button.new()
	clear_button.text = "Clear trace"
	clear_button.tooltip_text = "Clear the recent trace entries"
	clear_button.pressed.connect(_clear_trace)
	header.add_child(clear_button)
	fields.add_child(header)

	_active_rows.add_theme_constant_override("separation", 2)
	_pending_rows.add_theme_constant_override("separation", 2)
	_trace_rows.add_theme_constant_override("separation", 2)
	for rows in [_active_rows, _pending_rows, _trace_rows]:
		rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_section("Running rules", _active_rows))
	content.add_child(_section("Pending waits and loops", _pending_rows))
	content.add_child(_section("Recent rule trace", _trace_rows))
	_content_scroll = ScrollContainer.new()
	_content_scroll.custom_minimum_size.y = 150
	_content_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content_scroll.add_child(content)
	fields.add_child(_content_scroll)
	_add_empty(_trace_rows, "Waiting for runtime events.")
	_add_empty(_active_rows, "No running rules.")

	panel = Style.panel(fields, Style.SURFACE, Vector2(12, 10), true)
	panel.custom_minimum_size.x = Style.LIST_WIDTH + 90
	panel.clip_contents = true
	panel.visibility_changed.connect(_on_visibility_changed)
	return panel

func _section(title: String, content: Control) -> PanelContainer:
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	body.add_child(Style.label(title, Style.RELAY, 13))
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(content)
	var card := Style.entry(body)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return card

func bind_stage(stage: Stage) -> void:
	if _stage != null and is_instance_valid(_stage) and _stage.engine:
		if _stage.engine.trace_event.is_connected(_on_trace):
			_stage.engine.trace_event.disconnect(_on_trace)
		if _stage.engine.pending_changed.is_connected(_on_pending_changed):
			_stage.engine.pending_changed.disconnect(_on_pending_changed)
	_stage = stage
	_clear_rows(_active_rows)
	_clear_rows(_pending_rows)
	_clear_rows(_trace_rows)
	_trace_buffer.clear()
	if _stage == null or not is_instance_valid(_stage) or _stage.engine == null:
		_add_empty(_active_rows, "No live Stage attached.")
		_add_empty(_pending_rows, "Nothing pending.")
		_add_empty(_trace_rows, "Waiting for runtime events.")
		return
	_stage.engine.trace_event.connect(_on_trace)
	_stage.engine.pending_changed.connect(_on_pending_changed)
	_on_pending_changed(_stage.engine.pending_snapshot())
	_refresh_active()
	_add_empty(_trace_rows, "Waiting for runtime events.")

func unbind_stage() -> void:
	bind_stage(null)

func refresh_runtime() -> void:
	if _stage == null or not is_instance_valid(_stage) or _stage.engine == null:
		unbind_stage()
		return
	_refresh_active()
	_on_pending_changed(_stage.engine.pending_snapshot())

func _on_trace(entry: Dictionary) -> void:
	_trace_buffer.append(entry.duplicate(true))
	while _trace_buffer.size() > MAX_TRACE_ROWS:
		_trace_buffer.pop_front()
	if panel == null or not panel.is_visible_in_tree():
		_refresh_active()
		return
	_render_trace(entry)
	_refresh_active()

func _render_trace(entry: Dictionary) -> void:
	if _trace_rows.get_child_count() == 1 and _trace_rows.get_child(0).has_meta("empty"):
		_clear_rows(_trace_rows)
	var label := Style.label(_format_trace(entry), Style.TEXT, 12)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	row.add_child(Style.label(">", _trace_color(entry["kind"]), 13))
	row.add_child(label)
	_trace_rows.add_child(Style.entry(row))
	if _content_scroll.is_inside_tree():
		var process_frame := _content_scroll.get_tree().process_frame
		if not process_frame.is_connected(_scroll_content_to_end):
			process_frame.connect(_scroll_content_to_end, CONNECT_ONE_SHOT)

func _on_visibility_changed() -> void:
	if panel != null and panel.is_visible_in_tree():
		_flush_trace_buffer()
		_refresh_active()

func _flush_trace_buffer() -> void:
	_clear_rows(_trace_rows)
	if _trace_buffer.is_empty():
		_add_empty(_trace_rows, "Waiting for runtime events.")
		return
	for entry in _trace_buffer:
		_render_trace(entry)

func _scroll_content_to_end() -> void:
	if is_instance_valid(_content_scroll):
		_content_scroll.scroll_vertical = int(_content_scroll.get_v_scroll_bar().max_value)

func _on_pending_changed(entries: Array) -> void:
	_clear_rows(_pending_rows)
	if entries.is_empty():
		_add_empty(_pending_rows, "Nothing pending.")
		return
	for entry in entries:
		var remaining: float = entry["remaining"]
		var time_text := "" if remaining < 0.0 else " - %.1fs" % remaining
		_add_row(_pending_rows, "%s - %s%s" % [entry["rule"], entry["label"], time_text], Style.TEXT)

func _refresh_active() -> void:
	_clear_rows(_active_rows)
	if _stage == null or not is_instance_valid(_stage) or _stage.engine == null:
		_add_empty(_active_rows, "No live Stage attached.")
		return
	var active := _stage.engine.active_snapshot()
	if active.is_empty():
		_add_empty(_active_rows, "No running rules.")
		return
	for entry in active:
		var suffix := " - %d queued" % entry["queued"] if entry["queued"] > 0 else ""
		if entry["restarting"]:
			suffix += " - restarting"
		_add_row(_active_rows, "%s%s" % [entry["rule"], suffix], Style.TEXT)

func _trace_color(kind: String) -> Color:
	match kind:
		"event_fired":
			return Style.EVENT
		"rule_started", "step_started", "delay_started":
			return Style.RELAY
		"rule_completed":
			return Style.SUCCESS
		"rule_cancelled":
			return Style.ERROR
		_:
			return Style.MUTED

func _clear_trace() -> void:
	_trace_buffer.clear()
	_clear_rows(_trace_rows)
	_add_empty(_trace_rows, "Trace cleared. New events will appear here.")

func _add_row(rows: VBoxContainer, text: String, color: Color) -> void:
	var label := Style.label(text, color, 12)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_child(Style.entry(label))

func _add_empty(rows: VBoxContainer, text: String) -> void:
	var label := Style.label(text, Style.MUTED, 12)
	label.set_meta("empty", true)
	rows.add_child(label)

func _format_trace(entry: Dictionary) -> String:
	var kind: String = entry["kind"]
	var event: String = entry["event"]
	var rule: String = entry["rule"]
	var step: int = entry["step"]
	var verb: String = entry["verb"]
	var label := kind.replace("_", " ").capitalize()
	if kind == "event_fired":
		label += " - " + event
	elif not rule.is_empty():
		label += " - " + rule
		if step > 0:
			label += " - step %d" % step
		if not verb.is_empty():
			label += " - " + verb
	if not entry["detail"].is_empty():
		label += " - " + entry["detail"]
	return label

func _clear_rows(rows: VBoxContainer) -> void:
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
