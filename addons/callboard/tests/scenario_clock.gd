extends RefCounted
## Manually advanced clock for deterministic scenario tests and debugger sessions.

class ClockWait extends RefCounted:
	signal timeout
	var deadline := 0.0

var now := 0.0
var _waits: Array[ClockWait] = []

func wait(seconds: float) -> Signal:
	var pending := ClockWait.new()
	pending.deadline = now + maxf(0.0, seconds)
	_waits.append(pending)
	return pending.timeout

func advance(seconds: float) -> void:
	if seconds < 0.0:
		push_warning("Scenario clock cannot move backwards.")
		return
	now += seconds
	var pending_waits := _waits.duplicate()
	_waits.clear()
	for pending in pending_waits:
		if pending.deadline <= now:
			pending.timeout.emit()
		else:
			_waits.append(pending)

func pending_count() -> int:
	return _waits.size()

func time_seconds() -> float:
	return now

func cancel_all() -> void:
	_waits.clear()
