@tool
class_name CrossStageEventValidator extends RefCounted
## Resource-only checks for authored cross-Stage event routes.

const Settings := preload("res://addons/callboard/core/callboard_settings.gd")
const RuntimeInputRefScript := preload("res://addons/callboard/core/runtime_input_ref.gd")

static func apply(data: GraphDraft) -> void:
	if data == null or not _has_routes(data.rules):
		return
	var result := validate(data)
	data.errors.append_array(result["errors"])
	data.warnings.append_array(result["warnings"])

## `definitions` is injectable for tests and editor tooling. Empty definitions
## triggers a scan of the configured StageDefinition folders.
static func validate(data: GraphDraft, definitions: Array = []) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if data == null or not _has_routes(data.rules):
		return {"errors": errors, "warnings": warnings}
	var known_definitions := definitions
	if known_definitions.is_empty():
		known_definitions = _load_project_definitions()
	var source_info := _info_from_draft(data)
	var infos: Array[Dictionary] = []
	for definition: StageDefinition in known_definitions:
		if definition == null:
			continue
		if not source_info["path"].is_empty() and definition.resource_path == source_info["path"]:
			continue
		infos.append(_info_from_definition(definition))
	infos.append(source_info)
	var route_owners: Dictionary = {}
	for info: Dictionary in infos:
		for target_id: String in info["instance_ids"]:
			if not route_owners.has(target_id):
				route_owners[target_id] = []
			route_owners[target_id].append(info)
	for target_id: String in route_owners:
		if route_owners[target_id].size() > 1:
			errors.append("cross-Stage instance ID '%s' is declared by multiple StageDefinitions" % target_id)

	for rule: RuleData in data.rules:
		for step: StepData in _flatten_steps(rule.steps):
			if step.verb != &"emit_cross_stage":
				continue
			_validate_route(data, rule, step, infos, route_owners, errors, warnings)
	return {"errors": errors, "warnings": warnings}

static func _validate_route(data: GraphDraft, rule: RuleData, step: StepData,
		infos: Array[Dictionary], route_owners: Dictionary,
		errors: Array[String], warnings: Array[String]) -> void:
	if step.args.is_empty():
		return # The ordinary resource validator reports missing arguments.
	var event_literal := ExprText.parse_literal(step.args[0])
	if not event_literal.ok or not (event_literal.value is String or event_literal.value is StringName):
		warnings.append("rule '%s' emit_cross_stage event needs a literal ID for project-wide validation" % rule.id)
		return
	var event_id := StringName(String(event_literal.value))
	if event_id.is_empty() or event_id == &"on_change":
		errors.append("rule '%s' emit_cross_stage requires a non-empty event other than 'on_change'" % rule.id)
		return
	var target_id := ""
	if step.args.size() > 2:
		var target_literal := ExprText.parse_literal(step.args[2])
		if not target_literal.ok or not (target_literal.value is String or target_literal.value is StringName):
			warnings.append("rule '%s' emit_cross_stage target needs a literal ID for project-wide validation" % rule.id)
			return
		target_id = String(target_literal.value)
	var recipients: Array[Dictionary] = []
	if target_id.is_empty():
		for info: Dictionary in infos:
			if _event_is_known(info, event_id):
				recipients.append(info)
		if recipients.is_empty():
			errors.append("rule '%s' broadcasts '%s', but no configured StageDefinition declares or listens for it" % [rule.id, event_id])
	else:
		if not route_owners.has(target_id):
			warnings.append("rule '%s' targets '%s', which is not registered in any configured StageDefinition; add it to cross_stage_instance_ids for offline validation" % [rule.id, target_id])
			return
		for info: Dictionary in route_owners[target_id]:
			if not _event_is_known(info, event_id):
				errors.append("rule '%s' targets StageDefinition '%s' for '%s', but that event is not declared or listened for" % [
					rule.id, info["path"], event_id])
			else:
				recipients.append(info)
	if recipients.is_empty():
		return
	var outgoing := _outgoing_fields(data, rule, step)
	if not outgoing["ok"]:
		warnings.append("rule '%s' emit_cross_stage payload needs scene analysis for static field checks" % rule.id)
		return
	for recipient: Dictionary in recipients:
		var schema: Dictionary = recipient["schemas"].get(event_id, {})
		if schema.is_empty():
			continue
		for field_name: Variant in outgoing["fields"]:
			var name := StringName(String(field_name))
			if not schema.has(name):
				errors.append("rule '%s' sends undeclared field '%s' to StageDefinition '%s' for '%s'" % [
					rule.id, name, recipient["path"], event_id])
				continue
			var actual_type: int = outgoing["fields"][field_name]
			var expected_type: int = schema[name]
			if actual_type == TYPE_NIL:
				warnings.append("rule '%s' field '%s' type cannot be inferred for StageDefinition '%s'" % [
					rule.id, name, recipient["path"]])
			elif actual_type != expected_type and not (expected_type == TYPE_FLOAT and actual_type == TYPE_INT):
				errors.append("rule '%s' field '%s' has type %s, but StageDefinition '%s' expects %s for '%s'" % [
					rule.id, name, type_string(actual_type), recipient["path"], type_string(expected_type), event_id])

static func _outgoing_fields(data: GraphDraft, rule: RuleData, step: StepData) -> Dictionary:
	if step.args.size() < 2:
		return {"ok": true, "fields": {}}
	var bb := Blackboard.new()
	for variable: VariableData in data.variables:
		bb.define(variable.key, StringName(variable.scope), variable.default_value, variable.state_key)
		for alias: StringName in variable.aliases:
			bb.alias(alias, variable.key)
	var engine := RuleEngine.new(bb, {}, Callable())
	for field: PayloadFieldData in data.payload_fields:
		if not engine.payload_schema.has(field.event_id):
			engine.payload_schema[field.event_id] = {}
		engine.payload_schema[field.event_id][field.key] = field.value_type()
	var factory := CoreVerbs.new(StepContext.new(bb, engine, null, Callable()))
	factory.runtime_input_event = rule.trigger
	var source := step.args[1]
	var name_pattern := RegEx.create_from_string('(&?)("(?:[^"\\\\]|\\\\.)*")')
	var matches := name_pattern.search_all(source)
	matches.reverse()
	for token: RegExMatch in matches:
		if token.get_string(1) != "":
			source = source.left(token.get_start()) + "StringName(%s)" % token.get_string(2) + source.substr(token.get_end())
	var expression := Expression.new()
	if expression.parse(source) != OK:
		return {"ok": false, "fields": {}}
	var value: Variant = expression.execute([], factory, false)
	if expression.has_execute_failed() or not value is Dictionary:
		return {"ok": false, "fields": {}}
	var fields := {}
	for key: Variant in value:
		if not (key is String or key is StringName):
			return {"ok": false, "fields": {}}
		var field_value: Variant = value[key]
		fields[key] = field_value.value_type if field_value is RuntimeInputRefScript else typeof(field_value)
	return {"ok": true, "fields": fields}

static func _info_from_draft(data: GraphDraft) -> Dictionary:
	var base: StageDefinition = data.definition
	var schemas := {}
	for field: PayloadFieldData in data.payload_fields:
		if not schemas.has(field.event_id):
			schemas[field.event_id] = {}
		schemas[field.event_id][field.key] = field.value_type()
	return {
		"path": base.resource_path if base != null else "",
		"instance_ids": PackedStringArray(base.cross_stage_instance_ids) if base != null else PackedStringArray(),
		"calls": PackedStringArray(data.external_calls),
		"rules": data.rules,
		"schemas": schemas,
	}

static func _info_from_definition(definition: StageDefinition) -> Dictionary:
	definition._migrate()
	var schemas := {}
	for field: PayloadFieldData in definition.payload_fields:
		if not schemas.has(field.event_id):
			schemas[field.event_id] = {}
		schemas[field.event_id][field.key] = field.value_type()
	return {
		"path": definition.resource_path,
		"instance_ids": definition.cross_stage_instance_ids,
		"calls": definition.external_calls,
		"rules": definition.rules,
		"schemas": schemas,
	}

static func _event_is_known(info: Dictionary, event_id: StringName) -> bool:
	if info["calls"].has(event_id):
		return true
	for rule: RuleData in info["rules"]:
		if rule.trigger == event_id or event_id == StringName("relay:" + String(rule.emit)) and not rule.emit.is_empty():
			return true
		for step: StepData in _flatten_steps(rule.steps):
			if step.verb == &"wait_for_call" and not step.args.is_empty():
				var wait_event := ExprText.parse_literal(step.args[0])
				if wait_event.ok and wait_event.value == event_id:
					return true
			if step.verb == &"emit_relay" and not step.args.is_empty():
				var relay := ExprText.parse_literal(step.args[0])
				if relay.ok and (relay.value is String or relay.value is StringName) \
						and event_id == StringName("relay:" + String(relay.value)):
					return true
			if step.verb == &"repeat_emit" and step.args.size() > 1:
				var tick := ExprText.parse_literal(step.args[1])
				if tick.ok and (tick.value is String or tick.value is StringName) \
						and event_id == StringName("relay:" + String(tick.value)):
					return true
	return false

static func _has_routes(rules: Array[RuleData]) -> bool:
	for rule: RuleData in rules:
		for step: StepData in _flatten_steps(rule.steps):
			if step.verb == &"emit_cross_stage":
				return true
	return false

static func _flatten_steps(steps: Array) -> Array[StepData]:
	var result: Array[StepData] = []
	for step: StepData in steps:
		result.append(step)
		for branch: Array in step.parallel_branches:
			result.append_array(_flatten_steps(branch))
	return result

static func _load_project_definitions() -> Array[StageDefinition]:
	var definitions: Array[StageDefinition] = []
	var seen := {}
	for directory: String in Settings.stage_directories():
		for path: String in _definition_paths(directory):
			if seen.has(path):
				continue
			seen[path] = true
			var definition := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StageDefinition
			if definition != null:
				definitions.append(definition)
	return definitions

static func _definition_paths(directory: String) -> Array[String]:
	var paths: Array[String] = []
	if not DirAccess.dir_exists_absolute(directory):
		return paths
	var dir := DirAccess.open(directory)
	if dir == null or dir.list_dir_begin() != OK:
		return paths
	var entry := dir.get_next()
	while not entry.is_empty():
		var path := directory.path_join(entry)
		if dir.current_is_dir():
			if entry not in [".", ".."]:
				paths.append_array(_definition_paths(path))
		elif entry.ends_with(".tres"):
			if ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) is StageDefinition:
				paths.append(path)
		entry = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths
