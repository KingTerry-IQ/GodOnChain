extends Control

const BOOKMARKS_PATH: String = "user://bookmarks.json"
const OPTIONS_PATH: String = "user://options.tres"

@onready var options: Options

@onready var iq_sdk: IQ_SDK = $IQSDK
@onready var data_handler: DataHandler = $DataHandler

@onready var spinner: ProgressSpinner = $Spinner

enum DataType {
	METADATA = 0,
	SIMPLE_TEXT = 1,
	ASCII_ART = 2,
	DOWNLOADABLE_FILE = 3,
	GODOT_PCK = 4,
	DB_ROOT_TABLES = 5,
	DB_TABLE_ROWS = 6,
}

@onready var id_input: LineEdit = $Panel/MarginContainer/HBoxContainer/VBoxContainer/URL/VBoxContainer/TransactionId/IDInput
@onready var encrypt_option: OptionButton = $Panel/MarginContainer/HBoxContainer/VBoxContainer/URL/VBoxContainer/EncryptionPass/EncryptionOption
@onready var pass_input: LineEdit = $Panel/MarginContainer/HBoxContainer/VBoxContainer/URL/VBoxContainer/EncryptionPass/PassInput
@onready var bookmark_list: ItemList = $Panel/MarginContainer/HBoxContainer/Bookmarks/ScrollContainer/MarginContainer/VBoxContainer/BookmarkList
@onready var content_label: RichTextLabel = $Panel/MarginContainer/HBoxContainer/VBoxContainer/Content/VBoxContainer/ScrollContainer/ContentLabel
@onready var status_label: Label = $StatusLabel
@onready var data_type_option: OptionButton = $Panel/MarginContainer/HBoxContainer/VBoxContainer/URL/VBoxContainer/DataType/DataTypeOption
@onready var chain_option: OptionButton = $Panel/MarginContainer/HBoxContainer/VBoxContainer/URL/VBoxContainer/TransactionId/ChainOption

@onready var bookmarks_panel: Panel = $Panel/MarginContainer/HBoxContainer/Bookmarks
@onready var url_panel: HBoxContainer = $Panel/MarginContainer/HBoxContainer/VBoxContainer/URL

@onready var add_bookmark_panel: Panel = $AddBookmark
@onready var add_bookmark_name: LineEdit = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/Name/Name
@onready var add_bookmark_id: LineEdit = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/TransactionId/TransactionId
@onready var add_bookmark_encrypt: OptionButton = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/Passphrase/EncryptionOptionBookmark
@onready var add_bookmark_pass: LineEdit = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/Passphrase/Passphrase
@onready var add_bookmark_data_type: OptionButton = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/DataType/DataTypeOptionBookmark
@onready var delete_bookmark_button: Button = $Panel/MarginContainer/HBoxContainer/Bookmarks/ScrollContainer/MarginContainer/VBoxContainer/DeleteBookmarkButton
@onready var add_bookmark_chain_option: OptionButton = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/TransactionId/ChainOption

@onready var upload_panel: Panel = $Upload
@onready var upload_name: LineEdit = $Upload/MarginContainer/VBoxContainer/Name/Name
@onready var upload_encrypt: OptionButton = $Upload/MarginContainer/VBoxContainer/Passphrase/EncryptionOptionUpload
@onready var upload_pass: LineEdit = $Upload/MarginContainer/VBoxContainer/Passphrase/Passphrase
@onready var upload_data_type: OptionButton = $Upload/MarginContainer/VBoxContainer/DataType/DataTypeOptionUpload
@onready var upload_text_edit: TextEdit = $Upload/MarginContainer/VBoxContainer/TextEdit
@onready var upload_file_select_container: HBoxContainer = $Upload/MarginContainer/VBoxContainer/FileSelectContainer
@onready var upload_path_label: Label = $Upload/MarginContainer/VBoxContainer/FileSelectContainer/PathLabel
@onready var upload_cost_label: Label = $Upload/MarginContainer/VBoxContainer/CostLabel
@onready var upload_chain_option: OptionButton = $Upload/MarginContainer/VBoxContainer/Name/ChainOptionUpload

@onready var godot_path_container: HBoxContainer = $Panel/MarginContainer/HBoxContainer/VBoxContainer/URL/VBoxContainer/GodotPath
@onready var godot_path_label: Label = $Panel/MarginContainer/HBoxContainer/VBoxContainer/URL/VBoxContainer/GodotPath/GodotPath
@onready var godot_use_local_cache_check: CheckBox = $Panel/MarginContainer/HBoxContainer/VBoxContainer/URL/VBoxContainer/GodotPath/LocalCacheCheckbox

var bookmarks: Array[Variant] = []


func _ready() -> void:
	if ResourceLoader.exists(OPTIONS_PATH):
		options = ResourceLoader.load(OPTIONS_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
		iq_sdk.pck_executor._on_godot_selector_file_selected(options.godot_exe_path)
	else:
		options = Options.new()
	load_bookmarks()
	update_bookmark_list()


func _on_load_button_pressed() -> void:
	var id: String = id_input.text.strip_edges()
	var passphrase: String = pass_input.text.strip_edges()
	if id.is_empty():
		_show_status("TransactionID cannot be empty:")
		return
		
	match data_type_option.get_selected_id():
		DataType.METADATA:
			_show_status("Reading %s" % id)
			var result = await iq_sdk.read_code_in_metadata(id, spinner.set_progress, chain_option.text)
			content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			content_label.text = result
		DataType.SIMPLE_TEXT:
			_show_status("Reading %s" % id)
			var result = await iq_sdk.read_code_in_text(id, encrypt_option.selected, passphrase, spinner.set_progress, chain_option.text)
			content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			content_label.text = result
		DataType.ASCII_ART:
			_show_status("Reading %s (ASCII Art)" % id)
			var result = await iq_sdk.read_code_in_text(id, encrypt_option.selected, passphrase, spinner.set_progress, chain_option.text)
			content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			content_label.text = data_handler.parse_ascii_art(result)
		DataType.DOWNLOADABLE_FILE:
			_show_status("Downloading %s" % id)
			content_label.text = ""
			await iq_sdk.read_code_in_file(id, encrypt_option.selected, passphrase, spinner.set_progress, chain_option.text)
		DataType.GODOT_PCK:
			if iq_sdk.pck_executor._godot_exe_path == "":
				_show_status("Please select a path for Godot before attempting to launch a Godot .PCK \n Godot may be downloaded from https://godotengine.org/")
				return
			_show_status("Downloading and attempting to run Godot PCK at %s" % id)
			content_label.text = ""
			await iq_sdk.read_code_in_godot_pck(id, encrypt_option.selected, passphrase, godot_use_local_cache_check.button_pressed, spinner.set_progress, chain_option.text)
		DataType.DB_ROOT_TABLES:
			_show_status("Loading DB tables list for root %s on %s" % [id, chain_option.text])
			content_label.text = ""
			var result: Dictionary = await iq_sdk.get_db_table_list(id, spinner.set_progress, chain_option.text)
			content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			content_label.text = data_handler.format_as_db_list(result)
		DataType.DB_TABLE_ROWS:
			_show_status("Loading DB table rows for %s on %s" % [id, chain_option.text])
			content_label.text = ""
			var key := id
			var tname := ""
			if chain_option.text.to_lower().begins_with("mon") and key.contains("/"):
				var parts := key.split("/", true, 1)
				key = parts[0]
				tname = parts[1]
			var result: Dictionary = await iq_sdk.read_db_table_rows(key, tname, spinner.set_progress, chain_option.text, 30)
			content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			content_label.text = data_handler.format_as_db_rows(result)
		_:
			_show_status("DataType not yet implemented")

#region Bookmarks

func load_bookmarks() -> void:
	if not FileAccess.file_exists(BOOKMARKS_PATH):
		return
	var file = FileAccess.open(BOOKMARKS_PATH, FileAccess.READ)
	if file:
		var json_str = file.get_as_text()
		file.close()
		var json = JSON.new()
		var parse_result = json.parse(json_str)
		if parse_result == OK:
			bookmarks = json.data
		else:
			print("Error parsing bookmarks: ", json.get_error_message())


func save_bookmarks() -> void:
	var file = FileAccess.open(BOOKMARKS_PATH, FileAccess.WRITE)
	if file:
		var json_str = JSON.stringify(bookmarks)
		file.store_string(json_str)
		file.close()


func update_bookmark_list() -> void:
	bookmark_list.clear()
	for bm in bookmarks:
		bookmark_list.add_item(bm.name)


func _on_add_bookmark_button_pressed() -> void:
	add_bookmark_panel.show()
	add_bookmark_id.text = id_input.text
	add_bookmark_pass.text = pass_input.text
	add_bookmark_data_type.selected = data_type_option.selected
	add_bookmark_encrypt.selected = encrypt_option.selected
	add_bookmark_chain_option.selected = chain_option.selected


func _on_cancel_add_bookmark_button_pressed() -> void:
	add_bookmark_panel.hide()


func _on_confirm_add_bookmark_button_pressed() -> void:
	var id: String = add_bookmark_id.text.strip_edges()
	var bname: String = add_bookmark_name.text.strip_edges()
	var passphrase: String = add_bookmark_pass.text.strip_edges()
	var data_type: int = add_bookmark_data_type.selected
	var encrypt: int = add_bookmark_encrypt.selected
	var chain: int = add_bookmark_chain_option.selected
	if id.is_empty() or bname.is_empty():
		_show_status("ID and Name cannot be empty.")
		return
	bookmarks.append({ "name": bname, "id": id, "passphrase": passphrase, "type": data_type, "encrypt": encrypt, "chain": chain})
	save_bookmarks()
	update_bookmark_list()
	_show_status("Bookmark added: %s" % bname)
	add_bookmark_panel.hide()


func _on_bookmark_list_item_selected(index: int) -> void:
	if index >= 0 and index < bookmarks.size():
		delete_bookmark_button.disabled = false
		var bm = bookmarks[index]
		id_input.text = bm.id
		pass_input.text = bm.passphrase
		data_type_option.select(bm.type)
		encrypt_option.select(bm.encrypt)
		chain_option.select(bm.chain)
		_on_encryption_option_item_selected(bm.encrypt)
		_on_data_type_option_item_selected(bm.type)


func _on_delete_bookmark_button_pressed() -> void:
	var selected_index = bookmark_list.get_selected_items()[0]
	if selected_index >= 0 and selected_index < bookmarks.size():
		var bm_name = bookmarks[selected_index].name
		bookmarks.remove_at(selected_index)
		save_bookmarks()
		update_bookmark_list()
		bookmark_list.deselect_all()
		delete_bookmark_button.disabled = true
		id_input.text = ""
		pass_input.text = ""
		content_label.text = ""
		data_type_option.select(-1)
		encrypt_option.select(0)
		chain_option.select(0)
		_show_status("Deleted Bookmark: %s" % bm_name)
		
func _on_encryption_option_bookmark_item_selected(index: int) -> void:
	match index:
		0, 2: #No Encryption, or Hanlock
			add_bookmark_pass.hide()
			add_bookmark_pass.text = ""
		_:
			add_bookmark_pass.show()

#endregion

#region Upload

func _on_upload_button_pressed() -> void:
	upload_panel.show()


func _on_cancel_upload_pressed() -> void:
	upload_panel.hide()


func _on_data_type_option_upload_item_selected(index: int) -> void:
	match upload_chain_option.selected:
		0: #SOL
			match index:
				0:
					upload_text_edit.show()
					upload_file_select_container.hide()
					upload_cost_label.text = "Estimated Cost: %0.6f SOL" % 0.001005
				_:
					upload_text_edit.hide()
					upload_file_select_container.show()
					upload_cost_label.text = "Estimated Cost: %0.6f SOL" % iq_sdk.estimate_code_in_file_cost_SOL()
		1: #MON
			match index:
				0:
					upload_text_edit.show()
					upload_file_select_container.hide()
					upload_cost_label.text = "Estimated Cost: %0.6f MON" % 6.52
				_:
					upload_text_edit.hide()
					upload_file_select_container.show()
					upload_cost_label.text = "Estimated Cost: %0.6f MON" % iq_sdk.estimate_code_in_file_cost_MON()

func _on_chain_option_upload_item_selected(_index: int) -> void:
	_on_data_type_option_upload_item_selected(upload_data_type.selected)


func _on_confirm_upload_pressed() -> void:
	if upload_name.text.strip_edges().is_empty():
		_show_status("Give the new Inscription a name for a Bookmark before inscribing")
		return
	var upload_passphrase = upload_pass.text.strip_edges()
	match upload_data_type.selected:
		0: #Simple Text
			var inscribe_text: String = upload_text_edit.text
			var signature: String = str(await iq_sdk.write_code_in_text(inscribe_text, upload_encrypt.selected, upload_passphrase, spinner.set_progress, upload_chain_option.text)).strip_edges()
			var bname: String = upload_name.text.strip_edges()
			if (signature.is_empty()):
				_show_status("Returned Signature empty, can't save Bookmark, check Solscan")
				return
			bookmarks.append({ "name": bname, "id": signature, "passphrase": upload_passphrase, "type": upload_data_type.selected + 1, "encrypt": upload_encrypt.selected, "chain": upload_chain_option.selected }) #This is +1 because Metadata is slot 0, but Metadata doesn't make sense to have on Upload
			save_bookmarks()
			update_bookmark_list()
			_show_status("CodeIn Complete, Bookmark added: %s" % bname)
		2, 3: #Downloadable File or Godot PCK
			var signature: String = str(await iq_sdk.write_code_in_file(upload_encrypt.selected, upload_passphrase, spinner.set_progress, upload_chain_option.text)).strip_edges()
			var bname: String = upload_name.text.strip_edges()
			if (signature.is_empty()):
				_show_status("Returned Signature empty, can't save Bookmark, check Solscan")
				return
			bookmarks.append({ "name": bname, "id": signature, "passphrase": upload_passphrase, "type": upload_data_type.selected + 1, "encrypt": upload_encrypt.selected, "chain": upload_chain_option.selected }) #This is +1 because Metadata is slot 0, but Metadata doesn't make sense to have on Upload
			save_bookmarks()
			update_bookmark_list()
			_show_status("CodeIn Complete, Bookmark added: %s" % bname)
		_:
			_show_status("Upload not supported for this DataType (DB types use separate create/writeRow flows)")
	upload_name.text = ""
	upload_pass.text = ""
	upload_text_edit.text = ""
	upload_panel.hide()


func _on_iqsdk_file_upload_path_selected(path: String) -> void:
	upload_path_label.text = "Selected File: %s" % path
	_on_data_type_option_upload_item_selected(upload_data_type.selected)


func _on_file_selector_pressed() -> void:
	iq_sdk.select_file_for_upload()

func _on_encryption_option_upload_item_selected(index: int) -> void:
	match index:
		0, 2: #No Encryption or HanLock
			upload_pass.hide()
			upload_pass.text = ""
		_:
			upload_pass.show()

#endregion

#region MiscUI

func _show_status(msg: String) -> void:
	status_label.show()
	status_label.text = msg
	print(msg)
	await get_tree().create_timer(4).timeout
	status_label.hide()


func _on_iqsdk_load_complete() -> void:
	spinner.visible = false
	_show_status("Load Complete")


func _on_iqsdk_load_failed() -> void:
	spinner.visible = false
	_show_status("Load Failed - Check your RPC, or try again later")


func _on_iqsdk_load_started() -> void:
	spinner.visible = true


func _on_select_godot_path_button_pressed() -> void:
	iq_sdk.pck_executor.select_godot_exe_path()


func _on_iqsdk_godot_exe_path_selected(path: String) -> void:
	_show_status("Godot path: %s" % path)
	godot_path_label.text = "Godot Path: [Selected]"
	options.godot_exe_path = path
	ResourceSaver.save(options, OPTIONS_PATH)
	


func _on_data_type_option_item_selected(index: int) -> void:
	godot_path_container.visible = (index == DataType.GODOT_PCK) #GodotPCK


func _on_bookmarks_hide_button_toggled(toggled_on: bool) -> void:
	bookmarks_panel.visible = !toggled_on


func _on_url_hide_button_toggled(toggled_on: bool) -> void:
	url_panel.visible = !toggled_on

func _on_encryption_option_item_selected(index: int) -> void:
	match index:
		0, 2: #No Encryption or Hanlock
			pass_input.hide()
			pass_input.text = ""
		_:
			pass_input.show()

#endregion
