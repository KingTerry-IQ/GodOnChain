# Cross-process check: proves an app GodOnChain launches can use the on-chain
# SDK through the host, with no keys, no GDExtension and no copy of the SDK.
#
# Starts the sidecar, mints a token the way PckExecutor does, launches
# examples/onchain_hello as a separate Godot process, and answers the approval
# its write raises.
#
# Run: Godot --headless --path . --script res://tools/iq_apptest.gd
extends SceneTree

const EXAMPLE_PATH := "res://examples/onchain_hello"
const RESULT_FILE := "user://apptest_result.json"

var failures := 0
var seen_approval: Dictionary = {}


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  PASS  ", label)
	else:
		failures += 1
		print("  FAIL  ", label, "  ", detail)


func _capture(approval: Dictionary) -> void:
	seen_approval = approval


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame

	var host := IQHost.new()
	# Disposable vault: the real keys are never touched by a test.
	host.secrets_path = "user://apptest_secrets.cfg"
	host.salt_path = "user://apptest_secrets.salt"
	# Disposable discovery file too — publishing at the real location would
	# point every app on the machine at this suite's sidecar, and removing it
	# on teardown would leave a running GodOnChain undiscoverable.
	host.discovery_file = "user://apptest_host.json"
	root.add_child(host)
	await process_frame
	host.approval_requested.connect(_capture)

	print("\n--- host ---")
	var started: bool = await host.start()
	check("sidecar starts", started, host.last_error)
	if not started:
		_finish()
		return

	# Exactly what PckExecutor does before OS.create_process.
	var launch: Dictionary = await host.launch_environment("onchain_hello.pck")
	check("mints a token for the app", not launch.is_empty(), host.last_error)
	if launch.is_empty():
		host.stop()
		_finish()
		return

	print("\n--- launching the app as its own process ---")
	var result_path := ProjectSettings.globalize_path(RESULT_FILE)
	DirAccess.remove_absolute(result_path)

	var env: Dictionary = launch.get("env", {})
	for key: String in env:
		OS.set_environment(key, str(env[key]))

	# A stock Godot binary, exactly as PckExecutor uses. No extensions of ours.
	var pid := OS.create_process(
		OS.get_executable_path(),
		[
			"--headless",
			"--path",
			ProjectSettings.globalize_path(EXAMPLE_PATH),
			"--",
			"--write",
			"hello from an inscribed app",
			"--result-file",
			result_path,
			"--quit-when-done",
		],
		false
	)
	for key: String in env:
		OS.unset_environment(key)

	check("app process launched", pid != -1)
	if pid == -1:
		host.stop()
		_finish()
		return

	print("\n--- approval ---")
	var waited := 0
	while seen_approval.is_empty() and waited < 240:
		await create_timer(0.25).timeout
		waited += 1

	check("the app's write reached the host", not seen_approval.is_empty())
	if not seen_approval.is_empty():
		check(
			"  attributed to the app",
			str(seen_approval.get("label", "")) == "onchain_hello.pck",
			str(seen_approval.get("label", ""))
		)
		var details: Dictionary = seen_approval.get("details", {})
		check("  carries the filename", str(details.get("filename", "")) == "hello.txt")
		check("  carries a byte count", int(details.get("bytes", 0)) > 0)

		var denied: bool = await host.resolve_approval(str(seen_approval.get("id", "")), false)
		check("host denies it", denied)

	print("\n--- what the app saw ---")
	waited = 0
	while OS.is_process_running(pid) and waited < 240:
		await create_timer(0.25).timeout
		waited += 1
	check("app exited", not OS.is_process_running(pid))

	var report := _read_result(result_path)
	check("app reported back", not report.is_empty())
	if not report.is_empty():
		check("  it connected to the host", bool(report.get("connected", false)))
		check(
			"  it knew its own name",
			str(report.get("label", "")) == "onchain_hello.pck",
			str(report.get("label", ""))
		)
		check("  the denied write failed", not bool(report.get("ok", true)))
		var reported := str(report.get("error", "")).to_lower()
		check(
			"  because the user said no",
			reported.contains("deni") or reported.contains("declin"),
			reported
		)
		check(
			"  not because it lacked access",
			not reported.contains("authoris") and not reported.contains("token"),
			reported
		)

	host.stop()
	DirAccess.remove_absolute(result_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(host.secrets_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(host.salt_path))
	_finish()


func _read_result(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _finish() -> void:
	print("\n%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
