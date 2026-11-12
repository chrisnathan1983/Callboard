@tool
class_name Stage extends Node3D
## Scene host for the Blackboard, rule engine and verb factory.

signal rule_fired(rule_id: StringName, event: StringName)
signal scored(points: int)
signal var_changed(key: StringName, value: Variant)

@export var definition: StageDefinition
var saved_vars := {}    # injected by the manager; survives unloads
var fired := {}         # injected by the manager; stores one-shot latches
var bb: Blackboard
var engine: RuleEngine
var verbs: CoreVerbs
var graph_errors: Array[String] = []

## Events and keys supplied by gameplay code outside the rules.
var external_calls: Array[StringName] = [&"arrive"]
var external_vars: Array[StringName] = []

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	build()
	_restore_state()

## Also used on an unparented instance by the Callboard.
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

func _make_verbs(context: StepContext) -> CoreVerbs:
	return StagingVerbs.new(context)

func _build_props() -> void: pass
## Initialize values after authored defaults and props are available.
func _build_blackboard() -> void: pass
## Restore the resolved look of props from saved state without animation.
func _restore_state() -> void: pass

func activate() -> void:
	if not graph_errors.is_empty():
		for problem in graph_errors:
			push_error("[%s] %s" % [name, problem])
		return
	if OS.is_debug_build():
		for problem in check():
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

func check() -> Array[String]:
	return RuleValidator.check(engine.rules, bb, external_calls, external_vars)
