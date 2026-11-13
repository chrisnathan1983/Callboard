class_name CallboardDebugPanel extends PanelContainer
## Optional live Callboard for an in-game HUD.

const BOARD_SCRIPT_PATH := "res://addons/callboard/editor/callboard.gd"

var _board: Control

## Returns an unparented panel, or null if the live board is unavailable.
## Add the panel to the tree before binding a running Stage.
static func create() -> CallboardDebugPanel:
	if not OS.is_debug_build() or not ResourceLoader.exists(BOARD_SCRIPT_PATH, "Script"):
		return null
	var board_script := load(BOARD_SCRIPT_PATH) as Script
	if board_script == null or not board_script.can_instantiate():
		return null
	var panel := CallboardDebugPanel.new()
	panel._board = board_script.new() as Control
	panel.add_child(panel._board)
	return panel

## Call again when the game switches to a different Stage.
func bind_stage(stage: Stage) -> void:
	_board.call(&"bind_live", stage)
