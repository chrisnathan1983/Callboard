class_name GameManager extends Node3D
## Demo harness. Stands in for a StageManager: it owns the saved Blackboard state,
## and loads/unloads the stage.

@export var stage_scene: PackedScene

var saved_vars := {}     # persists across reloads (StageManager.stage_states[stage_id])
var fired_rules := {}    # persists across reloads for one-shot rules
var stage: Stage
var score := 0
var log_lines: Array[String] = []
@onready var hud: GameHud = $HUD

func _ready() -> void:
	hud.manager = self
	load_stage()

func load_stage() -> void:
	load_stage_scene(stage_scene)

func load_stage_scene(scene: PackedScene) -> void:
	stage = scene.instantiate()
	stage.saved_vars = saved_vars      # by reference, as a manager would inject them
	stage.fired = fired_rules
	add_child(stage)                   # _ready() builds props, Blackboard, rules
	stage.scored.connect(_on_scored)
	stage.rule_fired.connect(_on_rule_fired)
	hud.bind_stage(stage)
	stage.activate()
	_log("stage loaded")

func unload_stage() -> void:
	stage.deactivate()          # cancels every pending delay and loop
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

func _on_rule_fired(rule_id: StringName, event: StringName) -> void:
	_log("%s  <-  %s" % [rule_id, event])

func _log(text: String) -> void:
	log_lines.append(text)
	if log_lines.size() > 8:
		log_lines.pop_front()
