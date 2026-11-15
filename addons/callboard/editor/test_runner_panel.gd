@tool
extends VBoxContainer
## Developer-only bottom panel for running the repository's CI suites.

const SUITES := [
	{"name": "Unit tests", "path": "res://addons/callboard/tests/unit.gd"},
	{"name": "Callboard smoke test", "path": "res://addons/callboard/tests/editor_smoke.gd"},
	{"name": "Demo editor smoke test", "path": "res://demo/tests/editor_smoke.gd"},
	{"name": "Demo runtime smoke test", "path": "res://demo/tests/smoke.gd"},
]
const FAILURE_LOCATION_PATTERN := "(?<path>res://[^\\s\\):,]+\\.gd)(?::(?<line>[0-9]+))?"
const EXPECTED_DIAGNOSTIC_MARKER := "CALLBOARD_EXPECTED_DIAGNOSTIC:"
const TEARDOWN_LEAK_PATTERNS := [
	"ObjectDB instances were leaked",
	"RIDs of type ",
	"RID allocations of type ",
	"resources still in use at exit",
	"Leaked instance:",
	"Orphan StringName:",
	"unclaimed string names at exit",
	"Pages in use exist at exit in PagedAllocator",
	"Cannot get path of node as it is not in a scene tree",
]

var _suites: Array[Dictionary] = []

var _run_all_button: Button
var _status_label: Label
var _results_list: VBoxContainer
var _output: TextEdit
var _locations: VBoxContainer
var _thread := Thread.new()
var _pending_suites: Array[int] = []
var _active_suite := -1
var _last_started_suite := -1
var _is_run_all := false
var _results: Array[Dictionary] = []
var _row_statuses: Array[Label] = []
var _row_durations: Array[Label] = []

static func available_suites() -> Array[Dictionary]:
	var existing_paths: Array[String] = []
	for suite: Dictionary in SUITES:
		var path: String = suite["path"]
		if FileAccess.file_exists(path):
			existing_paths.append(path)
	return filter_available_suites(SUITES, existing_paths)

static func filter_available_suites(configured_suites: Array, existing_paths: Array[String]) -> Array[Dictionary]:
	var available: Array[Dictionary] = []
	for suite: Dictionary in configured_suites:
		if existing_paths.has(str(suite.get("path", ""))):
			available.append(suite.duplicate())
	return available

static func analyze_suite_output(output_text: String, exit_code: int) -> Dictionary:
	var failures: Array[String] = []
	var expected: Array[Dictionary] = []
	var lines := output_text.split("\n")
	var visible_lines: Array[String] = []
	for raw_line: String in lines:
		var line := raw_line.strip_edges()
		if not line.begins_with(EXPECTED_DIAGNOSTIC_MARKER):
			continue
		var declaration := line.trim_prefix(EXPECTED_DIAGNOSTIC_MARKER)
		var separator := declaration.find(":")
		if separator <= 0 or separator == declaration.length() - 1:
			failures.append("Malformed expected diagnostic marker: %s" % line)
			continue
		expected.append({
			"severity": declaration.substr(0, separator),
			"fragment": declaration.substr(separator + 1),
			"matched": false,
		})
	for raw_line: String in lines:
		var line := raw_line.strip_edges()
		if line.begins_with(EXPECTED_DIAGNOSTIC_MARKER):
			continue
		visible_lines.append(raw_line)
		if line.begins_with("SCRIPT ERROR:"):
			failures.append("Unexpected script error: %s" % line)
		elif line.begins_with("ERROR:"):
			var matched := false
			var error_message := line.trim_prefix("ERROR:").strip_edges()
			for expected_index in range(expected.size()):
				var diagnostic: Dictionary = expected[expected_index]
				if not diagnostic["matched"] and diagnostic["severity"] == "ERROR" \
						and error_message.begins_with(diagnostic["fragment"]):
					expected[expected_index]["matched"] = true
					matched = true
					break
			if not matched:
				failures.append("Unexpected engine error: %s" % line)
		elif line.begins_with("FAIL ") or line.begins_with("FAIL:") \
				or line.ends_with(": FAIL"):
			failures.append("Test assertion failed: %s" % line.strip_edges())
		for pattern: String in TEARDOWN_LEAK_PATTERNS:
			if line.contains(pattern):
				var leak_summary := "Teardown leak reported (matched %s)." % pattern.strip_edges()
				if not failures.has(leak_summary):
					failures.append(leak_summary)
				break
	for expected_index in range(expected.size()):
		var diagnostic: Dictionary = expected[expected_index]
		if not diagnostic["matched"]:
			failures.append("Expected diagnostic was not observed: %s: %s" % [
				diagnostic["severity"], diagnostic["fragment"]])
	if exit_code != 0:
		failures.append("Godot exited with code %d." % exit_code)
	return {
		"passed": failures.is_empty(),
		"failures": failures,
		"display_output": "\n".join(visible_lines),
	}

func _ready() -> void:
	_suites = available_suites()
	_build_ui()

func _process(_delta: float) -> void:
	if _active_suite < 0 or _thread.is_alive():
		return
	var result: Dictionary = _thread.wait_to_finish()
	_results[_active_suite] = result
	_show_suite_result(_active_suite, result)
	_active_suite = -1
	_start_next_suite()

func _build_ui() -> void:
	name = "CallboardTestRunner"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var toolbar := HBoxContainer.new()
	_run_all_button = Button.new()
	_run_all_button.text = "Run All Tests"
	_run_all_button.pressed.connect(_on_run_all_pressed)
	toolbar.add_child(_run_all_button)
	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toolbar.add_child(_status_label)
	add_child(toolbar)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(split)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 300
	split.add_child(left)
	_results_list = VBoxContainer.new()
	_results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(_results_list)
	for i in range(_suites.size()):
		_add_suite_row(i)
	var locations_title := Label.new()
	locations_title.text = "Failure locations"
	locations_title.add_theme_font_size_override("font_size", 14)
	left.add_child(locations_title)
	var location_scroll := ScrollContainer.new()
	location_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(location_scroll)
	_locations = VBoxContainer.new()
	_locations.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	location_scroll.add_child(_locations)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	var output_title := Label.new()
	output_title.text = "Captured output"
	output_title.add_theme_font_size_override("font_size", 14)
	right.add_child(output_title)
	_output = TextEdit.new()
	_output.editable = false
	_output.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_output)

func _add_suite_row(index: int) -> void:
	var row := HBoxContainer.new()
	var name_button := Button.new()
	name_button.text = _suites[index]["name"]
	name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_button.pressed.connect(_show_suite_output.bind(index))
	row.add_child(name_button)
	var status := Label.new()
	status.text = "Not run"
	status.custom_minimum_size.x = 84
	row.add_child(status)
	_row_statuses.append(status)
	var duration := Label.new()
	duration.text = ""
	duration.custom_minimum_size.x = 72
	duration.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(duration)
	_row_durations.append(duration)
	var run_button := Button.new()
	run_button.text = "Run"
	run_button.pressed.connect(_on_run_one_pressed.bind(index))
	row.add_child(run_button)
	_results_list.add_child(row)
	_results.append({})

func _on_run_all_pressed() -> void:
	if _active_suite >= 0:
		return
	_clear_results()
	_is_run_all = true
	_pending_suites.clear()
	for i in range(_suites.size()):
		_pending_suites.append(i)
	_start_next_suite()

func _on_run_one_pressed(index: int) -> void:
	if _active_suite >= 0:
		return
	_clear_result(index)
	_is_run_all = false
	_pending_suites.clear()
	_pending_suites.append(index)
	_start_next_suite()

func _clear_results() -> void:
	for i in range(_suites.size()):
		_clear_result(i)
	_output.clear()
	_clear_locations()

func _clear_result(index: int) -> void:
	_results[index] = {}
	_row_statuses[index].text = "Queued"
	_row_durations[index].text = ""

func _start_next_suite() -> void:
	if _pending_suites.is_empty():
		_run_all_button.disabled = false
		if not _is_run_all:
			if _last_started_suite >= 0 and not _results[_last_started_suite].is_empty():
				var state := "passed" if _results[_last_started_suite]["passed"] else "failed"
				_status_label.text = "%s %s" % [_suites[_last_started_suite]["name"], state]
			return
		var passed := 0
		var failed := 0
		for result in _results:
			if result.is_empty():
				continue
			if result["passed"]:
				passed += 1
			else:
				failed += 1
		_status_label.text = "Complete: %d passed, %d failed" % [passed, failed]
		return
	_active_suite = _pending_suites.pop_front()
	_last_started_suite = _active_suite
	_run_all_button.disabled = true
	_row_statuses[_active_suite].text = "Running…"
	_status_label.text = "Running %s" % _suites[_active_suite]["name"]
	var executable := _headless_executable_path()
	var project_path := ProjectSettings.globalize_path("res://")
	var script_path: String = _suites[_active_suite]["path"]
	var error := _thread.start(_execute_suite.bind(executable, project_path, script_path))
	if error != OK:
		var start_error_output := "Could not start the headless Godot process: %s" % error_string(error)
		var failed_to_start := {
			"exit_code": -1,
			"duration_ms": 0,
			"output": start_error_output,
			"display_output": start_error_output,
			"passed": false,
			"failures": [start_error_output],
		}
		_results[_active_suite] = failed_to_start
		_show_suite_result(_active_suite, failed_to_start)
		_active_suite = -1
		_start_next_suite()

func _headless_executable_path() -> String:
	var executable := OS.get_executable_path()
	if OS.get_name() == "Windows":
		var console_executable := executable.get_basename() + "_console.exe"
		if FileAccess.file_exists(console_executable):
			return console_executable
	return executable

static func _execute_suite(executable: String, project_path: String, script_path: String) -> Dictionary:
	var output: Array = []
	var args := PackedStringArray([
		"--headless", "--path", project_path, "--script", script_path,
	])
	var started := Time.get_ticks_msec()
	var exit_code := OS.execute(executable, args, output, true)
	var output_text := str(output[0]) if not output.is_empty() else "(No output captured.)"
	var analysis := analyze_suite_output(output_text, exit_code)
	return {
		"exit_code": exit_code,
		"duration_ms": Time.get_ticks_msec() - started,
		"output": output_text,
		"passed": analysis["passed"],
		"failures": analysis["failures"],
	}

func shutdown() -> void:
	if _active_suite >= 0 and _thread.is_started():
		_thread.wait_to_finish()
		_active_suite = -1

func _show_suite_result(index: int, result: Dictionary) -> void:
	var passed := bool(result["passed"])
	_row_statuses[index].text = "PASS" if passed else "FAIL"
	_row_durations[index].text = _format_duration(int(result["duration_ms"]))
	_show_suite_output(index)

func _show_suite_output(index: int) -> void:
	var result := _results[index]
	if result.is_empty():
		return
	var output_text: String = str(result.get("display_output", result["output"]))
	var failures: Array = result.get("failures", [])
	if not failures.is_empty():
		output_text += "\n\nTest runner findings:\n- " + "\n- ".join(failures)
	_output.text = output_text
	_build_failure_locations(str(result["output"]))

func _build_failure_locations(output_text: String) -> void:
	_clear_locations()
	var regex := RegEx.new()
	if regex.compile(FAILURE_LOCATION_PATTERN) != OK:
		return
	var seen := {}
	for match in regex.search_all(output_text):
		var path := match.get_string("path")
		var line_text := match.get_string("line")
		if line_text.is_empty() or not ResourceLoader.exists(path):
			continue
		var line := int(line_text)
		var key := "%s:%d" % [path, line]
		if seen.has(key):
			continue
		seen[key] = true
		var link := LinkButton.new()
		link.text = key
		link.tooltip_text = "Open this script at line %d" % line
		link.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		link.pressed.connect(_open_failure_location.bind(path, line))
		_locations.add_child(link)
	if seen.is_empty():
		var empty := Label.new()
		empty.text = "No script locations were reported."
		_locations.add_child(empty)

func _open_failure_location(path: String, line: int) -> void:
	var script := ResourceLoader.load(path) as Script
	if script:
		EditorInterface.edit_script(script, line - 1, 0)

func _clear_locations() -> void:
	for child in _locations.get_children():
		child.queue_free()

func _format_duration(duration_ms: int) -> String:
	if duration_ms < 1000:
		return "%d ms" % duration_ms
	return "%.1f s" % (float(duration_ms) / 1000.0)
