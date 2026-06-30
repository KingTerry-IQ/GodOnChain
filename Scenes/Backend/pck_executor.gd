extends Node
class_name PckExecutor

signal godot_exe_path_selected(path: String)

@onready var godot_selector_file_dialog: FileDialog = $GodotSelector

var _godot_exe_path: String = ""
var _pck_path: String = ProjectSettings.globalize_path("user://app/app.pck")  # Path to your exported .pck

func select_godot_exe_path() -> void:
	godot_selector_file_dialog.popup_centered_ratio(0.6)

func execute_subproject(pck_path: String = _pck_path) -> int:
	# Validate paths exist
	if not FileAccess.file_exists(_godot_exe_path):
		push_error("Godot executable not found at: " + _godot_exe_path)
		return -1
	
	if not FileAccess.file_exists(pck_path):
		push_error("PCK file not found at: " + pck_path)
		return -1
	
	# Launch the subproject independently (non-blocking)
	# Returns the Process ID (PID) on success, or -1 on failure
	var pid: int = OS.create_process(
		_godot_exe_path,
		["--main-pack", pck_path, "--verbose"],
		true   # open_console (same behavior as your original code)
	)
	
	if pid == -1:
		push_error("Failed to launch subproject: " + pck_path)
		return -1
	
	print("Subproject launched successfully! PID: ", pid)
	return pid
		
		
func _on_godot_selector_file_selected(path: String) -> void:
	_godot_exe_path = path
	godot_exe_path_selected.emit(path)
	print("Godot executable selected: " + path)

func _on_godot_selector_canceled() -> void:
	push_warning("Godot executable selection canceled. Subproject not launched.")
