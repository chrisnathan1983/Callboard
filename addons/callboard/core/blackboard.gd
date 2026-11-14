@tool
class_name Blackboard extends RefCounted

signal changed(key: StringName, value: Variant)
signal shared_changed(storage_key: StringName, value: Variant, writer: StringName, source: Blackboard)
## Emitted only after a value commits. `previous` and `value` retain the key's
## declared Variant type; initialization and restoration do not emit changes.
signal value_changed(key: StringName, previous: Variant, value: Variant, scope: StringName, writer: StringName, dispatch_context: Dictionary)

var schema := {}
var local := {}
var saved: Dictionary          # injected by the manager
var shared_values: Dictionary = {}
var session_values: Dictionary = {}
var shared_write_guard: Callable
var shared_write_commit: Callable
var _saved_names := {}        # saved storage key -> current Blackboard name
var _aliases: Dictionary = {} # original Blackboard name -> current name
var last_writers: Dictionary = {} # current Blackboard name -> most recent writer label
var _value_change_queue: Array[Dictionary] = []
var _dispatching_value_changes := false

func _init(p_saved := {}, p_shared := {}, p_session := {}) -> void:
	saved = p_saved
	shared_values = p_shared
	session_values = p_session

func define(key: StringName, scope: StringName, default: Variant, state_key: StringName = &"") -> void:
	var previous: Dictionary = schema.get(key, {})
	var storage_key: StringName = previous.get("state_key", key) if state_key.is_empty() else state_key
	if previous.get("scope") == &"saved":
		_saved_names.erase(previous["state_key"])
	schema[key] = {"scope": scope, "default": default, "state_key": storage_key, "type": typeof(default)}
	if scope in [&"saved", &"shared", &"session"]:
		var values: Dictionary = _storage_for_scope(scope)
		if scope == &"saved":
			_saved_names[storage_key] = key
		if not values.has(storage_key):
			values[storage_key] = default
		elif typeof(values[storage_key]) != typeof(default):
			push_warning("Blackboard value '%s' has a type that does not match its declaration." % storage_key)
			if scope in [&"saved", &"session"]:
				values[storage_key] = default
	else:
		local[key] = default

func get_var(key: StringName) -> Variant:
	key = resolve_key(key)
	var entry: Dictionary = schema.get(key, {})
	match entry.get("scope"):
		&"saved": return saved.get(entry["state_key"])
		&"shared": return shared_values.get(entry["state_key"])
		&"session": return session_values.get(entry["state_key"])
		_: return local.get(key)

func write(key: StringName, value: Variant, writer: StringName = &"", dispatch_context: Dictionary = {}) -> bool:
	key = resolve_key(key)
	if not schema.has(key):
		push_error("Undeclared Blackboard key '%s'" % key)
		return false
	var entry: Dictionary = schema.get(key, {})
	if entry["type"] == TYPE_FLOAT and typeof(value) == TYPE_INT:
		value = float(value)
	if typeof(value) != entry["type"]:
		push_warning("Blackboard write to '%s' rejected: expected type %d, got %d." % [key, entry["type"], typeof(value)])
		return false
	var scope: StringName = entry["scope"]
	var is_stored: bool = scope in [&"saved", &"shared", &"session"]
	var storage_key: StringName = entry["state_key"] if is_stored else key
	if scope == &"shared" and shared_write_guard.is_valid() \
			and not bool(shared_write_guard.call(storage_key, value, self)):
		return false
	if scope == &"shared" and shared_write_commit.is_valid():
		return bool(shared_write_commit.call(storage_key, key, value, writer, self, dispatch_context.duplicate(true)))
	var values: Dictionary = _storage_for_scope(scope)
	var previous: Variant = values.get(storage_key)
	if values.has(storage_key) and typeof(previous) == typeof(value) and previous == value:
		return false
	if not writer.is_empty():
		last_writers[key] = writer
	values[storage_key] = value
	_queue_value_change(key, previous, value, scope, writer, dispatch_context)
	changed.emit(key, value)
	_drain_value_changes()
	if scope == &"shared":
		shared_changed.emit(storage_key, value, writer, self)
	return true

func receive_shared_change(storage_key: StringName, value: Variant, writer: StringName,
		dispatch_context: Dictionary = {}, notify_shared := false,
		previous_value: Variant = null) -> void:
	for key: StringName in schema:
		var entry: Dictionary = schema[key]
		if entry.get("scope") == &"shared" and entry.get("state_key") == storage_key:
			if not writer.is_empty():
				last_writers[key] = writer
			_queue_value_change(key, previous_value, value, &"shared", writer, dispatch_context)
			changed.emit(key, value)
	_drain_value_changes()
	if notify_shared:
		shared_changed.emit(storage_key, value, writer, self)

func _queue_value_change(key: StringName, previous: Variant, value: Variant,
		scope: StringName, writer: StringName, dispatch_context: Dictionary) -> void:
	_value_change_queue.append({
		"key": key,
		"previous": previous,
		"value": value,
		"scope": scope,
		"writer": writer,
		"dispatch_context": dispatch_context.duplicate(true),
	})

func _drain_value_changes() -> void:
	if _dispatching_value_changes:
		return
	_dispatching_value_changes = true
	while not _value_change_queue.is_empty():
		var change: Dictionary = _value_change_queue.pop_front()
		value_changed.emit(change["key"], change["previous"], change["value"],
			change["scope"], change["writer"], change["dispatch_context"])
	_dispatching_value_changes = false

## Let gameplay code using an original saved name continue to access a renamed key.
func resolve_key(key: StringName) -> StringName:
	if schema.has(key):
		return key
	var resolved: StringName = key
	var visited := {}
	while _aliases.has(resolved) and not visited.has(resolved):
		visited[resolved] = true
		resolved = _aliases[resolved]
	if schema.has(resolved):
		return resolved
	return _saved_names.get(key, key)

## Preserve gameplay references when any authored key is renamed.
func alias(old_key: StringName, new_key: StringName) -> void:
	_aliases[old_key] = new_key

func is_set(key: StringName) -> bool:
	return bool(get_var(key))

func has(key: StringName) -> bool:
	return schema.has(resolve_key(key))

func _storage_for_scope(scope: StringName) -> Dictionary:
	match scope:
		&"saved": return saved
		&"shared": return shared_values
		&"session": return session_values
		_: return local

func receive_session_change(storage_key: StringName, value: Variant, previous: Variant,
		writer: StringName = &"session_reset") -> void:
	for key: StringName in schema:
		var entry: Dictionary = schema[key]
		if entry.get("scope") == &"session" and entry.get("state_key") == storage_key:
			if not writer.is_empty():
				last_writers[key] = writer
			_queue_value_change(key, previous, value, &"session", writer, {})
			changed.emit(key, value)
	_drain_value_changes()
