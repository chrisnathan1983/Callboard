class_name GameManager extends Node3D
## Demo harness. Stands in for a StageManager: it owns the saved Blackboard state,
## and loads/unloads the stage.

@export var stage_scene: PackedScene

var state_store := StageStateStore.new()
const STAGE_INSTANCE_ID := &"demo_yard"
var stage: Stage
var score := 0
@onready var hud: GameHud = $HUD

func _ready() -> void:
	hud.manager = self
	hud.bind_player($WorldManager/Player as Player)
	load_stage()

func load_stage() -> void:
	load_stage_scene(stage_scene)

func load_stage_scene(scene: PackedScene) -> void:
	stage = state_store.load_stage(scene, STAGE_INSTANCE_ID, self)
	if stage == null:
		return
	stage.scored.connect(_on_scored)
	# Bind listeners before activate() dispatches the arrival Call. That lets the
	# debugger and HUD see rules that fire immediately on arrival.
	hud.bind_stage(stage)
	stage.activate()

func unload_stage() -> void:
	state_store.unload_stage(stage)
	stage = null

func clear_stage(reset: bool) -> void:
	unload_stage()
	if reset:
		state_store.stage_states.erase(STAGE_INSTANCE_ID)
		state_store.shared_values.clear()
		score = 0
	load_stage()

func _on_scored(points: int) -> void:
	score += points
