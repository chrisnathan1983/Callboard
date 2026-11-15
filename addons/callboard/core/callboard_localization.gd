@tool
class_name CallboardLocalization extends RefCounted
## Resolves explicit translation keys and applies named String.format substitutions.

static func resolve(key: StringName, substitutions: Dictionary = {}, fallback := "") -> String:
	if key.is_empty():
		return _format(fallback, substitutions)
	var message := String(key)
	var translated := TranslationServer.translate(StringName(message))
	if translated == message and not fallback.is_empty():
		message = TranslationServer.translate(StringName(fallback))
	else:
		message = translated
	return _format(message, substitutions)

static func _format(message: String, substitutions: Dictionary) -> String:
	return message.format(substitutions) if not substitutions.is_empty() else message
