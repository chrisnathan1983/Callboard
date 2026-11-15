"""Install a built Callboard ZIP into a blank fixture and exercise both exports."""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from zipfile import BadZipFile, ZipFile


LEAK_PATTERNS = (
    "ObjectDB instances were leaked",
    "RIDs of type ",
    "RID allocations of type ",
    "resources still in use at exit",
    "Leaked instance:",
    "Pages in use exist at exit in PagedAllocator",
    "Cannot get path of node as it is not in a scene tree",
)
ERROR_LINE = re.compile(r"^(?:SCRIPT )?ERROR:", re.MULTILINE)


def run_logged(command: list[str], cwd: Path, log_path: Path, env: dict[str, str],
               timeout: int = 120) -> str:
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                            text=True, timeout=timeout)
    output = result.stdout + result.stderr
    log_path.write_text(output, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(
            f"Command exited {result.returncode}: {' '.join(command)}\n"
            f"See {log_path}\n{output[-5000:]}"
        )
    errors = [line for line in output.splitlines() if ERROR_LINE.match(line.strip())]
    leaks = [line for line in output.splitlines() if any(pattern in line for pattern in LEAK_PATTERNS)]
    if errors or leaks:
        details = "\n".join(errors + leaks)
        raise RuntimeError(f"Unexpected Godot diagnostics. See {log_path}\n{details[-5000:]}")
    return output


def inspect_archive(archive_path: Path) -> list[str]:
    try:
        with ZipFile(archive_path) as archive:
            files = archive.namelist()
            if any(Path(name).is_absolute() or ".." in Path(name).parts for name in files):
                raise RuntimeError("The addon ZIP contains an unsafe path.")
            required = {
                "LICENSE",
                "addons/callboard/plugin.cfg",
                "addons/callboard/plugin.gd",
                "addons/callboard/core/stage.gd",
                "addons/callboard/editor/export_plugin.gd",
            }
            missing = sorted(required.difference(files))
            if missing:
                raise RuntimeError(f"The addon ZIP is missing required files: {missing}")
            if any(name.startswith("addons/callboard/tests/") for name in files):
                raise RuntimeError("The installable addon ZIP must not contain repository tests.")
            return files
    except BadZipFile as exc:
        raise RuntimeError(f"Not a valid ZIP archive: {archive_path}") from exc


def fixture_files(project: Path, platform: str, output_extension: str) -> None:
    project.joinpath("project.godot").write_text(
        '''; Generated blank project for Callboard package integration checks.
config_version=5

[application]
config/name="Callboard Package Fixture"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.7")

[editor_plugins]
enabled=PackedStringArray("res://addons/callboard/plugin.cfg", "res://addons/callboard/tests/package_probe_plugin.cfg")

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
''', encoding="utf-8")
    project.joinpath("main.tscn").write_text(
        '''[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://main.gd" id="1_main"]

[node name="PackageFixture" type="Node"]
script = ExtResource("1_main")
''', encoding="utf-8")
    project.joinpath("main.gd").write_text(
        '''extends Node

const StageScript := preload("res://addons/callboard/core/stage.gd")
const RuleScript := preload("res://addons/callboard/core/rule.gd")
const StepScript := preload("res://addons/callboard/core/step.gd")

func _ready() -> void:
	_run_package_check()

func _run_package_check() -> void:
	var expects_debug := "--expect-debug" in OS.get_cmdline_user_args()
	var expects_source_probe := "--expect-source" in OS.get_cmdline_user_args()
	var expected_editor := expects_debug
	var assets_ok := ResourceLoader.exists("res://addons/callboard/core/stage.gd") \
		and ResourceLoader.exists("res://addons/callboard/core/stage_definition.gd") \
		and ResourceLoader.exists("res://addons/callboard/editor/rule_graph_view.gd") == expected_editor \
		and ResourceLoader.exists("res://addons/callboard/editor/test_runner_panel.gd") == expected_editor \
		and ResourceLoader.exists("res://addons/callboard/model/rule_graph_reader.gd") == expected_editor \
		and ResourceLoader.exists("res://addons/callboard/plugin.gd") == expected_editor \
		and ResourceLoader.exists("res://addons/callboard/tests/package_probe_plugin.gd") == expects_source_probe \
		and not ResourceLoader.exists("res://addons/callboard/tests/unit.gd")
	var stage := StageScript.new()
	stage.name = "MinimalPackageStage"
	stage.external_calls.append(&"package_probe")
	add_child(stage)
	var wait_rule := RuleScript.new(&"pending_package_wait", &"package_probe")
	wait_rule.steps.append(StepScript.new(func(_payload: Dictionary) -> void: pass).after(60.0))
	stage.engine.rules.append(wait_rule)
	stage.activate()
	stage.fire(&"package_probe")
	await get_tree().process_frame
	var wait_started: bool = not stage.engine.active_snapshot().is_empty()
	stage.deactivate()
	await get_tree().process_frame
	var wait_cancelled: bool = stage.engine.active_snapshot().is_empty()
	stage.queue_free()
	await get_tree().process_frame
	var passed: bool = assets_ok and wait_started and wait_cancelled
	print("CALLBOARD_PACKAGE_STAGE: ", "PASS" if passed else "FAIL",
		" assets=", assets_ok, " wait_started=", wait_started,
		" wait_cancelled=", wait_cancelled)
	get_tree().quit(0 if passed else 1)
''', encoding="utf-8")
    tests = project / "addons" / "callboard" / "tests"
    tests.mkdir(parents=True)
    tests.joinpath("package_probe_plugin.cfg").write_text(
        '''[plugin]
name="Callboard Package Probe"
description="Integration probe for the packaged Callboard editor plugin."
author="Callboard CI"
version="1.0"
script="package_probe_plugin.gd"
''', encoding="utf-8")
    tests.joinpath("package_probe_plugin.gd").write_text(
        '''@tool
extends EditorPlugin

const TestRunnerPanelScript := preload("res://addons/callboard/editor/test_runner_panel.gd")

func _enter_tree() -> void:
	_check_editor_registration.call_deferred()

func _check_editor_registration() -> void:
	var main_screen := EditorInterface.get_editor_main_screen()
	var board_found := false
	for _frame in 120:
		for child in main_screen.get_children():
			var script := child.get_script() as Script
			if script != null and script.resource_path.ends_with("/editor/callboard.gd"):
				board_found = true
				break
		if board_found:
			break
		await get_tree().process_frame
	var available_suites := TestRunnerPanelScript.available_suites()
	var runner_present := false
	for control in EditorInterface.get_base_control().find_children("*", "VBoxContainer", true, false):
		var script := control.get_script() as Script
		if script != null and script.resource_path.ends_with("/test_runner_panel.gd"):
			runner_present = true
	var passed: bool = board_found and available_suites.is_empty() and not runner_present
	print("CALLBOARD_PACKAGE_EDITOR: ", "PASS" if passed else "FAIL",
		" board=", board_found, " suites=", available_suites.size(),
		" runner=", runner_present)
''', encoding="utf-8")
    preset_name_debug = "Callboard Debug"
    preset_name_release = "Callboard Release"
    preset = f'''[preset.0]
name="{preset_name_debug}"
platform="{platform}"
runnable=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path="build/callboard-debug{output_extension}"
encryption_include_filters=""
encryption_exclude_filters=""
encrypt_pck=false
encrypt_directory=false

[preset.0.options]
binary_format/64_bits=true
binary_format/embed_pck=false
custom_template/debug=""
custom_template/release=""

[preset.1]
name="{preset_name_release}"
platform="{platform}"
runnable=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path="build/callboard-release{output_extension}"
encryption_include_filters=""
encryption_exclude_filters=""
encrypt_pck=false
encrypt_directory=false

[preset.1.options]
binary_format/64_bits=true
binary_format/embed_pck=false
custom_template/debug=""
custom_template/release=""
'''
    project.joinpath("export_presets.cfg").write_text(preset, encoding="utf-8")


def godot_environment(workdir: Path, export_templates: Path | None) -> dict[str, str]:
    env = os.environ.copy()
    user_data = workdir / "godot-user-data"
    if sys.platform == "win32":
        env["APPDATA"] = str(user_data / "Roaming")
        env["LOCALAPPDATA"] = str(user_data / "Local")
        source = export_templates or Path(os.environ.get("APPDATA", "")) / "Godot" / "export_templates" / "4.7.2.stable"
        destination = Path(env["APPDATA"]) / "Godot" / "export_templates" / "4.7.2.stable"
    else:
        env["XDG_DATA_HOME"] = str(user_data / "share")
        env["XDG_CONFIG_HOME"] = str(user_data / "config")
        env["XDG_CACHE_HOME"] = str(user_data / "cache")
        source = export_templates or Path.home() / ".local" / "share" / "godot" / "export_templates" / "4.7.2.stable"
        destination = Path(env["XDG_DATA_HOME"]) / "godot" / "export_templates" / "4.7.2.stable"
    if not source.is_dir():
        raise RuntimeError(
            "Godot export templates were not found. Install the 4.7.2-stable templates or pass --export-templates."
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination)
    return env


def run_check(archive_path: Path, godot: Path, workdir: Path,
              export_templates: Path | None) -> None:
    files = inspect_archive(archive_path)
    workdir.mkdir(parents=True)
    logs = workdir / "logs"
    logs.mkdir()
    env = godot_environment(workdir, export_templates)
    project = workdir / "fixture"
    project.mkdir()
    with ZipFile(archive_path) as archive:
        archive.extractall(project)

    is_windows = sys.platform == "win32"
    platform = "Windows Desktop" if is_windows else "Linux"
    extension = ".exe" if is_windows else ".x86_64"
    fixture_files(project, platform, extension)

    run_logged([str(godot), "--headless", "--editor", "--path", str(project), "--import"],
               project, logs / "editor-import.log", env)
    editor_command = [str(godot), "--headless", "--editor", "--path", str(project),
                      "--quit-after", "180", "--verbose"]
    for iteration in range(1, 4):
        output = run_logged(editor_command, project,
                            logs / f"editor-plugin-cycle-{iteration}.log", env)
        if "Loading resource: res://addons/callboard/plugin.gd" not in output \
                or "Unloading addon: res://addons/callboard/plugin.cfg" not in output \
                or "CALLBOARD_PACKAGE_EDITOR: PASS" not in output:
            raise RuntimeError(f"The editor did not load and unload the packaged plugin; see {logs}")

    source_runtime = run_logged(
        [str(godot), "--headless", "--path", str(project), "--",
         "--expect-debug", "--expect-source"],
        project, logs / "source-stage-smoke.log", env)
    if "CALLBOARD_PACKAGE_STAGE: PASS" not in source_runtime:
        raise RuntimeError(f"Minimal source Stage smoke test failed; see {logs}")

    export_modes = (
        ("debug", "--export-debug", "Callboard Debug", "--expect-debug"),
        ("release", "--export-release", "Callboard Release", "--expect-release"),
    )
    for mode, export_flag, preset_name, runtime_arg in export_modes:
        output_path = project / "build" / f"callboard-{mode}{extension}"
        output_path.parent.mkdir(parents=True, exist_ok=True)
        export_output = run_logged(
            [str(godot), "--headless", "--path", str(project), export_flag,
             preset_name, str(output_path)], project, logs / f"export-{mode}.log",
            env, timeout=240)
        if not output_path.is_file():
            raise RuntimeError(f"The {mode} executable was not created. See {logs}")
        pck_path = output_path.with_suffix(".pck")
        if not pck_path.is_file():
            raise RuntimeError(f"The {mode} export did not create its external PCK. See {logs}")
        app_output = run_logged(
            [str(output_path), "--headless", "--", runtime_arg],
            project, logs / f"runtime-{mode}.log", env, timeout=120)
        if "CALLBOARD_PACKAGE_STAGE: PASS" not in app_output:
            raise RuntimeError(f"The {mode} exported runtime did not start the Stage. See {logs}")
        if not export_output.strip():
            raise RuntimeError(f"Godot produced no {mode} export output. See {logs}")

    print(f"Packaged addon check passed: {archive_path.name}")
    print("Verified ZIP contents, clean plugin install, hidden developer panel without suites,")
    print("three editor setup/teardown cycles, pending-wait cancellation, and debug/release runtimes.")
    print(f"Logs: {logs}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--workdir", required=True, type=Path)
    parser.add_argument("--export-templates", type=Path)
    args = parser.parse_args()
    try:
        run_check(args.archive.resolve(), args.godot.resolve(), args.workdir.resolve(),
                  args.export_templates.resolve() if args.export_templates else None)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"Package integration check failed: {exc}", file=sys.stderr)
        if args.workdir.exists():
            print(f"Fixture and diagnostic logs were kept at: {args.workdir}", file=sys.stderr)
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()
