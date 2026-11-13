@tool
class_name CallboardHistory extends RefCounted
## Undo/redo snapshots for Callboard's authored edit state.

const HISTORY_LIMIT := 100

var undo_stack: Array[Dictionary] = []
var redo_stack: Array[Dictionary] = []
var current_state: Dictionary = {}
var saved_state: Dictionary = {}
var _last_spin_edit := 0

func reset(state: Dictionary) -> void:
	undo_stack.clear()
	redo_stack.clear()
	_last_spin_edit = 0
	current_state = state.duplicate(true)
	saved_state = current_state.duplicate(true)

func record(state: Dictionary, spin_id := 0) -> bool:
	if state != current_state:
		if spin_id == 0 or spin_id != _last_spin_edit:
			undo_stack.append(current_state)
			if undo_stack.size() > HISTORY_LIMIT:
				undo_stack.pop_front()
		elif not undo_stack.is_empty() and undo_stack.back() == state:
			undo_stack.pop_back()
			spin_id = 0
		redo_stack.clear()
		current_state = state.duplicate(true)
	_last_spin_edit = spin_id
	return is_dirty()

func undo(state: Dictionary) -> Dictionary:
	if undo_stack.is_empty():
		return {}
	redo_stack.append(state.duplicate(true))
	return undo_stack.pop_back()

func redo(state: Dictionary) -> Dictionary:
	if redo_stack.is_empty():
		return {}
	undo_stack.append(state.duplicate(true))
	return redo_stack.pop_back()

func restore(state: Dictionary) -> void:
	current_state = state.duplicate(true)
	_last_spin_edit = 0

func mark_saved(state: Dictionary) -> void:
	saved_state = state.duplicate(true)
	current_state = saved_state.duplicate(true)
	_last_spin_edit = 0

func is_dirty() -> bool:
	return current_state != saved_state

func can_undo() -> bool:
	return not undo_stack.is_empty()

func can_redo() -> bool:
	return not redo_stack.is_empty()
