@tool
class_name StageControlAdapter extends RefCounted
## Shared ownership for temporary input and camera changes. The host applies
## the effective state to its own player and camera rig.

signal state_changed

class CameraRequest extends RefCounted:
	enum Kind { FOCUS, FRAME, SHAKE }

	var kind: Kind
	var shot: StringName
	var blend_seconds: float
	var strength: float
	var frequency: float
	var target: Node3D:
		get:
			return _target.get_ref() as Node3D if _target != null else null
	var _target: WeakRef

var _input_locks: Dictionary = {}
var _camera_requests: Dictionary = {}
var _shake_requests: Dictionary = {}
var _owners: Dictionary[int, bool] = {}

func is_input_locked(channel: StringName = &"gameplay") -> bool:
	return _input_locks.has(channel)

## The most recent focus or framing request, or null to restore host control.
func camera_request(channel: StringName = &"main") -> CameraRequest:
	return _latest_request(_camera_requests, channel)

## Shake is independent of focus and framing. A null request stops the shake.
func shake_request(channel: StringName = &"main") -> CameraRequest:
	return _latest_request(_shake_requests, channel)

func _latest_request(requests: Dictionary, channel: StringName) -> CameraRequest:
	var claims: Dictionary = requests.get(channel, {})
	if claims.is_empty():
		return null
	return claims.values().back() as CameraRequest

func _claim_input(owner: RuleEngine.RunLifetime, channel: StringName) -> void:
	_claim(_input_locks, owner, channel, true)

func _release_input(owner: RuleEngine.RunLifetime, channel: StringName) -> void:
	if _remove_claim(_input_locks, channel, owner.get_instance_id()):
		state_changed.emit()

func _claim_camera(owner: RuleEngine.RunLifetime, channel: StringName, request: CameraRequest) -> void:
	var requests := _shake_requests if request.kind == CameraRequest.Kind.SHAKE else _camera_requests
	_claim(requests, owner, channel, request)

func _release_camera(owner: RuleEngine.RunLifetime, channel: StringName) -> void:
	var id := owner.get_instance_id()
	var removed_camera := _remove_claim(_camera_requests, channel, id)
	var removed_shake := _remove_claim(_shake_requests, channel, id)
	if removed_camera or removed_shake:
		state_changed.emit()

func _claim(channels: Dictionary, owner: RuleEngine.RunLifetime,
		channel: StringName, value: Variant) -> void:
	if owner.is_ended or channel.is_empty():
		return
	var id := owner.get_instance_id()
	if not _owners.has(id):
		_owners[id] = true
		owner.ended.connect(_release_owner.bind(id), CONNECT_ONE_SHOT)
	var claims: Dictionary = channels.get_or_add(channel, {})
	if claims.get(id) == value:
		return
	# Dictionary iteration preserves insertion order. Updating a camera claim
	# moves it to the top while keeping earlier owners available for restoration.
	claims.erase(id)
	claims[id] = value
	state_changed.emit()

func _remove_claim(channels: Dictionary, channel: StringName, id: int) -> bool:
	var claims: Dictionary = channels.get(channel, {})
	if not claims.erase(id):
		return false
	if claims.is_empty():
		channels.erase(channel)
	return true

func _release_owner(id: int) -> void:
	_owners.erase(id)
	var changed := false
	for channels: Dictionary in [_input_locks, _camera_requests, _shake_requests]:
		for channel: StringName in channels.keys():
			changed = _remove_claim(channels, channel, id) or changed
	if changed:
		state_changed.emit()
