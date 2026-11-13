@tool
class_name CallboardOverlayLayout extends RefCounted
## Positions Callboard's floating controls and reserves canvas space around them.

const GUTTER := 12.0

var _board: Control
var _file_tools: Control
var _create_tools: Control
var _left_tools: Control
var _blackboard_panel: Control
var _connections_panel: Control
var _live_debug_panel: Control
var _debug_button: Control
var _connection_rows: Control
var _settings_window: Control
var _blackboard: BlackboardPanel
var _inspector: RuleInspector
var _view: RuleGraphView

func setup(board: Control, file_tools: Control, create_tools: Control, left_tools: Control,
		blackboard_panel: Control, connections_panel: Control, live_debug_panel: Control,
		debug_button: Control, connection_rows: Control, settings_window: Control,
		blackboard: BlackboardPanel, inspector: RuleInspector,
		view: RuleGraphView) -> void:
	_board = board
	_file_tools = file_tools
	_create_tools = create_tools
	_left_tools = left_tools
	_blackboard_panel = blackboard_panel
	_connections_panel = connections_panel
	_live_debug_panel = live_debug_panel
	_debug_button = debug_button
	_connection_rows = connection_rows
	_settings_window = settings_window
	_blackboard = blackboard
	_inspector = inspector
	_view = view

func layout() -> void:
	if _settings_window == null:
		return
	for toolbar in [_file_tools, _create_tools]:
		toolbar.reset_size()
	_file_tools.position = Vector2(GUTTER, GUTTER)
	var create_x := (_board.size.x - _create_tools.size.x) * 0.5
	var top_bottom := GUTTER + _file_tools.size.y
	var create_y := GUTTER
	var create_min_x := _file_tools.position.x + _file_tools.size.x + GUTTER
	var create_max_x := _board.size.x - GUTTER - _create_tools.size.x
	if create_min_x <= create_max_x:
		create_x = clampf(create_x, create_min_x, create_max_x)
	elif create_x < create_min_x:
		create_y = top_bottom + 6.0
	_create_tools.position = Vector2(create_x, create_y)
	if _create_tools.visible:
		top_bottom = maxf(top_bottom, create_y + _create_tools.size.y)

	var window_y := top_bottom + GUTTER
	var view_toolbar := _view.get_menu_hbox().get_parent() as Control
	var footer_height := view_toolbar.get_combined_minimum_size().y + GUTTER * 2.0
	var available_height := maxf(_board.size.y - window_y - footer_height, 32.0)
	var left_size := _left_tools.get_combined_minimum_size()
	if _blackboard_panel.visible:
		left_size.y = minf(available_height, left_size.y + _blackboard.rows_height())
	elif _connections_panel.visible:
		left_size.y = minf(available_height, left_size.y + _connection_rows.get_combined_minimum_size().y)
	_left_tools.size = left_size
	_left_tools.position = Vector2(GUTTER, window_y)
	var fit_right := _board.size.x - GUTTER * 2.0
	if _settings_window.visible:
		var settings_height := minf(_inspector.content_height() + 60.0, 590.0)
		_settings_window.size = Vector2(_settings_window.get_combined_minimum_size().x, minf(settings_height, available_height))
		_settings_window.position = Vector2(_board.size.x - _settings_window.size.x - GUTTER, window_y)
		fit_right = _settings_window.position.x - GUTTER
	elif _live_debug_panel.visible:
		var debug_size := _live_debug_panel.get_combined_minimum_size()
		var debug_width := minf(debug_size.x, maxf(_board.size.x - GUTTER * 2.0, 1.0))
		var debug_height := maxf(_board.size.y - window_y - GUTTER, 32.0)
		_live_debug_panel.size = Vector2(debug_width, debug_height)
		_live_debug_panel.position = Vector2(_board.size.x - _live_debug_panel.size.x - GUTTER, window_y)
		fit_right = _live_debug_panel.position.x - GUTTER
	_view.set_minimap_right_edge(fit_right if _settings_window.visible or _live_debug_panel.visible
		else _board.size.x - GUTTER)

	if _debug_button.visible:
		_debug_button.reset_size()
		_debug_button.size = _debug_button.get_combined_minimum_size()
		_debug_button.position = Vector2(
			_board.size.x - _debug_button.size.x - GUTTER,
			maxf(GUTTER, window_y - _debug_button.size.y - 6.0))

	var fit_left := _left_tools.size.x + GUTTER * 2.0
	# A narrow workspace can pan beneath the overlays.
	if fit_right - fit_left < _board.size.x * 0.45:
		fit_left = GUTTER * 2.0
		fit_right = _board.size.x - GUTTER * 2.0
	_view.fit_area = Rect2(fit_left, window_y, maxf(fit_right - fit_left, 1.0), available_height)
