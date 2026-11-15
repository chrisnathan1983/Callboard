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
const COL_SHARED := Style.SUCCESS
const TYPES := {"bool": false, "int": 0, "float": 0.0, "String": ""}

var _data: GraphDraft
var _editable := true
var _live_mode := false
var _rows := VBoxContainer.new()
var _add := MenuButton.new()
var _latched := Label.new()
var _live_labels := {}   # key -> Label
var _objective_editors: Dictionary[ObjectiveData, LineEdit] = {}

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

func show_data(data: GraphDraft, editable := true, live := false) -> void:
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
	_objective_editors.clear()
	_latched.text = ""
	if _data.variables.is_empty():
		_rows.add_child(Style.label("No variables declared.", Style.MUTED, 13))
	for v in _data.variables:
		_rows.add_child(_make_row(v))
	_rows.add_child(HSeparator.new())
	_rows.add_child(_make_stage_settings())

func _make_row(v: VariableData) -> Control:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 6)
	var head := HBoxContainer.new()
	card.add_child(head)
	var key := LineEdit.new()
	key.text = v.key
	key.accessibility_name = "Variable name"
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key.editable = _editable
	key.tooltip_text = v.key
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
			_data.variables.erase(v)
			_rebuild()
			changed.emit())
		head.add_child(del)

	var row := HBoxContainer.new()
	card.add_child(row)
	var scope := OptionButton.new()
	scope.accessibility_name = "Variable scope"
	scope.add_item("Local")
	scope.add_item("Saved")
	scope.add_item("Shared")
	scope.add_item("Session")
	scope.get_popup().set_item_tooltip(0, "Reset this variable when the Stage is restored.")
	scope.get_popup().set_item_tooltip(1, "Keep this variable in saved Stage state.")
	scope.get_popup().set_item_tooltip(2, "Share this value across loaded Stage instances using the state store.")
	scope.get_popup().set_item_tooltip(3, "Keep this value across Stage reloads until the host calls reset_session().")
	var scope_index := ["local", "saved", "shared", "session"].find(v.scope)
	scope.select(scope_index if scope_index >= 0 else 0)
	scope.disabled = not _editable
	Style.tint(scope, _scope_color(v.scope))
	scope.item_selected.connect(func(i: int) -> void:
		v.scope = ["local", "saved", "shared", "session"][i]
		_rebuild()
		changed.emit())
	row.add_child(scope)
	if v.scope == "shared":
		var current_shared_key := v.state_key if not v.state_key.is_empty() else v.key
		var shared_key_row := HBoxContainer.new()
		card.add_child(shared_key_row)
		shared_key_row.add_child(Style.label("Shared key", Style.MUTED, 12))
		var shared_key_picker := OptionButton.new()
		shared_key_picker.accessibility_name = "Existing shared storage keys"
		shared_key_picker.tooltip_text = "Select an existing Shared storage key to intentionally link this variable."
		var shared_keys: Array[StringName] = []
		for other: VariableData in _data.variables:
			if other.scope == "shared" and not other.state_key.is_empty() and not shared_keys.has(other.state_key):
				shared_keys.append(other.state_key)
		if not current_shared_key.is_empty() and not shared_keys.has(current_shared_key):
			shared_keys.append(current_shared_key)
		shared_keys.sort()
		for storage_key: StringName in shared_keys:
			shared_key_picker.add_item(String(storage_key))
			shared_key_picker.set_item_tooltip(shared_key_picker.item_count - 1,
				"Use this exact shared storage identity.")
		var selected_key_index := shared_keys.find(current_shared_key)
		if selected_key_index >= 0:
			shared_key_picker.select(selected_key_index)
		shared_key_picker.disabled = not _editable
		shared_key_row.add_child(shared_key_picker)
		var shared_key_edit := LineEdit.new()
		shared_key_edit.text = String(current_shared_key)
		shared_key_edit.accessibility_name = "Shared storage key"
		shared_key_edit.placeholder_text = "Storage identity"
		shared_key_edit.tooltip_text = "Persisted Shared values use this identity. Matching identities link across variables and Stage definitions."
		shared_key_edit.editable = _editable
		shared_key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var commit_shared_key := func(_text := "") -> void:
			var new_storage_key := StringName(shared_key_edit.text.strip_edges())
			if new_storage_key.is_empty():
				shared_key_edit.text = String(current_shared_key)
				return
			if new_storage_key == current_shared_key:
				return
			v.state_key = new_storage_key
			_rebuild()
			changed.emit()
		shared_key_edit.text_submitted.connect(commit_shared_key)
		shared_key_edit.focus_exited.connect(commit_shared_key)
		shared_key_picker.item_selected.connect(func(i: int) -> void:
			if i < 0 or i >= shared_keys.size():
				return
			shared_key_edit.text = String(shared_keys[i])
			commit_shared_key.call())
		shared_key_row.add_child(shared_key_edit)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(Style.label("Default", Style.MUTED, 12))
	row.add_child(_default_editor(v))

	if _live_mode:
		var live := Label.new()
		live.text = "-"
		live.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_live_labels[v.key] = live
		card.add_child(live)
	return Style.entry(card)

func _scope_color(scope: String) -> Color:
	match scope:
		"saved": return COL_SAVED
		"shared": return COL_SHARED
		_: return COL_LOCAL

## The control matches the value's type: CheckBox, SpinBox (int / float), or LineEdit.
func _default_editor(v: VariableData) -> Control:
	var set_default := func(value: Variant, spin: SpinBox = null) -> void:
		v.default_value = value
		if spin:
			numeric_changed.emit(spin)
		else:
			changed.emit()
	match typeof(v.default_value):
		TYPE_BOOL:
			var c := CheckBox.new()
			c.button_pressed = v.default_value
			c.disabled = not _editable
			c.tooltip_text = "default"
			c.toggled.connect(func(on: bool) -> void: set_default.call(on))
			return c
		TYPE_INT, TYPE_FLOAT:
			var s := SpinBox.new()
			s.allow_greater = true
			s.allow_lesser = true
			s.step = 1.0 if typeof(v.default_value) == TYPE_INT else 0.01
			s.value = v.default_value
			s.editable = _editable
			s.custom_minimum_size = Vector2(80, 0)
			var is_int := typeof(v.default_value) == TYPE_INT
			s.value_changed.connect(func(x: float) -> void: set_default.call(int(x) if is_int else x, s))
			return s
	var l := LineEdit.new()
	var original_type := typeof(v.default_value)
	var is_complex := original_type not in [TYPE_STRING, TYPE_STRING_NAME]
	l.text = var_to_str(v.default_value) if is_complex else str(v.default_value)
	l.editable = _editable
	l.custom_minimum_size = Vector2(150 if is_complex else 80, 0)
	if is_complex:
		l.tooltip_text = "Edit the serialized Variant value. The value is changed only when it parses to the same Variant type."
	var commit := func(_text := "") -> void:
		if is_complex:
			var parsed: Variant = str_to_var(l.text)
			if typeof(parsed) == original_type:
				set_default.call(parsed)
			else:
				l.text = var_to_str(v.default_value)
		else:
			set_default.call(StringName(l.text) if original_type == TYPE_STRING_NAME else l.text)
	l.text_submitted.connect(commit)
	l.focus_exited.connect(commit)
	return l

func _make_stage_settings() -> Control:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", Style.ENTRY_GAP)
	section.add_child(Style.label("Stage state", Style.TEXT, 15))
	var managed := CheckButton.new()
	managed.text = "Managed lifecycle"
	managed.tooltip_text = "The Stage ignores Calls until activate(), then activates once per entry."
	managed.button_pressed = _data.managed_lifecycle
	managed.disabled = not _editable
	managed.toggled.connect(func(enabled: bool) -> void:
		_data.managed_lifecycle = enabled
		changed.emit())
	section.add_child(managed)
	section.add_child(_make_writer_section())
	section.add_child(_make_restoration_section())
	section.add_child(_make_objective_section())
	return section

func _make_objective_section() -> Control:
	var section := VBoxContainer.new()
	var header := HBoxContainer.new()
	var title := Style.label("Objectives", Style.TEXT, 13)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)
	if _editable:
		var add := Button.new()
		add.text = "+ Objective"
		add.pressed.connect(func() -> void:
			var names: Array = []
			for objective: ObjectiveData in _data.objectives:
				if objective != null:
					names.append(String(objective.id))
			var objective := ObjectiveData.new()
			objective.id = AuthoredData.unique_name(names, "objective")
			_data.objectives.append(objective)
			_rebuild()
			changed.emit())
		header.add_child(add)
	section.add_child(header)
	for index in _data.objectives.size():
		var objective := _data.objectives[index]
		var row := HBoxContainer.new()
		if objective != null:
			var id := LineEdit.new()
			id.text = objective.id
			id.accessibility_name = "Objective ID"
			id.placeholder_text = "Objective ID"
			id.editable = _editable
			var commit_id := func(_text := "") -> void:
				var name := StringName(id.text.strip_edges())
				if objective.id != name:
					objective.id = name
					changed.emit()
			id.text_submitted.connect(commit_id)
			id.focus_exited.connect(commit_id)
			row.add_child(id)
			var condition := LineEdit.new()
			condition.text = objective.condition
			condition.accessibility_name = "Completion condition"
			condition.placeholder_text = "Completion condition"
			condition.size_flags_horizontal = SIZE_EXPAND_FILL
			condition.editable = _editable
			var commit_condition := func(_text := "") -> void:
				var expression := condition.text.strip_edges()
				if objective.condition != expression:
					objective.condition = expression
					changed.emit()
			condition.text_submitted.connect(commit_condition)
			condition.focus_exited.connect(commit_condition)
			row.add_child(condition)
			_objective_editors[objective] = condition
		else:
			row.add_child(Style.label("Empty objective", Style.WARNING, 12))
		if _editable:
			var remove := Button.new()
			Style.button_icon(remove, &"Remove", "×")
			remove.accessibility_name = "Remove objective"
			remove.pressed.connect(func() -> void:
				_data.objectives.remove_at(index)
				_rebuild()
				changed.emit())
			row.add_child(remove)
		section.add_child(row)
	return section

func _make_writer_section() -> Control:
	var section := VBoxContainer.new()
	var header := HBoxContainer.new()
	var title := Style.label("External writers", Style.TEXT, 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var add := Button.new()
	add.text = "+ Writer"
	add.disabled = not _editable
	add.pressed.connect(func() -> void:
		var writer := BlackboardWriterData.new()
		writer.source = &"gameplay"
		_data.external_writers.append(writer)
		_rebuild()
		changed.emit())
	header.add_child(add)
	section.add_child(header)
	if _data.external_writers.is_empty():
		section.add_child(Style.label("No typed external writers declared.", Style.MUTED, 12))
	for writer: BlackboardWriterData in _data.external_writers:
		var row := HBoxContainer.new()
		var key := _key_picker(writer.key, func(value: StringName) -> void: writer.key = value)
		key.tooltip_text = "Blackboard key written by host code"
		row.add_child(key)
		var source := LineEdit.new()
		source.text = String(writer.source)
		source.placeholder_text = "writer ID"
		source.accessibility_name = "External writer ID"
		source.editable = _editable
		source.custom_minimum_size.x = 90
		var commit_source := func(_text := "") -> void:
			writer.source = StringName(source.text.strip_edges())
			changed.emit()
		source.text_submitted.connect(commit_source)
		source.focus_exited.connect(commit_source)
		row.add_child(source)
		var type := OptionButton.new()
		for option in ["Variant", "bool", "int", "float", "String", "StringName"]:
			type.add_item(option)
		type.select(maxi(0, ["Variant", "bool", "int", "float", "String", "StringName"].find(writer.value_type)))
		type.disabled = not _editable
		type.item_selected.connect(func(index: int) -> void:
			writer.value_type = type.get_item_text(index)
			changed.emit())
		row.add_child(type)
		var remove := Button.new()
		Style.button_icon(remove, &"Remove", "?")
		remove.tooltip_text = "Remove writer declaration"
		remove.disabled = not _editable
		remove.pressed.connect(func() -> void:
			_data.external_writers.erase(writer)
			_rebuild()
			changed.emit())
		row.add_child(remove)
		section.add_child(Style.entry(row))
	return section

func _make_restoration_section() -> Control:
	var section := VBoxContainer.new()
	var header := HBoxContainer.new()
	var title := Style.label("Restoration bindings", Style.TEXT, 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var add := Button.new()
	add.text = "+ Binding"
	add.disabled = not _editable
	add.pressed.connect(func() -> void:
		var binding := StageRestorationBinding.new()
		if not _data.variables.is_empty():
			binding.key = _data.variables[0].key
		_data.restoration_bindings.append(binding)
		_rebuild()
		changed.emit())
	header.add_child(add)
	section.add_child(header)
	if _data.restoration_bindings.is_empty():
		section.add_child(Style.label("No resolved state is bound to scene nodes.", Style.MUTED, 12))
	for binding: StageRestorationBinding in _data.restoration_bindings:
		section.add_child(_make_binding_card(binding))
	return section

func _make_binding_card(binding: StageRestorationBinding) -> Control:
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 5)
	var top := HBoxContainer.new()
	top.add_child(_key_picker(binding.key, func(value: StringName) -> void: binding.key = value))
	var kind := OptionButton.new()
	var kind_names := ["Visibility", "Transform", "Snap to Marker", "Animation Pose", "Child Index", "Property", "Light Energy", "Light Color", "Audio Playback", "Particle Emitting"]
	for label in kind_names:
		kind.add_item(label)
	kind.select(clampi(binding.kind, 0, kind_names.size() - 1))
	kind.disabled = not _editable
	kind.item_selected.connect(func(index: int) -> void:
		binding.kind = index
		_rebuild()
		changed.emit())
	top.add_child(kind)
	var remove := Button.new()
	Style.button_icon(remove, &"Remove", "?")
	remove.tooltip_text = "Remove restoration binding"
	remove.disabled = not _editable
	remove.pressed.connect(func() -> void:
		_data.restoration_bindings.erase(binding)
		_rebuild()
		changed.emit())
	top.add_child(remove)
	body.add_child(top)
	_add_path_field(body, "Target", binding, "target_path", _target_classes(binding.kind))
	match binding.kind:
		StageRestorationBinding.Kind.SNAP_TO_MARKER:
			_add_path_field(body, "Marker3D", binding, "marker_path", ["Marker3D"])
			_add_path_field(body, "AnimationPlayer (optional)", binding, "animation_player_path", ["AnimationPlayer"])
			_add_name_field(body, "Animation (optional)", binding, "animation_name",
				_scene_animations(binding.animation_player_path))
			_add_float_field(body, "Resolved time", binding, "animation_time")
		StageRestorationBinding.Kind.POSE_ANIMATION:
			_add_name_field(body, "Animation", binding, "animation_name",
				_scene_animations(binding.target_path))
			_add_float_field(body, "Resolved time", binding, "animation_time")
		StageRestorationBinding.Kind.CHILD_INDEX:
			_add_paths_field(body, "Child choices (one path per line)", binding)
		StageRestorationBinding.Kind.PROPERTY:
			_add_name_field(body, "Property", binding, "property_name",
				_scene_property_names(binding.target_path))
		StageRestorationBinding.Kind.AUDIO_PLAYBACK:
			var replay := CheckButton.new()
			replay.text = "Replay stateful audio on restore"
			replay.button_pressed = binding.replay_audio_on_restore
			replay.disabled = not _editable
			replay.toggled.connect(func(enabled: bool) -> void:
				binding.replay_audio_on_restore = enabled
				changed.emit())
			body.add_child(replay)
	return Style.entry(body)

func _key_picker(selected: StringName, assign: Callable) -> OptionButton:
	var picker := OptionButton.new()
	picker.accessibility_name = "Restoration Blackboard key"
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var selected_index := -1
	var missing_selection := not selected.is_empty() and not _data.variables.any(
		func(variable: VariableData) -> bool: return variable.key == selected)
	if missing_selection:
		picker.add_item("(missing: %s)" % selected)
	for variable: VariableData in _data.variables:
		picker.add_item(String(variable.key))
		if variable.key == selected:
			selected_index = picker.item_count - 1
	if picker.item_count == 0:
		picker.add_item("(no keys)")
	picker.select(maxi(0, selected_index if selected_index >= 0 else 0))
	picker.disabled = not _editable or _data.variables.is_empty()
	picker.item_selected.connect(func(index: int) -> void:
		var variable_index := index - (1 if missing_selection else 0)
		if variable_index >= 0 and variable_index < _data.variables.size():
			assign.call(_data.variables[variable_index].key)
			changed.emit())
	return picker

func _add_path_field(parent: VBoxContainer, label_text: String, binding: StageRestorationBinding,
		property: String, expected_classes: Array[String] = []) -> void:
	var row := HBoxContainer.new()
	row.add_child(Style.label(label_text, Style.MUTED, 12))
	var edit := LineEdit.new()
	var paths := _scene_node_paths(expected_classes)
	if not paths.is_empty():
		var picker := OptionButton.new()
		picker.accessibility_name = "%s node picker" % label_text
		picker.tooltip_text = "Choose a node path from the Stage preview scene. You can also enter a path directly."
		picker.add_item("Pick…")
		for path: String in paths:
			picker.add_item(path)
		picker.disabled = not _editable
		picker.item_selected.connect(func(index: int) -> void:
			if index > 0 and index <= paths.size():
				binding.set(property, NodePath(paths[index - 1]))
				edit.text = paths[index - 1]
				changed.emit())
		row.add_child(picker)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text = String(binding.get(property))
	edit.placeholder_text = "Scene node path"
	edit.editable = _editable
	edit.text_submitted.connect(func(text: String) -> void: binding.set(property, NodePath(text.strip_edges())); changed.emit())
	edit.focus_exited.connect(func() -> void: binding.set(property, NodePath(edit.text.strip_edges())); changed.emit())
	row.add_child(edit)
	parent.add_child(row)

func _target_classes(kind: int) -> Array[String]:
	match kind:
		StageRestorationBinding.Kind.TRANSFORM, StageRestorationBinding.Kind.SNAP_TO_MARKER:
			return ["Node3D"]
		StageRestorationBinding.Kind.POSE_ANIMATION:
			return ["AnimationPlayer"]
		StageRestorationBinding.Kind.LIGHT_ENERGY, StageRestorationBinding.Kind.LIGHT_COLOR:
			return ["Light3D"]
		StageRestorationBinding.Kind.AUDIO_PLAYBACK:
			return ["AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]
		StageRestorationBinding.Kind.PARTICLE_EMITTING:
			return ["GPUParticles3D", "CPUParticles3D"]
		_:
			return []

func _scene_node_paths(expected_classes: Array[String]) -> Array[String]:
	if _data == null or _data.definition == null:
		return []
	var scene_path := _data.definition.analysis_scene_path()
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return []
	var packed := ResourceLoader.load(scene_path) as PackedScene
	if packed == null:
		return []
	var state := packed.get_state()
	var result: Array[String] = []
	for index in state.get_node_count():
		var node_path := String(state.get_node_path(index))
		var node_type := String(state.get_node_type(index))
		if node_path == ".":
			continue
		if expected_classes.is_empty() or expected_classes.any(func(expected: String) -> bool:
			return node_type == expected or ClassDB.is_parent_class(node_type, expected)):
			result.append(node_path)
	return result

func _scene_property_names(path: NodePath) -> Array[String]:
	var result: Array[String] = []
	var state := _preview_scene_state()
	if state == null or path.is_empty():
		return result
	for node_index in state.get_node_count():
		if NodePath(state.get_node_path(node_index)) != path:
			continue
		var node_type := String(state.get_node_type(node_index))
		for info: Dictionary in ClassDB.class_get_property_list(node_type):
			var class_property := String(info.get("name", ""))
			if class_property not in ["script", "owner"] \
				and not (int(info.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY) \
				and not result.has(class_property):
				result.append(class_property)
		for property_index in state.get_node_property_count(node_index):
			var name := String(state.get_node_property_name(node_index, property_index))
			if name not in ["script", "owner"] and not result.has(name):
				result.append(name)
	result.sort()
	return result

func _scene_animations(path: NodePath) -> Array[String]:
	var result: Array[String] = []
	var state := _preview_scene_state()
	if state == null or path.is_empty():
		return result
	for node_index in state.get_node_count():
		if NodePath(state.get_node_path(node_index)) != path:
			continue
		for property_index in state.get_node_property_count(node_index):
			var property_name := String(state.get_node_property_name(node_index, property_index))
			if not property_name.begins_with("libraries/"):
				continue
			var library := state.get_node_property_value(node_index, property_index) as AnimationLibrary
			if library == null:
				continue
			var library_key := property_name.trim_prefix("libraries/")
			for animation_name: StringName in library.get_animation_list():
				var qualified := String(animation_name) if library_key.is_empty() \
					else "%s/%s" % [library_key, animation_name]
				if not result.has(qualified):
					result.append(qualified)
	result.sort()
	return result

func _preview_scene_state() -> SceneState:
	if _data == null or _data.definition == null:
		return null
	var scene_path := _data.definition.analysis_scene_path()
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return null
	var packed := ResourceLoader.load(scene_path) as PackedScene
	return packed.get_state() if packed != null else null

func _add_paths_field(parent: VBoxContainer, label_text: String, binding: StageRestorationBinding) -> void:
	parent.add_child(Style.label(label_text, Style.MUTED, 12))
	var edit := TextEdit.new()
	edit.custom_minimum_size.y = 70
	edit.text = "\n".join(binding.child_choices.map(func(path: NodePath) -> String: return String(path)))
	edit.editable = _editable
	var commit := func() -> void:
		binding.child_choices.clear()
		for line in edit.text.split("\n", false):
			var path := line.strip_edges()
			if not path.is_empty():
				binding.child_choices.append(NodePath(path))
		changed.emit()
	edit.focus_exited.connect(commit)
	parent.add_child(edit)

func _add_name_field(parent: VBoxContainer, label_text: String, binding: StageRestorationBinding,
		property: String, options: Array[String] = []) -> void:
	var row := HBoxContainer.new()
	row.add_child(Style.label(label_text, Style.MUTED, 12))
	var edit := LineEdit.new()
	if not options.is_empty():
		var picker := OptionButton.new()
		picker.accessibility_name = "%s picker" % label_text
		picker.tooltip_text = "Choose a value from the Stage preview scene, or enter one directly."
		picker.add_item("Pick…")
		for option: String in options:
			picker.add_item(option)
		picker.disabled = not _editable
		picker.item_selected.connect(func(index: int) -> void:
			if index > 0 and index <= options.size():
				edit.text = options[index - 1]
				binding.set(property, StringName(options[index - 1]))
				changed.emit())
		row.add_child(picker)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text = String(binding.get(property))
	edit.editable = _editable
	edit.text_submitted.connect(func(text: String) -> void: binding.set(property, StringName(text.strip_edges())); changed.emit())
	edit.focus_exited.connect(func() -> void: binding.set(property, StringName(edit.text.strip_edges())); changed.emit())
	row.add_child(edit)
	parent.add_child(row)

func _add_float_field(parent: VBoxContainer, label_text: String, binding: StageRestorationBinding, property: String) -> void:
	var row := HBoxContainer.new()
	row.add_child(Style.label(label_text, Style.MUTED, 12))
	var spin := SpinBox.new()
	spin.min_value = 0.0
	spin.max_value = 3600.0
	spin.step = 0.05
	spin.value = float(binding.get(property))
	spin.editable = _editable
	spin.value_changed.connect(func(value: float) -> void: binding.set(property, value); changed.emit())
	row.add_child(spin)
	parent.add_child(row)

func _rename(v: VariableData, edit: LineEdit) -> void:
	var new_key := edit.text.strip_edges()
	if new_key == v.key:
		return
	var taken: bool = _data.variables.any(func(o: VariableData) -> bool: return o != v and o.key == new_key)
	if not new_key.is_valid_identifier() or taken:
		edit.text = v.key
		return
	AuthoredData.rename_key(_data, v.key, new_key)
	for objective: ObjectiveData in _objective_editors:
		_objective_editors[objective].text = objective.condition
	edit.tooltip_text = new_key
	changed.emit()

func _on_add(index: int) -> void:
	var type_name: String = _add.get_popup().get_item_text(index)
	var keys: Array = _data.variables.map(func(x: VariableData) -> String: return String(x.key))
	var value: Variant = TYPES[type_name]
	var variable := VariableData.new()
	variable.key = AuthoredData.unique_name(keys, "new_var")
	variable.default_value = value
	variable.state_key = AuthoredData.new_state_key()
	_data.variables.append(variable)
	_rebuild()
	changed.emit()

func refresh_live(stage: Stage) -> void:
	for key in _live_labels:
		var value: Variant = stage.get_var(StringName(key))
		var l: Label = _live_labels[key]
		var writer: StringName = stage.bb.last_writers.get(StringName(key), &"")
		l.text = "Live: " + str(value)
		if not writer.is_empty():
			l.text += "  ·  Writer: " + String(writer)
		l.tooltip_text = l.text
		Style.tint(l, Style.SUCCESS if value is bool and value else Style.TEXT)
	var latched: PackedStringArray = []
	for rule in stage.engine.rules:
		if rule.one_shot and stage.fired.has(rule.latch_key()):
			latched.append(String(rule.id))
	_latched.text = "Latched one-shot rules: " + (", ".join(latched) if not latched.is_empty() else "none")
