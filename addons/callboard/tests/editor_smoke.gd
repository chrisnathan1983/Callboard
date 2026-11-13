extends SceneTree
## Headless authoring integration tests using addon-only fixtures.

const TMP_PATH := "res://.godot/addon_stage_tmp.tres"
const ExportFilter := preload("res://addons/callboard/editor/export_plugin.gd")

func _initialize() -> void:
	await process_frame
	var ok := _test_scene_assigned_props()
	ok = _test_layer_export_filter() and ok
	ok = _test_factory() and ok
	ok = _test_debug_panel() and ok
	ok = _test_project_settings() and ok
	print("ADDON EDITOR: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_scene_assigned_props() -> bool:
	var definition := StageDefinition.new()
	definition.stage_script = load("res://addons/callboard/tests/fixtures/assigned_prop_stage.gd")
	definition.preview_scene_path = "res://addons/callboard/tests/fixtures/assigned_prop_stage.tscn"
	definition.external_calls = PackedStringArray(["go"])
	definition.rules = [{
		"id": "use_scene_prop", "trigger": "go", "requires": [], "forbids": [],
		"cancel_if": [], "one_shot": false, "reentry": Rule.ReentryPolicy.IGNORE,
		"emit": "", "state_key": "use_scene_prop", "group": "", "steps": [{
			"verb": "show_node", "args": ["target", "true"],
		}, {
			"verb": "show_node", "args": ["assigned_target", "true"],
		}],
	}]
	if not _check("explicit preview fixture saved", ResourceSaver.save(definition, TMP_PATH) == OK):
		return false
	var board := Callboard.new()
	root.add_child(board)
	board.open_script(TMP_PATH)
	var ok := _check("Callboard resolves exported and @onready props from a differently named preview scene",
		board._data.get("compiles", false) and board._data["notes"].is_empty())
	if ok:
		board.add_call_name("preview_fixture_call")
		board.save()
		ok = _check("Callboard saves omit the transient analysis source",
			not "metadata/_analysis_scene_source" in FileAccess.get_file_as_string(TMP_PATH)) and ok
		board.open_script(TMP_PATH)
		var reloaded: StageDefinition = board._data.get("definition")
		ok = _check("Callboard save preserves the explicit preview scene",
			reloaded != null and reloaded.preview_scene_path == definition.preview_scene_path
			and reloaded.external_calls.has("preview_fixture_call")
			and board._data["compiles"] and board._data["notes"].is_empty()) and ok
	board.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	return ok

func _test_layer_export_filter() -> bool:
	var test_path := "res://addons/callboard/tests/fixtures/assigned_prop_stage.tscn"
	return _check("exports omit addon tests and keep authoring scripts for debug builds",
		ExportFilter.should_strip("res://addons/callboard/editor/callboard.gd", false)
		and ExportFilter.should_strip("res://addons/callboard/model/rule_graph_reader.gd", false)
		and ExportFilter.should_strip("res://addons/callboard/plugin.gd", false)
		and not ExportFilter.should_strip("res://addons/callboard/core/stage.gd", false)
		and not ExportFilter.should_strip("res://addons/callboard/core/callboard_debug_panel.gd", false)
		and ExportFilter.should_strip(test_path, false)
		and ExportFilter.should_strip(test_path, true)
		and not ExportFilter.should_strip("res://addons/callboard/editor/callboard.gd", true))

func _test_factory() -> bool:
	# Build an unparented resource-backed stage with its own verb factory.
	var script := GDScript.new()
	script.source_code = """@tool
extends Stage

const MESSAGE := 'A, "B"'
var target: Node3D

class CustomVerbs extends StagingVerbs:
	func stamp(prop: Node3D, label: String) -> Step:
		return Step.new(func(_c: Dictionary) -> void: prop.set_meta(&"label", label))

func _make_verbs(ctx: StepContext) -> CoreVerbs:
	return CustomVerbs.new(ctx)

func _build_props() -> void:
	target = Node3D.new()
	add_child(target)

func _build_blackboard() -> void:
	write_var(&"ready", true)
"""
	if not _check("custom factory fixture compiles", script.reload() == OK):
		return false
	var definition := StageDefinition.new()
	definition.stage_script = script
	definition.variables = [{"key": "ready", "scope": "local", "default": false}]
	var spec := {"verb": "stamp", "args": ["target", "MESSAGE"], "delay": "0.25"}
	definition.rules = [{
		"id": "custom", "trigger": "arrive", "requires": [], "forbids": [],
		"cancel_if": [], "one_shot": false, "emit": "", "steps": [spec],
	}]
	var stage := definition.instantiate()
	stage.build()
	var catalog := VerbCatalog.from_factory(stage.verbs)
	var ok := _check("factory discovers its custom verb and the inherited verbs",
		VerbCatalog.find(catalog, "stamp").size() > 0
		and VerbCatalog.find(catalog, "show_node").size() > 0
		and VerbCatalog.find(catalog, "repeat_emit").size() > 0)
	ok = _check("stage runs the blackboard hook after resource defaults", stage.is_set(&"ready")) and ok
	if _check("custom resource compiles", stage.graph_errors.is_empty()):
		var step := stage.engine.rules[0].steps[0]
		ok = _check("resource compiler supplies verb, prop, constant and delay metadata",
			step.verb == &"stamp" and step.args == [stage.get("target"), 'A, "B"']
			and step.delay == 0.25) and ok
		step.fn.call({})
		ok = _check("compiled custom step runs with the supplied arguments",
			stage.get("target").get_meta(&"label") == 'A, "B"') and ok
	else:
		ok = false
	stage.engine.rules.clear()
	stage.free()

	definition.rules[0].steps[0].args = PackedStringArray(["null", "MESSAGE"])
	stage = definition.instantiate()
	stage.build()
	ok = _check("validator still reports null props with compiler-generated metadata",
		stage.check().any(func(problem): return "'stamp' step with an unset prop" in problem)) and ok
	stage.engine.rules.clear()
	stage.free()

	return ok

func _test_debug_panel() -> bool:
	var panel := CallboardDebugPanel.create()
	if not _check("debug panel factory creates an unparented panel",
			panel != null and panel.get_parent() == null):
		return false
	root.add_child(panel)
	var first := Stage.new()
	first.definition = StageDefinition.new()
	root.add_child(first)
	var second := Stage.new()
	second.definition = StageDefinition.new()
	root.add_child(second)
	panel.bind_stage(first)
	var board := panel.get_child(0) as Callboard
	var ok := _check("debug panel binds the live board to the stage", board._live == first)
	panel.bind_stage(second)
	ok = _check("debug panel rebinds the board and disconnects the previous stage",
		board._live == second
		and not first.rule_fired.is_connected(board._on_live_rule_fired)) and ok
	panel.free()
	first.free()
	second.free()
	return ok

func _test_project_settings() -> bool:
	const Settings := preload("res://addons/callboard/core/callboard_settings.gd")
	var saved_folder: Variant = ProjectSettings.get_setting(Settings.DEFAULT_STAGE_FOLDER, null)
	var scan_folders: Variant = ProjectSettings.get_setting(Settings.STAGE_SCAN_FOLDERS, null)
	ProjectSettings.set_setting(Settings.DEFAULT_STAGE_FOLDER, null)
	ProjectSettings.set_setting(Settings.STAGE_SCAN_FOLDERS, null)
	ProjectSettings.set_setting(Settings.LEGACY_DEFAULT_FOLDER, "res://custom_stages/")
	ProjectSettings.set_setting(Settings.LEGACY_SCAN_FOLDERS, PackedStringArray(["res://extra_stages/"]))
	Settings.register_project_settings()
	var ok := _check("legacy stage folder settings migrate to the new fields",
		Settings.stage_directories() == ["res://custom_stages", "res://extra_stages"]
		and not ProjectSettings.has_setting(Settings.LEGACY_DEFAULT_FOLDER)
		and not ProjectSettings.has_setting(Settings.LEGACY_SCAN_FOLDERS))
	ProjectSettings.set_setting(Settings.DEFAULT_STAGE_FOLDER, saved_folder)
	ProjectSettings.set_setting(Settings.STAGE_SCAN_FOLDERS, scan_folders)
	return ok

func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond

