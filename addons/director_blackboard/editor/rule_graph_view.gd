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
signal wire_added(source: Dictionary, to_rule: String)   # source: {"event": name} or {"rule": id, "port": int}
signal wire_removed(to_rule: String)
signal rules_delete_requested(ids: Array)
signal rules_linked_to_group(ids: Array, group_name: String)
signal layout_changed

const COL_EVENT := Color(0.45, 0.7, 1.0)
const COL_RELAY := Color(1.0, 0.7, 0.3)
const COL_REQ := Color(0.5, 0.85, 0.5)
const COL_FORBID := Color(0.95, 0.5, 0.5)
const COL_CANCEL := Color(0.95, 0.75, 0.4)
const COL_DIM := Color(0.7, 0.7, 0.75)

var _rule_nodes := {}    # rule id -> GraphNode
var _event_nodes := {}   # event name -> GraphNode
var _frames := {}        # group name -> GraphFrame
var _resizing_frame := false

func _init() -> void:
	minimap_enabled = true
	show_zoom_label = true
	node_selected.connect(_on_node_selected)
	end_node_move.connect(func() -> void: layout_changed.emit())
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	delete_nodes_request.connect(_on_delete_request)
	graph_elements_linked_to_frame_request.connect(_on_linked_to_frame)

func set_editable(on: bool) -> void:
	right_disconnects = on

func _input(event: InputEvent) -> void:
	if _resizing_frame and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_resizing_frame = false
		layout_changed.emit()

func clear_view() -> void:
	_resizing_frame = false
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
		f.resizable = true
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
	return (scroll_offset + size * 0.5) / zoom

func select_rule(id: String) -> void:
	for c in get_children():
		if c is GraphElement:
			c.selected = false
	if _rule_nodes.has(id):
		_rule_nodes[id].selected = true

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
		rule_selected.emit(node.get_meta("rule_id"))
	elif node.has_meta("group_name"):
		group_selected.emit(node.get_meta("group_name"))

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
		rd["pos"] = Vector2(40 + d * 300, y)
		col_y[d] = y + 220.0

# --- Cards ------------------------------------------------------------------------

func _row(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", 13)
	return l

func _make_rule_node(rd: Dictionary, problems: Array) -> GraphNode:
	var n := GraphNode.new()
	n.name = _safe(rd["id"])
	n.set_meta("rule_id", rd["id"])
	var warned := problems.any(func(p: String) -> bool: return ("'%s'" % rd["id"]) in p)
	n.title = ("⚠ " if warned else "") + rd["id"]
	n.position_offset = rd["pos"]
	n.custom_minimum_size = Vector2(250, 0)

	# Each row is one slot. Entries: [label, left_port, right_port, color]
	var rows: Array = []
	rows.append([_row("on  " + (rd["trigger"] if rd["trigger"] != "" else "(drag a wire here)"), COL_EVENT), true, false, COL_EVENT])
	if not rd["requires"].is_empty():
		rows.append([_row("requires: " + ", ".join(rd["requires"]), COL_REQ), false, false, COL_DIM])
	if not rd["forbids"].is_empty():
		rows.append([_row("forbids: " + ", ".join(rd["forbids"]), COL_FORBID), false, false, COL_DIM])
	if not rd["cancel_if"].is_empty():
		rows.append([_row("cancel_if: " + ", ".join(rd["cancel_if"]), COL_CANCEL), false, false, COL_DIM])
	if rd["once"]:
		rows.append([_row("once", COL_DIM), false, false, COL_DIM])
	var i := 1
	for s in rd["steps"]:
		var prefix := "%d. " % i
		if s["delay"] != "":
			prefix += "(+%ss) " % s["delay"]
		rows.append([_row(prefix + "%s(%s)" % [s["verb"], ", ".join(PackedStringArray(s["args"]))], Color.WHITE), false, false, COL_DIM])
		i += 1
	var relays := output_relays(rd)
	for p in relays.size():
		var last := p == relays.size() - 1
		var label: String = ("emits  " + relays[p]) if relays[p] != "" else "emits  (drag to wire)"
		if not last:
			label = "fires  " + relays[p]
		rows.append([_row(label, COL_RELAY if relays[p] != "" else COL_DIM), false, true, COL_RELAY])

	for row in rows:
		n.add_child(row[0])
	for idx in rows.size():
		var row: Array = rows[idx]
		n.set_slot(idx, row[1], 0, row[3], row[2], 0, row[3])
	return n

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
		n.title = "event"
		n.position_offset = Vector2(min_x - 230.0, y)
		n.custom_minimum_size = Vector2(170, 0)
		n.add_child(_row(en["event"], COL_EVENT))
		n.set_slot(0, false, 0, COL_EVENT, true, 0, COL_EVENT)
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
