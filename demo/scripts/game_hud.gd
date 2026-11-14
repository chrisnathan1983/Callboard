class_name GameHud extends CanvasLayer
## Runtime HUD and keyboard controls for the demo harness.

var manager: GameManager
var hud: Label
var interaction_prompt: Label
var interaction_icon: TextureRect
var board_panel: CallboardDebugPanel

func _ready() -> void:
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_font_size_override("font_size", 15)
	add_child(hud)
	var prompt_row := HBoxContainer.new()
	prompt_row.anchor_left = 0.5
	prompt_row.anchor_right = 0.5
	prompt_row.anchor_top = 1.0
	prompt_row.anchor_bottom = 1.0
	prompt_row.offset_left = -180
	prompt_row.offset_right = 180
	prompt_row.offset_top = -76
	prompt_row.offset_bottom = -36
	prompt_row.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(prompt_row)
	interaction_icon = TextureRect.new()
	interaction_icon.custom_minimum_size = Vector2(28, 28)
	interaction_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	interaction_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	interaction_icon.hide()
	prompt_row.add_child(interaction_icon)
	interaction_prompt = Label.new()
	interaction_prompt.add_theme_font_size_override("font_size", 20)
	interaction_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_row.add_child(interaction_prompt)
	prompt_row.hide()

	board_panel = CallboardDebugPanel.create()
	if board_panel == null:
		return
	board_panel.anchor_left = 0.0
	board_panel.anchor_right = 1.0
	board_panel.anchor_top = 0.42
	board_panel.anchor_bottom = 1.0
	board_panel.hide()
	add_child(board_panel)

func bind_stage(stage: Stage) -> void:
	if board_panel:
		board_panel.bind_stage(stage)

func bind_player(player: Player) -> void:
	if player == null or player.interaction_resolver == null:
		return
	var resolver := player.interaction_resolver
	if not resolver.prompt_changed.is_connected(_on_interaction_prompt_changed):
		resolver.prompt_changed.connect(_on_interaction_prompt_changed)
	_on_interaction_prompt_changed(resolver._prompt_text, resolver._prompt_icon,
		resolver._prompt_priority)

func _on_interaction_prompt_changed(text: String, icon: Texture2D, _priority: int) -> void:
	if interaction_prompt == null:
		return
	interaction_prompt.text = "E  %s" % text if not text.is_empty() else ""
	interaction_icon.texture = icon
	interaction_icon.visible = not text.is_empty() and icon != null
	interaction_prompt.get_parent().visible = not text.is_empty()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_callboard"):
		if board_panel:
			board_panel.visible = not board_panel.visible
	if event.is_action_pressed(&"reset_stage"):
		manager.clear_stage(false)
	if event.is_action_pressed(&"strike_show"):
		manager.clear_stage(true)

func _process(_delta: float) -> void:
	if board_panel and board_panel.visible:
		hud.text = "F1: hide Callboard"
		return
	var stage := manager.stage
	hud.text = (
		"Score: %d  |  THE DUCK STOPS HERE\n"
		+ "%s\n"
		+ "WASD / arrows: move    E: interact    R: reload    X: start fresh%s"
	) % [manager.score, _objective(stage), "    F1: Callboard" if board_panel else ""]

func _objective(stage: Stage) -> String:
	if stage.has_fired(&"z1_delivered"):
		return "Delivered. Deputy Duck takes office immediately."
	if not stage.is_set(&"guard_calmed"):
		return "Distract Inspector Biscuit with the decoy or the biscuit pad."
	if not stage.is_set(&"permit_stamped"):
		return "Get a squeak permit at the yellow desk."
	return "Deliver the licensed duck at City Hall."
