@tool
class_name BlackboardPanel extends VBoxContainer
## Blackboard inspector. Editable in the editor: add, rename (rules and step arguments that
## reference the key are updated), delete, change scope, and edit defaults with a control
## matching the value's type. In live mode it is read-only and shows current values.

signal changed
signal numeric_changed(spin: SpinBox)
signal content_size_changed

const Style := preload("res://addons/callboard/editor/board_style.gd")
const COL_SAVED := Style.RELAY
const COL_LOCAL := Style.EVENT
const TYPES := {"bool": false, "int": 0, "float": 0.0, "String": ""}

var _data: Dictionary
var _editable := true
var _live_mode := false
var _rows := VBoxContainer.new()
var _add := MenuButton.new()
var _latched := Label.new()
var _live_labels := {}   # key -> Label

func _init() -> void:
	custom_minimum_size.x = Style.LIST_WIDTH
	add_theme_constant_override("separation", 10)
	var head := HBoxContainer.new()
	var title := Style.label("Blackboard", Style.TEXT, 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_add.text = "+ Variable"
	_add.flat = false
	for t in TYPES:
		_add.get_popup().add_item(t)
	_add.get_popup().index_pressed.connect(_on_add)
	head.add_child(_add)
	add_child(head)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", Style.ENTRY_GAP)
	_rows.minimum_size_changed.connect(func() -> void: content_size_changed.emit())
	scroll.add_child(_rows)
	add_child(scroll)
	_latched.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Style.fallback_font_size(_latched, 12)
	Style.tint(_latched, Style.MUTED)
	add_child(_latched)

func rows_height() -> float:
	return _rows.get_combined_minimum_size().y

func show_data(data: Dictionary, editable := true, live := false) -> void:
	_data = data
	_editable = editable
	_live_mode = live
	_add.visible = editable
	_latched.visible = live
	_rebuild()

func _rebuild() -> void:
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	_live_labels.clear()
	_latched.text = ""
	if _data["vars"].is_empty():
		_rows.add_child(Style.label("No variables declared.", Style.MUTED, 13))
	for v in _data["vars"]:
		_rows.add_child(_make_row(v))

func _make_row(v: Dictionary) -> Control:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 6)
	var head := HBoxContainer.new()
	card.add_child(head)
	var key := LineEdit.new()
	key.text = v["key"]
	key.accessibility_name = "Variable name"
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key.editable = _editable
	key.tooltip_text = v["key"]
	var commit_key := func(_t := "") -> void: _rename(v, key)
	key.text_submitted.connect(commit_key)
	key.focus_exited.connect(commit_key)
	head.add_child(key)
	if _editable:
		var del := Button.new()
		Style.button_icon(del, &"Remove", "✕")
		del.accessibility_name = "Delete variable"
		del.tooltip_text = "Delete variable (rules that use it will show a warning)"
		del.pressed.connect(func() -> void:
			_data["vars"].erase(v)
			_rebuild()
			changed.emit())
		head.add_child(del)

	var row := HBoxContainer.new()
	card.add_child(row)
	var scope := OptionButton.new()
	scope.accessibility_name = "Variable scope"
	scope.add_item("Saved")
	scope.add_item("Local")
	scope.get_popup().set_item_tooltip(0, "Keep this variable in saved Stage state.")
	scope.get_popup().set_item_tooltip(1, "Reset this variable when the Stage is restored.")
	scope.select(0 if v["scope"] == "saved" else 1)
	scope.disabled = not _editable
	Style.tint(scope, COL_SAVED if v["scope"] == "saved" else COL_LOCAL)
	scope.item_selected.connect(func(i: int) -> void:
		v["scope"] = "saved" if i == 0 else "local"
		Style.tint(scope, COL_SAVED if i == 0 else COL_LOCAL)
		changed.emit())
	row.add_child(scope)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(Style.label("Default", Style.MUTED, 12))
	row.add_child(_default_editor(v))

	if _live_mode:
		var live := Label.new()
		live.text = "-"
		live.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_live_labels[v["key"]] = live
		card.add_child(live)
	return Style.entry(card)

## The control matches the value's type: CheckBox, SpinBox (int / float), or LineEdit.
func _default_editor(v: Dictionary) -> Control:
	var set_default := func(value: Variant, spin: SpinBox = null) -> void:
		v["default"] = value
		if spin:
			numeric_changed.emit(spin)
		else:
			changed.emit()
	match typeof(v["default"]):
		TYPE_BOOL:
			var c := CheckBox.new()
			c.button_pressed = v["default"]
			c.disabled = not _editable
			c.tooltip_text = "default"
			c.toggled.connect(func(on: bool) -> void: set_default.call(on))
			return c
		TYPE_INT, TYPE_FLOAT:
			var s := SpinBox.new()
			s.allow_greater = true
			s.allow_lesser = true
			s.step = 1.0 if typeof(v["default"]) == TYPE_INT else 0.01
			s.value = v["default"]
			s.editable = _editable
			s.custom_minimum_size = Vector2(80, 0)
			var is_int := typeof(v["default"]) == TYPE_INT
			s.value_changed.connect(func(x: float) -> void: set_default.call(int(x) if is_int else x, s))
			return s
	var l := LineEdit.new()
	l.text = str(v["default"])
	l.editable = _editable
	l.custom_minimum_size = Vector2(80, 0)
	var is_name := typeof(v["default"]) == TYPE_STRING_NAME
	l.text_submitted.connect(func(t: String) -> void: set_default.call(StringName(t) if is_name else t))
	l.focus_exited.connect(func() -> void: set_default.call(StringName(l.text) if is_name else l.text))
	return l

func _rename(v: Dictionary, edit: LineEdit) -> void:
	var new_key := edit.text.strip_edges()
	if new_key == v["key"]:
		return
	var taken: bool = _data["vars"].any(func(o: Dictionary) -> bool: return o != v and o["key"] == new_key)
	if not new_key.is_valid_identifier() or taken:
		edit.text = v["key"]
		return
	AuthoredData.rename_key(_data, v["key"], new_key)
	edit.tooltip_text = new_key
	changed.emit()

func _on_add(index: int) -> void:
	var type_name: String = _add.get_popup().get_item_text(index)
	var keys: Array = _data["vars"].map(func(x: Dictionary) -> String: return x["key"])
	var value: Variant = TYPES[type_name]
	var variable := AuthoredData.new_variable(AuthoredData.unique_name(keys, "new_var"), "local", value)
	variable[AuthoredData.FIELD_STATE_KEY] = AuthoredData.new_state_key()
	_data["vars"].append(variable)
	_rebuild()
	changed.emit()

func refresh_live(stage: Stage) -> void:
	for key in _live_labels:
		var value: Variant = stage.get_var(StringName(key))
		var l: Label = _live_labels[key]
		l.text = "Live: " + str(value)
		l.tooltip_text = l.text
		Style.tint(l, Style.SUCCESS if value is bool and value else Style.TEXT)
	var latched: PackedStringArray = []
	for rule in stage.engine.rules:
		if rule.one_shot and stage.fired.has(rule.latch_key()):
			latched.append(String(rule.id))
	_latched.text = "Latched one-shot rules: " + (", ".join(latched) if not latched.is_empty() else "none")
