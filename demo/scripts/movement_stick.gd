extends Control
## The stick starts at the touch and its base follows once the thumb reaches full travel.

signal movement_changed(movement: Vector2)

const RADIUS := 58.0
const TRAVEL := 40.0
const DEAD_ZONE := 0.12

var has_moved := false
var _pointer := -1
var _origin := Vector2.ZERO
var _offset := Vector2.ZERO

func _ready() -> void:
	visibility_changed.connect(cancel)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		cancel()

func handle_input(event: InputEvent) -> bool:
	if not is_visible_in_tree():
		return false
	if event is InputEventScreenTouch:
		if event.pressed and not event.canceled and _pointer == -1:
			_pointer = event.index
			_origin = _local_position(event.position)
			queue_redraw()
			return true
		elif event.index == _pointer and (not event.pressed or event.canceled):
			cancel()
			return true
	elif event is InputEventScreenDrag and event.index == _pointer:
		var local_position := _local_position(event.position)
		_offset = (local_position - _origin).limit_length(TRAVEL)
		_origin = local_position - _offset
		var strength := maxf(inverse_lerp(DEAD_ZONE, 1.0, _offset.length() / TRAVEL), 0.0)
		has_moved = has_moved or strength > 0.0
		movement_changed.emit(_offset.normalized() * strength)
		queue_redraw()
		return true
	return false

func cancel() -> void:
	if _pointer == -1:
		return
	_pointer = -1
	_offset = Vector2.ZERO
	movement_changed.emit(Vector2.ZERO)
	queue_redraw()

func _local_position(viewport_position: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * viewport_position

func _draw() -> void:
	if _pointer == -1 and has_moved:
		return
	var center := _origin if _pointer != -1 else size * 0.5
	draw_circle(center, RADIUS, Color("142a3ce8"), true, -1.0, true)
	draw_arc(center, RADIUS - 1.0, 0.0, TAU, 64, Color("8bc6c9"), 2.0, true)
	for direction in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		draw_circle(center + direction * 49.0, 2.2, Color("8bc6c9"), true, -1.0, true)
	var knob_color := Color("f6ca76") if _pointer != -1 else Color("a6d6d7")
	draw_circle(center + _offset, 19.0, knob_color, true, -1.0, true)
