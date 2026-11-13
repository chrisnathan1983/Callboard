@tool
class_name Rule extends RefCounted
## Runtime rule compiled from a RuleData resource. Runs its steps in order and
## emits its completion relay when they finish.

enum ReentryPolicy { IGNORE = 0, RESTART = 1, QUEUE = 2 }

var id: StringName
var state_key: StringName  # Stable storage key for the one-shot latch.
var trigger: StringName  # Call ID or relay event ID, such as &"relay:calm_guard".
var requires: Array[StringName] = []  # Every guard must pass before starting.
var forbids: Array[StringName] = []  # Any passing guard blocks the start.
var cancel_if: Array[StringName] = []  # Any passing guard cancels at a cancellation check.
var one_shot := false  # Latches in Stage.fired on start.
var reentry := ReentryPolicy.IGNORE
var allow_overlap := false  # Suppresses shared-trigger overlap warnings.
var steps: Array[Step] = []
var emits: StringName = &""  # Bare completion relay name.

func _init(p_id: StringName, p_trigger: StringName) -> void:
	id = p_id
	trigger = p_trigger

func latch_key() -> StringName:
	return id if state_key.is_empty() else state_key
