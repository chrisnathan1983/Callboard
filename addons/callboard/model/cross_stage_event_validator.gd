@tool
class_name CrossStageEventValidator extends RefCounted
## Resource-only checks for project-wide Stage contracts and cross-Stage event routes.

const Settings := preload("res://addons/callboard/core/callboard_settings.gd")
const RuntimeInputRefScript := preload("res://addons/callboard/core/runtime_input_ref.gd")

static func apply(data: GraphDraft) -> void:
	if data == null:
		return
	var result := validate(data)
	data.errors.append_array(result["errors"])
	data.warnings.append_array(result["warnings"])

## `definitions` is injectable for tests and editor tooling. Empty definitions
## triggers a scan of the configured StageDefinition folders.
static func validate(data: GraphDraft, definitions: Array = []) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if data == null:
		return {"errors": errors, "warnings": warnings}
	var source_info := _info_from_draft(data)
	var infos: Array[Dictionary] = []
	var known_definitions: Array = _load_project_definitions() if definitions.is_empty() else definitions
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

	_validate_shared_contracts(infos, errors)
	if _has_routes(data.rules):
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
			errors.append("rule '%s' targets '%s', which is not registered in any configured StageDefinition; add it to cross_stage_instance_ids for offline validation" % [rule.id, target_id])
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
	return _build_info(base.resource_path if base != null else "",
		PackedStringArray(base.cross_stage_instance_ids) if base != null else PackedStringArray(),
		PackedStringArray(data.external_calls), data.rules, schemas, data.variables,
		PackedStringArray(data.external_vars), data.external_writers,
		base.preview_scene_path if base != null else "")

static func _info_from_definition(definition: StageDefinition) -> Dictionary:
	definition._migrate()
	var schemas := {}
	for field: PayloadFieldData in definition.payload_fields:
		if not schemas.has(field.event_id):
			schemas[field.event_id] = {}
		schemas[field.event_id][field.key] = field.value_type()
	return _build_info(definition.resource_path, definition.cross_stage_instance_ids,
		definition.external_calls, definition.rules, schemas, definition.variables,
		definition.external_vars, definition.external_writers, definition.preview_scene_path)

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

static func _build_info(path: String, instance_ids: PackedStringArray,
		calls: PackedStringArray, rules: Array, schemas: Dictionary,
		variables: Array, external_vars: PackedStringArray,
		external_writers: Array, preview_scene_path: String) -> Dictionary:
	var shared_keys := {}
	var shared_types := {}
	for variable: VariableData in variables:
		if variable == null or variable.scope != "shared":
			continue
		var storage_key: StringName = variable.state_key if not variable.state_key.is_empty() else variable.key
		if not shared_types.has(storage_key):
			shared_types[storage_key] = []
		shared_types[storage_key].append(typeof(variable.default_value))
		shared_keys[variable.key] = storage_key
		for alias: StringName in variable.aliases:
			shared_keys[alias] = storage_key
	var producers := {}
	for key: StringName in external_vars:
		if shared_keys.has(key):
			producers[shared_keys[key]] = true
	for writer: BlackboardWriterData in external_writers:
		if writer != null and shared_keys.has(writer.key):
			producers[shared_keys[writer.key]] = true
	for writer: BlackboardWriterData in _scene_writers(preview_scene_path):
		if writer != null and shared_keys.has(writer.key):
			producers[shared_keys[writer.key]] = true
	var reads := {}
	for rule: RuleData in rules:
		for expression: StringName in rule.requires + rule.forbids + rule.cancel_if:
			for key: StringName in GuardExpression.referenced_keys(expression):
				if shared_keys.has(key):
					reads[shared_keys[key]] = true
		for step: StepData in _flatten_steps(rule.steps):
			if step.verb == &"wait_until" and not step.args.is_empty():
				var condition := ExprText.parse_literal(step.args[0])
				if condition.ok and (condition.value is String or condition.value is StringName):
					for key: StringName in GuardExpression.referenced_keys(StringName(condition.value)):
						if shared_keys.has(key):
							reads[shared_keys[key]] = true
			if step.verb in [&"conditional"]:
				for expression: StringName in step.branch_conditions:
					for key: StringName in GuardExpression.referenced_keys(expression):
						if shared_keys.has(key):
							reads[shared_keys[key]] = true
			for argument: String in step.args:
				for key: StringName in _blackboard_expression_reads(argument):
					if shared_keys.has(key):
						reads[shared_keys[key]] = true
			if step.verb in [&"set_var", &"add_var"] and not step.args.is_empty():
				var target := ExprText.parse_literal(step.args[0])
				if target.ok and (target.value is String or target.value is StringName):
					var target_key := StringName(String(target.value))
					if shared_keys.has(target_key):
						producers[shared_keys[target_key]] = true
	return {
		"path": path, "instance_ids": instance_ids, "calls": calls,
		"rules": rules, "schemas": schemas, "shared_types": shared_types,
		"shared_reads": reads, "shared_producers": producers,
	}

static func _blackboard_expression_reads(expression: String) -> Array[StringName]:
	var result: Array[StringName] = []
	var pattern := RegEx.create_from_string('callboard_blackboard\\s*\\(\\s*&?"([^"\\\\]+)"\\s*\\)')
	for match: RegExMatch in pattern.search_all(expression):
		var key := StringName(match.get_string(1))
		if not result.has(key):
			result.append(key)
	return result

static func _validate_shared_contracts(infos: Array[Dictionary], errors: Array[String]) -> void:
	var type_owners := {}
	var producers := {}
	for info: Dictionary in infos:
		for storage_key: StringName in info["shared_types"]:
			for value_type: int in info["shared_types"][storage_key]:
				if type_owners.has(storage_key) and type_owners[storage_key]["type"] != value_type:
					errors.append("Shared key '%s' has conflicting types in StageDefinitions '%s' and '%s'" % [
						storage_key, type_owners[storage_key]["path"], info["path"]])
				elif not type_owners.has(storage_key):
					type_owners[storage_key] = {"type": value_type, "path": info["path"]}
		for storage_key: StringName in info["shared_producers"]:
			producers[storage_key] = true
	for info: Dictionary in infos:
		for storage_key: StringName in info["shared_reads"]:
			if not producers.has(storage_key):
				errors.append("StageDefinition '%s' reads Shared key '%s', but no Stage or declared host writer produces it" % [
					info["path"], storage_key])

static func _scene_writers(scene_path: String) -> Array[BlackboardWriterData]:
	var result: Array[BlackboardWriterData] = []
	if scene_path.is_empty():
		return result
	var scene := ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if scene == null:
		return result
	var state := scene.get_state()
	for node_index in state.get_node_count():
		for property_index in state.get_node_property_count(node_index):
			if state.get_node_property_name(node_index, property_index) != &"callboard_writers":
				continue
			var declarations: Variant = state.get_node_property_value(node_index, property_index)
			if declarations is Array:
				for writer: Variant in declarations:
					if writer is BlackboardWriterData:
						result.append(writer)
	return result

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
			paths.append(path)
		entry = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths
