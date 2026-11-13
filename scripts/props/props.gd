@tool
class_name Props extends RefCounted
## Tiny shared helpers for building placeholder props in code.

static func mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m

static func box(parent: Node, node_name: String, size: Vector3, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat(c)
	mi.position = pos
	parent.add_child(mi)
	return mi

## An E-to-interact area that fires `event` on the owning Stage.
static func trigger_box(parent: Node, size: Vector3, pos: Vector3, event: StringName, ctx: Dictionary = {}) -> TriggerArea:
	var area := TriggerArea.new()
	area.event = event
	area.mode = TriggerArea.Mode.INTERACT
	area.ctx = ctx
	area.position = pos
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	area.add_child(cs)
	parent.add_child(area)
	return area
