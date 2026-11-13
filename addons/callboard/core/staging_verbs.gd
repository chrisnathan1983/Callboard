@tool
class_name StagingVerbs extends CoreVerbs
## Steps that stage props and actors in the scene.

const COLOR_TWEEN_META := &"_callboard_color_tween"
const BASE_COLOR_META := &"_callboard_base_color"
const SPEECH_LABEL_NAME := &"CallboardSpeech"
const SPEECH_TWEEN_META := &"_callboard_speech_tween"

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
	var f := func(c: Dictionary) -> void:
		var engine := ctx.engine_ref.get_ref() as RuleEngine
		var rule := c.get("_rule") as Rule
		var gen := engine.token()
		apply.call(on)
		if on and duration > 0.0 and engine.alive(rule, gen):
			var timeout: Signal = ctx.wait.call(duration)
			timeout.connect(func() -> void:
				var current := ctx.engine_ref.get_ref() as RuleEngine
				if current and current.alive(rule, gen) and is_instance_valid(n):
					apply.call(false), CONNECT_ONE_SHOT)
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
		var t := host.create_tween()
		t.tween_property(n, "global_position", dest.global_position + offset, duration)
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
		_kill_tween(m, COLOR_TWEEN_META)
		material.albedo_color = Color(1, 0.15, 0.15)
		var t := host.create_tween()
		t.tween_property(material, "albedo_color", base, 0.8)
		m.set_meta(COLOR_TWEEN_META, t)
		t.tween_callback(func() -> void:
			if is_instance_valid(m) and m.get_meta(COLOR_TWEEN_META, null) == t:
				m.remove_meta(COLOR_TWEEN_META))
		return t.finished
	return Step.new(f)

func jump(m: MeshInstance3D) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> Signal:
		var material := _effect_material(m, "jump")
		if material == null:
			return host.get_tree().process_frame
		var base := _base_color(m, material)
		_kill_tween(m, COLOR_TWEEN_META)
		var color_tween := host.create_tween()
		color_tween.tween_property(material, "albedo_color", Color(1, 0.9, 0.3), 0.08).from(base)
		color_tween.tween_property(material, "albedo_color", base, 0.32)
		m.set_meta(COLOR_TWEEN_META, color_tween)
		color_tween.tween_callback(func() -> void:
			if is_instance_valid(m) and m.get_meta(COLOR_TWEEN_META, null) == color_tween:
				m.remove_meta(COLOR_TWEEN_META))
		var y := m.position.y
		var t := host.create_tween()
		t.tween_property(m, "position:y", y + 0.6, 0.15)
		t.tween_property(m, "position:y", y, 0.25).set_trans(Tween.TRANS_BOUNCE)
		return t.finished
	return Step.new(f)

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

func _kill_tween(node: Node, key: StringName) -> void:
	if not node.has_meta(key):
		return
	var previous: Tween = node.get_meta(key)
	if previous and previous.is_running():
		previous.kill()

func stun_player(seconds: float) -> Step:
	var host := context.host
	var f := func(_c: Dictionary) -> void:
		var p := host.get_tree().get_first_node_in_group(&"Player")
		if p:
			p.stun(seconds)   # not awaited: the stun runs on its own
	return Step.new(f)
