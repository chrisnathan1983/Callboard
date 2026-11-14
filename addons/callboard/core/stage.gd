@tool
class_name Stage extends Node3D
## Scene host for the Blackboard, rule engine and verb factory.

signal rule_fired(rule_id: StringName, event: StringName)
signal scored(points: int)
signal gameplay_event(event_id: StringName, arguments: Dictionary)
signal var_changed(key: StringName, value: Variant)

@export var definition: StageDefinition
var saved_vars := {}    # injected by the manager; survives unloads
var fired := {}         # injected by the manager; stores one-shot latches
var shared_vars: Dictionary = {}
var state_store: StageStateStore
var stage_instance_id: StringName
var managed_lifecycle := false
var is_active := false
var bb: Blackboard
var engine: RuleEngine
var verbs: CoreVerbs
var graph_errors: Array[String] = []

## Call IDs, external relay event IDs, and keys supplied by gameplay code.
var external_calls: Array[StringName] = [&"arrive"]
var external_vars: Array[StringName] = []
var external_writers: Array[BlackboardWriterData] = []
var payload_schema: Dictionary = {}

func _enter_tree() -> void:
	if definition != null:
		managed_lifecycle = definition.managed_lifecycle

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	build()
	_restore_state()
	_apply_restoration_bindings()

## Also used on an unparented instance by the Callboard.
func build() -> void:
	_create_runtime_services()
	_build_props()
	if definition:
		definition.apply_blackboard(self)
		managed_lifecycle = definition.managed_lifecycle
	collect_scene_blackboard_writers()
	_declare_external_writers()
	_build_blackboard()
	if definition:
		graph_errors = definition.apply_graph(self)

## Override only when `_build_props()` is independent of authored graph and Blackboard
## data, and the props remain valid across repeated analysis passes.
func can_reuse_analysis_props() -> bool:
	return false

## Configure state before the Stage enters the tree so saved values and latches
## exist when its Blackboard and graph are built.
func attach_state_store(store: StageStateStore, instance_id: StringName,
		p_saved_vars: Dictionary, p_fired: Dictionary, p_shared_vars: Dictionary) -> void:
	state_store = store
	stage_instance_id = instance_id
	saved_vars = p_saved_vars
	fired = p_fired
	shared_vars = p_shared_vars

func accepts_calls() -> bool:
	return not managed_lifecycle or is_active

func _apply_restoration_bindings() -> void:
	if definition == null:
		return
	for binding: StageRestorationBinding in definition.restoration_bindings:
		if binding != null:
			binding.apply(self)

## Reapply an authored draft to a retained editor-analysis scene. Props are built once;
## Blackboard services and the graph are recreated for each validation pass.
func rebuild_for_analysis(draft: StageDefinition) -> bool:
	if not can_reuse_analysis_props():
		return false
	if engine:
		engine.cancel_all()
	saved_vars.clear()
	fired.clear()
	definition = draft
	_create_runtime_services()
	definition.apply_blackboard(self)
	managed_lifecycle = definition.managed_lifecycle
	collect_scene_blackboard_writers()
	_declare_external_writers()
	_build_blackboard()
	graph_errors = definition.apply_graph(self)
	return true

func _create_runtime_services() -> void:
	bb = Blackboard.new(saved_vars, shared_vars)
	bb.changed.connect(var_changed.emit)
	if state_store != null:
		state_store.register_blackboard(bb)
	engine = RuleEngine.new(bb, fired, _wait)
	engine.rule_fired.connect(rule_fired.emit)
	verbs = _make_verbs(StepContext.new(bb, engine, self, scored.emit))

func _make_verbs(context: StepContext) -> CoreVerbs:
	return StagingVerbs.new(context)

func _build_props() -> void: pass
## Declare keys written by gameplay code. Called after Blackboard definitions are applied.
func _declare_external_writers() -> void: pass

## Register a typed external producer. Call from `_declare_external_writers()` or a
## scene component's `callboard_writers` export so editor analysis can see the output.
func register_external_writer(key: StringName, source: StringName = &"gameplay", value_type := "Variant") -> void:
	var writer := BlackboardWriterData.new()
	writer.key = key
	writer.source = source
	writer.value_type = value_type
	for existing: BlackboardWriterData in external_writers:
		if existing.key == writer.key and existing.source == writer.source:
			existing.value_type = writer.value_type
			return
	external_writers.append(writer)

## Gather declarations from scene nodes that export `callboard_writers`.
func collect_scene_blackboard_writers() -> void:
	for node in find_children("*", "Node", true, false):
		for property: Dictionary in node.get_property_list():
			if property.name != "callboard_writers":
				continue
			var declarations: Variant = node.get("callboard_writers")
			if declarations is Array:
				for writer: Variant in declarations:
					if writer is BlackboardWriterData:
						var source: StringName = writer.source if not writer.source.is_empty() else StringName(node.name)
						register_external_writer(writer.key, source, writer.value_type)
			break
## Initialize values after authored defaults and props are available.
func _build_blackboard() -> void: pass
## Restore the resolved look of props from saved state without animation.
func _restore_state() -> void: pass

func activate() -> void:
	if managed_lifecycle and is_active:
		return
	if not graph_errors.is_empty():
		for problem in graph_errors:
			push_error("[%s] %s" % [name, problem])
		return
	if OS.is_debug_build():
		for problem in check():
			push_warning("[%s] %s" % [name, problem])
	if managed_lifecycle:
		is_active = true
	fire(&"arrive")

func deactivate() -> void:
	if managed_lifecycle:
		is_active = false
	if engine != null:
		engine.cancel_all()

func _exit_tree() -> void:
	if engine:
		deactivate()
	if state_store != null:
		if bb != null:
			state_store.unregister_blackboard(bb)
		state_store.release_stage(self)

func _wait(seconds: float) -> Signal:
	return get_tree().create_timer(seconds, false).timeout

func define_saved(key: StringName, default_val: Variant = false, state_key: StringName = &"") -> void:
	bb.define(key, &"saved", default_val, state_key)

func define_shared(key: StringName, default_val: Variant = false, state_key: StringName = &"") -> void:
	bb.define(key, &"shared", default_val, state_key)

func define_local(key: StringName, default_val: Variant = false, state_key: StringName = &"") -> void:
	bb.define(key, &"local", default_val, state_key)

func get_var(key: StringName) -> Variant:
	return bb.get_var(key)

func write_var(key: StringName, value: Variant, writer: StringName = &"") -> void:
	if writer.is_empty():
		for declaration: BlackboardWriterData in external_writers:
			if declaration.key == bb.resolve_key(key):
				writer = declaration.source
				break
	bb.write(key, value, writer)

func is_set(key: StringName) -> bool:
	return bb.is_set(key)

func has_fired(rule_id: StringName) -> bool:
	for rule: Rule in engine.rules:
		if rule.id == rule_id:
			return fired.has(rule.latch_key())
	return fired.has(rule_id)

func fire(event: StringName, payload := {}) -> void:
	if not accepts_calls():
		return
	if OS.is_debug_build() and not _event_is_known(event):
		push_warning("Stage '%s' fired unknown event '%s'. Declare gameplay events in external_calls." % [name, event])
	engine.fire(event, payload)

## Publish a typed request for host gameplay code. The Stage does not interpret event IDs.
func publish_gameplay_event(event_id: StringName, arguments: Dictionary = {}) -> void:
	if not accepts_calls():
		return
	if event_id.is_empty():
		if OS.is_debug_build():
			push_warning("Stage '%s' cannot publish a gameplay event with an empty ID." % name)
		return
	gameplay_event.emit(event_id, arguments.duplicate(true))

## Use a declared Boolean Blackboard key to latch a relay fired by gameplay code.
func fire_relay_once(relay: StringName, latch: StringName, source_id: StringName, source_event: StringName) -> bool:
	if bb == null or relay.is_empty() or not accepts_calls():
		return false
	if not bb.has(latch):
		if OS.is_debug_build():
			push_warning("Stage '%s' cannot fire relay '%s': latch key '%s' is not declared." % [name, relay, latch])
		return false
	if bb.schema[bb.resolve_key(latch)]["type"] != TYPE_BOOL:
		if OS.is_debug_build():
			push_warning("Stage '%s' cannot fire relay '%s': latch key '%s' must be Boolean." % [name, relay, latch])
		return false
	if is_set(latch):
		return false
	write_var(latch, true, source_id)
	rule_fired.emit(source_id, source_event)
	fire(StringName("relay:" + relay))
	return true

func _event_is_known(event: StringName) -> bool:
	if external_calls.has(event):
		return true
	for rule: Rule in engine.rules:
		if rule.trigger == event:
			return true
		if event == StringName("relay:" + String(rule.emits)) and not rule.emits.is_empty():
			return true
		for step: Step in rule.steps:
			if not step.emits.is_empty() and event == StringName("relay:" + String(step.emits)):
				return true
	return false

func check() -> Array[String]:
	var problems := RuleValidator.check(engine.rules, bb, external_calls, external_vars, payload_schema, external_writers)
	if state_store != null:
		problems.append_array(state_store.shared_schema_errors(bb))
	if verbs is StagingVerbs:
		for rule: Rule in engine.rules:
			for step: Step in rule.steps:
				problems.append_array((verbs as StagingVerbs).validate_step(rule.id, step, bb))
	var seen_fields := {}
	for field: PayloadFieldData in definition.payload_fields if definition != null else []:
		if not field.key.is_valid_identifier() or field.key in [&"payload", &"_callboard"]:
			problems.append("payload field '%s' has an invalid name" % field.key)
		var pair := "%s.%s" % [field.event_id, field.key]
		if seen_fields.has(pair):
			problems.append("payload field '%s' is declared more than once for '%s'" % [field.key, field.event_id])
		seen_fields[pair] = true
		if field.type_name not in ["bool", "int", "float", "String"]:
			problems.append("payload field '%s' for '%s' has an unsupported type '%s'" % [field.key, field.event_id, field.type_name])
		if not _event_is_known(field.event_id):
			problems.append("payload schema refers to unknown Call or relay '%s'" % field.event_id)
	for binding: StageRestorationBinding in definition.restoration_bindings if definition != null else []:
		if binding != null:
			problems.append_array(binding.validate(self))
	return problems
