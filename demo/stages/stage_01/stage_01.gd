@tool
class_name Stage01 extends Stage
## A playable example of a Callboard Stage that mixes scene-placed and scripted props.
##
## Open stage_01.tscn to arrange the set, assign nodes, and configure the trigger areas.
## Open stage_01.tres in Callboard to edit the Calls, Blackboard keys, and rules.
## The scene root extends Stage and its Definition points to that resource. Load the
## PackedScene in your game so the authored children and Inspector assignments are present.
## Callboard uses the matching scene when previewing the definition, so it validates
## the same prop references the running game uses.

# Constants are available to argument expressions in the graph. The calm rule passes
# this offset to move_to(guard, shelter, GUARD_REST_OFFSET).
const GUARD_REST_OFFSET := Vector3(0, -0.1, 1.5)

# Option 1: Export a typed node reference, then assign it on the Stage root in the
# Inspector. You can swap the node without changing any rule that refers to its field.
@export var guard: MeshInstance3D
@export var lamp: OmniLight3D

# Option 2: Resolve a child by path after the scene enters the tree. Keep the field
# typed so Callboard can offer it for compatible verb arguments. In the graph, type
# the field name (window), not the node path ($Window).
@onready var shelter: MeshInstance3D = $Shelter
@onready var window: MeshInstance3D = $Window
@onready var reward: MeshInstance3D = $Reward
@onready var permit_desk: MeshInstance3D = $PermitDesk
@onready var permit: MeshInstance3D = $PermitDesk/Permit

# Option 3: Declare a typed field here and assign it in _build_props(). These props
# are absent from the scene tree in the editor, but available in the rule graph.
var treat: MeshInstance3D
var decoy: MeshInstance3D

func _build_props() -> void:
	# Stage calls this hook before compiling rule arguments, both during gameplay
	# and when Callboard validates a draft. Build only the nodes the graph needs.
	# Don't fire Calls or depend on Blackboard values here. The Blackboard defaults
	# from the definition are applied after this hook.
	treat = Props.box(self, "TreatProp", Vector3(0.7, 0.2, 0.2), $TreatSpawn.position,
		Color(0.98, 0.96, 0.85))
	decoy = Props.box(self, "DecoyProp", Vector3(0.5, 0.4, 0.5), $DecoySpawn.position,
		Color(0.2, 0.75, 0.25))
	treat.hide()
	decoy.hide()

	# DeliveryArea, DecoyArea, and PermitArea use TriggerArea in Interact mode.
	# Their Event fields match the external Calls in the StageDefinition.
	# BumpPad is another scene-placed prop. It calls Stage.fire_relay_once() with
	# "treat_out", using the local Blackboard key of the same name as its latch.
	# Both the decoy and treat paths eventually emit the "calm_guard" relay.

func can_reuse_analysis_props() -> bool:
	# Opt in because the prop layout is independent of the draft graph and its
	# Blackboard values. Callboard can validate edits against the same preview nodes.
	return true

func _make_verbs(context: StepContext) -> CoreVerbs:
	# Extend StagingVerbs to keep built-in actions like show_node() and move_to().
	# Stage01Verbs adds light() and stun_player(). Callboard reads their typed
	# parameters and defaults for the step editor and validates the arguments.
	return Stage01Verbs.new(context)

func _restore_state() -> void:
	# The game manager supplies the saved Blackboard values and one-shot latches
	# before adding this Stage to the tree. This hook runs after build() and before
	# the manager calls activate(), which dispatches the "arrive" Call.
	# Restore the visible results directly. The rules own the animations and score.
	if get_var(&"guard_calmed"):
		guard.global_position = shelter.global_position + GUARD_REST_OFFSET
	permit.visible = is_set(&"permit_stamped")
	if has_fired(&"z1_delivered"):
		reward.show()
