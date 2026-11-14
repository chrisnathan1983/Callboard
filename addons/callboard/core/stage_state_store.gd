@tool
class_name StageStateStore extends Resource
## Shared persistence for independently loaded Stage instances.

@export var stage_states: Dictionary = {}
@export var shared_values: Dictionary = {}

var _shared_boards: Array[WeakRef] = []
var _loaded_ids: Dictionary = {}
var _shared_write_queue: Array[Dictionary] = []
var _dispatching_shared_writes := false

func state_for(instance_id: StringName) -> Dictionary:
	if instance_id.is_empty():
		push_warning("StageStateStore requires a stable, non-empty stage instance ID.")
		return {"saved": {}, "fired": {}}
	if not stage_states.has(instance_id):
		stage_states[instance_id] = {"saved": {}, "fired": {}}
	var state: Dictionary = stage_states[instance_id]
	if not state.get("saved") is Dictionary:
		state["saved"] = {}
	if not state.get("fired") is Dictionary:
		state["fired"] = {}
	return state

## Inject state before the Stage enters the tree and initializes its Blackboard.
func attach(stage: Stage, instance_id: StringName) -> bool:
	if stage == null or instance_id.is_empty():
		return false
	if _loaded_ids.has(instance_id) and is_instance_valid(_loaded_ids[instance_id]):
		push_warning("Stage instance ID '%s' is already loaded." % instance_id)
		return false
	var state := state_for(instance_id)
	stage.attach_state_store(self, instance_id, state["saved"], state["fired"], shared_values)
	_loaded_ids[instance_id] = stage
	return true

func load_stage(scene: PackedScene, instance_id: StringName, parent: Node) -> Stage:
	if scene == null or parent == null:
		return null
	var stage := scene.instantiate() as Stage
	if stage == null:
		push_error("StageStateStore scene must have a Stage root.")
		return null
	if not attach(stage, instance_id):
		stage.free()
		return null
	parent.add_child(stage)
	return stage

func unload_stage(stage: Stage) -> void:
	if stage == null or not is_instance_valid(stage):
		return
	stage.deactivate()
	_loaded_ids.erase(stage.stage_instance_id)
	if stage.get_parent():
		stage.get_parent().remove_child(stage)
	stage.queue_free()

func release_stage(stage: Stage) -> void:
	if stage == null or stage.stage_instance_id.is_empty():
		return
	if _loaded_ids.get(stage.stage_instance_id) == stage:
		_loaded_ids.erase(stage.stage_instance_id)

func register_blackboard(board: Blackboard) -> void:
	if board == null:
		return
	board.shared_values = shared_values
	board.shared_write_guard = Callable(self, "validate_shared_write")
	board.shared_write_commit = Callable(self, "commit_shared_write")
	_shared_boards = _valid_board_refs()
	_shared_boards.append(weakref(board))

func is_dispatching_shared_writes() -> bool:
	return _dispatching_shared_writes

func unregister_blackboard(board: Blackboard) -> void:
	if board == null:
		return
	board.shared_write_guard = Callable()
	board.shared_write_commit = Callable()
	var remaining: Array[WeakRef] = []
	for ref: WeakRef in _valid_board_refs():
		if ref.get_ref() != board:
			remaining.append(ref)
	_shared_boards = remaining

func commit_shared_write(storage_key: StringName, key: StringName, value: Variant,
		writer: StringName, source: Blackboard, dispatch_context: Dictionary = {}) -> bool:
	if source == null or not validate_shared_write(storage_key, value, source):
		return false
	_shared_write_queue.append({
		"storage_key": storage_key,
		"key": key,
		"value": value,
		"writer": writer,
		"source": source,
		"dispatch_context": dispatch_context.duplicate(true),
	})
	if _dispatching_shared_writes:
		return true
	_dispatching_shared_writes = true
	var committed := false
	while not _shared_write_queue.is_empty():
		var request: Dictionary = _shared_write_queue.pop_front()
		var request_key: StringName = request["storage_key"]
		var request_value: Variant = request["value"]
		var request_source: Blackboard = request["source"]
		if not validate_shared_write(request_key, request_value, request_source):
			continue
		if shared_values.has(request_key) and shared_values[request_key] == request_value \
				and typeof(shared_values[request_key]) == typeof(request_value):
			continue
		var previous_value: Variant = shared_values.get(request_key)
		shared_values[request_key] = request_value
		committed = true
		var request_writer: StringName = request["writer"]
		var request_context: Dictionary = request.get("dispatch_context", {})
		if is_instance_valid(request_source):
			request_source.receive_shared_change(request_key, request_value, request_writer, request_context, true, previous_value)
		for ref: WeakRef in _valid_board_refs():
			var board := ref.get_ref() as Blackboard
			if board != null and board != request_source:
				board.receive_shared_change(request_key, request_value, request_writer, request_context, false, previous_value)
	_dispatching_shared_writes = false
	return committed

func validate_shared_write(storage_key: StringName, value: Variant, _source: Blackboard) -> bool:
	for ref: WeakRef in _valid_board_refs():
		var board := ref.get_ref() as Blackboard
		if board == null:
			continue
		for entry: Dictionary in board.schema.values():
			if entry.get("scope") == &"shared" and entry.get("state_key") == storage_key \
					and entry.get("type", TYPE_NIL) != typeof(value):
				push_warning("Shared Blackboard key '%s' has conflicting types across loaded Stages." % storage_key)
				return false
	return true

func shared_schema_errors(board: Blackboard) -> Array[String]:
	var problems: Array[String] = []
	if board == null:
		return problems
	for other_ref: WeakRef in _valid_board_refs():
		var other := other_ref.get_ref() as Blackboard
		if other == null or other == board:
			continue
		for key: StringName in board.schema:
			var entry: Dictionary = board.schema[key]
			if entry.get("scope") != &"shared":
				continue
			for other_key: StringName in other.schema:
				var other_entry: Dictionary = other.schema[other_key]
				if other_entry.get("scope") == &"shared" \
						and other_entry.get("state_key") == entry.get("state_key") \
						and other_entry.get("type") != entry.get("type"):
					problems.append("shared Blackboard key '%s' has conflicting types in loaded Stages" % entry.get("state_key"))
	return problems

func _valid_board_refs() -> Array[WeakRef]:
	var valid: Array[WeakRef] = []
	for ref: WeakRef in _shared_boards:
		if ref.get_ref() is Blackboard:
			valid.append(ref)
	return valid
