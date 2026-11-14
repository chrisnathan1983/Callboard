@tool
class_name Blackboard extends RefCounted

signal changed(key: StringName, value: Variant)
signal shared_changed(storage_key: StringName, value: Variant, writer: StringName, source: Blackboard)

var schema := {}
var local := {}
var saved: Dictionary          # injected by the manager
var shared_values: Dictionary = {}
var shared_write_guard: Callable
var _saved_names := {}        # saved storage key -> current Blackboard name
var _aliases: Dictionary = {} # original Blackboard name -> current name
var last_writers: Dictionary = {} # current Blackboard name -> most recent writer label

func _init(p_saved := {}, p_shared := {}) -> void:
	saved = p_saved
	shared_values = p_shared

func define(key: StringName, scope: StringName, default: Variant, state_key: StringName = &"") -> void:
	var previous: Dictionary = schema.get(key, {})
	var storage_key: StringName = previous.get("state_key", key) if state_key.is_empty() else state_key
	if previous.get("scope") == &"saved":
		_saved_names.erase(previous["state_key"])
	schema[key] = {"scope": scope, "default": default, "state_key": storage_key, "type": typeof(default)}
	if scope == &"saved" or scope == &"shared":
		var values: Dictionary = shared_values if scope == &"shared" else saved
		if scope == &"saved":
			_saved_names[storage_key] = key
		if not values.has(storage_key):
			values[storage_key] = default
		elif typeof(values[storage_key]) != typeof(default):
			push_warning("Blackboard value '%s' has a type that does not match its declaration." % storage_key)
			if scope == &"saved":
				values[storage_key] = default
	else:
		local[key] = default

func get_var(key: StringName) -> Variant:
	key = resolve_key(key)
	var entry: Dictionary = schema.get(key, {})
	match entry.get("scope"):
		&"saved": return saved.get(entry["state_key"])
		&"shared": return shared_values.get(entry["state_key"])
		_: return local.get(key)

func write(key: StringName, value: Variant, writer: StringName = &"") -> void:
	key = resolve_key(key)
	if not schema.has(key):
		push_error("Undeclared Blackboard key '%s'" % key)
		return
	var entry: Dictionary = schema.get(key, {})
	if entry["type"] == TYPE_FLOAT and typeof(value) == TYPE_INT:
		value = float(value)
	if typeof(value) != entry["type"]:
		push_warning("Blackboard write to '%s' rejected: expected type %d, got %d." % [key, entry["type"], typeof(value)])
		return
	var scope: StringName = entry["scope"]
	var is_persistent: bool = scope in [&"saved", &"shared"]
	var storage_key: StringName = entry["state_key"] if is_persistent else key
	if scope == &"shared" and shared_write_guard.is_valid() \
			and not bool(shared_write_guard.call(storage_key, value, self)):
		return
	if not writer.is_empty():
		last_writers[key] = writer
	var values: Dictionary = shared_values if scope == &"shared" else (saved if scope == &"saved" else local)
	var previous: Variant = values.get(storage_key)
	if values.has(storage_key) and typeof(previous) == typeof(value) and previous == value:
		return
	values[storage_key] = value
	changed.emit(key, value)
	if scope == &"shared":
		shared_changed.emit(storage_key, value, writer, self)

func receive_shared_change(storage_key: StringName, value: Variant, writer: StringName) -> void:
	for key: StringName in schema:
		var entry: Dictionary = schema[key]
		if entry.get("scope") == &"shared" and entry.get("state_key") == storage_key:
			if not writer.is_empty():
				last_writers[key] = writer
			changed.emit(key, value)

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
