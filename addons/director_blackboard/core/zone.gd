@tool
class_name Zone extends Node3D
## Scene host for the Blackboard, rule engine and verb factory.

signal rule_fired(rule_id: StringName, event: StringName)
signal scored(points: int)
signal var_changed(key: StringName, value: Variant)

@export var definition: ZoneDefinition
var saved_vars := {}    # injected by the manager; survives unloads
var fired := {}         # injected by the manager; latches once rules
var bb: Blackboard
var engine: RuleEngine
var verbs: CoreVerbs
var graph_errors: Array[String] = []

## Events and keys supplied by gameplay code outside the rules.
var external_events: Array[StringName] = [&"arrive"]
var external_vars: Array[StringName] = []

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	build()
	_restore_state()

## Also used on an unparented instance by the Rule Board.
func build() -> void:
	bb = Blackboard.new(saved_vars)
	bb.changed.connect(var_changed.emit)
	engine = RuleEngine.new(bb, fired, _wait)
	engine.rule_fired.connect(rule_fired.emit)
	verbs = _make_verbs(StepContext.new(bb, engine, self, scored.emit))
	_build_props()
	if definition:
		definition.apply_blackboard(self)
	_build_blackboard()
	if definition:
		graph_errors = definition.apply_graph(self)
	else:
		_build_rules()

func _make_verbs(context: StepContext) -> CoreVerbs:
	return StagingVerbs.new(context)

func _build_props() -> void: pass
## Initialize values after authored defaults and props are available.
func _build_blackboard() -> void: pass
func _build_rules() -> void: pass
## Restore the resolved look of props from saved state without animation.
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
	engine.cancel_all()

func _exit_tree() -> void:
	if engine:
		deactivate()

func _wait(seconds: float) -> Signal:
	return get_tree().create_timer(seconds).timeout

func define_saved(key: StringName, default_val: Variant = false, state_key: StringName = &"") -> void:
	bb.define(key, &"saved", default_val, state_key)

func define_local(key: StringName, default_val: Variant = false, state_key: StringName = &"") -> void:
	bb.define(key, &"local", default_val, state_key)

func get_var(key: StringName) -> Variant:
	return bb.get_var(key)

func write_var(key: StringName, value: Variant) -> void:
	bb.write(key, value)

func is_set(key: StringName) -> bool:
	return bb.is_set(key)

func fire(event: StringName, ctx := {}) -> void:
	engine.fire(event, ctx)

## Use a declared Blackboard key to latch a relay fired by gameplay code.
func fire_relay_once(relay: StringName, latch: StringName, source_id: StringName, source_event: StringName) -> bool:
	if bb == null or relay.is_empty() or not bb.has(latch) or is_set(latch):
		return false
	write_var(latch, true)
	rule_fired.emit(source_id, source_event)
	fire(StringName("relay:" + relay))
	return true

func validate() -> Array[String]:
	return RuleValidator.validate(engine.rules, bb, external_events, external_vars)

# Script-authored rules call these methods directly. Resource rules use the factory.
func rule(id: StringName, trigger: StringName) -> Rule:
	var r := Rule.new(id, trigger)
	engine.rules.append(r)
	return r

func _legacy_verb(verb: StringName, args: Array) -> Step:
	var step: Step = verbs.callv(verb, args)
	step.verb = verb
	step.args = args
	return step

func show_node(n: Node3D, should_be_visible := true) -> Step:
	return _legacy_verb(&"show_node", [n, should_be_visible])

func pop(n: Node3D) -> Step:
	return _legacy_verb(&"pop", [n])

func bounce(n: Node3D) -> Step:
	return _legacy_verb(&"bounce", [n])

func light(n: Node3D, on: bool, duration := 0.0, key: StringName = &"lamp_on") -> Step:
	return _legacy_verb(&"light", [n, on, duration, key])

func say(n: Node3D, text: String, seconds := 1.0) -> Step:
	return _legacy_verb(&"say", [n, text, seconds])

func move_to(n: Node3D, dest: Node3D, offset := Vector3.ZERO, duration := 0.7) -> Step:
	return _legacy_verb(&"move_to", [n, dest, offset, duration])

func flash(m: MeshInstance3D) -> Step:
	return _legacy_verb(&"flash", [m])

func jump(m: MeshInstance3D) -> Step:
	return _legacy_verb(&"jump", [m])

func set_var(key: StringName, value: Variant = true) -> Step:
	return _legacy_verb(&"set_var", [key, value])

func score(points: int) -> Step:
	return _legacy_verb(&"score", [points])

func stun_player(seconds: float) -> Step:
	return _legacy_verb(&"stun_player", [seconds])

func repeat_emit(interval: float, tick: StringName) -> Step:
	return _legacy_verb(&"repeat_emit", [interval, tick])
