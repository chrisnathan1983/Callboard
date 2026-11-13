class_name GameHud extends CanvasLayer
## Runtime HUD and keyboard controls for the demo harness.

const BOARD_SCRIPT_PATH := "res://addons/callboard/editor/callboard.gd"

var manager: GameManager
var hud: Label
var board: Control
var board_panel: PanelContainer

func _ready() -> void:
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_font_size_override("font_size", 15)
	add_child(hud)

	if not OS.is_debug_build() or not ResourceLoader.exists(BOARD_SCRIPT_PATH, "Script"):
		return
	var board_script := load(BOARD_SCRIPT_PATH) as Script
	if board_script:
		board_panel = PanelContainer.new()
		board_panel.anchor_left = 0.0
		board_panel.anchor_right = 1.0
		board_panel.anchor_top = 0.42
		board_panel.anchor_bottom = 1.0
		board_panel.visible = false
		board = board_script.new() as Control
		board_panel.add_child(board)
		add_child(board_panel)

func bind_stage(stage: Stage) -> void:
	if board:
		board.call("bind_live", stage)

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
	hud.text = (
		"Score: %d\n\n"
		+ "WASD / arrows: move    E: interact (shelter = offer decoy, doorway = deliver)\n"
		+ "Bump the blue pad for the treat.    R: reset the stage    X: strike the show%s\n\n"
		+ "saved vars (persist): %s\n"
		+ "local vars (reset on reload): %s\n\n"
		+ "rules fired:\n%s"
	) % [manager.score, "    F1: Callboard" if board_panel else "",
		manager.stage.saved_vars, manager.stage.bb.local, "\n".join(manager.log_lines)]
