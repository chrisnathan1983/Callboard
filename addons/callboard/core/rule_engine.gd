@tool
class_name RuleEngine extends RefCounted

signal rule_fired(rule_id: StringName, event: StringName)
signal trace_event(entry: Dictionary)
signal pending_changed(entries: Array)
signal run_cancelled(rule_id: StringName)
signal all_cancelled

class AwaitedSignal extends RefCounted:
	signal completed

var rules: Array[Rule] = []
var fired: Dictionary                 # injected, latches one-shot rules
var bb: Blackboard
var payload_schema: Dictionary = {}
var wait: Callable                    # func(seconds: float) -> Signal; tests swap this
var _gen := 0
var _active := {}                      # Rule -> pending payloads and restart request
var _pending_waits: Dictionary = {}
var _pending_callbacks: Dictionary = {}
var _awaited_signals: Dictionary = {}
var _next_wait_id := 1
const MAX_FIRE_DEPTH := 64

func _init(p_bb: Blackboard, p_fired: Dictionary, p_wait: Callable) -> void:
	bb = p_bb
	fired = p_fired
	wait = p_wait

func token() -> int: return _gen
func cancel_all() -> void:
	_gen += 1
	all_cancelled.emit()
	_active.clear()
	_pending_waits.clear()
	for tracker in _pending_callbacks.values():
		var tracked_signal: Signal = tracker["signal"]
		var callback: Callable = tracker["callback"]
		if not tracked_signal.is_null() and tracked_signal.is_connected(callback):
			tracked_signal.disconnect(callback)
	_pending_callbacks.clear()
	pending_changed.emit(pending_snapshot())
	var cancelled := _awaited_signals.values()
	_awaited_signals.clear()
	for entry: Dictionary in cancelled:
		var source: Signal = entry["source"]
		var callback: Callable = entry["callback"]
		if not source.is_null() and source.is_connected(callback):
			source.disconnect(callback)
		entry["completion"].completed.emit()

func fire(event: StringName, payload := {}) -> void:
	_fire(event, payload, 0)

func _fire(event: StringName, payload: Dictionary, prior_depth: int) -> void:
	var depth := prior_depth + 1
	if depth > MAX_FIRE_DEPTH:
		push_error("Callboard stopped relay recursion at depth %d while firing '%s'." % [MAX_FIRE_DEPTH, event])
		return
	_emit_trace("event_fired", &"", event)
	var gen := _gen
	for r in rules:
		if gen != _gen:
			return
		if r.trigger == event and passes(r, payload, event):
			_dispatch(r, event, payload.duplicate(true), gen, depth)

func _dispatch(r: Rule, event: StringName, payload: Dictionary, gen: int, depth: int) -> void:
	if _active.has(r):
		var active: Dictionary = _active[r]
		var pending: Array[Dictionary] = active["pending"]
		match r.reentry:
			Rule.ReentryPolicy.RESTART:
				active["restart"] = true
				active["run"]["cancelled"] = true
				pending.clear()
				pending.append({"payload": payload.duplicate(true), "depth": depth})
			Rule.ReentryPolicy.QUEUE:
				pending.append({"payload": payload.duplicate(true), "depth": depth})
		return

	var pending: Array[Dictionary] = []
	var active := {"pending": pending, "restart": false}
	_active[r] = active
	await _run(r, event, payload, gen, depth)
	while gen == _gen and not pending.is_empty():
		var next: Dictionary = pending.pop_front()
		active["restart"] = false
		var next_payload: Dictionary = next["payload"]
		if passes(r, next_payload, event) and alive(r, gen, next_payload):
			await _run(r, event, next_payload, gen, int(next["depth"]))
	if gen == _gen:
		_active.erase(r)

func _run(rule: Rule, event: StringName, payload: Dictionary, generation: int, depth: int) -> void:
	# Non-blocking steps can outlive a successful run, so keep cancellation
	# on the run itself even after the rule leaves the active table.
	var run := {"cancelled": false, "payload": payload.duplicate(true), "event": event, "depth": depth}
	_active[rule]["run"] = run
	if rule.one_shot:
		fired[rule.latch_key()] = true
	_emit_trace("rule_started", rule.id, event)
	rule_fired.emit(rule.id, event)
	if not alive(rule, generation):
		_cancel_run(run, rule.id, event)
		return
	var step_payload := payload.duplicate(true)
	step_payload["payload"] = payload.duplicate(true)
	step_payload["_callboard"] = {"rule": rule, "run": run}
	for step_index in rule.steps.size():
		var step := rule.steps[step_index]
		if step.delay > 0.0:
			_emit_trace("delay_started", rule.id, event, step_index, step, "%0.2fs" % step.delay)
			await interruptible(wait_tracked(step.delay, rule.id, "step delay"))
			if not alive(rule, generation, payload):
				_cancel_run(run, rule.id, event, step_index, step)
				return
		_emit_trace("step_started", rule.id, event, step_index, step)
		await step.fn.call(step_payload)
		if not alive(rule, generation, payload):
			_cancel_run(run, rule.id, event, step_index, step)
			return
		_emit_trace("step_completed", rule.id, event, step_index, step)
	if not rule.emits.is_empty():
		_fire("relay:" + rule.emits, payload, depth)
	_emit_trace("rule_completed", rule.id, event)

func _cancel_run(run: Dictionary, rule_id: StringName, event: StringName,
		step_index := -1, step: Step = null) -> void:
	run["cancelled"] = true
	run_cancelled.emit(rule_id)
	_emit_trace("rule_cancelled", rule_id, event, step_index, step)

## Returns the engine's configured wait signal and publishes it to live diagnostics.
func wait_tracked(seconds: float, rule_id: StringName, label: String) -> Signal:
	var timeout: Signal = wait.call(seconds)
	track_signal(timeout, rule_id, label, seconds)
	return timeout

## Completes when the source emits or the engine is deactivated.
func interruptible(source: Signal) -> Signal:
	var completion := AwaitedSignal.new()
	var id := completion.get_instance_id()
	var callback := _complete_wait.bind(id)
	_awaited_signals[id] = {"source": source, "callback": callback, "completion": completion}
	source.connect(callback, CONNECT_ONE_SHOT)
	return completion.completed

func _complete_wait(id: int) -> void:
	var entry: Dictionary = _awaited_signals.get(id, {})
	_awaited_signals.erase(id)
	if not entry.is_empty():
		entry["completion"].completed.emit()

## Tracks an awaited or non-blocking signal until it completes.
func track_signal(signal_to_track: Signal, rule_id: StringName, label: String, seconds := -1.0) -> void:
	var id := _next_wait_id
	_next_wait_id += 1
	_pending_waits[id] = {
		"id": id,
		"rule": String(rule_id),
		"label": label,
		"started_ms": Time.get_ticks_msec(),
		"duration": seconds,
	}
	pending_changed.emit(pending_snapshot())
	var callback := func() -> void: _finish_tracked_signal(id)
	_pending_callbacks[id] = {"signal": signal_to_track, "callback": callback}
	signal_to_track.connect(callback, CONNECT_ONE_SHOT)

func pending_snapshot() -> Array:
	var now := Time.get_ticks_msec()
	var entries: Array = []
	for id in _pending_waits:
		var entry: Dictionary = _pending_waits[id].duplicate()
		var duration: float = entry["duration"]
		entry["remaining"] = maxf(0.0, duration - (now - entry["started_ms"]) / 1000.0) if duration >= 0.0 else -1.0
		entries.append(entry)
	return entries

func active_snapshot() -> Array:
	var entries: Array = []
	for rule: Rule in _active:
		var active: Dictionary = _active[rule]
		entries.append({
			"rule": String(rule.id),
			"queued": active["pending"].size(),
			"restarting": active["restart"],
		})
	return entries

func _finish_tracked_signal(id: int) -> void:
	_pending_callbacks.erase(id)
	if _pending_waits.erase(id):
		pending_changed.emit(pending_snapshot())

func _emit_trace(kind: String, rule_id: StringName, event: StringName,
		step_index := -1, step: Step = null, detail := "") -> void:
	trace_event.emit({
		"time_ms": Time.get_ticks_msec(),
		"kind": kind,
		"rule": String(rule_id),
		"event": String(event),
		"step": step_index + 1 if step_index >= 0 else 0,
		"verb": String(step.verb) if step != null else "",
		"detail": detail,
	})

func passes(r: Rule, payload: Dictionary = {}, event: StringName = &"") -> bool:
	if r.one_shot and fired.has(r.latch_key()): return false
	return (r.requires.all(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema()))
		and not r.forbids.any(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())))

func alive(r: Rule, gen: int, payload: Dictionary = {}) -> bool:
	if payload.is_empty() and _active.has(r):
		var active_run: Dictionary = _active[r].get("run", {})
		payload = active_run.get("payload", {})
	var event: StringName = _active.get(r, {}).get("run", {}).get("event", r.trigger)
	return (gen == _gen and not _active.get(r, {}).get("restart", false)
		and not r.cancel_if.any(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())))

func _payload_schema() -> Dictionary:
	return payload_schema
