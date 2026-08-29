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

@onready var godot_selector_file_dialog: FileDialog = $GodotSelector

## Set by IQ_SDK. Left null, apps simply launch without on-chain access.
var host: IQHost

var _godot_exe_path: String = ""
var _pck_path: String = ProjectSettings.globalize_path("user://app/app.pck")  # Path to your exported .pck

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
