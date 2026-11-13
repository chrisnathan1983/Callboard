@tool
class_name Stage01 extends Stage
## Stage 1: a guard patrols a doorway and trips a warning lamp until it is calmed.
## Events, Blackboard defaults and graph are authored in stage_01.tres.

const SHELTER_POS := Vector3(-6, 0.5, -3)
const GUARD_REST_OFFSET := Vector3(0, -0.1, 1.5)

var guard: MeshInstance3D
var shelter: MeshInstance3D
var lamp: OmniLight3D
var window: MeshInstance3D
var treat: MeshInstance3D
var decoy: MeshInstance3D
var reward: MeshInstance3D

func _init() -> void:
	name = "Stage01"

func can_reuse_analysis_props() -> bool:
	return true

func _build_props() -> void:
	Props.box(self, "Ground", Vector3(24, 0.1, 18), Vector3(0, -0.05, 0), Color(0.92, 0.95, 1.0))
	Props.box(self, "Building", Vector3(7, 3.5, 3), Vector3(0, 1.75, -6), Color(0.55, 0.35, 0.25))
	Props.box(self, "DoorStep", Vector3(3, 0.2, 1.4), Vector3(0, 0.1, -4.1), Color(0.4, 0.4, 0.4))
	window = Props.box(self, "Window", Vector3(1.4, 1.1, 0.1), Vector3(2.4, 2.0, -4.45), Color(0.9, 0.85, 0.5))

	lamp = OmniLight3D.new()
	lamp.name = "Lamp"
	lamp.position = Vector3(0, 2.6, -4.0)
	lamp.light_energy = 3.0
	lamp.omni_range = 7.0
	lamp.visible = false
	add_child(lamp)
	Props.box(self, "LampBulb", Vector3(0.25, 0.25, 0.25), Vector3(0, 2.6, -4.3), Color(1, 0.95, 0.6))
	Props.trigger_box(self, Vector3(3.2, 2, 2.4), Vector3(0, 1, -3.6), &"deliver")

	shelter = Props.box(self, "Shelter", Vector3(1.6, 1.0, 1.6), SHELTER_POS, Color(0.7, 0.2, 0.15))
	Props.trigger_box(self, Vector3(3.5, 2, 3.5), SHELTER_POS + Vector3(0, 0.5, 0), &"offer:decoy")

	guard = MeshInstance3D.new()
	guard.name = "Guard"
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.0
	guard.mesh = capsule
	guard.material_override = Props.mat(Color(0.45, 0.28, 0.12))
	guard.position = Vector3(-2.5, 0.5, -1.0)
	add_child(guard)

	var pad := BumpProp.new()
	pad.name = "BumpPad"
	pad.relay = &"treat_out"
	pad.position = Vector3(5, 0.6, -1)
	Props.box(pad, "Mesh", Vector3(0.7, 0.7, 1.1), Vector3.ZERO, Color(0.2, 0.3, 0.8))
	var bump := Area3D.new()
	bump.name = "BumpArea"
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.8, 2.0, 2.2)
	cs.shape = shape
	bump.add_child(cs)
	pad.add_child(bump)
	pad.bump_area = bump
	add_child(pad)

	treat = Props.box(self, "TreatProp", Vector3(0.7, 0.2, 0.2), Vector3(5.9, 0.3, -1), Color(0.98, 0.96, 0.85))
	decoy = Props.box(self, "DecoyProp", Vector3(0.5, 0.4, 0.5), Vector3(-4.8, 0.25, -2.2), Color(0.2, 0.75, 0.25))
	reward = Props.box(self, "RewardProp", Vector3(0.6, 0.6, 0.6), Vector3(0.9, 0.5, -3.6), Color(0.85, 0.1, 0.3))
	for p in [treat, decoy, reward]:
		p.visible = false

func _restore_state() -> void:
	if get_var(&"guard_calmed"):
		guard.position = SHELTER_POS + GUARD_REST_OFFSET
	if fired.has(&"z1_delivered"):
		reward.visible = true
