@tool
class_name RuleInspector extends ScrollContainer
## Property editor for the selected rule (or group). Edits the model dictionaries in place and
## emits `changed`. Step argument widgets are generated from the verb's typed signature:
## props become dropdowns of compatible props, bools check boxes, numbers spin boxes,
## Blackboard `key` parameters a dropdown of declared keys, anything else a raw expression box.

signal changed(rule_id: String)
signal numeric_changed(rule_id: String, spin: SpinBox)
signal structure_changed(rule_id: String)   # inspector rebuilt itself; board should refresh the graph
signal delete_requested(rule_id: String)
signal duplicate_requested(rule_id: String)
signal group_edited(group_name: String)
signal group_delete_requested(group_name: String)
signal content_size_changed

const Style := preload("res://addons/callboard/editor/board_style.gd")

var _data: Dictionary
var _rule: Dictionary
var _group: Dictionary
var _read_only := false
var _box := VBoxContainer.new()

func _init() -> void:
	custom_minimum_size = Vector2(284, 0)
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 8)
	_box.minimum_size_changed.connect(func() -> void: content_size_changed.emit())
	add_child(_box)

func _ready() -> void:
	if Engine.is_editor_hint():
		custom_minimum_size.x = 284 * get_theme_default_base_scale()

func content_height() -> float:
	return _box.get_combined_minimum_size().y

func clear() -> void:
	_clear()
	_rule = {}
	_group = {}

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
	if _rule.is_empty():
		return
	_clear()
	var r := _rule
	var rule_notes: Array = _data.get("notes", []).filter(func(note: String) -> bool:
		return ("'%s'" % r["id"]) in note)
	if not rule_notes.is_empty():
		_box.add_child(Style.label("Notes", Style.WARNING, 13))
		for note in rule_notes:
			var note_label := Style.label(note, Style.WARNING, 13)
			note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_box.add_child(note_label)
	_line("ID", r["id"], func(t: String) -> void: _set_id(t))

	var trig := HBoxContainer.new()
	var trig_edit := LineEdit.new()
	trig_edit.text = r["trigger"]
	trig_edit.tooltip_text = trig_edit.text
	trig_edit.placeholder_text = "trigger"
	trig_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var apply_trig := func(_t := "") -> void:
		trig_edit.tooltip_text = trig_edit.text.strip_edges()
		_set_trigger(trig_edit.tooltip_text)
	trig_edit.text_submitted.connect(apply_trig)
	trig_edit.focus_exited.connect(apply_trig)
	trig.add_child(_name_label("Trigger"))
	trig.add_child(trig_edit)
	var pick := MenuButton.new()
	pick.text = "▾"
	pick.flat = false
	pick.tooltip_text = "Pick a declared Call or an emitted relay"
	var options := _trigger_options()
	for o in options:
		pick.get_popup().add_item(o)
	pick.get_popup().index_pressed.connect(func(i: int) -> void:
		trig_edit.text = options[i]
		apply_trig.call())
	trig.add_child(pick)
	_box.add_child(trig)

	for g in AuthoredData.GUARDS:
		_box.add_child(_guard_menu(g))

	var policy := OptionButton.new()
	var one_shot := CheckBox.new()
	one_shot.text = "One-shot"
	one_shot.tooltip_text = "The rule's latch persists in saved state"
	one_shot.button_pressed = r[AuthoredData.FIELD_ONE_SHOT]
	one_shot.toggled.connect(func(on: bool) -> void:
		r[AuthoredData.FIELD_ONE_SHOT] = on
		if on and r.get(AuthoredData.FIELD_REENTRY, Rule.ReentryPolicy.IGNORE) != Rule.ReentryPolicy.IGNORE:
			r[AuthoredData.FIELD_REENTRY] = Rule.ReentryPolicy.IGNORE
			policy.select(policy.get_item_index(Rule.ReentryPolicy.IGNORE))
		for incompatible_policy in [Rule.ReentryPolicy.RESTART, Rule.ReentryPolicy.QUEUE]:
			policy.get_popup().set_item_disabled(
				policy.get_item_index(incompatible_policy), on)
		changed.emit(r["id"]))
	_box.add_child(one_shot)

	var reentry := HBoxContainer.new()
	reentry.add_child(_name_label("While running"))
	policy.name = "ReentryPolicy"
	policy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	policy.add_item("Ignore", Rule.ReentryPolicy.IGNORE)
	policy.add_item("Restart", Rule.ReentryPolicy.RESTART)
	policy.add_item("Queue", Rule.ReentryPolicy.QUEUE)
	var menu := policy.get_popup()
	menu.set_item_tooltip(0, "Drop triggers received while this rule is running.")
	menu.set_item_tooltip(1, "Stop at the next cancellation check and use the latest trigger. Unavailable for one-shot rules.")
	menu.set_item_tooltip(2, "Run pending triggers in order once the active run ends. Unavailable for one-shot rules.")
	for incompatible_policy in [Rule.ReentryPolicy.RESTART, Rule.ReentryPolicy.QUEUE]:
		menu.set_item_disabled(policy.get_item_index(incompatible_policy), bool(r.get(AuthoredData.FIELD_ONE_SHOT, false)))
	if bool(r.get(AuthoredData.FIELD_ONE_SHOT, false)) and r.get(AuthoredData.FIELD_REENTRY, Rule.ReentryPolicy.IGNORE) != Rule.ReentryPolicy.IGNORE:
		r[AuthoredData.FIELD_REENTRY] = Rule.ReentryPolicy.IGNORE
	policy.select(policy.get_item_index(r.get(AuthoredData.FIELD_REENTRY, Rule.ReentryPolicy.IGNORE)))
	policy.item_selected.connect(func(i: int) -> void:
		if bool(r.get(AuthoredData.FIELD_ONE_SHOT, false)) and policy.get_item_id(i) != Rule.ReentryPolicy.IGNORE:
			policy.select(policy.get_item_index(Rule.ReentryPolicy.IGNORE))
			return
		r[AuthoredData.FIELD_REENTRY] = policy.get_item_id(i)
		changed.emit(r["id"]))
	reentry.add_child(policy)
	_box.add_child(reentry)
	var overlap := CheckBox.new()
	overlap.text = "Allow simultaneous rules"
	overlap.tooltip_text = "Suppress shared-trigger overlap warnings for this rule. Use when concurrent runs are intentional."
	overlap.button_pressed = bool(r.get(AuthoredData.FIELD_ALLOW_OVERLAP, false))
	overlap.toggled.connect(func(on: bool) -> void:
		r[AuthoredData.FIELD_ALLOW_OVERLAP] = on
		changed.emit(r["id"]))
	_box.add_child(overlap)

	_line("Emits relay", r["emit"], func(t: String) -> void:
		r["emit"] = t
		changed.emit(r["id"]))

	var grp := HBoxContainer.new()
	grp.add_child(_name_label("Group"))
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.fit_to_longest_item = false
	ob.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	add.flat = false
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

	var mine: Array = _data["notes"].filter(func(p: String) -> bool: return ("'%s'" % r["id"]) in p)
	if not mine.is_empty():
		_title("Problems")
		for p in mine:
			var l := Label.new()
			l.text = "⚠ " + p
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			Style.tint(l, Style.WARNING)
			_box.add_child(l)
	if _read_only:
		_lock(_box)

func _title(text: String) -> void:
	_box.add_child(Style.label(text, Style.EVENT, 13))

func _name_label(text: String) -> Label:
	var l := Style.label(text, Style.MUTED, 13)
	l.custom_minimum_size.x = 92 * get_theme_default_base_scale()
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.tooltip_text = text
	return l

func _line(label: String, value: String, on_commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_child(_name_label(label))
	var e := LineEdit.new()
	e.text = value
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var apply := func(_t := "") -> void:
		var text := e.text.strip_edges()
		if text != e.get_meta("committed", value):
			e.set_meta("committed", text)
			on_commit.call(text)
	e.text_submitted.connect(apply)
	e.focus_exited.connect(apply)
	row.add_child(e)
	_box.add_child(row)

func _set_id(t: String) -> void:
	if t == _rule["id"]:
		return
	if t == "" or AuthoredData.rule_ids(_data).has(t) or not t.is_valid_identifier():
		_rebuild_later()   # reject: restore the old text
		return
	_rule[AuthoredData.FIELD_STATE_KEY] = _rule.get(AuthoredData.FIELD_STATE_KEY, _rule["id"])
	_rule["id"] = t
	changed.emit(t)

func _set_trigger(t: String) -> void:
	if t == _rule["trigger"]:
		return
	_rule["trigger"] = t
	changed.emit(_rule["id"])

## Declared external events plus every relay some rule emits.
func _trigger_options() -> Array:
	var out: Array = _data["external_calls"].duplicate()
	for rd in _data["rules"]:
		for relay in RuleGraphView.output_relays(rd):
			if relay != "" and not out.has("relay:" + relay):
				out.append("relay:" + relay)
	return out

func _guard_menu(field: String) -> MenuButton:
	var mb := MenuButton.new()
	mb.flat = false
	mb.alignment = HORIZONTAL_ALIGNMENT_LEFT
	mb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var popup := mb.get_popup()
	popup.hide_on_checkable_item_selection = false
	var keys: Array = _data["vars"].map(func(v: Dictionary) -> String: return v["key"])
	for k in _rule[field]:   # keep dangling keys visible so they can be unchecked
		if not keys.has(k):
			keys.append(k)
	var refresh_text := func() -> void:
		mb.text = "%s: %s" % [field.capitalize(), ", ".join(_rule[field]) if not _rule[field].is_empty() else "None"]
		mb.tooltip_text = mb.text
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
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var panel := Style.panel(vb, Color("#1b2635"), Vector2(8, 8))

	var head := HBoxContainer.new()
	var num := Style.label("%02d" % (idx + 1), Style.EVENT, 12)
	head.add_child(num)
	var ob := OptionButton.new()
	var names: Array = _data["catalog"].map(func(v: Dictionary) -> String: return v["name"])
	if not names.has(step["verb"]):
		names.append(step["verb"])
	for n in names:
		ob.add_item(n)
	ob.select(names.find(step["verb"]))
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.fit_to_longest_item = false
	ob.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	delay_row.add_child(_name_label("Delay (s)"))
	var sp := SpinBox.new()
	sp.min_value = 0.0
	sp.max_value = 60.0
	sp.step = 0.05
	sp.value = step["delay"].to_float()
	sp.value_changed.connect(func(v: float) -> void:
		step["delay"] = "" if v <= 0.0 else str(snappedf(v, 0.01))
		numeric_changed.emit(_rule["id"], sp))
	delay_row.add_child(sp)
	vb.add_child(delay_row)
	return panel

func _current(step: Dictionary, i: int, param: Dictionary) -> String:
	if i < step["args"].size():
		return step["args"][i]
	return param["default"] if param["default"] != "" else VerbCatalog.fallback(param, _data)

## Writes `expr` into argument i, filling any skipped earlier optional arguments with defaults.
func _set_arg(step: Dictionary, i: int, expr: String, spin: SpinBox = null) -> void:
	VerbCatalog.set_arg(_data, step, i, expr)
	if spin:
		numeric_changed.emit(_rule["id"], spin)
	else:
		changed.emit(_rule["id"])

func _arg_widget(step: Dictionary, i: int, param: Dictionary) -> Control:
	var cur := _current(step, i, param)
	var lit := ExprText.parse_literal(cur)
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
					_set_arg(step, i, str(int(v)) if is_int else ExprText.format_literal(snappedf(v, 0.001)), s))
				return s
		TYPE_STRING:
			if lit["ok"] and typeof(lit["value"]) == TYPE_STRING:
				return _text_arg(step, i, String(lit["value"]), func(t: String) -> String: return ExprText.format_literal(t))
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
	group_edited.emit(new_name)

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
