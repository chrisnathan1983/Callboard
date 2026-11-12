extends CanvasLayer
## Runtime HUD and keyboard controls for the demo harness.

var manager
var hud: Label
var board: RuleBoard
var board_panel: PanelContainer

func _ready() -> void:
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_font_size_override("font_size", 15)
	add_child(hud)

	board_panel = PanelContainer.new()
	board_panel.anchor_left = 0.0
	board_panel.anchor_right = 1.0
	board_panel.anchor_top = 0.42
	board_panel.anchor_bottom = 1.0
	board_panel.visible = false
	board = RuleBoard.new()
	board_panel.add_child(board)
	add_child(board_panel)

func bind_zone(zone: Zone) -> void:
	board.bind_live(zone)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1:
				board_panel.visible = not board_panel.visible
			KEY_R:
				manager.clear_zone(false)
			KEY_X:
				manager.clear_zone(true)

func _process(_delta: float) -> void:
	if board_panel.visible:
		hud.text = "F1: hide Rule Board"
		return
	hud.text = (
		"Score: %d\n\n"
		+ "WASD / arrows: move    E: interact (shelter = offer decoy, doorway = deliver)\n"
		+ "Bump the blue pad for the treat.    R: reload zone    X: wipe saved state    F1: Rule Board\n\n"
		+ "saved vars (persist): %s\n"
		+ "local vars (reset on reload): %s\n\n"
		+ "rules fired:\n%s"
	) % [manager.score, manager.zone.saved_vars, manager.zone.local_vars, "\n".join(manager.log_lines)]
