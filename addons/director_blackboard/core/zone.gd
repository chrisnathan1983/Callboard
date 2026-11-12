@tool
class_name Zone extends Node3D
## Event router + Blackboard host + verb library + validator.
## A zone can load its authored events, Blackboard and rules from a ZoneDefinition.

signal rule_fired(rule_id: StringName, event: StringName)
signal scored(points: int)
signal var_changed(key: StringName, value: Variant)

@export var definition: ZoneDefinition
var rules: Array[Rule] = []
var graph_errors: Array[String] = []

# --- Blackboard -------------------------------------------------------------------
#var schema := {}        # key -> {"scope": &"saved"|&"local", "default": Variant}
#var local_vars := {}    # ephemeral: reset when the zone unloads
var saved_vars := {}    # injected by the manager; survives unloads
var fired := {}         # injected by the manager; latches `once` rules
#var _saved_keys := {}
var bb: Blackboard

## Events that come from outside the rules (props, input, the manager). Zones list theirs.
var external_events: Array[StringName] = [&"arrive"]
## Blackboard keys written outside the rules (by prefab scripts, for example).
var external_vars: Array[StringName] = []
var _gen := 0           # bump on deactivate to cancel pending work

# --- Lifecycle --------------------------------------------------------------------

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	build()
	_restore_state()

## Props, then Blackboard, then rules. The Rule Board calls this on an unparented
## instance to inspect a zone without running it.
func build() -> void:
	bb = Blackboard.new(saved_vars)
	_build_props()
	if definition:
		definition.apply_blackboard(self)
		#_build_blackboard()
		graph_errors = definition.apply_graph(self)
	else:
		#_build_blackboard()
		_build_rules()

func _build_props() -> void: pass
## For resource-backed zones, initialize values here after the authored defaults load.
func _build_blackboard() -> void: pass
func _build_rules() -> void: pass
## Prop-driven restore: saved state decides a prop's resolved look on load, no animation.
func _restore_state() -> void: pass

func activate() -> void:
	if not graph_errors.is_empty():
		for problem in graph_errors:
			push_error("[%s] %s" % [name, problem])
		return
	if OS.is_debug_build():
		for problem in validate():
			push_error("[%s] %s" % [name, problem])
	fire(&"arrive")

func deactivate() -> void:
	_gen += 1

# --- Blackboard API ---------------------------------------------------------------

func define_saved(key: StringName, default_val: Variant = false) -> void:
	bb.define(key, &"saved", default_val)
	# _saved_keys[key] = true
	# schema[key] = {"scope": &"saved", "default": default_val}
	# if not saved_vars.has(key):
	# 	saved_vars[key] = default_val

func define_local(key: StringName, default_val: Variant = false) -> void:
	bb.define(key, &"local", default_val)
	# schema[key] = {"scope": &"local", "default": default_val}
	# local_vars[key] = default_val

func get_var(key: StringName) -> Variant:
	return bb.get_var(key)
	#return saved_vars.get(key) if _saved_keys.has(key) else local_vars.get(key)

func write_var(key: StringName, value: Variant) -> void:
	bb.write(key, value)
	# if _saved_keys.has(key):
	# 	saved_vars[key] = value
	# else:
	# 	local_vars[key] = value
	# var_changed.emit(key, value)

func is_set(key: StringName) -> bool:
	return bb.is_set(key)
	# return bool(get_var(key))

# --- Router -----------------------------------------------------------------------

func rule(id: StringName, trigger: StringName) -> Rule:
	var r := Rule.new(id, trigger)
	rules.append(r)
	return r

func fire(event: StringName, ctx := {}) -> void:
	for r in rules:
		if r.trigger == event and passes(r):
			_run(r, event, ctx)

func _run(r: Rule, event: StringName, ctx: Dictionary) -> void:
	if r.once:
		fired[r.id] = true   # latch immediately so converging paths cannot double-fire
	rule_fired.emit(r.id, event)
	var gen := _gen
	var c := ctx.merged({"_rule": r})
	for s in r.steps:
		if s.delay > 0.0:
			await get_tree().create_timer(s.delay).timeout
			if not alive(r, gen): return
		await s.fn.call(c)
		if not alive(r, gen): return
	if r.emits != &"":
		fire("relay:" + r.emits, ctx)

## Fire-time guard: checked once, when the trigger arrives.
func passes(r: Rule) -> bool:
	if r.once and fired.has(r.id):
		return false
	return r.requires.all(is_set) and not r.forbids.any(is_set)

## Mid-flight guard: checked after every await.
func alive(r: Rule, gen: int) -> bool:
	return gen == _gen and not r.cancel_if.any(is_set)

# --- Validator --------------------------------------------------------------------

## Returns human-readable problems; empty means the wiring is consistent.
## Messages quote rule ids as 'id' so the Rule Board can badge the right card.
func validate() -> Array[String]:
	var problems: Array[String] = []
	var emitted := {}
	var settable := {}
	var seen := {}
	for k in external_vars:
		settable[k] = true
	for r in rules:
		if seen.has(r.id):
			problems.append("duplicate rule id '%s'" % r.id)
		seen[r.id] = true
		if r.emits != &"":
			emitted["relay:" + r.emits] = true
		for s in r.steps:
			if s.emits != &"":
				emitted["relay:" + s.emits] = true
			for k in s.sets:
				settable[k] = true
				if not bb.has(k):
					problems.append("rule '%s' writes '%s' which is not declared on the Blackboard" % [r.id, k])
	for r in rules:
		if r.trigger == &"":
			problems.append("rule '%s' has no trigger" % r.id)
		elif not emitted.has(r.trigger) and not external_events.has(r.trigger):
			problems.append("rule '%s' listens to '%s' but nothing emits it and it is not a declared external event" % [r.id, r.trigger])
		for k in r.requires + r.forbids + r.cancel_if:
			if not bb.has(k):
				problems.append("rule '%s' checks key '%s' which is not declared on the Blackboard" % [r.id, k])
			elif not settable.has(k):
				problems.append("rule '%s' checks key '%s' but nothing sets it" % [r.id, k])
		for s in r.steps:
			if s.args.has(null):
				problems.append("rule '%s' has a '%s' step with an unset prop" % [r.id, s.verb])
		if r.steps.is_empty() and r.emits == &"":
			problems.append("rule '%s' does nothing (no steps, no emit)" % r.id)
	for event in emitted:
		if not rules.any(func(x: Rule) -> bool: return x.trigger == event):
			problems.append("'%s' is emitted but no rule listens to it" % event)
	return problems

# --- Verbs: each returns a Step ---------------------------------------------------

func _step(verb: StringName, args: Array, fn: Callable) -> Step:
	var s := Step.new(fn)
	s.verb = verb
	s.args = args
	return s

func show_node(n: Node3D, should_be_visible := true) -> Step:
	return _step(&"show_node", [n, should_be_visible], func(_c: Dictionary) -> void: n.visible = should_be_visible)

func pop(n: Node3D) -> Step:
	var f := func(_c: Dictionary) -> void:
		n.scale = Vector3.ZERO
		var t := create_tween()
		t.tween_property(n, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		await t.finished   # the next step runs when the animation actually ends
	return _step(&"pop", [n], f)

func bounce(n: Node3D) -> Step:
	var f := func(_c: Dictionary) -> void:
		var t := create_tween()
		t.tween_property(n, "scale", Vector3(1.25, 0.75, 1.25), 0.1)
		t.tween_property(n, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BOUNCE)
		await t.finished
	return _step(&"bounce", [n], f)

## Switches a light and mirrors it into a local Blackboard key. duration > 0 switches it
## off again later (non-blocking).
func light(n: Node3D, on: bool, duration := 0.0, key: StringName = &"lamp_on") -> Step:
	var apply := func(value: bool) -> void:
		n.visible = value
		write_var(key, value)
	var f := func(_c: Dictionary) -> void:
		apply.call(on)
		if on and duration > 0.0:
			var gen := _gen
			get_tree().create_timer(duration).timeout.connect(func() -> void:
				if is_instance_valid(self) and gen == _gen:
					apply.call(false))
	var s := _step(&"light", [n, on, duration, key], f)
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
	return _step(&"say", [n, text, seconds], f)

func move_to(n: Node3D, dest: Node3D, offset := Vector3.ZERO, duration := 0.7) -> Step:
	var f := func(_c: Dictionary) -> void:
		var t := create_tween()
		t.tween_property(n, "global_position", dest.global_position + offset, duration)
		await t.finished
	return _step(&"move_to", [n, dest, offset, duration], f)

## Tints the mesh's material_override.
func flash(m: MeshInstance3D) -> Step:
	var f := func(_c: Dictionary) -> void:
		var material := m.material_override as StandardMaterial3D
		var base := material.albedo_color
		material.albedo_color = Color(1, 0.15, 0.15)
		var t := create_tween()
		t.tween_property(material, "albedo_color", base, 0.8)
		await t.finished
	return _step(&"flash", [m], f)

func jump(m: MeshInstance3D) -> Step:
	var f := func(_c: Dictionary) -> void:
		var material := m.material_override as StandardMaterial3D
		material.albedo_color = Color(1, 0.9, 0.3)
		var y := m.position.y
		var t := create_tween()
		t.tween_property(m, "position:y", y + 0.6, 0.15)
		t.tween_property(m, "position:y", y, 0.25).set_trans(Tween.TRANS_BOUNCE)
		await t.finished
	return _step(&"jump", [m], f)

## Writes a Blackboard key. Saved or local is decided by how the key was declared.
func set_var(key: StringName, value: Variant = true) -> Step:
	var s := _step(&"set_var", [key, value], func(_c: Dictionary) -> void: write_var(key, value))
	s.sets = [key]
	return s

func score(points: int) -> Step:
	return _step(&"score", [points], func(_c: Dictionary) -> void: scored.emit(points))

func stun_player(seconds: float) -> Step:
	var f := func(_c: Dictionary) -> void:
		var p := get_tree().get_first_node_in_group(&"Player")
		if p:
			p.stun(seconds)   # not awaited: the stun runs on its own
	return _step(&"stun_player", [seconds], f)

## Fires "relay:<tick>" every interval. Stops when the zone deactivates or any of the
## running rule's cancel_if keys becomes truthy.
func repeat_emit(interval: float, tick: StringName) -> Step:
	var f := func(c: Dictionary) -> void:
		var r: Rule = c["_rule"]
		var gen := _gen
		while alive(r, gen):
			await get_tree().create_timer(interval).timeout
			if alive(r, gen):
				fire("relay:" + tick, c)
	var s := _step(&"repeat_emit", [interval, tick], f)
	s.emits = tick
	return s
