## GodOnChain's own front end onto the IQ Labs SDK.
##
## The SDK itself runs in the bundled sidecar that IQHost starts (see
## iq_host.gd for why it stays a service rather than becoming in-process
## GDScript). This node owns that host, talks to it through the same IQClient
## that launched .pck apps use, and adds the app-level behaviour on top:
## file pick/save dialogs, encryption, and running downloaded Godot packages.

extends Node

class_name IQ_SDK

signal load_started
signal load_complete
signal load_failed

signal file_upload_path_selected(path: String)
signal godot_exe_path_selected(path: String)

## Forwarded from IQHost so the UI can report backend problems.
signal backend_ready(url: String)
signal backend_failed(reason: String)

@onready var file_upload_dialog: FileDialog = $FileUploadSelector
@onready var file_download_dialog: FileDialog = $FileDownloadSelector
@onready var pck_executor: PckExecutor = $PckExecutor
@onready var data_handler: DataHandler = $DataHandler

## The bundled sidecar process.
var host: IQHost
## Our connection to it. Identical to what child apps get.
var client: IQClient
## Keys and RPC endpoints, formerly the wrapper repo's .env file.
var settings: IQSettings
## "App X wants to spend" prompts.
var approvals: IQApprovals

var _file_upload_path: String = ""

var downloaded_data: PackedByteArray # Holds the file data after download


func _ready() -> void:
	host = IQHost.new()
	host.name = "IQHost"
	add_child(host)

	approvals = IQApprovals.new(host)
	approvals.name = "IQApprovals"
	add_child(approvals)

	settings = IQSettings.new(host)
	settings.name = "IQSettings"
	add_child(settings)
	# Keys are read by the sidecar at spawn, so changing them means a restart.
	settings.settings_saved.connect(_on_settings_saved)

	client = IQClient.new()
	client.name = "IQClient"
	add_child(client)

	host.sidecar_ready.connect(_on_sidecar_ready)
	host.sidecar_failed.connect(func(reason: String) -> void: backend_failed.emit(reason))
	host.sidecar_lost.connect(func(reason: String) -> void: backend_failed.emit(reason))

	# Launched apps reach the sidecar through their own minted token.
	pck_executor.host = host
	data_handler.client = client


## Builds the on-chain screens under `root`, the themed Control they live in.
func attach_ui(root: Control) -> void:
	settings.attach(root)
	approvals.attach(root)


## Starts the bundled sidecar and connects to it. Returns true when usable.
func start_backend() -> bool:
	if not await host.start():
		return false
	return await client.discover()


func _on_settings_saved() -> void:
	await restart_backend()


## Restarts the sidecar, e.g. after the keys changed.
func restart_backend() -> bool:
	host.stop()
	return await start_backend()


func _on_sidecar_ready(url: String) -> void:
	backend_ready.emit(url)


## True once there is a signer configured for the chain.
func can_write(chain: String) -> bool:
	return host != null and host.can_write(chain)


func select_file_for_upload() -> void:
	file_upload_dialog.popup_centered_ratio(0.6)


#region Reads

func read_code_in_metadata(
	signature: String, progress_callback: Callable = Callable(), chain: String = "SOL"
) -> String:
	load_started.emit()

	var metadata_dict: Dictionary = await client.read_metadata(signature, chain)

	if metadata_dict.is_empty():
		push_error("Metadata read failed: " + client.last_error)
		load_failed.emit()
		return ""

	if progress_callback.is_valid():
		progress_callback.call(100.0)

	load_complete.emit()
	return JSON.stringify(metadata_dict)


func read_code_in_text(
	signature: String,
	encrypt_type: int = 0,
	encrypt_pass: String = "",
	progress_callback: Callable = Callable(),
	chain: String = "SOL"
) -> String:
	load_started.emit()
	var response = await client.read_code_in(signature, chain, progress_callback)
	if response:
		var decrypted: String = await data_handler.decrypt(response.data, encrypt_type, encrypt_pass)
		load_complete.emit()
		return decrypted
	push_error("Read failed: " + client.last_error)
	load_failed.emit()
	return ""


func read_code_in_file(
	signature: String,
	encrypt_type: int = 0,
	encrypt_pass: String = "",
	progress_callback: Callable = Callable(),
	chain: String = "SOL"
) -> void:
	load_started.emit()
	var response = await client.read_code_in(signature, chain, progress_callback)
	if !response:
		push_error("Read failed: " + client.last_error)
		load_failed.emit()
		return
	var decrypted: String = await data_handler.decrypt(response.data, encrypt_type, encrypt_pass)
	downloaded_data = _base64_to_raw(decrypted)
	var metadata = JSON.parse_string(response.metadata)
	var filename: String = metadata.filename
	var filetype: String = metadata.filetype
	if filetype.is_empty():
		filetype = filename.get_extension() #This generally shouldn't happen
	file_download_dialog.clear_filters()
	if !filetype.is_empty():
		var filter_desc = filetype.to_upper() + " Files"
		file_download_dialog.add_filter("*." + filetype + " ; " + filter_desc)

	var downloads_abs_path: String = ProjectSettings.globalize_path("user://downloads")

	file_download_dialog.root_subfolder = downloads_abs_path
	file_download_dialog.current_dir = downloads_abs_path
	file_download_dialog.current_file = filename

	file_download_dialog.popup_centered(Vector2i(900, 600))


func read_code_in_godot_pck(
	signature: String,
	encrypt_type: int = 0,
	encrypt_pass: String = "",
	use_cache: bool = false,
	progress_callback: Callable = Callable(),
	chain: String = "SOL"
) -> void:
	load_started.emit()

	var dir_path: String = "user://app/%s" % signature
	var dir_err = DirAccess.make_dir_recursive_absolute(dir_path)
	if dir_err != OK:
		push_error("Failed to create directory: " + error_string(dir_err))
		load_failed.emit()
		return

	if use_cache:
		# Check only the immediate directory for a cached .pck or .zip file
		var dir := DirAccess.open(dir_path)
		if dir:
			var files := dir.get_files()
			for file_name in files:
				var ext := file_name.get_extension().to_lower()
				if ext == "pck" or ext == "zip":
					var cached_path := dir_path + "/" + file_name
					var cached_globalized_path := ProjectSettings.globalize_path(cached_path)
					print("Using cached file: " + cached_globalized_path)
					await pck_executor.execute_subproject(cached_globalized_path, signature)
					load_complete.emit()
					return  # Skip download
	var response = await client.read_code_in(signature, chain, progress_callback)
	if !response:
		push_error("Read failed: " + client.last_error)
		load_failed.emit()
		return
	var decrypted: String = await data_handler.decrypt(response.data, encrypt_type, encrypt_pass)
	downloaded_data = _base64_to_raw(decrypted)
	var metadata: Dictionary = response.metadata if response.metadata is Dictionary else (JSON.parse_string(response.metadata) or {}) if response.metadata is String else {}
	var filename: String = metadata.get("filename", metadata.get("handle", ""))
	var filetype: String = metadata.get("filetype", metadata.get("typeField", ""))
	if filetype != "pck" && filetype != "zip":
		push_warning("The metadata does not label the file as a pck/zip.  We will not attempt to download/run it.  Switch the read to Downloadable File if you still want to download it.")
		return
	var file_path = "user://app/%s/%s" % [signature, filename]
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		push_error("Filed to open file for writing: " + str(FileAccess.get_open_error()))
		load_failed.emit()
		return
	file.store_buffer(downloaded_data)
	file.close()

	var globalized_path = ProjectSettings.globalize_path(file_path)

	print("File downloaded and saved to: " + globalized_path)
	await pck_executor.execute_subproject(globalized_path, signature)
	load_complete.emit()

#endregion


#region Writes

func write_code_in_text(
	data: String,
	encrypt_type: int = 0,
	encrypt_pass: String = "",
	progress_callback: Callable = Callable(),
	chain: String = "SOL"
) -> String:
	load_started.emit()
	var encrypted: String = await data_handler.encrypt(data, encrypt_type, encrypt_pass)
	var response = await client.write_code_in(encrypted, "", "", chain, progress_callback)
	if response:
		load_complete.emit()
		return str(response)
	push_error("Write failed: " + client.last_error)
	load_failed.emit()
	return ""


func write_code_in_file(
	encrypt_type: int = 0,
	encrypt_pass: String = "",
	progress_callback: Callable = Callable(),
	chain: String = "SOL"
) -> String:
	load_started.emit()

	if _file_upload_path.is_empty():
		push_warning("File not yet selected")
		load_failed.emit()
		return ""

	var base64_data: String = _file_to_base64(_file_upload_path)
	if base64_data.is_empty():
		load_failed.emit()
		return ""
	var filename = _file_upload_path.get_file()
	var filetype = _file_upload_path.get_extension().to_lower()

	var encrypted: String = await data_handler.encrypt(base64_data, encrypt_type, encrypt_pass)

	var response = await client.write_code_in(
		encrypted, filename, filetype, chain, progress_callback
	)
	if response:
		load_complete.emit()
		return str(response)
	push_error("Write failed: " + client.last_error)
	load_failed.emit()
	return ""

#endregion


#region Cost estimates

func estimate_code_in_file_cost_SOL() -> float:
	if _file_upload_path.is_empty():
		push_warning("File not yet selected")
		return 0.0

	if not FileAccess.file_exists(_file_upload_path):
		push_warning("File does not exist at: " + _file_upload_path)
		return 0.0

	var file = FileAccess.open(_file_upload_path, FileAccess.READ)
	if file == null:
		push_warning("Cannot open file. Error code: " + str(FileAccess.get_open_error()))
		return 0.0

	var original_size: int = file.get_length()
	file.close()

	if original_size <= 0:
		push_warning("File is empty (0 bytes)")
		return 0.0

	@warning_ignore("integer_division")
	var base64_length: int = ((original_size + 2) / 3) * 4

	@warning_ignore("integer_division")
	var num_chunks: int = (base64_length + 849) / 850

	var initial_tx: float = 0.0001
	var per_chunk: float = 0.000005
	var final_tx: float = 0.005005

	var total_cost: float = initial_tx + (num_chunks * per_chunk) + final_tx
	return total_cost


func estimate_code_in_file_cost_MON() -> float:
	if _file_upload_path.is_empty():
		push_warning("File not yet selected")
		return 0.0

	if not FileAccess.file_exists(_file_upload_path):
		push_warning("File does not exist at: " + _file_upload_path)
		return 0.0

	var file = FileAccess.open(_file_upload_path, FileAccess.READ)
	if file == null:
		push_warning("Cannot open file. Error code: " + str(FileAccess.get_open_error()))
		return 0.0

	var original_size: int = file.get_length()
	file.close()

	if original_size <= 0:
		push_warning("File is empty (0 bytes)")
		return 0.0

	@warning_ignore("integer_division")
	var base64_length: int = ((original_size + 2) / 3) * 4

	@warning_ignore("integer_division")
	var num_chunks: int = (base64_length + 849) / 70656 #Assumed, conservatively, ~69KB/chunk, as calculated from the number of transactions, though the real amount may be ~95KB/chunk

	var initial_tx: float = 0
	var per_chunk: float = 0.415971708
	var final_tx: float = 6.51834143

	var total_cost: float = initial_tx + (num_chunks * per_chunk) + final_tx
	return total_cost

#endregion


#region Database
# ID semantics for browser: table list always takes dbRootId as "ID".
# Table rows: SOL "ID" = tablePda ; MON "ID" = "dbRootId/tableName" (slash composite)
# or pass table_name.

func get_db_table_list(
	db_root_id: String, progress_callback: Callable = Callable(), chain: String = "SOL"
) -> Dictionary:
	load_started.emit()

	var result: Dictionary = await client.get_db_table_list(db_root_id, chain, progress_callback)
	if result.is_empty():
		push_error("Table list read failed: " + client.last_error)
		load_failed.emit()
		return {}

	load_complete.emit()
	return result


func read_db_table_rows(
	db_root_or_pda: String,
	table_name: String = "",
	progress_callback: Callable = Callable(),
	chain: String = "SOL",
	limit: int = 20,
	before: String = ""
) -> Dictionary:
	load_started.emit()

	var normalized := chain.to_lower()
	var result: Dictionary

	if normalized == "mon" or normalized == "monad":
		var root_id := db_root_or_pda
		var t_name := table_name
		if t_name.is_empty() and db_root_or_pda.contains("/"):
			var parts := db_root_or_pda.split("/", true, 1)
			root_id = parts[0]
			t_name = parts[1]
		if t_name.is_empty():
			push_error(
				"MON readTableRows requires tableName (use 'dbRoot/tableName' in ID field or pass as 2nd arg)"
			)
			load_failed.emit()
			return {}
		result = await client.read_db_table_rows(
			"", root_id, t_name, chain, limit, before, progress_callback
		)
	else:
		result = await client.read_db_table_rows(
			db_root_or_pda, "", "", chain, limit, before, progress_callback
		)

	if result.is_empty():
		push_error("Row read failed: " + client.last_error)
		load_failed.emit()
		return {}

	load_complete.emit()
	return result

#endregion


#region Helpers and dialog callbacks

func _file_to_base64(file_path: String) -> String:
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open file: " + file_path)
		return ""
	var bytes: PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	return Marshalls.raw_to_base64(bytes)


func _base64_to_raw(base64_data: String) -> PackedByteArray:
	return Marshalls.base64_to_raw(base64_data)


func _on_file_upload_selector_file_selected(path: String) -> void:
	_file_upload_path = path
	file_upload_path_selected.emit(path)
	print("File for upload selected: " + path)


func _on_file_upload_selector_canceled() -> void:
	push_warning("File upload selection cancelled")


func _on_file_download_selector_file_selected(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_buffer(downloaded_data)
		file.close()
		print("File saved to: ", path)
		load_complete.emit()
	else:
		print("Error saving file: ", FileAccess.get_open_error())
		load_failed.emit()


func _on_file_download_selector_canceled() -> void:
	load_complete.emit()


func _on_pck_executor_godot_exe_path_selected(path: String) -> void:
	godot_exe_path_selected.emit(path)

#endregion
