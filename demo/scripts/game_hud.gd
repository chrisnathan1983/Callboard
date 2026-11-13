class_name GameHud extends CanvasLayer
## Runtime HUD and keyboard controls for the demo harness.

var manager: GameManager
var hud: Label
var board_panel: CallboardDebugPanel

func _ready() -> void:
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_font_size_override("font_size", 15)
	add_child(hud)

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
