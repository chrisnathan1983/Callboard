@tool
class_name RuleInspector extends ScrollContainer
## Property editor for the selected rule (or group). Edits the model dictionaries in place and
## emits `changed`. Step argument widgets are generated from the verb's typed signature:
## props become dropdowns of compatible props, bools check boxes, numbers spin boxes,
## Blackboard `key` parameters a dropdown of declared keys, anything else a raw expression box.

signal changed(rule_id: String)
signal structure_changed(rule_id: String)   # inspector rebuilt itself; board should refresh the graph
signal delete_requested(rule_id: String)
signal duplicate_requested(rule_id: String)
signal group_edited
signal group_delete_requested(group_name: String)

var _data: Dictionary
var _rule: Dictionary
var _group: Dictionary
var _read_only := false
var _box := VBoxContainer.new()

func _init() -> void:
	custom_minimum_size = Vector2(290, 0)
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_box)

func show_message(text: String) -> void:
	_clear()
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_box.add_child(l)

func show_rule(rule: Dictionary, data: Dictionary, read_only := false) -> void:
	_rule = rule
	_group = {}
	_data = data
	_read_only = read_only
	_build_rule()

func show_group(group: Dictionary, data: Dictionary, read_only := false) -> void:
	_group = group
	_rule = {}
	_data = data
	_read_only = read_only
	_clear()
	_title("Group")
	var name_edit := LineEdit.new()
	name_edit.text = group["name"]
	var apply := func(_t := "") -> void: _rename_group(name_edit)
	name_edit.text_submitted.connect(apply)
	name_edit.focus_exited.connect(apply)
	_box.add_child(name_edit)
	var del := Button.new()
	del.text = "Delete group (keeps its rules)"
	del.pressed.connect(func() -> void: group_delete_requested.emit(group["name"]))
	_box.add_child(del)
	if read_only:
		_lock(_box)

func _clear() -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()

func _rebuild_later() -> void:
	call_deferred("_build_rule")

# --- Rule form --------------------------------------------------------------------

func _build_rule() -> void:
	_clear()
	if _rule.is_empty():
		return
	var r := _rule
	_title("Rule")
	_line("id", r["id"], func(t: String) -> void: _set_id(t))

	var trig := HBoxContainer.new()
	var trig_edit := LineEdit.new()
	trig_edit.text = r["trigger"]
	trig_edit.placeholder_text = "trigger"
	trig_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var apply_trig := func(_t := "") -> void: _set_trigger(trig_edit.text.strip_edges())
	trig_edit.text_submitted.connect(apply_trig)
	trig_edit.focus_exited.connect(apply_trig)
	trig.add_child(_name_label("on"))
	trig.add_child(trig_edit)
	var pick := MenuButton.new()
	pick.text = "▾"
	pick.tooltip_text = "Pick a declared event or an emitted relay"
	var options := _trigger_options()
	for o in options:
		pick.get_popup().add_item(o)
	pick.get_popup().index_pressed.connect(func(i: int) -> void:
		trig_edit.text = options[i]
		apply_trig.call())
	trig.add_child(pick)
	_box.add_child(trig)

	for g in ZoneSource.GUARDS:
		_box.add_child(_guard_menu(g))

	var once := CheckBox.new()
	once.text = "once (latched, persists)"
	once.button_pressed = r["once"]
	once.toggled.connect(func(on: bool) -> void:
		r["once"] = on
		changed.emit(r["id"]))
	_box.add_child(once)

	_line("emits relay", r["emit"], func(t: String) -> void:
		r["emit"] = t
		changed.emit(r["id"]))

	var grp := HBoxContainer.new()
	grp.add_child(_name_label("group"))
	var ob := OptionButton.new()
	ob.add_item("(none)")
	var sel := 0
	for i in _data["groups"].size():
		ob.add_item(_data["groups"][i]["name"])
		if _data["groups"][i]["name"] == r["group"]:
			sel = i + 1
	ob.select(sel)
	ob.item_selected.connect(func(i: int) -> void:
		r["group"] = "" if i == 0 else _data["groups"][i - 1]["name"]
		changed.emit(r["id"]))
	grp.add_child(ob)
	_box.add_child(grp)

	_title("Steps")
	for i in r["steps"].size():
		_box.add_child(_step_panel(i))
	var add := MenuButton.new()
	add.text = "+ Add step"
	var verbs: Array = _data["catalog"].map(func(v: Dictionary) -> String: return v["name"])
	for v in verbs:
		add.get_popup().add_item(v)
	add.get_popup().index_pressed.connect(func(i: int) -> void:
		r["steps"].append(VerbCatalog.new_step(_data, verbs[i]))
		changed.emit(r["id"])
		_rebuild_later())
	_box.add_child(add)

	var buttons := HBoxContainer.new()
	var dup := Button.new()
	dup.text = "Duplicate"
	dup.pressed.connect(func() -> void: duplicate_requested.emit(r["id"]))
	buttons.add_child(dup)
	var del := Button.new()
	del.text = "Delete rule"
	del.pressed.connect(func() -> void: delete_requested.emit(r["id"]))
	buttons.add_child(del)
	_box.add_child(buttons)

	var mine: Array = _data["problems"].filter(func(p: String) -> bool: return ("'%s'" % r["id"]) in p)
	if not mine.is_empty():
		_title("Problems")
		for p in mine:
			var l := Label.new()
			l.text = "⚠ " + p
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.add_theme_color_override("font_color", Color(1, 0.8, 0.4))
			_box.add_child(l)
	if _read_only:
		_lock(_box)

func _title(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	_box.add_child(l)

func _name_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(70, 0)
	return l

func _line(label: String, value: String, on_commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_child(_name_label(label))
	var e := LineEdit.new()
	e.text = value
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var apply := func(_t := "") -> void: on_commit.call(e.text.strip_edges())
	e.text_submitted.connect(apply)
	e.focus_exited.connect(apply)
	row.add_child(e)
	_box.add_child(row)

func _set_id(t: String) -> void:
	if t == _rule["id"]:
		return
	if t == "" or ZoneSource.rule_ids(_data).has(t) or not t.is_valid_identifier():
		_rebuild_later()   # reject: restore the old text
		return
	_rule["id"] = t
	changed.emit(t)

func _set_trigger(t: String) -> void:
	if t == _rule["trigger"]:
		return
	_rule["trigger"] = t
	changed.emit(_rule["id"])

## Declared external events plus every relay some rule emits.
func _trigger_options() -> Array:
	var out: Array = _data["external_events"].duplicate()
	for rd in _data["rules"]:
		for relay in RuleGraphView.output_relays(rd):
			if relay != "" and not out.has("relay:" + relay):
				out.append("relay:" + relay)
	return out

func _guard_menu(field: String) -> MenuButton:
	var mb := MenuButton.new()
	mb.flat = false
	mb.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var popup := mb.get_popup()
	popup.hide_on_checkable_item_selection = false
	var keys: Array = _data["vars"].map(func(v: Dictionary) -> String: return v["key"])
	for k in _rule[field]:   # keep dangling keys visible so they can be unchecked
		if not keys.has(k):
			keys.append(k)
	var refresh_text := func() -> void:
		mb.text = "%s: %s" % [field, ", ".join(_rule[field]) if not _rule[field].is_empty() else "-"]
	for i in keys.size():
		popup.add_check_item(keys[i])
		popup.set_item_checked(i, _rule[field].has(keys[i]))
	popup.index_pressed.connect(func(i: int) -> void:
		var on := not popup.is_item_checked(i)
		popup.set_item_checked(i, on)
		if on and not _rule[field].has(keys[i]):
			_rule[field].append(keys[i])
		elif not on:
			_rule[field].erase(keys[i])
		refresh_text.call()
		changed.emit(_rule["id"]))
	refresh_text.call()
	return mb

# --- Steps ------------------------------------------------------------------------

func _step_panel(idx: int) -> Control:
	var step: Dictionary = _rule["steps"][idx]
	var verb := VerbCatalog.find(_data["catalog"], step["verb"])
	var params: Array = verb.get("args", [])
	var panel := PanelContainer.new()
	var vb := VBoxContainer.new()
	panel.add_child(vb)

	var head := HBoxContainer.new()
	var num := Label.new()
	num.text = "%d." % (idx + 1)
	head.add_child(num)
	var ob := OptionButton.new()
	var names: Array = _data["catalog"].map(func(v: Dictionary) -> String: return v["name"])
	if not names.has(step["verb"]):
		names.append(step["verb"])
	for n in names:
		ob.add_item(n)
	ob.select(names.find(step["verb"]))
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.item_selected.connect(func(i: int) -> void:
		var fresh := VerbCatalog.new_step(_data, names[i])
		step["verb"] = fresh["verb"]
		step["args"] = fresh["args"]
		changed.emit(_rule["id"])
		_rebuild_later())
	head.add_child(ob)
	for spec in [["▲", -1], ["▼", 1]]:
		var b := Button.new()
		b.text = spec[0]
		b.disabled = (idx == 0 and spec[1] < 0) or (idx == _rule["steps"].size() - 1 and spec[1] > 0)
		b.pressed.connect(func() -> void:
			var steps: Array = _rule["steps"]
			steps.remove_at(idx)
			steps.insert(idx + spec[1], step)
			changed.emit(_rule["id"])
			_rebuild_later())
		head.add_child(b)
	var rm := Button.new()
	rm.text = "✕"
	rm.pressed.connect(func() -> void:
		_rule["steps"].remove_at(idx)
		changed.emit(_rule["id"])
		_rebuild_later())
	head.add_child(rm)
	vb.add_child(head)

	for j in params.size():
		var row := HBoxContainer.new()
		row.add_child(_name_label(params[j]["name"]))
		var w := _arg_widget(step, j, params[j])
		w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(w)
		vb.add_child(row)

	var delay_row := HBoxContainer.new()
	delay_row.add_child(_name_label("after (s)"))
	var sp := SpinBox.new()
	sp.min_value = 0.0
	sp.max_value = 60.0
	sp.step = 0.05
	sp.value = step["delay"].to_float()
	sp.value_changed.connect(func(v: float) -> void:
		step["delay"] = "" if v <= 0.0 else str(snappedf(v, 0.01))
		changed.emit(_rule["id"]))
	delay_row.add_child(sp)
	vb.add_child(delay_row)
	return panel

func _current(step: Dictionary, i: int, param: Dictionary) -> String:
	if i < step["args"].size():
		return step["args"][i]
	return param["default"] if param["default"] != "" else VerbCatalog.fallback(param, _data)

## Writes `expr` into argument i, filling any skipped earlier optional arguments with defaults.
func _set_arg(step: Dictionary, i: int, expr: String) -> void:
	var verb := VerbCatalog.find(_data["catalog"], step["verb"])
	while step["args"].size() <= i:
		var p: Dictionary = verb["args"][step["args"].size()]
		step["args"].append(p["default"] if p["default"] != "" else VerbCatalog.fallback(p, _data))
	step["args"][i] = expr
	changed.emit(_rule["id"])

func _arg_widget(step: Dictionary, i: int, param: Dictionary) -> Control:
	var cur := _current(step, i, param)
	var lit := ZoneSource.parse_literal(cur)
	match param["type"]:
		TYPE_OBJECT:
			var ob := OptionButton.new()
			var names: Array = []
			for p in _data["props"]:
				if VerbCatalog.prop_fits(p["class"], param["class"]):
					names.append(p["name"])
			if not names.has(cur):
				names.append(cur)   # unknown / unset: stays visible, and is flagged by the validator
			for n in names:
				ob.add_item(n)
			ob.select(names.find(cur))
			ob.item_selected.connect(func(k: int) -> void: _set_arg(step, i, names[k]))
			return ob
		TYPE_BOOL:
			if lit["ok"] and typeof(lit["value"]) == TYPE_BOOL:
				var c := CheckBox.new()
				c.button_pressed = lit["value"]
				c.toggled.connect(func(on: bool) -> void: _set_arg(step, i, "true" if on else "false"))
				return c
		TYPE_INT, TYPE_FLOAT:
			if lit["ok"] and typeof(lit["value"]) in [TYPE_INT, TYPE_FLOAT]:
				var s := SpinBox.new()
				s.allow_greater = true
				s.allow_lesser = true
				s.step = 1.0 if param["type"] == TYPE_INT else 0.05
				s.value = float(lit["value"])
				var is_int: bool = param["type"] == TYPE_INT
				s.value_changed.connect(func(v: float) -> void:
					_set_arg(step, i, str(int(v)) if is_int else ZoneSource.format_literal(snappedf(v, 0.001))))
				return s
		TYPE_STRING:
			if lit["ok"] and typeof(lit["value"]) == TYPE_STRING:
				return _text_arg(step, i, String(lit["value"]), func(t: String) -> String: return ZoneSource.format_literal(t))
		TYPE_STRING_NAME:
			if param["name"] == "key":
				var ob := OptionButton.new()
				var keys: Array = _data["vars"].map(func(v: Dictionary) -> String: return v["key"])
				var cur_key: String = String(lit["value"]) if lit["ok"] else ""
				if not keys.has(cur_key):
					keys.append(cur_key)
				for k in keys:
					ob.add_item(k)
				ob.select(keys.find(cur_key))
				ob.item_selected.connect(func(k: int) -> void: _set_arg(step, i, '&"%s"' % keys[k]))
				return ob
			if lit["ok"]:
				return _text_arg(step, i, String(lit["value"]), func(t: String) -> String: return '&"%s"' % t)
	# Anything else (Vector3, constants, expressions): edit the raw GDScript expression.
	var raw := LineEdit.new()
	raw.text = cur
	raw.tooltip_text = "GDScript expression, e.g. a constant or Vector3(0, 1, 0)"
	var shown := [cur]
	var apply := func(_t := "") -> void:
		var expr := raw.text.strip_edges()
		if expr != shown[0]:
			shown[0] = expr
			_set_arg(step, i, expr)
	raw.text_submitted.connect(apply)
	raw.focus_exited.connect(apply)
	return raw

func _text_arg(step: Dictionary, i: int, text: String, to_expr: Callable) -> Control:
	var e := LineEdit.new()
	e.text = text
	var shown := [to_expr.call(text)]
	var apply := func(_t := "") -> void:
		var expr: String = to_expr.call(e.text)
		if expr != shown[0]:
			shown[0] = expr
			_set_arg(step, i, expr)
	e.text_submitted.connect(apply)
	e.focus_exited.connect(apply)
	return e

func _rename_group(edit: LineEdit) -> void:
	var new_name := edit.text.strip_edges()
	if new_name == _group["name"]:
		return
	var taken: bool = _data["groups"].any(func(g: Dictionary) -> bool: return g["name"] == new_name)
	if new_name == "" or taken or '"' in new_name:
		edit.text = _group["name"]
		return
	for rd in _data["rules"]:
		if rd["group"] == _group["name"]:
			rd["group"] = new_name
	_group["name"] = new_name
	group_edited.emit()

func _lock(node: Node) -> void:
	for c in node.get_children():
		if c is BaseButton:
			(c as BaseButton).disabled = true
		elif c is LineEdit:
			(c as LineEdit).editable = false
		elif c is SpinBox:
			(c as SpinBox).editable = false
		elif c is MenuButton:
			(c as MenuButton).disabled = true
		_lock(c)
