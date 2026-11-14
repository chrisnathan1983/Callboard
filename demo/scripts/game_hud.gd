class_name GameHud extends CanvasLayer
## Objective, touch controls, and optional live Callboard for the demo.

const MovementStick := preload("res://demo/scripts/movement_stick.gd")
const INK := Color("142a3c")
const PAPER := Color("fff9ea")
const GOLD := Color("f6ca76")
const MARGIN := 20.0
const ACTION_HEIGHT := 58.0

var manager: GameManager
var board_panel: CallboardDebugPanel

var _player: Player
var _score: Label
var _objective_text: Label
var _actions: HBoxContainer
var _board_button: Button
var _play_controls: Control
var _stick: MovementStick
var _interact: Button
var _move_hint: Label
var _touch_buttons: Array[Button] = []
var _pressed_button: Button
var _button_pointer := -1

func _ready() -> void:
	var layout := Control.new()
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layout)

	var inset := MarginContainer.new()
	inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inset.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inset.offset_left = MARGIN
	inset.offset_top = MARGIN
	inset.offset_right = -MARGIN
	inset.offset_bottom = -MARGIN
	layout.add_child(inset)

	var header := VBoxContainer.new()
	header.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_theme_constant_override("separation", 8)
	inset.add_child(header)

	var toolbar := HFlowContainer.new()
	toolbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toolbar.add_theme_constant_override("h_separation", 8)
	toolbar.add_theme_constant_override("v_separation", 8)
	header.add_child(toolbar)
	var title := _label("The Duck Stops Here", 27, PAPER)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(title)

	_actions = HBoxContainer.new()
	_actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_actions.add_theme_constant_override("separation", 8)
	toolbar.add_child(_actions)
	_actions.add_child(_button("Reload · R", func() -> void: manager.clear_stage(false)))
	_actions.add_child(_button("Start fresh · X", func() -> void: manager.clear_stage(true)))

	var objective_card := PanelContainer.new()
	objective_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	objective_card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	objective_card.add_theme_stylebox_override("panel", _surface(INK, Color("527781")))
	header.add_child(objective_card)
	var objective_stack := VBoxContainer.new()
	objective_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	objective_card.add_child(objective_stack)
	_score = _label("", 16, GOLD)
	objective_stack.add_child(_score)
	_objective_text = _label("", 18, PAPER)
	_objective_text.custom_minimum_size.x = 360
	_objective_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	objective_stack.add_child(_objective_text)

	_play_controls = Control.new()
	_play_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_play_controls.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.add_child(_play_controls)
	_stick = MovementStick.new()
	_stick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_stick.offset_left = -MovementStick.RADIUS
	_stick.offset_right = MovementStick.RADIUS
	_stick.offset_bottom = -MARGIN - ACTION_HEIGHT - 28.0
	_stick.offset_top = _stick.offset_bottom - MovementStick.RADIUS * 2.0
	_stick.movement_changed.connect(_on_movement_changed)
	_play_controls.add_child(_stick)

	_interact = _button("", _on_interact, true)
	_interact.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_interact.offset_left = -120.0
	_interact.offset_top = -MARGIN - ACTION_HEIGHT
	_interact.offset_right = 120.0
	_interact.offset_bottom = -MARGIN
	_interact.hide()
	_play_controls.add_child(_interact)

	_move_hint = _label("Drag anywhere to move", 14, PAPER)
	_move_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stick.add_child(_move_hint)
	_move_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_move_hint.offset_left = -110.0
	_move_hint.offset_right = 110.0
	_move_hint.offset_top = 0.0
	_move_hint.offset_bottom = MARGIN

	board_panel = CallboardDebugPanel.create()
	if board_panel:
		board_panel.anchor_right = 1.0
		board_panel.anchor_bottom = 1.0
		board_panel.anchor_top = 0.42
		board_panel.hide()
		layout.add_child(board_panel)
		_board_button = _button("Callboard · F1", _toggle_board)
		_actions.add_child(_board_button)

func bind_stage(stage: Stage) -> void:
	if board_panel:
		board_panel.bind_stage(stage)

func bind_player(player: Player) -> void:
	if is_instance_valid(_player) and _player.interaction_resolver != null:
		_stick.cancel()
		_player.interaction_resolver.prompt_changed.disconnect(_on_interaction_prompt_changed)
	_player = player
	if _player == null or _player.interaction_resolver == null:
		_on_interaction_prompt_changed("", null, 0)
		return
	var resolver := _player.interaction_resolver
	resolver.prompt_changed.connect(_on_interaction_prompt_changed)
	_on_interaction_prompt_changed(resolver._prompt_text, resolver._prompt_icon, resolver._prompt_priority)

func _on_movement_changed(movement: Vector2) -> void:
	if _stick.has_moved:
		_move_hint.hide()
	if is_instance_valid(_player):
		_player.touch_movement = movement

func _on_interaction_prompt_changed(text: String, icon: Texture2D, _priority: int) -> void:
	if _pressed_button == _interact:
		_cancel_button_press()
	_interact.text = "%s · E" % text
	_interact.icon = icon
	_interact.visible = not text.is_empty()

func _on_interact() -> void:
	if is_instance_valid(_player):
		_player.interact()

func _toggle_board() -> void:
	if not board_panel:
		return
	board_panel.visible = not board_panel.visible
	_play_controls.visible = not board_panel.visible
	_board_button.text = "Close board · F1" if board_panel.visible else "Callboard · F1"

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_cancel_button_press()

func _input(event: InputEvent) -> void:
	# Godot emulates mouse input from one finger for ordinary GUI. Track these
	# buttons by touch ID so another finger can tap while the stick is held.
	if event is InputEventScreenDrag and event.index == _button_pointer:
		_pressed_button.modulate = Color.WHITE if _button_contains(_pressed_button, event.position) else PAPER
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		if event.pressed and not event.canceled:
			for button in _touch_buttons:
				if not _button_contains(button, event.position):
					continue
				if _button_pointer == -1:
					_button_pointer = event.index
					_pressed_button = button
					button.modulate = Color.WHITE
				get_viewport().set_input_as_handled()
				return
		elif event.index == _button_pointer:
			var button := _pressed_button
			_cancel_button_press()
			get_viewport().set_input_as_handled()
			if not event.canceled and _button_contains(button, event.position):
				button.pressed.emit()
			return
	if _stick and _stick.handle_input(event):
		get_viewport().set_input_as_handled()

func _cancel_button_press() -> void:
	if is_instance_valid(_pressed_button):
		_pressed_button.modulate = PAPER
	_pressed_button = null
	_button_pointer = -1

func _button_contains(button: Button, viewport_position: Vector2) -> bool:
	var local_position := button.get_global_transform_with_canvas().affine_inverse() * viewport_position
	return button.is_visible_in_tree() and Rect2(Vector2.ZERO, button.size).has_point(local_position)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_callboard"):
		_toggle_board()
	elif event.is_action_pressed(&"reset_stage"):
		manager.clear_stage(false)
	elif event.is_action_pressed(&"strike_show"):
		manager.clear_stage(true)

func _process(_delta: float) -> void:
	if manager == null or not is_instance_valid(manager.stage):
		return
	_score.text = "Score: %d" % manager.score
	_objective_text.text = _objective(manager.stage)

func _objective(stage: Stage) -> String:
	if stage.has_fired(&"z1_delivered"):
		return "Delivered. Deputy Duck takes office."
	if not stage.is_set(&"guard_calmed"):
		return "Distract Inspector Biscuit with the decoy or the biscuit pad."
	if not stage.is_set(&"permit_stamped"):
		return "Get a squeak permit at the yellow desk."
	return "Deliver the licensed duck at City Hall."

func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _button(text: String, action: Callable, primary := false) -> Button:
	var button := Button.new()
	button.text = text
	button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 48
	button.modulate = PAPER
	button.add_theme_font_size_override("font_size", 17)
	button.add_theme_color_override("font_color", INK if primary else PAPER)
	button.add_theme_constant_override("icon_max_width", 24)
	button.add_theme_stylebox_override("normal", _surface(GOLD if primary else INK, GOLD if primary else Color("527781")))
	button.pressed.connect(action)
	_touch_buttons.append(button)
	return button

func _surface(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style
