@tool
class_name StagingVerbs extends CoreVerbs
## Steps that stage props and actors in the scene.

const COLOR_TWEEN_META := &"_callboard_color_tween"
const BASE_COLOR_META := &"_callboard_base_color"
const LIGHT_ACTIVATION_META := &"_callboard_light_activation"
const SPEECH_LABEL_NAME := &"CallboardSpeech"
const SPEECH_TWEEN_META := &"_callboard_speech_tween"
const POSITION_TWEEN_META := &"_callboard_position_tween"
const BASE_Y_META := &"_callboard_base_y"

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
## off again on timeout or cancellation (non-blocking).
func _light(n: Node3D, on: bool, duration: float, key: StringName) -> Step:
	var ctx := context
	var f := func(c: Dictionary) -> void:
		var engine := ctx.engine_ref.get_ref() as RuleEngine
		var rule := c.get("_rule") as Rule
		var gen := engine.token()
		var rule_id := StringName(rule.id) if rule != null else &"<anonymous>"
		var node_id := n.get_instance_id()
		var activation := int(n.get_meta(LIGHT_ACTIVATION_META, 0)) + 1
		n.set_meta(LIGHT_ACTIVATION_META, activation)
		n.visible = on
		ctx.bb.write(key, on)
		if on and duration > 0.0 and (rule == null or engine.alive(rule, gen)):
			var on_run_cancelled := Callable()
			var turn_off := Callable()
			turn_off = func() -> void:
				var current := ctx.engine_ref.get_ref() as RuleEngine
				if current != null:
					if on_run_cancelled.is_valid() and current.run_cancelled.is_connected(on_run_cancelled):
						current.run_cancelled.disconnect(on_run_cancelled)
					if turn_off.is_valid() and current.all_cancelled.is_connected(turn_off):
						current.all_cancelled.disconnect(turn_off)
				var light_node := instance_from_id(node_id) as Node3D
				if light_node != null and light_node.get_meta(LIGHT_ACTIVATION_META, 0) == activation:
					light_node.set_meta(LIGHT_ACTIVATION_META, activation + 1)
					light_node.hide()
					ctx.bb.write(key, false)
			var run: Dictionary = c.get("_run", {})
			on_run_cancelled = func(cancelled_rule_id: StringName) -> void:
				if cancelled_rule_id == rule_id and run.get("cancelled", false):
					turn_off.call()
			if rule != null:
				engine.run_cancelled.connect(on_run_cancelled)
			engine.all_cancelled.connect(turn_off, CONNECT_ONE_SHOT)
			var timeout: Signal = engine.wait_tracked(duration, rule_id, "light off")
			timeout.connect(func() -> void:
				turn_off.call(), CONNECT_ONE_SHOT)
	var s := Step.new(f)
	s.sets = [key]
	return s

## Floating text over a prop. Non-blocking.
func say(n: Node3D, text: String, seconds := 1.0) -> Step:
	var f := func(_c: Dictionary) -> void:
		var label := n.get_node_or_null(NodePath(SPEECH_LABEL_NAME)) as Label3D
		if label == null:
			label = Label3D.new()
			label.name = SPEECH_LABEL_NAME
			n.add_child(label)
		else:
			var previous: Tween = label.get_meta(SPEECH_TWEEN_META) if label.has_meta(SPEECH_TWEEN_META) else null
			if previous and previous.is_running():
				previous.kill()
		label.text = text
		label.font_size = 96
		label.pixel_size = 0.01
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.position = Vector3(0, 1.6, 0)
		var t := label.create_tween()
		t.tween_interval(seconds)
		t.tween_callback(label.queue_free)
		label.set_meta(SPEECH_TWEEN_META, t)
	return Step.new(f)

func move_to(n: Node3D, dest: Node3D, offset := Vector3.ZERO, duration := 0.7) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> Signal:
		_kill_node_tween(n, POSITION_TWEEN_META)
		var target_global := dest.global_position + offset
		var parent := n.get_parent_node_3d()
		var target_local := target_global if parent == null or n.top_level else parent.to_local(target_global)
		n.set_meta(BASE_Y_META, target_local.y)
		var t := host.create_tween()
		n.set_meta(POSITION_TWEEN_META, t)
		t.tween_property(n, "global_position", target_global, duration)
		return t.finished
	return Step.new(f)

## Tints the mesh's material_override.
func flash(m: MeshInstance3D) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> Signal:
		var material := _effect_material(m, "flash")
		if material == null:
			return host.get_tree().process_frame
		var base := _base_color(m, material)
		var tint := Color(1, 0.15, 0.15)
		material.albedo_color = tint
		var t := host.create_tween()
		t.tween_method(_color_setter(m, material, t), tint, base, 0.8)
		return t.finished
	return Step.new(f)

func jump(m: MeshInstance3D) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> Signal:
		var material := _effect_material(m, "jump")
		if material == null:
			return host.get_tree().process_frame
		var base := _base_color(m, material)
		var tint := Color(1, 0.9, 0.3)
		var color_tween := host.create_tween()
		var set_color := _color_setter(m, material, color_tween)
		color_tween.tween_method(set_color, base, tint, 0.08)
		color_tween.tween_method(set_color, tint, base, 0.32)
		var previous: Tween = m.get_meta(POSITION_TWEEN_META) if m.has_meta(POSITION_TWEEN_META) else null
		var y := m.position.y
		if previous and previous.is_running() and m.has_meta(BASE_Y_META):
			y = float(m.get_meta(BASE_Y_META))
		_kill_node_tween(m, POSITION_TWEEN_META)
		m.set_meta(BASE_Y_META, y)
		var t := host.create_tween()
		m.set_meta(POSITION_TWEEN_META, t)
		t.tween_property(m, "position:y", y + 0.6, 0.15)
		t.tween_property(m, "position:y", y, 0.25).set_trans(Tween.TRANS_BOUNCE)
		return t.finished
	return Step.new(f)

func _kill_node_tween(node: Node, meta: StringName) -> void:
	if not is_instance_valid(node) or not node.has_meta(meta):
		return
	var previous: Variant = node.get_meta(meta)
	if previous is Tween and previous.is_running():
		previous.kill()

func _effect_material(m: MeshInstance3D, verb: String) -> BaseMaterial3D:
	if not is_instance_valid(m):
		push_warning("Callboard %s skipped: mesh is no longer valid." % verb)
		return null
	var material := m.material_override as BaseMaterial3D
	if material == null:
		push_warning("Callboard %s skipped: '%s' has no BaseMaterial3D material_override." % [verb, m.name])
	return material

func _base_color(m: MeshInstance3D, material: BaseMaterial3D) -> Color:
	var saved: Dictionary = m.get_meta(BASE_COLOR_META) if m.has_meta(BASE_COLOR_META) else {}
	if saved.get("material_id") != material.get_instance_id():
		saved = {"material_id": material.get_instance_id(), "color": material.albedo_color}
		m.set_meta(BASE_COLOR_META, saved)
	return saved["color"]

## Replacing the tint leaves earlier tweens free to finish and resume waiting rules.
func _color_setter(mesh: MeshInstance3D, material: BaseMaterial3D, tween: Tween) -> Callable:
	var mesh_id := mesh.get_instance_id()
	var tween_id := tween.get_instance_id()
	mesh.set_meta(COLOR_TWEEN_META, tween_id)
	return func(color: Color) -> void:
		var current_mesh := instance_from_id(mesh_id) as MeshInstance3D
		if current_mesh != null and current_mesh.get_meta(COLOR_TWEEN_META, 0) == tween_id:
			material.albedo_color = color
