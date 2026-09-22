## Launches an inscribed Godot package as its own process.
##
## Before launching, it mints that app a scoped token on the IQ sidecar and
## puts the connection details in the environment, so the app can use the
## on-chain SDK through addons/iq_client/iq_client.gd without shipping keys or
## needing GodOnChain's GDExtensions. The token is read-only: writes come back
## to the user as an approval prompt, tagged with the label set here.

extends Node
class_name PckExecutor

signal godot_exe_path_selected(path: String)

const VERSIONS_URL := "https://godotengine.org/versions.json"
const GITHUB_RELEASES := "https://api.github.com/repos/godotengine/godot/releases?per_page=20"
const GITHUB_DOWNLOAD := "https://github.com/godotengine/godot/releases/download/%s-stable/%s"
const BUILDS_DOWNLOAD := "https://github.com/godotengine/godot-builds/releases/download/%s-stable/%s"
const TUXFAMILY_DOWNLOAD := "https://downloads.tuxfamily.org/godotengine/%s/%s"
const BIN_ROOT := "user://bin/godot"
const VERSION_PATH := "user://bin/godot/VERSION"
const UA := "GodOnChain/0.1 (Godot fetch)"

@onready var godot_selector_file_dialog: FileDialog = $GodotSelector

## Set by IQ_SDK. Left null, apps simply launch without on-chain access.
var host: IQHost

var last_error: String = ""
var _godot_exe_path: String = ""
var _pck_path: String = ProjectSettings.globalize_path("user://app/app.pck")  # Path to your exported .pck
var _ensure_in_flight: bool = false

## token id -> pid, so a token can be revoked once its app exits.
var _launched: Dictionary = {}


func _ready() -> void:
	# Reap tokens for apps that have since closed.
	var reaper := Timer.new()
	reaper.wait_time = 10.0
	reaper.timeout.connect(_revoke_finished_apps)
	add_child(reaper)
	reaper.start()


func select_godot_exe_path() -> void:
	godot_selector_file_dialog.popup_centered_ratio(0.6)


func has_godot_exe() -> bool:
	return not _godot_exe_path.is_empty() and FileAccess.file_exists(_godot_exe_path)


## If no executable is selected (or the saved path is gone), download the
## latest Godot 4 stable for this OS and point at it. A path the user already
## picked is left alone. Safe to call twice: a second caller waits.
func ensure_latest_godot(progress: Callable = Callable()) -> bool:
	last_error = ""
	if has_godot_exe():
		return true
	if _ensure_in_flight:
		while _ensure_in_flight:
			await get_tree().process_frame
		return has_godot_exe()
	_ensure_in_flight = true
	var ok := await _fetch_latest_godot(progress)
	_ensure_in_flight = false
	return ok or has_godot_exe()


## Launches the package. `label` names the app in approval prompts; pass the
## signature or filename so the user can tell which app is asking to spend.
func execute_subproject(pck_path: String = _pck_path, label: String = "") -> int:
	# Validate paths exist
	if not FileAccess.file_exists(_godot_exe_path):
		push_error("Godot executable not found at: " + _godot_exe_path)
		return -1

	if not FileAccess.file_exists(pck_path):
		push_error("PCK file not found at: " + pck_path)
		return -1

	var app_label := label if not label.is_empty() else pck_path.get_file()
	var token_id: String = await _publish_host_environment(app_label)

	# Launch the subproject independently (non-blocking)
	# Returns the Process ID (PID) on success, or -1 on failure
	var pid: int = OS.create_process(
		_godot_exe_path,
		["--main-pack", pck_path, "--verbose"],
		true   # open_console (same behavior as your original code)
	)

	# The child has its own copy now; don't leave a token in our environment
	# for the next app we launch to inherit.
	_clear_host_environment()

	if pid == -1:
		push_error("Failed to launch subproject: " + pck_path)
		if not token_id.is_empty():
			await host.revoke_app_token(token_id)
		return -1

	if not token_id.is_empty():
		_launched[token_id] = pid

	print("Subproject launched successfully! PID: ", pid)
	return pid


## Mints a token for the app and puts it in our environment, which the child
## inherits at spawn. Returns the token id, or "" if there is no host.
func _publish_host_environment(label: String) -> String:
	if host == null or not host.is_ready:
		return ""

	var launch: Dictionary = await host.launch_environment(label)
	if launch.is_empty():
		push_warning("Could not grant '%s' on-chain access: %s" % [label, host.last_error])
		return ""

	var env: Dictionary = launch.get("env", {})
	for key: String in env:
		OS.set_environment(key, str(env[key]))

	return str(launch.get("id", ""))


func _clear_host_environment() -> void:
	OS.unset_environment(IQClient.ENV_URL)
	OS.unset_environment(IQClient.ENV_TOKEN)
	OS.unset_environment(IQClient.ENV_APP)


## Revokes tokens belonging to apps that have exited, so a token cannot
## outlive the process it was minted for.
func _revoke_finished_apps() -> void:
	if host == null or not host.is_ready:
		return
	for token_id: String in _launched.keys():
		var pid: int = _launched[token_id]
		if not OS.is_process_running(pid):
			_launched.erase(token_id)
			await host.revoke_app_token(token_id)


func _on_godot_selector_file_selected(path: String) -> void:
	_godot_exe_path = path
	godot_exe_path_selected.emit(path)
	print("Godot executable selected: " + path)


func _on_godot_selector_canceled() -> void:
	push_warning("Godot executable selection canceled. Subproject not launched.")


func _fetch_latest_godot(progress: Callable) -> bool:
	_report_progress(progress, 1)
	var flavor := _editor_flavor()
	if flavor.is_empty():
		last_error = "No official Godot editor build for this OS."
		return false

	var version := await _latest_stable_4()
	if version.is_empty():
		version = "4.7.2"
		push_warning("Could not look up the latest Godot stable; trying %s." % version)

	var zip_name := "Godot_v%s-stable_%s.zip" % [version, flavor]
	var dest_dir := "%s/%s" % [BIN_ROOT, version]
	var cached := _find_godot_exe(ProjectSettings.globalize_path(dest_dir))
	if not cached.is_empty():
		if not has_godot_exe():
			_use_godot_exe(cached)
		_report_progress(progress, 100)
		return true

	_report_progress(progress, 5)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://bin"))
	var archive := "user://bin/godot-download.zip"
	var urls: PackedStringArray = [
		GITHUB_DOWNLOAD % [version, zip_name],
		BUILDS_DOWNLOAD % [version, zip_name],
		TUXFAMILY_DOWNLOAD % [version, zip_name],
	]
	var downloaded := false
	for url in urls:
		if await _download_file(url, archive, progress):
			downloaded = true
			break
	if not downloaded:
		if last_error.is_empty():
			last_error = "Could not download %s." % zip_name
		return false

	_report_progress(progress, 92)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dest_dir))
	if not _extract_zip(archive, dest_dir):
		return false
	DirAccess.remove_absolute(ProjectSettings.globalize_path(archive))

	var found := _find_godot_exe(ProjectSettings.globalize_path(dest_dir))
	if found.is_empty() or not FileAccess.file_exists(found):
		last_error = "Extracted Godot %s but could not find the editor binary." % version
		return false

	_mark_executable(found)
	_write_version(version)
	if not has_godot_exe():
		_use_godot_exe(found)
	_report_progress(progress, 100)
	return true


func _latest_stable_4() -> String:
	var from_site := await _latest_from_versions_json()
	if not from_site.is_empty():
		return from_site
	return await _latest_from_github_releases()


func _latest_from_versions_json() -> String:
	var parsed: Variant = await _http_json(VERSIONS_URL)
	if parsed is Array:
		for entry: Variant in parsed:
			if not entry is Dictionary:
				continue
			var name := str((entry as Dictionary).get("name", "")).strip_edges()
			if not name.begins_with("4."):
				continue
			var releases: Variant = (entry as Dictionary).get("releases", [])
			if releases is Array:
				for rel: Variant in releases:
					if rel is Dictionary and str((rel as Dictionary).get("name", "")) == "stable":
						return name
	return ""


func _latest_from_github_releases() -> String:
	var parsed: Variant = await _http_json(
		GITHUB_RELEASES,
		PackedStringArray([
			"User-Agent: %s" % UA,
			"Accept: application/vnd.github+json",
		])
	)
	if parsed is Array:
		for entry: Variant in parsed:
			if not entry is Dictionary:
				continue
			var rec := entry as Dictionary
			if rec.get("prerelease", false):
				continue
			var tag := str(rec.get("tag_name", "")).strip_edges()
			if tag.begins_with("4.") and tag.ends_with("-stable"):
				return tag.trim_suffix("-stable")
	return ""


func _editor_flavor() -> String:
	var osn := OS.get_name()
	if osn == "Windows":
		if OS.has_feature("arm64"):
			return "windows_arm64.exe"
		if OS.has_feature("x86_64"):
			return "win64.exe"
		if OS.has_feature("x86_32"):
			return "win32.exe"
		return "win64.exe"
	if osn == "macOS":
		return "macos.universal"
	if osn == "Linux":
		if OS.has_feature("arm64"):
			return "linux.arm64"
		if OS.has_feature("arm32"):
			return "linux.arm32"
		if OS.has_feature("x86_64"):
			return "linux.x86_64"
		if OS.has_feature("x86_32"):
			return "linux.x86_32"
		return "linux.x86_64"
	return ""


func _http_json(url: String, headers: PackedStringArray = PackedStringArray()) -> Variant:
	var http := HTTPRequest.new()
	http.timeout = 30
	add_child(http)
	if not http.is_inside_tree():
		await get_tree().process_frame
	if headers.is_empty():
		headers = PackedStringArray(["User-Agent: %s" % UA])
	var err := http.request(url, headers)
	if err != OK:
		last_error = "Could not start request to %s (%s)." % [url, error_string(err)]
		http.queue_free()
		return null
	var result: Array = await http.request_completed
	http.queue_free()
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200:
		last_error = "%s returned HTTP %s." % [url, str(result[1])]
		return null
	return JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())


func _download_file(url: String, dest: String, progress: Callable) -> bool:
	var abs_dest := ProjectSettings.globalize_path(dest)
	DirAccess.make_dir_recursive_absolute(abs_dest.get_base_dir())
	var http := HTTPRequest.new()
	http.timeout = 0
	http.download_file = abs_dest
	http.download_chunk_size = 1024 * 1024
	add_child(http)
	if not http.is_inside_tree():
		await get_tree().process_frame
	var ticker := Timer.new()
	ticker.wait_time = 0.4
	ticker.timeout.connect(func() -> void:
		var total := http.get_body_size()
		if total > 0:
			_report_progress(progress, 5 + int(85.0 * float(http.get_downloaded_bytes()) / float(total)))
	)
	add_child(ticker)
	var err := http.request(url, PackedStringArray(["User-Agent: %s" % UA]))
	if err != OK:
		last_error = "Could not start download from %s." % url
		ticker.queue_free()
		http.queue_free()
		return false
	ticker.start()
	var result: Array = await http.request_completed
	ticker.stop()
	ticker.queue_free()
	http.queue_free()
	if int(result[1]) != 200:
		last_error = "Download from %s returned HTTP %s." % [url, str(result[1])]
		DirAccess.remove_absolute(abs_dest)
		return false
	if not FileAccess.file_exists(abs_dest):
		last_error = "Download finished but %s is missing." % abs_dest
		return false
	var size := FileAccess.get_size(abs_dest)
	if size < 1_000_000:
		last_error = "Downloaded file is too small to be a Godot editor (%s bytes)." % str(size)
		DirAccess.remove_absolute(abs_dest)
		return false
	return true


func _extract_zip(archive: String, dest: String) -> bool:
	var abs_archive := ProjectSettings.globalize_path(archive)
	var abs_dest := ProjectSettings.globalize_path(dest)
	var zip := ZIPReader.new()
	if zip.open(abs_archive) != OK:
		last_error = "Could not open %s." % abs_archive
		return false
	for name in zip.get_files():
		if name.ends_with("/"):
			continue
		var out_path := abs_dest.path_join(name.replace("\\", "/"))
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var out := FileAccess.open(out_path, FileAccess.WRITE)
		if out == null:
			continue
		out.store_buffer(zip.read_file(name))
		out.close()
	zip.close()
	return true


func _find_godot_exe(dir: String) -> String:
	if dir.is_empty():
		return ""
	var macos := dir.path_join("Godot.app").path_join("Contents").path_join("MacOS").path_join("Godot")
	if FileAccess.file_exists(macos):
		return macos
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	d.list_dir_begin()
	var fname := d.get_next()
	var nested: PackedStringArray = []
	var candidate := ""
	while fname != "":
		var full := dir.path_join(fname)
		if d.current_is_dir() and not fname.begins_with("."):
			nested.append(full)
		elif _is_godot_editor_binary(fname) and FileAccess.file_exists(full):
			if fname.to_lower().contains("console"):
				if candidate.is_empty():
					candidate = full
			else:
				d.list_dir_end()
				return full
		fname = d.get_next()
	d.list_dir_end()
	if not candidate.is_empty():
		return candidate
	for sub in nested:
		var hit := _find_godot_exe(sub)
		if not hit.is_empty():
			return hit
	return ""


func _is_godot_editor_binary(fname: String) -> bool:
	var lower := fname.to_lower()
	if lower.ends_with(".txt") or lower.ends_with(".md") or lower.ends_with(".zip") or lower.ends_with(".pck"):
		return false
	if lower == "godot":
		return true
	if lower.begins_with("godot_v") or (lower.begins_with("godot") and lower.ends_with(".exe")):
		return true
	return false


func _mark_executable(path: String) -> void:
	if OS.get_name() == "Windows":
		return
	OS.execute("chmod", PackedStringArray(["+x", path]), [], false, true)
	if OS.get_name() == "macOS":
		var app := path
		while not app.ends_with(".app") and app.get_base_dir() != app:
			app = app.get_base_dir()
		if app.ends_with(".app"):
			OS.execute("xattr", PackedStringArray(["-cr", app]), [], false, true)


func _write_version(version: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BIN_ROOT))
	var file := FileAccess.open(VERSION_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(version)
	file.close()


func _use_godot_exe(path: String) -> void:
	_on_godot_selector_file_selected(path)


func _report_progress(progress: Callable, percent: int) -> void:
	if progress.is_valid():
		progress.call(clampi(percent, 0, 100))
