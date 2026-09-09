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

@onready var id_input: LineEdit = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/TransactionId/IDInput
@onready var encrypt_option: OptionButton = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/EncryptionPass/EncryptionOption
@onready var pass_input: LineEdit = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/EncryptionPass/PassInput
@onready var bookmark_tree: Tree = $Panel/MarginContainer/MainVBox/MainHBox/Bookmarks/ScrollContainer/MarginContainer/VBoxContainer/BookmarkTree
@onready var move_bookmark_button: Button = $Panel/MarginContainer/MainVBox/MainHBox/Bookmarks/ScrollContainer/MarginContainer/VBoxContainer/MoveBookmarkButton
@onready var content_title: Label = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/Content/ContentVBox/ContentHeader/ContentTitle
@onready var content_label: RichTextLabel = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/Content/ContentVBox/ScrollContainer/ContentLabel
@onready var status_label: Label = $StatusLabel
@onready var data_type_option: OptionButton = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/DataType/DataTypeOption
@onready var chain_option: OptionButton = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/TransactionId/ChainOption

@onready var bookmarks_panel: Panel = $Panel/MarginContainer/MainVBox/MainHBox/Bookmarks
@onready var url_panel: HBoxContainer = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL

@onready var add_bookmark_panel: Panel = $AddBookmark
@onready var add_bookmark_name: LineEdit = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/Name/Name
@onready var add_bookmark_id: LineEdit = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/TransactionId/TransactionId
@onready var add_bookmark_encrypt: OptionButton = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/Passphrase/EncryptionOptionBookmark
@onready var add_bookmark_pass: LineEdit = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/Passphrase/Passphrase
@onready var add_bookmark_data_type: OptionButton = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/DataType/DataTypeOptionBookmark
@onready var add_bookmark_folder_option: OptionButton = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/Folder/FolderOptionBookmark
@onready var delete_bookmark_button: Button = $Panel/MarginContainer/MainVBox/MainHBox/Bookmarks/ScrollContainer/MarginContainer/VBoxContainer/DeleteBookmarkButton
@onready var add_bookmark_chain_option: OptionButton = $AddBookmark/MarginContainer/CenterContainer/VBoxContainer/TransactionId/ChainOption

@onready var folder_prompt: Panel = $FolderPrompt
@onready var folder_prompt_name: LineEdit = $FolderPrompt/MarginContainer/VBox/NameRow/FolderName

@onready var move_prompt: Panel = $MovePrompt
@onready var move_prompt_current: Label = $MovePrompt/MarginContainer/VBox/CurrentLabel
@onready var move_prompt_target: OptionButton = $MovePrompt/MarginContainer/VBox/TargetRow/TargetFolderOption

@onready var upload_folder_option: OptionButton = $Upload/MarginContainer/VBoxContainer/FolderUpload/FolderOptionUpload


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

@onready var godot_path_container: HBoxContainer = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/GodotPath
@onready var godot_path_label: Label = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/GodotPath/GodotPath
@onready var godot_use_local_cache_check: CheckBox = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/GodotPath/LocalCacheCheckbox

@onready var db_pagination_container: HBoxContainer = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/DBPagination
@onready var db_before_input: LineEdit = $Panel/MarginContainer/MainVBox/MainHBox/VBoxContainer/URL/VBoxContainer/DBPagination/DBBeforeInput

var bookmarks: Array[Variant] = []


func _ready() -> void:
	if ResourceLoader.exists(OPTIONS_PATH):
		options = ResourceLoader.load(OPTIONS_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
		iq_sdk.pck_executor._on_godot_selector_file_selected(options.godot_exe_path)
	else:
		options = Options.new()
	load_bookmarks()
	# Migrate old flat bookmarks if they lack structure (they work as root leaves already)
	if bookmarks == null or not bookmarks is Array:
		bookmarks = []
	update_bookmark_tree()
	# Note: most new buttons/prompts are connected via scene .tscn signals now.
	_set_content_title("— VIEWER —")

	# The bundled on-chain service. Apps launched from here share this one
	# instance, so it comes up with the app rather than on demand.
	iq_sdk.attach_ui(self)
	# Docked at the bottom of the main column rather than hidden behind a
	# button: this process holds signing keys and serves apps the user
	# downloaded, and a record nobody looks at is not accountability.
	iq_sdk.attach_activity($Panel/MarginContainer/MainVBox)
	iq_sdk.backend_failed.connect(_on_backend_failed)
	await _start_backend()


## Brings up the bundled on-chain service and reports how it went.
func _start_backend() -> void:
	# Keys live in an encrypted vault; reads do not need it, so unlocking is
	# offered rather than required.
	if iq_sdk.settings.needs_unlock():
		_show_status("Unlock your signing keys, or continue read-only.")
		await iq_sdk.settings.prompt_unlock()

	_show_status("Starting the on-chain service...")
	if await iq_sdk.start_backend():
		_show_status("On-chain service ready.")
		# First run: nothing is configured yet, so ask before they hit a failure.
		if iq_sdk.settings.is_unconfigured():
			iq_sdk.settings.open()
	else:
		_show_status("On-chain service unavailable. " + iq_sdk.host.last_error)


func _on_backend_failed(reason: String) -> void:
	_show_status("On-chain service: " + reason)


func _set_content_title(text: String) -> void:
	if content_title:
		content_title.text = text


func _on_load_button_pressed() -> void:
	var id: String = id_input.text.strip_edges()
	var passphrase: String = pass_input.text.strip_edges()
	if id.is_empty():
		_show_status("TransactionID cannot be empty:")
		return
	_set_content_title("Loading: " + id.substr(0, 16) + ( "..." if id.length() > 16 else "" ))
		
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
			var key := id
			var tname := ""
			if IQClient.is_evm(chain_option.text) and key.contains("/"):
				var parts := key.split("/", true, 1)
				key = parts[0]
				tname = parts[1]
			var before := db_before_input.text.strip_edges()
			var result: Dictionary = await iq_sdk.read_db_table_rows(key, tname, spinner.set_progress, chain_option.text, 30, before)
			content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			var formatted := data_handler.format_as_db_rows(result)
			if before.is_empty():
				content_label.text = formatted
			else:
				content_label.text += "\n\n--- older rows (before " + before.substr(0, 12) + "...) ---\n\n" + formatted
			# Auto-advance the before cursor to the oldest row in this page for easy "load more"
			var rows_arr: Array = result.get("rows", [])
			if not rows_arr.is_empty():
				var last = rows_arr.back()
				var last_row: Dictionary = last if last is Dictionary else {}
				var next_before: String = ""
				if last_row:
					next_before = str(last_row.get("__txSignature", last_row.get("signature", last_row.get("txHash", ""))))
				if not next_before.is_empty() and next_before != before:
					db_before_input.text = next_before
					_show_status("Page loaded. 'Before' cursor auto-set for older rows. Fill/clear it and Go again to paginate.")
				elif rows_arr.is_empty() or formatted.strip_edges().is_empty():
					_show_status("No additional rows found at this cursor (end of available data or all skipped non-row txs).")
		_:
			_show_status("DataType not yet implemented")

#region Bookmarks

func load_bookmarks() -> void:
	bookmarks = []
	if not FileAccess.file_exists(BOOKMARKS_PATH):
		return
	var file = FileAccess.open(BOOKMARKS_PATH, FileAccess.READ)
	if file:
		var json_str = file.get_as_text()
		file.close()
		var json = JSON.new()
		var parse_result = json.parse(json_str)
		if parse_result == OK:
			bookmarks = json.data if json.data is Array else []
			# Earlier builds wrote Terry's picks into this file. They now live
			# in code so updates can add more, and so they cannot be deleted.
			if _strip_seeded_terry_copies(bookmarks):
				save_bookmarks()
		else:
			print("Error parsing bookmarks: ", json.get_error_message())
			bookmarks = []


func save_bookmarks() -> void:
	_strip_seeded_terry_copies(bookmarks)
	var file = FileAccess.open(BOOKMARKS_PATH, FileAccess.WRITE)
	if file:
		var json_str = JSON.stringify(bookmarks)
		file.store_string(json_str)
		file.close()


func update_bookmark_tree() -> void:
	bookmark_tree.clear()
	var root := bookmark_tree.create_item()
	root.set_text(0, "root")
	var merged_folder_names := {}
	for folder in _terry_default_bookmarks():
		var fname := str(folder.get("name", ""))
		merged_folder_names[fname] = true
		var ti := bookmark_tree.create_item(root)
		_style_bookmark_tree_item(ti, folder)
		_populate_tree(ti, folder.get("children", []))
		var user_folder := _find_root_folder(fname)
		if not user_folder.is_empty():
			_populate_tree(ti, user_folder.get("children", []))
	var user_rest: Array = []
	for item in bookmarks:
		if item.get("is_folder", false) and merged_folder_names.has(str(item.get("name", ""))):
			continue
		user_rest.append(item)
	_populate_tree(root, user_rest)


func _populate_tree(parent: TreeItem, items: Array) -> void:
	for item in items:
		var ti := bookmark_tree.create_item(parent)
		var is_folder = item.get("is_folder", false)
		_style_bookmark_tree_item(ti, item)
		if is_folder:
			_populate_tree(ti, item.get("children", []))


func _style_bookmark_tree_item(ti: TreeItem, item: Dictionary) -> void:
	var locked: bool = _is_terry_item(item)
	if item.get("is_folder", false):
		ti.set_text(0, "[F] " + str(item.get("name", "unnamed")))
		ti.set_custom_color(0, Color(0.95, 0.8, 0.35) if locked else Color(0.4, 0.95, 0.5))
	else:
		var prefix := "★ " if locked else "  "
		ti.set_text(0, prefix + _bookmark_display_name(item))
		if locked:
			ti.set_custom_color(0, Color(0.95, 0.8, 0.35))
	if locked:
		ti.set_tooltip_text(0, "Terry's pick — stays in the sidebar")
	ti.set_metadata(0, item)


func _chain_label(chain_idx: int) -> String:
	if chain_option and chain_idx >= 0 and chain_idx < chain_option.item_count:
		return chain_option.get_item_text(chain_idx)
	return ""


## Stored name plus a chain tag, e.g. "GOD [SOL]". Skips the tag if the name
## already ends with it so user-typed suffixes are not doubled.
func _bookmark_display_name(item: Dictionary) -> String:
	var display_name: String = str(item.get("name", "unnamed"))
	var chain_tag := _chain_label(int(item.get("chain", 1)))
	if chain_tag.is_empty():
		return display_name
	var suffix := " [%s]" % chain_tag
	if display_name.ends_with(suffix):
		return display_name
	return display_name + suffix


func _is_terry_item(item: Dictionary) -> bool:
	return bool(item.get("terry", false))


func _make_bookmark(bname: String, tx_id: String, data_type: int, chain: int) -> Dictionary:
	return {
		"name": bname,
		"id": tx_id,
		"passphrase": "",
		"type": data_type,
		"encrypt": 0,
		"chain": chain,
		"terry": true,
	}


func _make_folder(fname: String, children: Array) -> Dictionary:
	return { "name": fname, "is_folder": true, "children": children, "terry": true }


func _terry_folder_names() -> Dictionary:
	var names := {}
	for folder in _terry_default_bookmarks():
		var fname := str(folder.get("name", ""))
		if not fname.is_empty():
			names[fname] = true
	return names


func _terry_inscription_ids() -> Dictionary:
	var ids := {}
	for folder in _terry_default_bookmarks():
		for child in folder.get("children", []):
			var tx_id := str(child.get("id", ""))
			if not tx_id.is_empty():
				ids[tx_id] = true
	return ids


## Drops copies of Terry's picks that were saved into the user file by older
## builds, plus empty folders that only existed to hold them.
func _strip_seeded_terry_copies(arr: Array) -> bool:
	var terry_ids := _terry_inscription_ids()
	var terry_folders := _terry_folder_names()
	return _strip_terry_recursive(arr, terry_ids, terry_folders)


func _strip_terry_recursive(arr: Array, terry_ids: Dictionary, terry_folders: Dictionary) -> bool:
	var mutated := false
	for i in range(arr.size() - 1, -1, -1):
		var item = arr[i]
		if not item is Dictionary:
			continue
		if item.get("is_folder", false):
			var kids: Array = item.get("children", [])
			if _strip_terry_recursive(kids, terry_ids, terry_folders):
				mutated = true
			var fname := str(item.get("name", ""))
			if _is_terry_item(item) or (terry_folders.has(fname) and kids.is_empty()):
				arr.remove_at(i)
				mutated = true
		else:
			var tx_id := str(item.get("id", ""))
			if _is_terry_item(item) or (not tx_id.is_empty() and terry_ids.has(tx_id)):
				arr.remove_at(i)
				mutated = true
	return mutated


func _find_root_folder(fname: String) -> Dictionary:
	for item in bookmarks:
		if item is Dictionary and item.get("is_folder", false) and str(item.get("name", "")) == fname:
			return item
	return {}


## Always-present sidebar: Terry's picks, grouped the way they are meant to be used.
func _terry_default_bookmarks() -> Array[Variant]:
	const SOL := 0
	const MON := 1
	return [
		_make_folder("MON Godot apps", [
			_make_bookmark("GOD", "0x495cbc05d9e6a4ae78614955df116c61f15673fbfbe116ad8be84bf7e8c617f8", DataType.GODOT_PCK, MON),
			_make_bookmark("GodGivesSatoshiSeedPhrase", "0x0d0871dd2446a3ef83dc1578e3efbd63e4fb7ba53f56d9738f3d9c0bf07271ce", DataType.GODOT_PCK, MON),
			_make_bookmark("GodDoodle", "0x71029e2791594e51e6ac30b1a069e2de477d07ada6c49d8cd6ea7ce19575072a", DataType.GODOT_PCK, MON),
			_make_bookmark("BurningBushProtocol", "0x368babd9dfd16ca377732a9e18627e72d0870e445544072604b14248f5d65526", DataType.GODOT_PCK, MON),
		]),
		_make_folder("MON Downloadable Files", [
			_make_bookmark("TempleOS ISO", "0x2b04df7d6ea4103d25a98208c93dc11e2978a48d95de03c2d1c0226f5f548db3", DataType.DOWNLOADABLE_FILE, MON),
		]),
		_make_folder("SOL Godot apps", [
			_make_bookmark("GOD", "FVBWr5tASdzcaDBu7QgoEz1pbiNLqcWNcnmtdA8PkMEpr4j4ZbKK62T7bjVsY3HWw2Q8SfyFkX8jjcYVVEtPGdB", DataType.GODOT_PCK, SOL),
			_make_bookmark("Pong", "4pWighbsUxyzvUn1RmEbFxEVZwc97r5CivYNqFGZs9upD7eHxu1mbo6EaPfp5ifJL6EghpCVvuEGX94hvMsQ3y3r", DataType.GODOT_PCK, SOL),
			_make_bookmark("DOOM", "3XxCCCirmnFRTJuuXzWN7U7ify64j5qhUEUhZSKGe2BvCY5RznwRJ9ZJyrCXQRZhGR5QSpyk3Y4SJtm6qDR8jo7s", DataType.GODOT_PCK, SOL),
			_make_bookmark("Pixelorama", "56JdKH2UnxM597oPH6XvEjm1vf8Zu5kmDjBnJhNb7UftS8UikAtYhz161Zp7oBqJ8NGxmzsvsnoD3GxsTFHpCavv", DataType.GODOT_PCK, SOL),
			_make_bookmark("GodotOS", "63XqBqdKLVUSbWu395tiLUwGKku9aNLB6RWVHAakqg2bPcZgAddD7sDWzy8ENmPfsubxTn56MLGm9h5vEjJpisqm", DataType.GODOT_PCK, SOL),
		]),
		_make_folder("SOL Downloadable Files", [
			_make_bookmark("Quran", "5MeE35tzrCCoSEEUNCcg8xt4L5qAKeMrKMPLYr9mqe6zy4ZTdtcKnz1Z1WNtGVDqVkMLdLhnjjbTve3hwBbWaCDB", DataType.DOWNLOADABLE_FILE, SOL),
		]),
	]


func _on_add_bookmark_button_pressed() -> void:
	populate_folder_options(add_bookmark_folder_option)
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
	var folder_choice: String = add_bookmark_folder_option.get_item_text(add_bookmark_folder_option.selected) if add_bookmark_folder_option.selected >= 0 else "[Root]"
	if id.is_empty() or bname.is_empty():
		_show_status("ID and Name cannot be empty.")
		return
	if _terry_inscription_ids().has(id):
		_show_status("That's already one of Terry's picks.")
		return
	var bm := { "name": bname, "id": id, "passphrase": passphrase, "type": data_type, "encrypt": encrypt, "chain": chain }
	_add_bookmark_to_folder(bm, folder_choice)
	save_bookmarks()
	update_bookmark_tree()
	_show_status("Bookmark added: %s" % _bookmark_display_name(bm))
	add_bookmark_panel.hide()


func _on_bookmark_tree_item_selected() -> void:
	var sel := bookmark_tree.get_selected()
	if sel == null:
		delete_bookmark_button.disabled = true
		move_bookmark_button.disabled = true
		return
	var meta = sel.get_metadata(0)
	if meta == null or not (meta is Dictionary):
		delete_bookmark_button.disabled = true
		move_bookmark_button.disabled = true
		return
	var data: Dictionary = meta
	if data.is_empty():
		return
	var is_folder: bool = data.get("is_folder", false)
	var locked: bool = _is_terry_item(data)
	delete_bookmark_button.disabled = locked
	move_bookmark_button.disabled = is_folder or locked
	if not is_folder:
		id_input.text = data.get("id", "")
		pass_input.text = data.get("passphrase", "")
		data_type_option.select(data.get("type", 0))
		encrypt_option.select(data.get("encrypt", 0))
		chain_option.select(data.get("chain", 1))
		_on_encryption_option_item_selected(data.get("encrypt", 0))
		_on_data_type_option_item_selected(data.get("type", 0))
		if data.get("type", 0) == DataType.DB_TABLE_ROWS:
			db_before_input.text = ""  # before is session-only, not bookmarked
		_set_content_title("Bookmark: " + _bookmark_display_name(data))
	else:
		# folder selected: clear inputs or leave, just show status
		_set_content_title("Folder: " + data.get("name", ""))


func _on_delete_bookmark_button_pressed() -> void:
	var sel := bookmark_tree.get_selected()
	if sel == null:
		return
	var meta = sel.get_metadata(0)
	if meta == null or not (meta is Dictionary):
		return
	var data: Dictionary = meta
	if data.is_empty():
		return
	if _is_terry_item(data):
		_show_status("Terry's picks stay in the sidebar.")
		return
	var bm_name: String = data.get("name", "item")
	if data.get("is_folder", false):
		var kids: Array = data.get("children", []).duplicate()
		if _remove_item_from_bookmarks(data):
			for k in kids:
				bookmarks.append(k)  # promote children to root on folder delete
			_show_status("Deleted Folder (promoted contents): %s" % bm_name)
	else:
		if _remove_item_from_bookmarks(data):
			_show_status("Deleted Bookmark: %s" % bm_name)
	save_bookmarks()
	update_bookmark_tree()
	bookmark_tree.deselect_all()
	delete_bookmark_button.disabled = true
	move_bookmark_button.disabled = true
	id_input.text = ""
	pass_input.text = ""
	content_label.text = ""
	_set_content_title("— VIEWER —")
	data_type_option.select(-1)
	encrypt_option.select(0)
	chain_option.select(0)


func _on_new_folder_button_pressed() -> void:
	folder_prompt_name.text = ""
	folder_prompt.show()
	folder_prompt_name.grab_focus()


func _on_cancel_folder_pressed() -> void:
	folder_prompt.hide()


func _on_confirm_folder_pressed() -> void:
	var fname: String = folder_prompt_name.text.strip_edges()
	if fname.is_empty():
		_show_status("Folder name cannot be empty.")
		return
	if _terry_folder_names().has(fname):
		_show_status("Folder '%s' is reserved for Terry's picks." % fname)
		return
	# Prevent duplicate folder names at root for simplicity
	for item in bookmarks:
		if item.get("is_folder", false) and item.get("name", "") == fname:
			_show_status("Folder '%s' already exists at root." % fname)
			return
	bookmarks.append({ "name": fname, "is_folder": true, "children": [] })
	save_bookmarks()
	update_bookmark_tree()
	_show_status("Folder created: %s" % fname)
	folder_prompt.hide()


func _on_move_bookmark_button_pressed() -> void:
	var sel := bookmark_tree.get_selected()
	if sel == null:
		return
	var meta = sel.get_metadata(0)
	if meta == null or not (meta is Dictionary):
		return
	var data: Dictionary = meta
	if data.is_empty() or data.get("is_folder", false) or _is_terry_item(data):
		return
	move_prompt_current.text = "Selected: " + _bookmark_display_name(data)
	populate_folder_options(move_prompt_target)
	# Optionally preselect root or current parent - simple for now
	move_prompt.show()


func _on_cancel_move_pressed() -> void:
	move_prompt.hide()


func _on_confirm_move_pressed() -> void:
	var sel := bookmark_tree.get_selected()
	if sel == null:
		move_prompt.hide()
		return
	var meta = sel.get_metadata(0)
	if meta == null or not (meta is Dictionary):
		move_prompt.hide()
		return
	var data: Dictionary = meta
	if data.is_empty() or data.get("is_folder", false) or _is_terry_item(data):
		move_prompt.hide()
		return
	var target: String = move_prompt_target.get_item_text(move_prompt_target.selected) if move_prompt_target.selected >= 0 else "[Root]"
	# First remove from current location
	if not _remove_item_from_bookmarks(data):
		_show_status("Failed to locate bookmark for move.")
		move_prompt.hide()
		return
	# Then add to target
	_add_bookmark_to_folder(data, target)
	save_bookmarks()
	update_bookmark_tree()
	bookmark_tree.deselect_all()
	move_bookmark_button.disabled = true
	delete_bookmark_button.disabled = true
	_show_status("Moved '%s' to %s" % [data.get("name", ""), target])
	move_prompt.hide()


func populate_folder_options(opt: OptionButton) -> void:
	opt.clear()
	opt.add_item("[Root]")
	var seen := {}
	for folder in _terry_default_bookmarks():
		var fname := str(folder.get("name", ""))
		if not fname.is_empty() and not seen.has(fname):
			opt.add_item(fname)
			seen[fname] = true
	for item in bookmarks:
		if item.get("is_folder", false):
			var fname := str(item.get("name", ""))
			if not seen.has(fname):
				opt.add_item(fname)
				seen[fname] = true


func _add_bookmark_to_folder(bm: Dictionary, folder_choice: String) -> void:
	if folder_choice == "[Root]" or folder_choice.is_empty():
		bookmarks.append(bm)
		return
	var existing := _find_root_folder(folder_choice)
	if not existing.is_empty():
		if not existing.has("children"):
			existing["children"] = []
		existing.children.append(bm)
		return
	bookmarks.append({ "name": folder_choice, "is_folder": true, "children": [bm] })


func _remove_item_from_bookmarks(target: Dictionary) -> bool:
	if _is_terry_item(target):
		return false
	return _remove_recursive(bookmarks, target)


func _remove_recursive(arr: Array, target: Dictionary) -> bool:
	for i in range(arr.size() - 1, -1, -1):
		var item: Dictionary = arr[i]
		if item == target:  # reference equality
			arr.remove_at(i)
			return true
		if item.get("is_folder", false):
			var kids: Array = item.get("children", [])
			if _remove_recursive(kids, target):
				return true
	return false


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
	populate_folder_options(upload_folder_option)
	upload_panel.show()


func _on_cancel_upload_pressed() -> void:
	upload_panel.hide()


## Quotes the write before it happens, through the same model the approval
## prompt and the activity log use — so the number here and the number on the
## prompt are the same number. It used to be a per-chain literal, and they
## disagreed.
func _on_data_type_option_upload_item_selected(index: int) -> void:
	var chain: String = upload_chain_option.text
	var text_mode: bool = index == 0

	upload_text_edit.visible = text_mode
	upload_file_select_container.visible = not text_mode

	var bytes: int = (
		upload_text_edit.text.to_utf8_buffer().size()
		if text_mode
		else iq_sdk.upload_payload_bytes()
	)
	upload_cost_label.text = "Estimated Cost: " + IQCosts.format(chain, bytes)


func _on_chain_option_upload_item_selected(_index: int) -> void:
	_on_data_type_option_upload_item_selected(upload_data_type.selected)


## Checks there is actually a usable signer before starting an inscription,
## so a locked vault or a missing key is a clear message rather than a failed
## job several seconds later. Offers the unlock screen when that is the fix.
func _ensure_can_write(chain: String) -> bool:
	if iq_sdk.can_write(chain):
		return true

	if iq_sdk.settings.needs_unlock():
		_show_status("Unlock your signing keys to inscribe.")
		if await iq_sdk.settings.prompt_unlock() and iq_sdk.can_write(chain):
			# Keys reached the sidecar at spawn, so it needs restarting with them.
			_show_status("Applying your keys...")
			return await iq_sdk.restart_backend()
		_show_status("Inscribing needs your signing keys. Still in read-only mode.")
		return false

	_show_status("No %s signing key is configured. Click KEYS to add one." % chain.to_upper())
	iq_sdk.settings.open()
	return false


func _on_confirm_upload_pressed() -> void:
	if upload_name.text.strip_edges().is_empty():
		_show_status("Give the new Inscription a name for a Bookmark before inscribing")
		return
	if not await _ensure_can_write(upload_chain_option.text):
		return
	var upload_passphrase = upload_pass.text.strip_edges()
	var folder_choice: String = upload_folder_option.get_item_text(upload_folder_option.selected) if upload_folder_option.selected >= 0 else "[Root]"
	var added_bm := false
	match upload_data_type.selected:
		0: #Simple Text
			var inscribe_text: String = upload_text_edit.text
			var signature: String = str(await iq_sdk.write_code_in_text(inscribe_text, upload_encrypt.selected, upload_passphrase, spinner.set_progress, upload_chain_option.text)).strip_edges()
			var bname: String = upload_name.text.strip_edges()
			if (signature.is_empty()):
				_show_status("Returned Signature empty, can't save Bookmark, check Solscan")
				return
			var bm := { "name": bname, "id": signature, "passphrase": upload_passphrase, "type": upload_data_type.selected + 1, "encrypt": upload_encrypt.selected, "chain": upload_chain_option.selected }
			_add_bookmark_to_folder(bm, folder_choice)
			added_bm = true
		2, 3: #Downloadable File or Godot PCK
			var signature: String = str(await iq_sdk.write_code_in_file(upload_encrypt.selected, upload_passphrase, spinner.set_progress, upload_chain_option.text)).strip_edges()
			var bname: String = upload_name.text.strip_edges()
			if (signature.is_empty()):
				_show_status("Returned Signature empty, can't save Bookmark, check Solscan")
				return
			var bm := { "name": bname, "id": signature, "passphrase": upload_passphrase, "type": upload_data_type.selected + 1, "encrypt": upload_encrypt.selected, "chain": upload_chain_option.selected }
			_add_bookmark_to_folder(bm, folder_choice)
			added_bm = true
		_:
			_show_status("Upload not supported for this DataType (DB types use separate create/writeRow flows)")
	if added_bm:
		save_bookmarks()
		update_bookmark_tree()
		_show_status("CodeIn Complete, Bookmark added: %s" % upload_name.text.strip_edges())
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
	# title already set before load; optionally could snapshot id here


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
	db_pagination_container.visible = (index == DataType.DB_TABLE_ROWS)
	if index != DataType.DB_TABLE_ROWS:
		db_before_input.text = ""


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

func _on_copy_content_pressed() -> void:
	if content_label.text.length() > 0:
		DisplayServer.clipboard_set(content_label.text)
		_show_status("Copied viewer content to clipboard.")
	else:
		_show_status("Nothing to copy.")
