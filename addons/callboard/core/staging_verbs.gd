@tool
class_name StagingVerbs extends CoreVerbs
## Steps that stage props and actors in the scene.

func show_node(n: Node3D, should_be_visible := true) -> Step:
	return Step.new(func(_c: Dictionary) -> void: n.visible = should_be_visible)

func pop(n: Node3D) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> Signal:
		n.scale = Vector3.ZERO
		var t := host.create_tween()
		t.tween_property(n, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		return t.finished   # the next step runs when the animation actually ends
	return Step.new(f)

func bounce(n: Node3D) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> Signal:
		var t := host.create_tween()
		t.tween_property(n, "scale", Vector3(1.25, 0.75, 1.25), 0.1)
		t.tween_property(n, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BOUNCE)
		return t.finished
	return Step.new(f)

## Switches a light and mirrors it into a local Blackboard key. duration > 0 switches it
## off again later (non-blocking).
func light(n: Node3D, on: bool, duration := 0.0, key: StringName = &"lamp_on") -> Step:
	var ctx := context
	var apply := func(value: bool) -> void:
		n.visible = value
		ctx.bb.write(key, value)
	var f := func(_c: Dictionary) -> void:
		var engine := ctx.engine_ref.get_ref() as RuleEngine
		var gen := engine.token()
		apply.call(on)
		if on and duration > 0.0 and engine.token() == gen:
			var timeout: Signal = ctx.wait.call(duration)
			timeout.connect(func() -> void:
				var current := ctx.engine_ref.get_ref() as RuleEngine
				if current and current.token() == gen and is_instance_valid(n):
					apply.call(false), CONNECT_ONE_SHOT)
	var s := Step.new(f)
	s.sets = [key]
	return s

## Floating text over a prop. Non-blocking.
func say(n: Node3D, text: String, seconds := 1.0) -> Step:
	var f := func(_c: Dictionary) -> void:
		var label := Label3D.new()
		label.text = text
		label.font_size = 96
		label.pixel_size = 0.01
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.position = Vector3(0, 1.6, 0)
		n.add_child(label)
		var t := label.create_tween()
		t.tween_interval(seconds)
		t.tween_callback(label.queue_free)
	return Step.new(f)

func move_to(n: Node3D, dest: Node3D, offset := Vector3.ZERO, duration := 0.7) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> Signal:
		var t := host.create_tween()
		t.tween_property(n, "global_position", dest.global_position + offset, duration)
		return t.finished
	return Step.new(f)

## Tints the mesh's material_override.
func flash(m: MeshInstance3D) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> Signal:
		var material := m.material_override as StandardMaterial3D
		var base := material.albedo_color
		material.albedo_color = Color(1, 0.15, 0.15)
		var t := host.create_tween()
		t.tween_property(material, "albedo_color", base, 0.8)
		return t.finished
	return Step.new(f)

func jump(m: MeshInstance3D) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> Signal:
		var material := m.material_override as StandardMaterial3D
		material.albedo_color = Color(1, 0.9, 0.3)
		var y := m.position.y
		var t := host.create_tween()
		t.tween_property(m, "position:y", y + 0.6, 0.15)
		t.tween_property(m, "position:y", y, 0.25).set_trans(Tween.TRANS_BOUNCE)
		return t.finished
	return Step.new(f)

func stun_player(seconds: float) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> void:
		var p := host.get_tree().get_first_node_in_group(&"Player")
		if p:
			p.stun(seconds)   # not awaited: the stun runs on its own
	return Step.new(f)
