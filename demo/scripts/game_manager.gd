class_name GameManager extends Node3D
## Demo harness. Stands in for a StageManager: it owns the saved Blackboard state,
## and loads/unloads the stage.

@export var stage_scene: PackedScene

var saved_vars := {}     # persists across reloads (StageManager.stage_states[stage_id])
var fired_rules := {}    # persists across reloads for one-shot rules
var stage: Stage
var score := 0
@onready var hud: GameHud = $HUD

func _ready() -> void:
	hud.manager = self
	load_stage()

func load_stage() -> void:
	load_stage_scene(stage_scene)

func load_stage_scene(scene: PackedScene) -> void:
	stage = scene.instantiate()
	# Supply both dictionaries before add_child(): Stage._ready() builds the graph
	# and calls _restore_state() as soon as the scene enters the tree.
	stage.saved_vars = saved_vars
	stage.fired = fired_rules
	add_child(stage)
	stage.scored.connect(_on_scored)
	# Bind listeners before activate() dispatches the arrival Call. That lets the
	# debugger and HUD see rules that fire immediately on arrival.
	hud.bind_stage(stage)
	stage.activate()

func unload_stage() -> void:
	# Cancel the old graph's work before replacing its scene.
	stage.deactivate()
	remove_child(stage)
	stage.queue_free()

func clear_stage(reset: bool) -> void:
	unload_stage()
	if reset:
		saved_vars.clear()
		fired_rules.clear()
		score = 0
	load_stage()

func _on_scored(points: int) -> void:
	score += points
