extends Node

class_name IQ_SDK

signal load_started
signal load_complete
signal load_failed

signal file_upload_path_selected(path: String)
signal godot_exe_path_selected(path: String)

@onready var file_upload_dialog: FileDialog = $FileUploadSelector
@onready var file_download_dialog: FileDialog = $FileDownloadSelector
@onready var pck_executor: PckExecutor = $PckExecutor
@onready var data_handler: DataHandler = $DataHandler

var _file_upload_path: String = ""

var downloaded_data: PackedByteArray # Holds the file data after download

func select_file_for_upload() -> void:
	file_upload_dialog.popup_centered_ratio(0.6)

func read_code_in_metadata(signature: String, progress_callback: Callable = Callable(), chain: String = "SOL") -> String:
	load_started.emit()
	
	var normalized_chain := chain.to_lower()
	if normalized_chain != "sol" and normalized_chain != "mon":
		normalized_chain = "sol"
	
	var metadata_dict: Dictionary = await _fetch_iqlabs_metadata(signature, normalized_chain)
	
	if metadata_dict.is_empty():
		load_failed.emit()
		return ""
	
	if progress_callback.is_valid():
		progress_callback.call(100.0)
	
	load_complete.emit()
	return JSON.stringify(metadata_dict)

func read_code_in_text(signature: String, encrypt_type: int = 0, encrypt_pass: String = "", progress_callback: Callable = Callable(), chain: String = "SOL") -> String:
	load_started.emit()
	var response = await _read_code_in(signature, progress_callback, chain)
	if response:
		var decrypted: String = await data_handler.decrypt(response.data, encrypt_type, encrypt_pass)
		load_complete.emit()
		return decrypted
	load_failed.emit()
	return ""
		
func read_code_in_file(signature: String, encrypt_type: int = 0, encrypt_pass: String = "", progress_callback: Callable = Callable(), chain: String = "SOL") -> void:
	load_started.emit()
	var response = await _read_code_in(signature, progress_callback, chain)
	if !response:
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

func read_code_in_godot_pck(signature: String, encrypt_type: int = 0, encrypt_pass: String = "", use_cache: bool = false, progress_callback: Callable = Callable(), chain: String = "SOL") -> void:
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
					pck_executor.execute_subproject(cached_globalized_path)
					load_complete.emit()
					return  # Skip download
	var response = await _read_code_in(signature, progress_callback, chain)
	if !response:
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
	pck_executor.execute_subproject(globalized_path)
	load_complete.emit()

func write_code_in_text(data: String, encrypt_type: int = 0, encrypt_pass: String = "", progress_callback: Callable = Callable(), chain: String = "SOL") -> String:
	load_started.emit()
	var encrypted: String = await data_handler.encrypt(data, encrypt_type, encrypt_pass)
	var response = await _write_code_in(encrypted, "", "", progress_callback, chain)
	if response:
		load_complete.emit()
		return response
	else:
		load_failed.emit()
		return ""

func write_code_in_file(encrypt_type: int = 0, encrypt_pass: String = "", progress_callback: Callable = Callable(), chain: String = "SOL") -> String:
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
	
	var response = await _write_code_in(encrypted, filename, filetype, progress_callback, chain)
	if response:
		load_complete.emit()
		return response
	else:
		load_failed.emit()
		return ""

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

func _fetch_iqlabs_metadata(signature: String, chain: String = "sol") -> Dictionary:
	if signature.is_empty():
		push_error("Signature cannot be empty")
		return {}
	
	var url := "http://localhost:6900/metadata?signature=%s&chain=%s" % [
		signature.uri_encode(),
		chain
	]
	
	var http_request := HTTPRequest.new()
	add_child(http_request)
	
	var error := http_request.request(url)
	if error != OK:
		push_error("Failed to create metadata request: %s" % error)
		http_request.queue_free()
		return {}
	
	var result_data = await http_request.request_completed
	http_request.queue_free()
	
	var request_result: int = result_data[0]
	var response_code: int = result_data[1]
	var body: PackedByteArray = result_data[3]
	
	if request_result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var err_msg := body.get_string_from_utf8()
		push_error("Metadata request failed (HTTP %d): %s" % [response_code, err_msg])
		return {}
	
	var json_string := body.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(json_string) != OK:
		push_error("Failed to parse metadata JSON: " + json.get_error_message())
		return {}
	
	return json.data   # Returns clean Dictionary with signer + all metadata fields

func _read_code_in(signature: String, progress_callback: Callable = Callable(), chain: String = "SOL") -> Variant:
	if signature.is_empty():
		push_error("Signature cannot be empty")
		return null

	var http_request: HTTPRequest = HTTPRequest.new()
	add_child(http_request)

	var url: String = "http://localhost:6900/read?signature=" + signature.uri_encode() + "&chain=" + chain.uri_encode()
	var error: Error = http_request.request(url)
	if error != OK:
		push_error("HTTP request failed: %s" % error)
		http_request.queue_free()
		return null

	var response = await http_request.request_completed
	http_request.queue_free()

	var result_code: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]

	if result_code != HTTPRequest.RESULT_SUCCESS:
		push_error("Request failed with result: %s" % result_code)
		return null
	if response_code != 200:
		var error_msg = body.get_string_from_utf8()
		push_error("Server error %d: %s" % [response_code, error_msg])
		return null

	var body_str = body.get_string_from_utf8()
	var json = JSON.new()
	if json.parse(body_str) != OK:
		push_error("JSON parse error: %s" % json.get_error_message())
		return null

	var job_data: Dictionary = json.data
	if not job_data.has("jobId"):
		push_error("No jobId returned from server")
		return null

	var job_id: String = job_data["jobId"]
	return await _poll_job(job_id, progress_callback)

func _write_code_in(data: String, filename: String = "", filetype: String = "", progress_callback: Callable = Callable(), chain: String = "SOL") -> Variant:
	data = data.strip_edges()
	if data.is_empty():
		push_error("Data cannot be empty")
		return null

	var http_request: HTTPRequest = HTTPRequest.new()
	add_child(http_request)

	var url: String = "http://localhost:6900/write"
	var body_dict: Dictionary = {
		"data": data,
		"filename": filename.strip_edges(),
		"filetype": filetype.strip_edges(),
		"chain": chain,
	}
	var body_string: String = JSON.stringify(body_dict)
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])

	var error: Error = http_request.request(url, headers, HTTPClient.METHOD_POST, body_string)
	if error != OK:
		push_error("HTTP request failed: %s" % error)
		http_request.queue_free()
		return null

	var response = await http_request.request_completed
	http_request.queue_free()

	var result_code: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]

	if result_code != HTTPRequest.RESULT_SUCCESS:
		push_error("Request failed with result: %s" % result_code)
		return null
	if response_code != 200:
		var error_msg = body.get_string_from_utf8()
		push_error("Server error %d: %s" % [response_code, error_msg])
		return null

	var body_str = body.get_string_from_utf8()
	var json = JSON.new()
	if json.parse(body_str) != OK:
		push_error("JSON parse error: %s" % json.get_error_message())
		return null

	var job_data: Dictionary = json.data
	if not job_data.has("jobId"):
		push_error("No jobId returned from server")
		return null

	var job_id: String = job_data["jobId"]
	return await _poll_job(job_id, progress_callback)
	
func _poll_job(job_id: String, progress_callback: Callable = Callable()) -> Variant:

	while true: #I don't care about max attempts in this context

		var http_request: HTTPRequest = HTTPRequest.new()
		add_child(http_request)

		var url: String = "http://localhost:6900/progress?jobId=" + job_id.uri_encode()
		var error: Error = http_request.request(url)
		if error != OK:
			push_error("Progress poll failed: %s" % error)
			http_request.queue_free()
			return null

		var response = await http_request.request_completed
		http_request.queue_free()

		var result_code: int = response[0]
		var response_code: int = response[1]
		var body: PackedByteArray = response[3]

		if result_code != HTTPRequest.RESULT_SUCCESS or response_code != 200:
			var err_body = body.get_string_from_utf8()
			push_error("Progress poll server error: %s" % err_body)
			return null

		var body_str = body.get_string_from_utf8()
		var json = JSON.new()
		if json.parse(body_str) != OK:
			push_error("Progress JSON parse error: %s" % json.get_error_message())
			return null

		var data: Dictionary = json.data
		var prog: float = float(data.get("progress", 0))
		if progress_callback.is_valid():
			progress_callback.call(prog)

		var status: String = data.get("status", "")
		if status == "completed":
			return data.get("result")
		elif status == "error":
			push_error("Job failed: %s" % data.get("error", "Unknown error"))
			return null

		await get_tree().create_timer(0.5).timeout   # poll every 0.5 seconds

	push_error("Job timed out after 30 minutes")
	return null

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
