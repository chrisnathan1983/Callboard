@tool
class_name Rule extends RefCounted
## "When <trigger> fires and the fire-time guards pass, run <steps>, then emit <emits>."
## Plain properties, so a graph editor and a code generator can read and write them directly.

var id: StringName
var trigger: StringName                  # &"arrive", &"deliver", &"relay:calm_guard"
var requires: Array[StringName] = []     # fire-time guard: keys that must be truthy
var forbids: Array[StringName] = []      # fire-time guard: keys that must be falsy
var cancel_if: Array[StringName] = []    # mid-flight guard: abort if any becomes truthy
var once := false                        # latched in Zone.fired on first run
var steps: Array[Step] = []
var emits: StringName = &""              # optional relay fired when all steps finish

func _init(p_id: StringName, p_trigger: StringName) -> void:
	id = p_id
	trigger = p_trigger
