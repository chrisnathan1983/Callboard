@tool
class_name Rule extends RefCounted
## "When <trigger> fires and the fire-time guards pass, run <steps>, then emit <emits>."
## Plain properties, so a graph editor and a code generator can read and write them directly.

enum ReentryPolicy { IGNORE = 0, RESTART = 1, QUEUE = 2 }

var id: StringName
var state_key: StringName                 # optional stable key for the once latch
var trigger: StringName                  # &"arrive", &"deliver", &"relay:calm_guard"
var requires: Array[StringName] = []     # fire-time guard: keys that must be truthy
var forbids: Array[StringName] = []      # fire-time guard: keys that must be falsy
var cancel_if: Array[StringName] = []    # mid-flight guard: abort if any becomes truthy
var one_shot := false                    # latched in Stage.fired on first run
var reentry := ReentryPolicy.IGNORE
var allow_overlap := false              # suppress shared-trigger overlap warnings
var steps: Array[Step] = []
var emits: StringName = &""              # optional relay fired when all steps finish

func _init(p_id: StringName, p_trigger: StringName) -> void:
	id = p_id
	trigger = p_trigger

func latch_key() -> StringName:
	return id if state_key.is_empty() else state_key
