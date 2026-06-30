extends Node
class_name DataHandler

const PBKDF2_ITERATIONS := 100_000
const SALT_SIZE := 16
const KEY_SIZE := 32

static var _crypto: Crypto = Crypto.new()
static var _aes: AESContext = AESContext.new()

func encrypt(input: String, encrypt_type: int = 0, encrypt_pass: String = "") -> String:
	match encrypt_type:
		0:
			return input
		1:
			return _AES_encrypt(input, encrypt_pass)
		2:
			return await _han_encrypt(input)
		_:
			push_error("Encrypt type not yet implemented")
			return input
	
func decrypt(input: String, encrypt_type: int = 0, encrypt_pass: String = "") -> String:
	match encrypt_type:
		0:
			return input
		1:
			return _AES_decrypt(input, encrypt_pass)
		2:
			return await _han_decrypt(input)
		_:
			push_error("Encrypt type not yet implemented")
			return input


#region PBKDF2 + AES-256-CBC

static func _pbkdf2(password: PackedByteArray, salt: PackedByteArray, iterations: int, dk_len: int) -> PackedByteArray:
	var h_len := 32
	@warning_ignore("integer_division")
	var block_count := (dk_len + h_len - 1) / h_len
	var derived := PackedByteArray()
	for i in range(1, block_count + 1):
		var block_salt := salt.duplicate()
		block_salt.append_array([(i >> 24) & 0xff, (i >> 16) & 0xff, (i >> 8) & 0xff, i & 0xff])
		var u := _crypto.hmac_digest(HashingContext.HASH_SHA256, password, block_salt)
		var t := u.duplicate()
		for _iter in range(1, iterations):
			u = _crypto.hmac_digest(HashingContext.HASH_SHA256, password, u)
			for j in range(h_len):
				t[j] ^= u[j]
		derived.append_array(t)
	derived.resize(dk_len)
	return derived

# Derives a 32-byte AES-256 key from a passphrase using SHA-256
static func _derive_key(passphrase: String, salt: PackedByteArray) -> PackedByteArray:
	return _pbkdf2(passphrase.to_utf8_buffer(), salt, PBKDF2_ITERATIONS, KEY_SIZE)

# PKCS#7 Padding: Adds bytes to make data a multiple of block_size (16 for AES)
static func _pad(data: PackedByteArray, block_size: int = 16) -> PackedByteArray:
	var pad_length = block_size - (data.size() % block_size)
	var padded = PackedByteArray()
	padded.append_array(data)
	for i in range(pad_length):
		padded.append(pad_length)
	return padded
	
# PKCS#7 Unpadding: Removes padding bytes
static func _unpad(data: PackedByteArray, block_size: int = 16) -> PackedByteArray:
	if data.size() == 0:
		return data
	var last_byte = data[data.size() - 1]
	var pad_length = last_byte
	if pad_length < 1 or pad_length > block_size:
		push_error("Invalid padding length")
		return data
	for i in range(pad_length):
		if data[data.size()  - 1 - i] != pad_length:
			push_error("Invalid padding")
			return data
	var unpadded = PackedByteArray()
	unpadded.append_array(data.slice(0, data.size() - pad_length))
	return unpadded
	
# Encrypts a string to Base64 (includes random IV prepended to ciphertext)
func _AES_encrypt(text: String, passphrase: String) -> String:
	if passphrase == "":
		return text
	
	var salt := _crypto.generate_random_bytes(SALT_SIZE)           # ← NEW
	var key := _derive_key(passphrase, salt)                      # ← CHANGED
	var iv := _crypto.generate_random_bytes(16)
	var data := text.to_utf8_buffer()
	var padded_data := _pad(data)
	
	_aes.start(AESContext.MODE_CBC_ENCRYPT, key, iv)
	var encrypted := _aes.update(padded_data)
	_aes.finish()
	
	# Format: [salt][iv][ciphertext] → same format as the PBE class
	var output := PackedByteArray()
	output.append_array(salt)
	output.append_array(iv)
	output.append_array(encrypted)
	return Marshalls.raw_to_base64(output)

func _AES_decrypt(encrypted_b64: String, passphrase: String) -> String:
	if passphrase == "":
		return encrypted_b64
	
	var output_bytes := Marshalls.base64_to_raw(encrypted_b64)
	if output_bytes.size() < SALT_SIZE + 16:
		push_error("Invalid encrypted data")
		return ""
	
	var salt := output_bytes.slice(0, SALT_SIZE)                    # ← NEW
	var iv := output_bytes.slice(SALT_SIZE, SALT_SIZE + 16)
	var ciphertext := output_bytes.slice(SALT_SIZE + 16)
	
	var key := _derive_key(passphrase, salt)                        # ← CHANGED
	_aes.start(AESContext.MODE_CBC_DECRYPT, key, iv)
	var decrypted_padded := _aes.update(ciphertext)
	_aes.finish()
	
	var decrypted := _unpad(decrypted_padded)
	return decrypted.get_string_from_utf8()

#endregion

#region Hanlock

func _han_encrypt(input: String) -> String:
	if input.is_empty():
		push_error("Cannot encrypt empty string")
		return ""

	var http_request: HTTPRequest = HTTPRequest.new()
	add_child(http_request)

	var url: String = "http://localhost:6900/han_encrypt"

	var body_dict: Dictionary = {
		"data": input,
	}
	var body_string: String = JSON.stringify(body_dict)
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])

	var error: Error = http_request.request(url, headers, HTTPClient.METHOD_POST, body_string)
	if error != OK:
		push_error("HTTP request failed: %s" % error)
		http_request.queue_free()
		return ""

	var response = await http_request.request_completed
	http_request.queue_free()

	var result: int = response[0]
	var response_code: int = response[1]
	#var headers_resp: PackedStringArray = response[2]
	var body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("Request failed with result: %s" % result)
		return ""

	if response_code != 200:
		var error_msg = body.get_string_from_utf8()
		push_error("Server error %d: %s" % [response_code, error_msg])
		return ""

	var body_str = body.get_string_from_utf8()
	
	return body_str
	
func _han_decrypt(input: String) -> String:
	if input.is_empty():
		push_error("Cannot encrypt empty string")
		return ""

	var http_request: HTTPRequest = HTTPRequest.new()
	add_child(http_request)

	var url: String = "http://localhost:6900/han_decrypt"

	var body_dict: Dictionary = {
		"data": input,
	}
	var body_string: String = JSON.stringify(body_dict)
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])

	var error: Error = http_request.request(url, headers, HTTPClient.METHOD_POST, body_string)
	if error != OK:
		push_error("HTTP request failed: %s" % error)
		http_request.queue_free()
		return ""

	var response = await http_request.request_completed
	http_request.queue_free()

	var result: int = response[0]
	var response_code: int = response[1]
	#var headers_resp: PackedStringArray = response[2]
	var body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("Request failed with result: %s" % result)
		return ""

	if response_code != 200:
		var error_msg = body.get_string_from_utf8()
		push_error("Server error %d: %s" % [response_code, error_msg])
		return ""

	var body_str = body.get_string_from_utf8()

	return body_str

#endregion

#region XChaCha20-Poly1305

#endregion



#region DataTypes

func parse_ascii_art(input: String) -> String:
	var prefix = "[ width: "
	
	if not input.begins_with(prefix):
		return input
		
	var remaining = input.substr(prefix.length())
	var space_pos = remaining.find(" ]")
	
	if space_pos == -1:
		return input
		
	var width_str = remaining.substr(0, space_pos).strip_edges()
	var width = width_str.to_int()
	var data = remaining.substr(space_pos + 2)
	return _format_ascii_art(data, width)

func _format_ascii_art(text: String, desired_width: int) -> String:
	var result: String = ""
	var length: int = text.length()
	for i in range(0, length, desired_width):
		if i > 0:
			result += "\n"
		var chunk_length: int = min(desired_width, length - i)
		result += text.substr(i, chunk_length)
	return result

#endregion

#region DB (static DataType integration for new LocalServer DB endpoints)

func format_as_db_list(result: Dictionary) -> String:
	if result.is_empty():
		return "Empty result or load failed."
	var out: String = ""
	var chain := str(result.get("chain", ""))
	if chain:
		out += "Chain: " + chain + "\n"
	if result.has("creator"):
		out += "Creator: " + str(result["creator"]) + "\n"
	if result.has("rootPda"):
		out += "Root PDA: " + str(result["rootPda"]) + "\n"
	if result.has("dbRootId"):
		out += "dbRootId: " + str(result["dbRootId"]) + "\n"

	var table_list: Array = []
	if result.has("tables"):
		table_list = result["tables"] as Array
	elif result.has("tableSeeds"):
		table_list = result["tableSeeds"] as Array
	elif result.has("globalTables"):
		table_list = result["globalTables"] as Array

	if not table_list.is_empty():
		out += "\nTables (%d):\n" % table_list.size()
		for entry in table_list:
			if entry is Dictionary:
				var name: String = str(entry.get("name", entry.get("seedHex", "?")))
				var seed: String = str(entry.get("seedHex", entry.get("name", "")))
				out += "  • " + name
				if seed and seed != name:
					out += " (seed: " + seed + ")"
				out += "\n"
			else:
				out += "  • " + str(entry) + "\n"
	else:
		# Fallback for raw
		out += "\n" + JSON.stringify(result, "\t")

	return out

func format_as_db_rows(result: Dictionary) -> String:
	if result.is_empty():
		return "Empty result or load failed."
	var rows: Array = result.get("rows", []) as Array
	var count: int = result.get("count", rows.size())
	var out: String = "Rows: " + str(count) + "\n"
	var chain := str(result.get("chain", ""))
	if chain:
		out += "Chain: " + chain + "  "
	if result.has("tableName"):
		out += "Table: " + str(result["tableName"]) + "  "
	if result.has("tablePda"):
		out += "PDA: " + str(result["tablePda"])
	out += "\n\n"
	if rows.is_empty():
		out += "(no rows)\n"
	else:
		for i in range(rows.size()):
			var row: Variant = rows[i]
			out += "[%d] %s\n\n" % [i, JSON.stringify(row, "  ")]
	return out

#endregion
