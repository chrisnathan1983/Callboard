@tool
class_name RuleGraphView extends GraphEdit
## Renders board data as a node graph: one card per rule, one source node per external event,
## GraphFrames for groups. Wires are derived from relay relationships, never stored.
##
## The view never edits the model. It turns gestures into semantic signals and the board
## applies them, then calls show_data() again.
##   drag output -> input     wire_added
##   drag a wire off an input wire_removed
##   Delete key               rules_delete_requested
##   drop card on a frame     rules_linked_to_group

signal rule_selected(rule_id: String)
signal group_selected(group_name: String)
signal selection_cleared
signal wire_added(source: Dictionary, to_rule: String)   # source: {"event": name} or {"rule": id, "port": int}
signal wire_removed(to_rule: String)
signal rules_delete_requested(ids: Array)
signal rules_linked_to_group(ids: Array, group_name: String)
signal layout_changed

const Style := preload("res://addons/director_blackboard/editor/board_style.gd")
const CARD_WIDTH := 264.0
const COL_EVENT := Style.EVENT
const COL_RELAY := Style.RELAY
const COL_REQ := Style.SUCCESS
const COL_FORBID := Style.ERROR
const COL_CANCEL := Style.WARNING
const COL_DIM := Style.MUTED
const LIVE_ACTIVITY := Color("#fff3b2")

var fit_area := Rect2()
var _rule_nodes := {}    # rule id -> GraphNode
var _event_nodes := {}   # event name -> GraphNode
var _frames := {}        # group name -> GraphFrame
var _resizing_frame := false
var _editable := true
var _fit_requested := false
var _inspected_node: GraphElement
var _icon_material: ShaderMaterial

func _init() -> void:
	minimap_enabled = true
	minimap_size = Vector2i(170, 110)
	show_zoom_label = true
	grid_pattern = GRID_PATTERN_DOTS
	connection_lines_thickness = 2.0
	if not Engine.is_editor_hint():
		var canvas := StyleBoxFlat.new()
		canvas.bg_color = Color("#101621")
		add_theme_stylebox_override("panel", canvas)
		add_theme_stylebox_override("menu_panel", Style.surface(Style.SURFACE, Style.BORDER, Vector2(8, 5), 6))
		add_theme_color_override("grid_minor", Color("#202b3a"))
		add_theme_color_override("grid_major", Color("#293649"))
		add_theme_color_override("activity", LIVE_ACTIVITY)
	var fit := Button.new()
	fit.text = "Fit all"
	fit.tooltip_text = "Frame every event, rule and group"
	fit.pressed.connect(request_fit)
	get_menu_hbox().add_child(fit)
	var menu := get_menu_hbox().get_parent() as Control
	menu.minimum_size_changed.connect(_position_view_tools, CONNECT_DEFERRED)
	_position_view_tools.call_deferred()
	visibility_changed.connect(_queue_fit)
	theme_changed.connect(_refresh_wire_focus, CONNECT_DEFERRED)
	node_selected.connect(_on_node_selected)
	node_deselected.connect(_on_node_deselected)
	end_node_move.connect(func() -> void: layout_changed.emit())
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	delete_nodes_request.connect(_on_delete_request)
	graph_elements_linked_to_frame_request.connect(_on_linked_to_frame)

func set_editable(on: bool) -> void:
	if _editable and not on:
		_apply_wire_focus(&"")
	_editable = on
	right_disconnects = on
	if not on:
		if Engine.is_editor_hint():
			remove_theme_color_override("activity")
		else:
			add_theme_color_override("activity", LIVE_ACTIVITY)

func _position_view_tools() -> void:
	var menu := get_menu_hbox().get_parent() as Control
	menu.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)

func request_fit() -> void:
	_fit_requested = true
	_queue_fit()

func _queue_fit() -> void:
	if _fit_requested and is_visible_in_tree() and not get_tree().process_frame.is_connected(_fit_all):
		# Let the split containers and card rows settle before measuring their bounds.
		get_tree().process_frame.connect(_fit_all, CONNECT_ONE_SHOT)

func _fit_all() -> void:
	if not is_visible_in_tree():
		return
	_fit_requested = false
	var bounds := Rect2()
	var has_elements := false
	for nodes in [_event_nodes, _rule_nodes, _frames]:
		for element: GraphElement in nodes.values():
			var rect := Rect2(element.position_offset, element.size)
			bounds = bounds.merge(rect) if has_elements else rect
			has_elements = true
	if not has_elements:
		return
	var area := fit_area if fit_area.has_area() else Rect2(Vector2.ZERO, size)
	var available := (area.size - Vector2(40, 32)).max(Vector2.ONE)
	zoom = clampf(minf(available.x / bounds.size.x, available.y / bounds.size.y), zoom_min, 1.0)
	scroll_offset = bounds.get_center() * zoom - area.get_center()

func _input(event: InputEvent) -> void:
	if _resizing_frame and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_resizing_frame = false
		layout_changed.emit()

func clear_view() -> void:
	_resizing_frame = false
	_inspected_node = null
	clear_connections()
	var elements: Array = get_children().filter(func(c: Node) -> bool: return c is GraphElement and not c.has_meta("dead"))
	# GraphEdit queues deferred move_child calls when frames are added, and freeing or removing
	# elements synchronously leaves those pointing at nodes that are gone. So: detach from
	# frames, then retire each element in place (unique name, hidden, queue_free) and let the
	# engine free it at the end of the frame. The new name keeps the original free for reuse.
	for c in elements:
		if get_element_frame(c.name) != null:
			detach_graph_element_from_frame(c.name)
	for c in elements:
		c.set_meta("dead", true)
		c.selected = false
		c.visible = false
		c.name = "dead_%d" % c.get_instance_id()
		c.queue_free()
	_rule_nodes.clear()
	_event_nodes.clear()
	_frames.clear()

func show_data(data: Dictionary) -> void:
	clear_view()
	var rules: Array = data["rules"]
	var problems: Array = data["problems"]
	_auto_layout(rules)

	for g in data["groups"]:
		var f := GraphFrame.new()
		f.name = "frame_" + _safe(g["name"])
		f.set_meta("group_name", g["name"])
		f.title = g["name"]
		f.position_offset = g["rect"].position
		f.size = g["rect"].size
		f.autoshrink_enabled = false
		f.autoshrink_margin = 24
		f.resizable = _editable
		if not Engine.is_editor_hint():
			f.add_theme_stylebox_override("panel", Style.surface(Color("#1c27366b"), Color("#384c64"), Vector2.ZERO, 9))
			f.add_theme_stylebox_override("panel_selected", Style.surface(Color("#233447a3"), COL_EVENT, Vector2.ZERO, 9))
			f.add_theme_stylebox_override("titlebar", Style.surface(Color("#27374a"), Color("#384c64"), Vector2(12, 4), 7))
			f.add_theme_stylebox_override("titlebar_selected", Style.surface(Color("#2a4655"), COL_EVENT, Vector2(12, 4), 7))
		_style_title(f.get_titlebar_hbox(), Style.TEXT, &"Folder", 17)
		_scale_card_padding(f, &"GraphFrame")
		f.resize_request.connect(func(new_size: Vector2) -> void:
			f.size = new_size
			_resizing_frame = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
			if not _resizing_frame:
				layout_changed.emit())
		add_child(f)
		_frames[g["name"]] = f

	for rd in rules:
		var n := _make_rule_node(rd, problems)
		add_child(n)
		_rule_nodes[rd["id"]] = n
		if rd["group"] != "" and _frames.has(rd["group"]):
			attach_graph_element_to_frame(n.name, _frames[rd["group"]].name)

	_make_event_nodes(data["external_events"], rules)
	_connect_all(rules)

## Current card positions and frame rects, to be written back into the model.
func get_positions() -> Dictionary:
	var out := {}
	for id in _rule_nodes:
		out[id] = (_rule_nodes[id] as GraphNode).position_offset
	return out

func get_group_rects() -> Dictionary:
	var out := {}
	for g in _frames:
		var f: GraphFrame = _frames[g]
		out[g] = Rect2(f.position_offset, f.size)
	return out

## World-space point at the middle of the visible canvas.
func view_center() -> Vector2:
	var center := fit_area.get_center() if fit_area.has_area() else size * 0.5
	return (scroll_offset + center) / zoom

func reveal_rule(rule_id: String, obstruction: Rect2) -> void:
	var card: GraphNode = _rule_nodes.get(rule_id)
	if card == null:
		return
	var bounds := Rect2(card.position_offset * zoom - scroll_offset, card.size * zoom)
	if not bounds.intersects(obstruction):
		return
	# Rule Settings sits on the right. Stop as soon as the card clears it.
	var left := maxf(0.0, obstruction.position.x - 12.0 - bounds.size.x)
	scroll_offset.x += maxf(0.0, bounds.position.x - left)

func context_target_at(pointer: Vector2) -> Dictionary:
	# Cards draw over frames. Within each layer, the last child draws on top.
	var children := get_children()
	children.reverse()
	for layer in [&"GraphNode", &"GraphFrame"]:
		for child in children:
			var element := child as GraphElement
			if element == null or not element.visible or not element.is_class(layer):
				continue
			if not Rect2(element.position, element.size * zoom).has_point(pointer):
				continue
			if element.has_meta("event"):
				return {"kind": "event", "id": element.get_meta("event")}
			if element.has_meta("rule_id"):
				return {"kind": "rule", "id": element.get_meta("rule_id")}
			if element.has_meta("group_name"):
				return {"kind": "group", "id": element.get_meta("group_name")}
	return {}

func select_rule(id: String) -> void:
	for c in get_children():
		if c is GraphElement:
			c.selected = false
	if _rule_nodes.has(id):
		_inspected_node = _rule_nodes[id]
		_inspected_node.selected = true

func select_group(group_name: String) -> bool:
	var frame: GraphFrame = _frames.get(group_name)
	if frame == null:
		return false
	_inspected_node = frame
	frame.selected = true
	return true

func _refresh_wire_focus() -> void:
	if not _editable:
		return
	var focused := &""
	if is_instance_valid(_inspected_node) and _inspected_node.selected and _inspected_node.has_meta("rule_id"):
		focused = _inspected_node.name
	if focused != &"":
		var canvas := get_theme_stylebox("panel") as StyleBoxFlat
		var dim_color := canvas.bg_color if canvas != null else Style.SURFACE
		dim_color.a = 0.55
		if get_theme_color("activity") != dim_color:
			add_theme_color_override("activity", dim_color)
	_apply_wire_focus(focused)

func _apply_wire_focus(focused: StringName) -> void:
	for wire in get_connection_list():
		var unrelated: bool = focused != &"" and wire["from_node"] != focused and wire["to_node"] != focused
		set_connection_activity(wire["from_node"], wire["from_port"], wire["to_node"], wire["to_port"], 0.65 if unrelated else 0.0)

## Port layout of a rule card: relays fired by its steps, then the rule's own `emits`.
static func output_relays(rd: Dictionary) -> Array:
	var relays: Array = []
	for s in rd["steps"]:
		if s["emits"] != "" and not relays.has(s["emits"]):
			relays.append(s["emits"])
	relays.append(rd["emit"])   # last port always exists so a wire can be dragged from it
	return relays

# --- Live highlighting ------------------------------------------------------------

func pulse(rule_id: String) -> void:
	var n: GraphNode = _rule_nodes.get(rule_id)
	if n == null:
		return
	_flash_node(n)
	var wires: Array = []
	for c in get_connection_list():
		if c["from_node"] == n.name:
			wires.append(c)
			set_connection_activity(c["from_node"], c["from_port"], c["to_node"], c["to_port"], 1.0)
	var t := n.create_tween()
	t.tween_interval(1.0)
	t.tween_callback(func() -> void:
		for c in wires:
			set_connection_activity(c["from_node"], c["from_port"], c["to_node"], c["to_port"], 0.0))

func pulse_event(event: String) -> void:
	var n: GraphNode = _event_nodes.get(event)
	if n:
		_flash_node(n)

func _flash_node(n: GraphNode) -> void:
	n.modulate = Color(2.0, 1.8, 0.7)
	var t := n.create_tween()
	t.tween_property(n, "modulate", Color.WHITE, 1.0)

# --- Gestures -> signals ----------------------------------------------------------

func _node_of(node_name: StringName) -> Node:
	return get_node_or_null(NodePath(String(node_name)))

func _on_node_selected(node: Node) -> void:
	if node.has_meta("rule_id"):
		_inspected_node = node as GraphElement
		_refresh_wire_focus()
		rule_selected.emit(node.get_meta("rule_id"))
	elif node.has_meta("group_name"):
		_inspected_node = node as GraphElement
		_refresh_wire_focus()
		group_selected.emit(node.get_meta("group_name"))

func _on_node_deselected(node: Node) -> void:
	if node == _inspected_node:
		# GraphEdit may select another card in the same input event.
		_clear_deselected.call_deferred()

func _clear_deselected() -> void:
	if is_instance_valid(_inspected_node) and not _inspected_node.selected:
		for nodes in [_rule_nodes, _frames]:
			for element: GraphElement in nodes.values():
				if element.selected:
					_on_node_selected(element)
					return
		_inspected_node = null
		_refresh_wire_focus()
		selection_cleared.emit()

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, _to_port: int) -> void:
	var src := _node_of(from_node)
	var dst := _node_of(to_node)
	if src == null or dst == null or not dst.has_meta("rule_id"):
		return
	if src.has_meta("event"):
		wire_added.emit({"event": src.get_meta("event")}, dst.get_meta("rule_id"))
	elif src.has_meta("rule_id"):
		wire_added.emit({"rule": src.get_meta("rule_id"), "port": from_port}, dst.get_meta("rule_id"))

func _on_disconnection_request(_from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	var dst := _node_of(to_node)
	if dst and dst.has_meta("rule_id"):
		wire_removed.emit(dst.get_meta("rule_id"))

func _on_delete_request(nodes: Array) -> void:
	var ids: Array = []
	for nm in nodes:
		var n := _node_of(nm)
		if n and n.has_meta("rule_id"):
			ids.append(n.get_meta("rule_id"))
	if not ids.is_empty():
		rules_delete_requested.emit(ids)

func _on_linked_to_frame(elements: Array, frame: StringName) -> void:
	var f := _node_of(frame)
	if f == null or not f.has_meta("group_name"):
		return
	var ids: Array = []
	for nm in elements:
		var n := _node_of(nm)
		if n and n.has_meta("rule_id"):
			ids.append(n.get_meta("rule_id"))
	if not ids.is_empty():
		rules_linked_to_group.emit(ids, f.get_meta("group_name"))

# --- Layout -----------------------------------------------------------------------

func _safe(s: String) -> String:
	for ch in [":", ".", "@", "/", "%", '"']:
		s = s.replace(ch, "_")
	return s

## Rules with no "# @node" comment get a column by relay depth so new rules are never stacked.
func _auto_layout(rules: Array) -> void:
	var depth := {}
	for rd in rules:
		depth[rd["id"]] = 0
	for _i in rules.size():
		for a in rules:
			for relay in output_relays(a):
				if relay == "":
					continue
				for b in rules:
					if b["trigger"] == "relay:" + relay and b["id"] != a["id"]:
						depth[b["id"]] = maxi(depth[b["id"]], depth[a["id"]] + 1)
	var col_y := {}
	for rd in rules:
		if rd["has_pos"]:
			continue
		var d: int = depth[rd["id"]]
		var y: float = col_y.get(d, 40.0)
		rd["pos"] = Vector2(40 + d * (CARD_WIDTH + 42.0), y)
		col_y[d] = y + 220.0

# --- Cards ------------------------------------------------------------------------

func _row(text: String, color: Color, icon_name := &"", fill := Color.TRANSPARENT) -> Control:
	var label := Style.label(text, color, 13)
	_scale_card_label(label, 13)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.tooltip_text = text
	if fill.a > 0 and not Engine.is_editor_hint():
		label.add_theme_stylebox_override("normal", Style.surface(fill, Color.TRANSPARENT, Vector2(7, 2), 4))
	if not Engine.is_editor_hint() or icon_name == &"":
		return label
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.tooltip_text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if icon_name == &"✓":
		var check := Style.label("✓", color, 13)
		_scale_card_label(check, 13)
		check.custom_minimum_size.x = 16
		check.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		check.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(check)
	else:
		row.add_child(_editor_icon(icon_name, color))
	row.add_child(label)
	return row

func _editor_icon(icon_name: StringName, color: Color) -> TextureRect:
	if _icon_material == null:
		# Keep the native glyph's silhouette and use the label color for its ink.
		var shader := Shader.new()
		shader.code = """
shader_type canvas_item;
render_mode unshaded;

varying vec4 icon_tint;

void vertex() {
	icon_tint = COLOR;
}

void fragment() {
	COLOR = vec4(icon_tint.rgb, icon_tint.a * texture(TEXTURE, UV).a);
}
"""
		_icon_material = ShaderMaterial.new()
		_icon_material.shader = shader
	var icon := TextureRect.new()
	icon.material = _icon_material
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var refresh := func() -> void:
		icon.visible = icon.has_theme_icon(icon_name, &"EditorIcons")
		if icon.visible:
			icon.texture = icon.get_theme_icon(icon_name, &"EditorIcons")
			icon.self_modulate = Style.resolve_color(icon, color)
			icon.custom_minimum_size = Vector2(16, 16) * minf(1.0, icon.get_theme_default_base_scale())
	icon.ready.connect(refresh)
	icon.theme_changed.connect(refresh, CONNECT_DEFERRED)
	return icon

func _style_title(titlebar: HBoxContainer, color: Color, icon_name: StringName, size_in_graph := 14) -> void:
	for child in titlebar.get_children():
		if child is Label:
			child.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			child.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			Style.tint(child, color)
			Style.fallback_font_size(child, size_in_graph)
			_scale_card_label(child, size_in_graph)
	if Engine.is_editor_hint():
		var icon := _editor_icon(icon_name, color)
		titlebar.add_child(icon)
		titlebar.move_child(icon, 0)

func _style_card(node: GraphNode, width: float, title_color: Color, header: Color, icon_name: StringName) -> void:
	node.custom_minimum_size.x = width
	node.add_theme_constant_override("separation", 5)
	if not Engine.is_editor_hint():
		node.add_theme_stylebox_override("panel", Style.surface(Style.SURFACE, Style.BORDER, Vector2(13, 9)))
		node.add_theme_stylebox_override("panel_selected", Style.surface(Color("#1d2938"), COL_EVENT, Vector2(13, 9)))
		node.add_theme_stylebox_override("titlebar", Style.surface(header, Style.BORDER, Vector2(12, 7), 6))
		node.add_theme_stylebox_override("titlebar_selected", Style.surface(header.lightened(0.07), COL_EVENT, Vector2(12, 7), 6))
	_style_title(node.get_titlebar_hbox(), title_color, icon_name)
	_scale_card_padding(node, &"GraphNode")

func _scale_card_label(label: Label, size_in_graph: int) -> void:
	if Engine.is_editor_hint():
		# The graph uses authored coordinates and has its own zoom.
		label.ready.connect(func() -> void:
			if label.get_theme_default_base_scale() > 1.0:
				label.add_theme_font_size_override("font_size", size_in_graph))

func _scale_card_padding(card: GraphElement, type: StringName) -> void:
	if not Engine.is_editor_hint():
		return
	var refresh := func() -> void:
		if not is_instance_valid(card):
			return
		var editor_scale := get_theme_default_base_scale()
		if editor_scale <= 1.0:
			return
		var items: Array[StringName] = [&"panel", &"panel_selected", &"titlebar", &"titlebar_selected"]
		if card is GraphNode:
			items.append_array([&"slot", &"slot_selected"])
			if card.get_theme_constant("separation") != 2:
				card.add_theme_constant_override("separation", 2)
		for item in items:
			var source := get_theme_stylebox(item, type)
			if card.has_meta(item) and card.get_meta(item) == source:
				continue
			var scaled := source.duplicate() as StyleBox
			for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				scaled.set_content_margin(side, source.get_margin(side) / editor_scale)
			card.set_meta(item, source)
			card.add_theme_stylebox_override(item, scaled)
		if card is GraphNode:
			card.reset_size()
	card.ready.connect(refresh)
	card.theme_changed.connect(refresh, CONNECT_DEFERRED)

func _make_rule_node(rd: Dictionary, problems: Array) -> GraphNode:
	var n := GraphNode.new()
	n.name = _safe(rd["id"])
	n.set_meta("rule_id", rd["id"])
	var warned := problems.any(func(p: String) -> bool: return ("'%s'" % rd["id"]) in p)
	n.title = ("⚠ " if warned and not Engine.is_editor_hint() else "") + rd["id"]
	n.tooltip_text = rd["id"]
	n.position_offset = rd["pos"]
	_style_card(n, CARD_WIDTH, Style.WARNING if warned else Style.TEXT, Color("#253347"), &"NodeWarning" if warned else &"GraphNode")

	# Each row is one slot. Entries: [label, left_port, right_port, color]
	var rows: Array = []
	var trigger: String = rd["trigger"]
	var trigger_text := "On  " + trigger if not trigger.is_empty() else "Connect a trigger"
	var trigger_color := COL_RELAY if trigger.begins_with("relay:") else COL_EVENT
	rows.append([_row(trigger_text, trigger_color, &"Signal", Color("#203341")), true, false, trigger_color])
	if not rd["requires"].is_empty():
		rows.append([_row("requires: " + ", ".join(rd["requires"]), COL_REQ, &"✓"), false, false, COL_DIM])
	if not rd["forbids"].is_empty():
		rows.append([_row("forbids: " + ", ".join(rd["forbids"]), COL_FORBID, &"GuiClose"), false, false, COL_DIM])
	if not rd["cancel_if"].is_empty():
		rows.append([_row("cancel_if: " + ", ".join(rd["cancel_if"]), COL_CANCEL, &"Stop"), false, false, COL_DIM])
	if rd["once"]:
		rows.append([_row("Run once", COL_DIM, &"Lock"), false, false, COL_DIM])
	var i := 1
	for s in rd["steps"]:
		var prefix := "%d. " % i
		if s["delay"] != "":
			prefix += "+%ss  " % s["delay"]
		var step_icon := &"Timer" if s["delay"] != "" else &"Play"
		rows.append([_row(prefix + "%s(%s)" % [s["verb"], ", ".join(PackedStringArray(s["args"]))], Style.TEXT, step_icon), false, false, COL_DIM])
		i += 1
	var relays := output_relays(rd)
	for p in relays.size():
		var last := p == relays.size() - 1
		if not _editable and relays[p] == "":
			continue
		var label: String = ("Emits  " + relays[p]) if relays[p] != "" else "Add relay"
		if not last:
			label = "Fires  " + relays[p]
		var relay_icon := &"Signal" if relays[p] != "" else &"Add"
		var row := _row(label, COL_RELAY if relays[p] != "" else COL_DIM, relay_icon, Color("#302b2a") if relays[p] != "" else Color.TRANSPARENT)
		if relays[p] == "":
			row.tooltip_text = "Drag the output port to a rule to create a relay"
		rows.append([row, false, true, COL_RELAY])

	_add_card_rows(n, rows)
	return n

func _add_card_rows(node: GraphNode, rows: Array) -> void:
	for row in rows:
		node.add_child(row[0])
	for i in rows.size():
		var row: Array = rows[i]
		node.set_slot(i, row[1], 0, row[3], row[2], 0, row[3])
	if Engine.is_editor_hint():
		node.theme_changed.connect(func() -> void:
			for i in rows.size():
				var row: Array = rows[i]
				if row[1]:
					node.set_slot_color_left(i, Style.resolve_color(node, row[3]))
				if row[2]:
					node.set_slot_color_right(i, Style.resolve_color(node, row[3])))

func _make_event_nodes(events: Array, rules: Array) -> void:
	var min_x := 0.0
	for rd in rules:
		min_x = minf(min_x, rd["pos"].x)
	var entries: Array = []
	for e in events:
		var y := 1e9
		for rd in rules:
			if rd["trigger"] == e:
				y = minf(y, rd["pos"].y)
		entries.append({"event": e, "y": y if y < 1e9 else 0.0})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["y"] < b["y"])
	var prev_y := -1e9
	for en in entries:
		var y: float = maxf(en["y"], prev_y + 90.0)
		prev_y = y
		var n := GraphNode.new()
		n.name = "ev_" + _safe(en["event"])
		n.set_meta("event", en["event"])
		n.title = "External event"
		n.tooltip_text = en["event"]
		n.position_offset = Vector2(min_x - 230.0, y)
		_style_card(n, 174.0, COL_EVENT, Color("#1e3947"), &"Signal")
		_add_card_rows(n, [[_row(en["event"], Style.TEXT), false, true, COL_EVENT]])
		add_child(n)
		_event_nodes[en["event"]] = n

func _connect_all(rules: Array) -> void:
	for ev in _event_nodes:
		for b in rules:
			if b["trigger"] == ev:
				_wire(_event_nodes[ev].name, 0, _rule_nodes[b["id"]].name)
	for a in rules:
		var relays := output_relays(a)
		for port in relays.size():
			if relays[port] == "":
				continue
			for b in rules:
				if b["trigger"] == "relay:" + relays[port] and b["id"] != a["id"]:
					_wire(_rule_nodes[a["id"]].name, port, _rule_nodes[b["id"]].name)

func _wire(from_node: StringName, from_port: int, to_node: StringName) -> void:
	var err := connect_node(from_node, from_port, to_node, 0)
	if err != OK:
		push_warning("RuleGraphView: could not connect %s -> %s (%d)" % [from_node, to_node, err])
