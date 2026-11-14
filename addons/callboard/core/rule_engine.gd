@tool
class_name RuleEngine extends RefCounted

signal rule_fired(rule_id: StringName, event: StringName)
signal trace_event(entry: Dictionary)
signal pending_changed(entries: Array)
signal run_cancelled(rule_id: StringName)
signal all_cancelled
signal dispatch_limit_reached(limit: String, event_chain: PackedStringArray, rule_id: StringName)

class AwaitedSignal extends RefCounted:
	signal completed
	signal cancelled

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
var _tracked_wait_ids: Dictionary = {}
var _cancel_if_callbacks: Dictionary = {}
var _event_context_stack: Array[Dictionary] = []
var _next_wait_id := 1
const MAX_FIRE_DEPTH := 64
const MAX_PENDING_PER_RULE := 128
const MAX_DISPATCHES_PER_FRAME := 256
var _dispatch_frame := -1
var _dispatches_this_frame := 0

func _init(p_bb: Blackboard, p_fired: Dictionary, p_wait: Callable) -> void:
	bb = p_bb
	fired = p_fired
	wait = p_wait

func token() -> int: return _gen
func cancel_all() -> void:
	_gen += 1
	all_cancelled.emit()
	for active: Dictionary in _active.values():
		var run: Dictionary = active.get("run", {})
		if not run.is_empty():
			run["cancelled"] = true
			var cancelled_signal: AwaitedSignal = run.get("cancel_signal") as AwaitedSignal
			if cancelled_signal != null:
				cancelled_signal.cancelled.emit()
	_active.clear()
	_pending_waits.clear()
	for tracker in _pending_callbacks.values():
		var tracked_signal: Signal = tracker["signal"]
		var callback: Callable = tracker["callback"]
		var tracked_object := tracked_signal.get_object()
		if is_instance_valid(tracked_object) and tracked_signal.is_connected(callback):
			tracked_signal.disconnect(callback)
	_pending_callbacks.clear()
	for watcher in _cancel_if_callbacks.values():
		var watched_signal: Signal = watcher["signal"]
		var watch_callback: Callable = watcher["callback"]
		if watched_signal.is_connected(watch_callback):
			watched_signal.disconnect(watch_callback)
	_cancel_if_callbacks.clear()
	_tracked_wait_ids.clear()
	pending_changed.emit(pending_snapshot())
	var cancelled := _awaited_signals.values()
	_awaited_signals.clear()
	for entry: Dictionary in cancelled:
		_disconnect_wait_connections(entry)
		entry["completion"].completed.emit()

func fire(event: StringName, payload := {}) -> void:
	var context := {"path": []}
	if not _event_context_stack.is_empty():
		context = _event_context_stack.back()
	_fire(event, payload, context)

## Carry an existing ancestry into public gameplay or host callbacks after a yield.
func fire_from_context(event: StringName, payload: Dictionary, context: Dictionary) -> void:
	_fire(event, payload, context)

func _fire(event: StringName, payload: Dictionary, parent_context: Dictionary) -> void:
	var path: Array = parent_context.get("path", []).duplicate()
	path.append(String(event))
	var depth := path.size()
	if depth > MAX_FIRE_DEPTH:
		_report_dispatch_limit("event depth", path)
		return
	var context := {"path": path}
	_event_context_stack.append(context)
	_emit_trace("event_fired", &"", event)
	_event_context_stack.pop_back()
	var gen := _gen
	for r in rules:
		if gen != _gen:
			return
		if r.trigger == event and passes(r, payload, event):
			if not _consume_dispatch_budget(context):
				return
			_dispatch(r, event, payload.duplicate(true), gen, depth, context)

func _dispatch(r: Rule, event: StringName, payload: Dictionary, gen: int, depth: int,
		context: Dictionary) -> void:
	if _active.has(r):
		var active: Dictionary = _active[r]
		match r.reentry:
			Rule.ReentryPolicy.RESTART:
				active["restart"] = true
				var current_run: Dictionary = active.get("run", {})
				current_run["cancelled"] = true
				var pending: Array = active["pending"]
				pending.clear()
				pending.append({"payload": payload.duplicate(true), "depth": depth, "context": context})
				active["pending"] = pending
				_active[r] = active
				# The suspended dispatch can resume synchronously when cancelled is
				# emitted, so publish the replacement before waking the old run.
				_signal_run_cancelled(current_run, r.id)
				var cancelled_signal: AwaitedSignal = current_run.get("cancel_signal") as AwaitedSignal
				if cancelled_signal != null:
					cancelled_signal.cancelled.emit()
			Rule.ReentryPolicy.QUEUE:
				var pending: Array = active["pending"]
				if pending.size() >= MAX_PENDING_PER_RULE:
					_report_dispatch_limit("pending queue", context.get("path", []), r.id)
					return
				pending.append({"payload": payload.duplicate(true), "depth": depth, "context": context})
				active["pending"] = pending
				_active[r] = active
		return

	var active := {"pending": [], "restart": false}
	_active[r] = active
	await _run(r, event, payload, gen, depth, context)
	while gen == _gen and _active.has(r) and not _active[r]["pending"].is_empty():
		var current_active: Dictionary = _active[r]
		var next: Dictionary = current_active["pending"].pop_front()
		current_active["restart"] = false
		current_active.erase("run")
		var next_payload: Dictionary = next["payload"]
		if passes(r, next_payload, event) and alive(r, gen, next_payload):
			await _run(r, event, next_payload, gen, int(next["depth"]), next["context"])
	if gen == _gen:
		_active.erase(r)

func _run(rule: Rule, event: StringName, payload: Dictionary, generation: int, depth: int,
		context: Dictionary) -> void:
	if generation != _gen or rule.cancel_if.any(func(guard: StringName) -> bool:
		return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())):
		return
	# Non-blocking steps can outlive a successful run, so keep cancellation
	# on the run itself even after the rule leaves the active table.
	var run := {
		"cancelled": false,
		"cancel_signal": AwaitedSignal.new(),
		"payload": payload.duplicate(true),
		"event": event,
		"depth": depth,
		"context": context,
	}
	_active[rule]["run"] = run
	_watch_cancel_if(rule, run, generation, payload, event)
	if rule.one_shot:
		fired[rule.latch_key()] = true
	_event_context_stack.append(context)
	_emit_trace("rule_started", rule.id, event)
	rule_fired.emit(rule.id, event)
	_event_context_stack.pop_back()
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
			await interruptible(wait_tracked(step.delay, rule.id, "step delay"), Callable(),
				[(run["cancel_signal"] as AwaitedSignal).cancelled], run, true)
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
		_fire("relay:" + rule.emits, payload, context)
	_emit_trace("rule_completed", rule.id, event)
	_release_cancel_if(run)

func _cancel_run(run: Dictionary, rule_id: StringName, event: StringName,
		step_index := -1, step: Step = null) -> void:
	run["cancelled"] = true
	_release_cancel_if(run)
	var cancelled_signal: AwaitedSignal = run.get("cancel_signal") as AwaitedSignal
	if cancelled_signal != null:
		cancelled_signal.cancelled.emit()
	_signal_run_cancelled(run, rule_id)
	_emit_trace("rule_cancelled", rule_id, event, step_index, step)

func _signal_run_cancelled(run: Dictionary, rule_id: StringName) -> void:
	if run.get("cancel_notified", false):
		return
	run["cancel_notified"] = true
	run_cancelled.emit(rule_id)

func _watch_cancel_if(rule: Rule, run: Dictionary, generation: int,
		payload: Dictionary, event: StringName) -> void:
	if rule.cancel_if.is_empty():
		return
	var watch_id := _next_wait_id
	_next_wait_id += 1
	var callback := func(_key: StringName, _value: Variant) -> void:
		if run.get("cancelled", false) or generation != _gen:
			return
		if rule.cancel_if.any(func(guard: StringName) -> bool:
			return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())):
			run["cancelled"] = true
			_signal_run_cancelled(run, rule.id)
			var cancelled_signal: AwaitedSignal = run.get("cancel_signal") as AwaitedSignal
			if cancelled_signal != null:
				cancelled_signal.cancelled.emit()
	run["cancel_if_watch_id"] = watch_id
	_cancel_if_callbacks[watch_id] = {"signal": bb.changed, "callback": callback}
	bb.changed.connect(callback)

func _release_cancel_if(run: Dictionary) -> void:
	var watch_id := int(run.get("cancel_if_watch_id", -1))
	var watcher: Dictionary = _cancel_if_callbacks.get(watch_id, {})
	if not watcher.is_empty():
		var watched_signal: Signal = watcher["signal"]
		var callback: Callable = watcher["callback"]
		if watched_signal.is_connected(callback):
			watched_signal.disconnect(callback)
		_cancel_if_callbacks.erase(watch_id)
	run.erase("cancel_if_watch_id")

## Returns the engine's configured wait signal and publishes it to live diagnostics.
func wait_tracked(seconds: float, rule_id: StringName, label: String) -> Signal:
	var timeout: Signal = wait.call(seconds)
	var id := track_signal(timeout, rule_id, label, seconds)
	var signal_key := _signal_key(timeout)
	var ids: Array = _tracked_wait_ids.get(signal_key, [])
	ids.append(id)
	_tracked_wait_ids[signal_key] = ids
	return timeout

## Completes when its source emits, its run is replaced, or the engine is deactivated.
## `completion_if` can ignore unrelated source emissions without dropping the wait.
func interruptible(source: Signal, completion_if := Callable(),
		cancel_on: Array[Signal] = [], run: Dictionary = {}, defer_cancel := false) -> Signal:
	var completion := AwaitedSignal.new()
	var id := completion.get_instance_id()
	var source_callback := func(...emitted_values: Array) -> void:
		if completion_if.is_valid() and not bool(completion_if.callv(emitted_values)):
			return
		_complete_wait(id)
	var connections: Array[Dictionary] = [{"signal": source, "callback": source_callback}]
	source.connect(source_callback)
	for cancel_signal: Signal in cancel_on:
		if cancel_signal.is_null():
			continue
		var cancel_callback := func(..._ignored: Array) -> void:
			if not run.is_empty():
				run["cancelled"] = true
			if defer_cancel:
				# Let multiple same-frame triggers coalesce before the suspended
				# dispatch consumes the replacement payload.
				call_deferred("_complete_wait", id)
			else:
				_complete_wait(id)
		connections.append({"signal": cancel_signal, "callback": cancel_callback})
		cancel_signal.connect(cancel_callback)
	var tracked_id := -1
	var signal_key := _signal_key(source)
	var tracked_ids: Array = _tracked_wait_ids.get(signal_key, [])
	if not tracked_ids.is_empty():
		tracked_id = int(tracked_ids.pop_front())
		if tracked_ids.is_empty():
			_tracked_wait_ids.erase(signal_key)
		else:
			_tracked_wait_ids[signal_key] = tracked_ids
	_awaited_signals[id] = {
		"connections": connections,
		"completion": completion,
		"tracked_id": tracked_id,
	}
	# A listener can restart the run while wait_tracked() publishes diagnostics,
	# before this cancellation connection has been installed. Defer completion so
	# the caller can begin awaiting the returned signal first.
	if run.get("cancelled", false):
		call_deferred("_complete_wait", id)
	return completion.completed

func _signal_key(signal_to_key: Signal) -> String:
	return "%d:%s" % [signal_to_key.get_object_id(), signal_to_key.get_name()]

func _complete_wait(id: int) -> void:
	var entry: Dictionary = _awaited_signals.get(id, {})
	_awaited_signals.erase(id)
	if not entry.is_empty():
		_disconnect_wait_connections(entry)
		var tracked_id := int(entry.get("tracked_id", -1))
		if tracked_id >= 0:
			_finish_tracked_signal(tracked_id)
		entry["completion"].completed.emit()

func _disconnect_wait_connections(entry: Dictionary) -> void:
	for connection: Dictionary in entry.get("connections", []):
		var source: Signal = connection["signal"]
		var callback: Callable = connection["callback"]
		var source_object := source.get_object()
		if is_instance_valid(source_object) and source.is_connected(callback):
			source.disconnect(callback)

## Tracks an awaited or non-blocking signal until it completes.
func track_signal(signal_to_track: Signal, rule_id: StringName, label: String, seconds := -1.0) -> int:
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
	var callback := func(..._emitted_values: Array) -> void: _finish_tracked_signal(id)
	_pending_callbacks[id] = {"signal": signal_to_track, "callback": callback}
	signal_to_track.connect(callback, CONNECT_ONE_SHOT)
	return id

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
	var callback_data: Dictionary = _pending_callbacks.get(id, {})
	if not callback_data.is_empty():
		var signal_to_track: Signal = callback_data["signal"]
		var callback: Callable = callback_data["callback"]
		var tracked_object := signal_to_track.get_object()
		if is_instance_valid(tracked_object) and signal_to_track.is_connected(callback):
			signal_to_track.disconnect(callback)
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

func _consume_dispatch_budget(context: Dictionary) -> bool:
	var frame := Engine.get_process_frames()
	if frame != _dispatch_frame:
		_dispatch_frame = frame
		_dispatches_this_frame = 0
	if _dispatches_this_frame >= MAX_DISPATCHES_PER_FRAME:
		_report_dispatch_limit("per-frame dispatch budget", context.get("path", []))
		return false
	_dispatches_this_frame += 1
	return true

func _report_dispatch_limit(limit: String, path: Array, rule_id: StringName = &"") -> void:
	var chain := PackedStringArray()
	for event in path:
		chain.append(String(event))
	dispatch_limit_reached.emit(limit, chain, rule_id)
	var suffix := " while dispatching rule '%s'" % rule_id if not rule_id.is_empty() else ""
	push_error("Callboard stopped %s%s. Event chain: %s" % [limit, suffix, " -> ".join(chain)])

func passes(r: Rule, payload: Dictionary = {}, event: StringName = &"") -> bool:
	if r.one_shot and fired.has(r.latch_key()): return false
	return (r.requires.all(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema()))
		and not r.forbids.any(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema()))
		and not r.cancel_if.any(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())))

func alive(r: Rule, gen: int, payload: Dictionary = {}) -> bool:
	var active_run: Dictionary = _active.get(r, {}).get("run", {})
	if payload.is_empty() and _active.has(r):
		payload = active_run.get("payload", {})
	var event: StringName = _active.get(r, {}).get("run", {}).get("event", r.trigger)
	return (gen == _gen and not active_run.get("cancelled", false)
		and not _active.get(r, {}).get("restart", false)
		and not r.cancel_if.any(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())))

func _payload_schema() -> Dictionary:
	return payload_schema
