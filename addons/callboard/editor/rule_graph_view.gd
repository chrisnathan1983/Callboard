@tool
class_name RuleGraphView extends GraphEdit
## Renders board data as a node graph: one card per rule, one source node per external event,
## GraphFrames for groups. Wires are derived from relay relationships, never stored.
##
## The view never edits the model. It turns gestures into semantic signals and the board
## applies them, then calls update_data() to refresh the affected graph content.
##   drag output -> input     wire_added
##   drag a wire off an input wire_removed
##   Delete key               rules_delete_requested
##   drop card on a frame     rules_linked_to_group

signal rule_selected(rule_id: String)
signal group_selected(group_name: String)
signal selection_cleared
signal wire_added(source: Dictionary, to_rule: String)   # source: {"event": name}, {"rule": id, "port": int}, or {"rule": id, "relay": name}
signal wire_removed(to_rule: String)
signal rules_delete_requested(ids: Array)
signal rules_linked_to_group(ids: Array, group_name: String)
signal layout_changed

const Style := preload("res://addons/callboard/editor/board_style.gd")
const CARD_WIDTH := 264.0
const COMPACT_CARD_WIDTH := CARD_WIDTH
const CALL_WIDTH := 174.0
const CALL_GAP := 20.0
const COL_EVENT := Style.EVENT
const COL_RELAY := Style.RELAY
const COL_REQ := Style.SUCCESS
const COL_FORBID := Style.ERROR
const COL_CANCEL := Style.WARNING
const COL_DIM := Style.MUTED

var fit_area := Rect2()
var _rule_nodes := {}    # rule id -> GraphNode
var _event_nodes := {}   # event name -> GraphNode
var _frames := {}        # group name -> GraphFrame
var _rule_signatures := {}
var _resizing_frame := false
var _editable := true
var _fit_requested := false
var _inspected_node: GraphElement
var _icon_material: ShaderMaterial
var _minimap_control: Control
var _compact_button: Button
var _minimized := false
var _last_data: Dictionary = {}

func _init() -> void:
	minimap_enabled = true
	minimap_size = Vector2i(170, 110)
	show_zoom_label = true
	grid_pattern = GRID_PATTERN_DOTS
	connection_lines_thickness = 2.0
	var fit := Button.new()
	fit.text = "Fit all"
	Style.button_icon(fit, &"ZoomReset", "", true)
	fit.tooltip_text = "Frame every Call, rule and group"
	fit.pressed.connect(request_fit)
	get_menu_hbox().add_child(fit)
	var arrange := Button.new()
	arrange.text = "Arrange"
	arrange.tooltip_text = "Arrange rules by relay flow and place Calls beside them"
	arrange.pressed.connect(auto_arrange)
	get_menu_hbox().add_child(arrange)
	_compact_button = Button.new()
	_compact_button.text = "Compact"
	_compact_button.toggle_mode = true
	_compact_button.tooltip_text = "Collapse rule details"
	_compact_button.toggled.connect(set_minimized)
	get_menu_hbox().add_child(_compact_button)
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
		remove_theme_color_override("activity")

func set_minimized(on: bool) -> void:
	if _minimized == on:
		return
	var selected_rule := String(_inspected_node.get_meta("rule_id", "")) if is_instance_valid(_inspected_node) else ""
	var selected_group := String(_inspected_node.get_meta("group_name", "")) if is_instance_valid(_inspected_node) else ""
	_minimized = on
	if is_instance_valid(_compact_button):
		_compact_button.set_pressed_no_signal(on)
	if not _last_data.is_empty():
		show_data(_last_data)
		if not selected_rule.is_empty():
			select_rule(selected_rule)
		elif not selected_group.is_empty():
			select_group(selected_group)

func _ready() -> void:
	_minimap_control = _find_minimap_control(self)

func _find_minimap_control(root: Node) -> Control:
	for child in root.get_children(true):
		if child.name == "_minimap" and child is Control:
			return child as Control
		var nested := _find_minimap_control(child)
		if nested != null:
			return nested
	return null

## Keep GraphEdit's built-in overview map clear of the floating right-side panel.
func set_minimap_right_edge(right_edge: float) -> void:
	if not is_instance_valid(_minimap_control):
		_minimap_control = _find_minimap_control(self)
	if _minimap_control == null:
		return
	var host := _minimap_control.get_parent() as Control
	if host == null:
		return
	var map_size := _minimap_control.size
	var right_offset := maxf(right_edge, map_size.x + 12.0) - host.size.x
	_minimap_control.anchor_left = 1.0
	_minimap_control.anchor_right = 1.0
	_minimap_control.anchor_top = 1.0
	_minimap_control.anchor_bottom = 1.0
	_minimap_control.offset_left = right_offset - map_size.x
	_minimap_control.offset_right = right_offset
	_minimap_control.offset_top = -map_size.y - 8.0
	_minimap_control.offset_bottom = -8.0

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
	_rule_signatures.clear()

func show_data(data: Dictionary) -> void:
	_last_data = data
	clear_view()
	var rules: Array = data["rules"]
	var problems: Array = data["notes"]
	if not _has_position_data(data):
		_auto_layout(rules, true)

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

	_make_event_nodes(data["external_calls"], rules, data.get("call_positions", {}))
	_connect_all(rules)
	_cache_rule_signatures(rules, problems)

## Updates stable graph structures in place. A structural change falls back to a full build;
## otherwise only rule cards whose rendered content changed are recreated.
func update_data(data: Dictionary) -> void:
	_last_data = data
	var rules: Array = data["rules"]
	var problems: Array = data["notes"]
	if (not _same_ids(_rule_nodes, rules.map(func(rd: Dictionary) -> String: return rd["id"]))
		or not _same_ids(_event_nodes, data["external_calls"])
		or not _same_ids(_frames, data["groups"].map(func(group: Dictionary) -> String: return group["name"]))):
		show_data(data)
		return

	clear_connections()
	for group in data["groups"]:
		var frame: GraphFrame = _frames[group["name"]]
		frame.position_offset = group["rect"].position
		frame.size = group["rect"].size

	for rd in rules:
		var id: String = rd["id"]
		var signature := _rule_signature(rd, problems)
		var node: GraphNode = _rule_nodes[id]
		if _rule_signatures.get(id) != signature:
			_retire_element(node)
			node = _make_rule_node(rd, problems)
			add_child(node)
			_rule_nodes[id] = node
		else:
			node.position_offset = rd["pos"]
		var frame: GraphFrame = _frames.get(rd["group"])
		var current_frame := get_element_frame(node.name)
		if frame != current_frame:
			if current_frame != null:
				detach_graph_element_from_frame(node.name)
			if frame != null:
				attach_graph_element_to_frame(node.name, frame.name)
		_rule_signatures[id] = signature

	var event_positions := _event_positions(data["external_calls"], rules, data.get("call_positions", {}))
	for event_id in _event_nodes:
		(_event_nodes[event_id] as GraphNode).position_offset = event_positions[event_id]
	_connect_all(rules)
	_refresh_wire_focus()

func _same_ids(nodes: Dictionary, ids: Array) -> bool:
	if nodes.size() != ids.size():
		return false
	for id in ids:
		if not nodes.has(id):
			return false
	return true

func _rule_signature(rd: Dictionary, problems: Array) -> Dictionary:
	var content := rd.duplicate(true)
	content.erase("pos")
	content.erase(AuthoredData.FIELD_HAS_POS)
	content.erase("group")
	return {
		"content": content,
		"warned": problems.any(func(problem: String) -> bool: return ("'%s'" % rd["id"]) in problem),
		"editable": _editable,
	}

func _cache_rule_signatures(rules: Array, problems: Array) -> void:
	_rule_signatures.clear()
	for rd in rules:
		_rule_signatures[rd["id"]] = _rule_signature(rd, problems)

func _retire_element(element: GraphElement) -> void:
	if _inspected_node == element:
		_inspected_node = null
	element.selected = false
	if get_element_frame(element.name) != null:
		detach_graph_element_from_frame(element.name)
	element.set_meta("dead", true)
	element.visible = false
	element.name = "dead_%d" % element.get_instance_id()
	element.queue_free()

## Current card positions and frame rects, to be written back into the model.
func get_positions() -> Dictionary:
	var out := {}
	for id in _rule_nodes:
		out[id] = (_rule_nodes[id] as GraphNode).position_offset
	return out

## Current external Call node positions, keyed by Call ID.
func get_call_positions() -> Dictionary:
	var out := {}
	for id in _event_nodes:
		out[id] = (_event_nodes[id] as GraphNode).position_offset
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

func reveal_rule_in_canvas(rule_id: String) -> void:
	var card: GraphNode = _rule_nodes.get(rule_id)
	if card == null or not fit_area.has_area():
		return
	var bounds := Rect2(card.position_offset * zoom - scroll_offset, card.size * zoom)
	if not fit_area.encloses(bounds):
		scroll_offset += bounds.get_center() - fit_area.get_center()

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

func clear_selection() -> void:
	_deselect_elements()
	_clear_deselected()

func _deselect_elements() -> void:
	for c in get_children():
		if c is GraphElement:
			c.selected = false

func select_rule(id: String) -> void:
	_deselect_elements()
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
		var source_id: String = src.get_meta("rule_id")
		var target_id: String = dst.get_meta("rule_id")
		if _minimized:
			_request_compact_wire(source_id, target_id)
		else:
			wire_added.emit({"rule": source_id, "port": from_port}, target_id)

func _request_compact_wire(source_id: String, target_id: String) -> void:
	var source_rule: Dictionary = _last_data["rules"].filter(
		func(rule: Dictionary) -> bool: return rule["id"] == source_id).front()
	var choices: Array[String] = []
	for relay in output_relays(source_rule):
		if not choices.has(relay):
			choices.append(relay)
	if choices.size() <= 1:
		wire_added.emit({"rule": source_id, "relay": choices[0]}, target_id)
		return
	var popup := PopupMenu.new()
	add_child(popup)
	for relay in choices:
		popup.add_item("(new relay)" if relay.is_empty() else relay)
	popup.id_pressed.connect(func(id: int) -> void:
		wire_added.emit({"rule": source_id, "relay": choices[id]}, target_id))
	popup.popup_hide.connect(func() -> void: popup.queue_free())
	popup.popup(Rect2i(get_global_mouse_position(), Vector2i.ZERO))

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

func _has_position_data(data: Dictionary) -> bool:
	if not data.get("call_positions", {}).is_empty():
		return true
	for rd in data["rules"]:
		if rd.get(AuthoredData.FIELD_HAS_POS, false):
			return true
	return false

func auto_arrange() -> void:
	if _last_data.is_empty() or not _editable:
		return
	var rules: Array = _last_data["rules"]
	_auto_layout(rules, true)
	for rd in rules:
		rd[AuthoredData.FIELD_HAS_POS] = true
		var node: GraphNode = _rule_nodes.get(rd["id"])
		if node:
			node.position_offset = rd["pos"]
	var call_positions := _event_positions(_last_data["external_calls"], rules, {}, true)
	for id in _event_nodes:
		(_event_nodes[id] as GraphNode).position_offset = call_positions[id]
	layout_changed.emit()
	request_fit()

## Rules without saved positions are placed by relay depth. Force is reserved for
## first-open layouts and the explicit Arrange command.
func _auto_layout(rules: Array, force := false) -> void:
	var node_width := COMPACT_CARD_WIDTH if _minimized else CARD_WIDTH
	var row_spacing := 88.0 if _minimized else 220.0
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
		if not force and rd[AuthoredData.FIELD_HAS_POS]:
			continue
		var d: int = depth[rd["id"]]
		var y: float = col_y.get(d, 40.0)
		rd["pos"] = Vector2(40 + d * (node_width + 42.0), y)
		col_y[d] = y + row_spacing

# --- Cards ------------------------------------------------------------------------

func _row(text: String, color: Color, icon_name := &"") -> Control:
	var label := Style.label(text, color, 13)
	_scale_card_label(label, 13)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.tooltip_text = text
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

func _style_card(node: GraphNode, width: float, title_color: Color, icon_name: StringName) -> void:
	node.custom_minimum_size.x = width
	node.add_theme_constant_override("separation", 5)
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
	_style_card(n, COMPACT_CARD_WIDTH if _minimized else CARD_WIDTH,
		Style.WARNING if warned else Style.TEXT, &"NodeWarning" if warned else &"GraphNode")

	# Each row is one slot: [control, left_port, right_port, color, optional_right_color].
	var rows: Array = []
	var trigger: String = rd["trigger"]
	var trigger_text := "On  " + trigger if not trigger.is_empty() else "Connect a trigger"
	var trigger_color := COL_RELAY if trigger.begins_with("relay:") else COL_EVENT
	var relays := output_relays(rd)
	if _minimized:
		var compact_row := HBoxContainer.new()
		compact_row.custom_minimum_size = Vector2(0, 22)
		compact_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		compact_row.add_theme_constant_override("separation", 0)
		_add_compact_title_icons(compact_row, rd)
		_add_compact_relay_label(compact_row, relays)
		var has_output: bool = _editable or relays.any(func(relay: String) -> bool: return relay != "")
		rows.append([compact_row, true, has_output, trigger_color, COL_RELAY])
		_add_card_rows(n, rows)
		return n
	rows.append([_row(trigger_text, trigger_color, &"Signal"), true, false, trigger_color])
	if not rd["requires"].is_empty():
		rows.append([_row("requires: " + ", ".join(rd["requires"]), COL_REQ, &"✓"), false, false, COL_DIM])
	if not rd["forbids"].is_empty():
		rows.append([_row("forbids: " + ", ".join(rd["forbids"]), COL_FORBID, &"GuiClose"), false, false, COL_DIM])
	if not rd["cancel_if"].is_empty():
		rows.append([_row("cancel_if: " + ", ".join(rd["cancel_if"]), COL_CANCEL, &"Stop"), false, false, COL_DIM])
	if rd[AuthoredData.FIELD_ONE_SHOT]:
		rows.append([_row("One-shot", COL_DIM, &"Lock"), false, false, COL_DIM])
	var i := 1
	for s in rd["steps"]:
		var prefix := "%d. " % i
		if s["delay"] != "":
			prefix += "+%ss  " % s["delay"]
		var step_icon := &"Timer" if s["delay"] != "" else &"Play"
		rows.append([_row(prefix + "%s(%s)" % [s["verb"], ", ".join(PackedStringArray(s["args"]))], Style.TEXT, step_icon), false, false, COL_DIM])
		i += 1
	for p in relays.size():
		var last := p == relays.size() - 1
		if not _editable and relays[p] == "":
			continue
		var label: String = ("Emits  " + relays[p]) if relays[p] != "" else "Add relay"
		if not last:
			label = "Fires  " + relays[p]
		var relay_icon := &"Signal" if relays[p] != "" else &"Add"
		var row := _row(label, COL_RELAY if relays[p] != "" else COL_DIM, relay_icon)
		if relays[p] == "":
			row.tooltip_text = "Drag the output port to a rule to create a relay"
		rows.append([row, false, true, COL_RELAY])

	_add_card_rows(n, rows)
	return n

func _add_compact_title_icons(row: HBoxContainer, rd: Dictionary) -> void:
	if not rd["requires"].is_empty():
		_add_title_icon(row, &"", "✓", COL_REQ,
			"Requires: " + ", ".join(rd["requires"]))
	if not rd["forbids"].is_empty():
		_add_title_icon(row, &"GuiClose", "×", COL_FORBID,
			"Forbids: " + ", ".join(rd["forbids"]))
	if not rd["cancel_if"].is_empty():
		_add_title_icon(row, &"Stop", "■", COL_CANCEL,
			"Cancel if: " + ", ".join(rd["cancel_if"]))
	if not rd["steps"].is_empty():
		var action_names: Array[String] = []
		for step in rd["steps"]:
			action_names.append(step["verb"])
		_add_title_icon(row, &"Play", "▶", Style.TEXT,
			"Steps: " + ", ".join(action_names))
		var delayed: Array = rd["steps"].filter(func(step: Dictionary) -> bool: return step["delay"] != "")
		if not delayed.is_empty():
			var delay_details: Array[String] = []
			for step in delayed:
				delay_details.append(step["delay"] + "s")
			_add_title_icon(row, &"Timer", "◷", Style.EVENT,
				"Step delays: " + ", ".join(delay_details))
	if rd[AuthoredData.FIELD_ONE_SHOT]:
		_add_title_icon(row, &"Lock", "●", COL_DIM, "One-shot")

func _add_compact_relay_label(row: HBoxContainer, relays: Array) -> void:
	var emitted: Array[String] = []
	for relay in relays:
		if relay != "" and not emitted.has(relay):
			emitted.append(relay)
	var detail := ", ".join(emitted) if not emitted.is_empty() else "not set"
	var label_text := ", ".join(emitted) if not emitted.is_empty() else "Add relay"
	var relay_color := COL_RELAY if not emitted.is_empty() else COL_DIM
	_add_title_icon(row, &"Signal", "↗", relay_color, "Emits: " + detail)
	var label := Style.label(label_text, relay_color, 11)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.tooltip_text = "Emits: " + detail
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(label)

func _add_title_icon(row: HBoxContainer, icon_name: StringName, fallback: String,
		color: Color, tooltip: String) -> void:
	var control: Control
	if icon_name != &"" and Engine.is_editor_hint():
		control = _editor_icon(icon_name, color)
		control.mouse_filter = Control.MOUSE_FILTER_PASS
	else:
		var label := Style.label(fallback, color, 13)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.custom_minimum_size.x = 16
		control = label
	control.tooltip_text = tooltip
	control.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(control)
func _add_card_rows(node: GraphNode, rows: Array) -> void:
	for row in rows:
		node.add_child(row[0])
	for i in rows.size():
		var row: Array = rows[i]
		var left_color: Color = row[3]
		var right_color: Color = row[4] if row.size() > 4 else row[3]
		node.set_slot(i, row[1], 0, left_color, row[2], 0, right_color)
	if Engine.is_editor_hint():
		node.theme_changed.connect(func() -> void:
			for i in rows.size():
				var row: Array = rows[i]
				var left_color: Color = row[3]
				var right_color: Color = row[4] if row.size() > 4 else row[3]
				if row[1]:
					node.set_slot_color_left(i, Style.resolve_color(node, left_color))
				if row[2]:
					node.set_slot_color_right(i, Style.resolve_color(node, right_color)))

func _make_event_nodes(events: Array, rules: Array, saved_positions: Dictionary) -> void:
	var positions := _event_positions(events, rules, saved_positions)
	for event_id in events:
		var n := GraphNode.new()
		n.name = "ev_" + _safe(event_id)
		n.set_meta("event", event_id)
		n.title = "External Relay" if event_id.begins_with(RuleConnections.RELAY_PREFIX) else "Call"
		n.tooltip_text = event_id
		n.position_offset = positions[event_id]
		_style_card(n, CALL_WIDTH, COL_EVENT, &"Signal")
		_add_card_rows(n, [[_row(event_id, Style.TEXT), false, true, COL_EVENT]])
		add_child(n)
		_event_nodes[event_id] = n

func _event_positions(events: Array, rules: Array, saved_positions: Dictionary = {}, force := false) -> Dictionary:
	var min_x := INF
	for rd in rules:
		min_x = minf(min_x, rd["pos"].x)
	if min_x == INF:
		min_x = 0.0
	var entries: Array = []
	for e in events:
		var y := 1e9
		for rd in rules:
			if rd["trigger"] == e:
				y = minf(y, rd["pos"].y)
		entries.append({"event": e, "y": y if y < 1e9 else 0.0})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["y"] < b["y"])
	var prev_y := -1e9
	var positions := {}
	for en in entries:
		var event_id: String = en["event"]
		if not force and saved_positions.get(event_id) is Vector2:
			var saved: Vector2 = saved_positions[event_id]
			positions[event_id] = saved
			prev_y = maxf(prev_y, saved.y)
			continue
		var y: float = maxf(en["y"], prev_y + 90.0)
		prev_y = y
		positions[event_id] = Vector2(min_x - CALL_WIDTH - CALL_GAP, y)
	return positions

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
					_wire(_rule_nodes[a["id"]].name, 0 if _minimized else port, _rule_nodes[b["id"]].name)

func _wire(from_node: StringName, from_port: int, to_node: StringName) -> void:
	var err := connect_node(from_node, from_port, to_node, 0)
	if err != OK:
		push_warning("RuleGraphView: could not connect %s -> %s (%d)" % [from_node, to_node, err])
