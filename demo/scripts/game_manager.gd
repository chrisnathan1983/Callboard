class_name GameManager extends Node3D
## The host owns the state store, decides which Stage is active, and handles gameplay effects.

const MAIN_OFFICE := &"city_hall"
const ANNEX := &"annex"

@export var stage_scene: PackedScene

var state_store := StageStateStore.new()
var stage: Stage
var office_id := MAIN_OFFICE
var score := 0
var _offices: Dictionary[StringName, Stage] = {}
@onready var hud: GameHud = $HUD
@onready var _player: Player = $WorldManager/Player

func _ready() -> void:
	hud.manager = self
	hud.bind_player(_player)
	_open_office()

func _get_office(id: StringName) -> Stage:
	if _offices.has(id):
		return _offices[id]
	# Use a stable ID for each logical office even though both use the same scene.
	# The store attaches the saved Blackboard values and rule latches before
	# _ready() builds the graph and applies the StageDefinition's restoration bindings.
	var loaded := state_store.load_stage(stage_scene, id, self)
	if loaded == null:
		return null
	loaded.hide()
	_offices[id] = loaded
	# Bind once for this instance so returning to an office cannot double the score
	# or apply the same gameplay event twice. A managed Stage is still dormant here.
	loaded.scored.connect(_on_scored)
	loaded.gameplay_event.connect(_on_gameplay_event)
	return loaded

func _open_office() -> void:
	stage = _get_office(office_id)
	if stage == null:
		return
	_get_office(ANNEX if office_id == MAIN_OFFICE else MAIN_OFFICE)
	stage.show()
	hud.bind_stage(stage)
	# Activate only after listeners and the debugger are ready for the arrive Call.
	stage.activate()

func switch_office() -> void:
	if stage == null:
		return
	# Rebuild the office we just left as the dormant neighbor. If we exit
	# during a cutscene, its next visit starts from the resolved saved pose.
	# The reloaded neighbor still receives live shared Blackboard updates.
	_unload_current_office()
	office_id = ANNEX if office_id == MAIN_OFFICE else MAIN_OFFICE
	_open_office()

func office_name() -> String:
	return "City Hall" if office_id == MAIN_OFFICE else "City Hall Annex"

func clear_stage(reset: bool) -> void:
	# Reload exercises scene restoration. Start fresh clears both offices so
	# the shared total and the sum of the saved delivery counters stay in sync.
	if reset:
		for loaded: Stage in _offices.values():
			state_store.unload_stage(loaded)
		_offices.clear()
		state_store.stage_states.clear()
		state_store.shared_values.clear()
		score = 0
	else:
		_unload_current_office()
	_open_office()

func _unload_current_office() -> void:
	# The store deactivates before unloading, releasing pending rule waits.
	state_store.unload_stage(stage)
	_offices.erase(office_id)

func _on_scored(points: int) -> void:
	score += points

func _on_gameplay_event(event_id: StringName, arguments: Dictionary) -> void:
	# The rule requests an effect with gameplay_event(id, args). The host
	# interprets its arguments and applies it to the player, who lives outside
	# the Stage. The graph can be validated without a Player in the preview.
	if event_id == &"stun_courier":
		_player.stun(float(arguments.get("seconds", 0.0)))
