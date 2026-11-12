extends Node3D
## Demo harness. Stands in for the ZoneManager: it owns the saved Blackboard state,
## and loads/unloads the zone.

@export var zone_scene: PackedScene

var saved_vars := {}     # persists across reloads (ZoneManager.zone_states[zone_id])
var fired_rules := {}    # persists across reloads (for `once` rules)
var zone: Zone
var score := 0
var log_lines: Array[String] = []
var hud

func _ready() -> void:
	hud = get_node("HUD")
	hud.manager = self
	load_zone()

func load_zone() -> void:
	load_zone_scene(zone_scene)

func load_zone_scene(scene: PackedScene) -> void:
	zone = scene.instantiate()
	zone.saved_vars = saved_vars      # by reference, as a manager would inject them
	zone.fired = fired_rules
	add_child(zone)                   # _ready() builds props, Blackboard, rules
	zone.scored.connect(func(p: int) -> void: score += p)
	zone.rule_fired.connect(_on_rule_fired)
	hud.bind_zone(zone)
	zone.activate()
	_log("zone loaded")

func unload_zone() -> void:
	zone.deactivate()          # cancels every pending delay and loop
	remove_child(zone)
	zone.queue_free()

func clear_zone(reset: bool) -> void:
	unload_zone()
	if reset:
		saved_vars.clear()
		fired_rules.clear()
		score = 0
	load_zone()

func _on_rule_fired(rule_id: StringName, event: StringName) -> void:
	_log("%s  <-  %s" % [rule_id, event])

func _log(text: String) -> void:
	log_lines.append(text)
	if log_lines.size() > 8:
		log_lines.pop_front()
