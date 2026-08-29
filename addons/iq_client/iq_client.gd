## Client for the IQ Labs on-chain SDK, as hosted by GodOnChain.
##
## Drop this file into any Godot project. It is plain GDScript over HTTPRequest
## with no GDExtension and no addons, so it runs under whatever stock Godot
## binary GodOnChain launched you with.
##
## It finds its host in one of two ways:
##
##   1. Environment variables, set by GodOnChain when it launched this app.
##      You get your own token, labelled with your app name, so approval
##      prompts can tell the user who is asking.
##   2. A discovery file written by a running GodOnChain, for apps started on
##      their own. That token is read-only and anonymous.
##
## Reads are free and always allowed. Writes spend real funds, so the host asks
## the user first: expect write_code_in() to block while that prompt is open,
## and to fail if they decline.
##
## Usage:
##     var iq := IQClient.new()
##     add_child(iq)
##     if not await iq.discover():
##         push_error(iq.last_error)
##         return
##     var doc = await iq.read_code_in(signature, "sol")
##     print(doc.data)

class_name IQClient
extends Node

## Emitted once a reachable host has been confirmed.
signal host_found(url: String)
## Emitted when no host could be found, or it stopped answering.
signal host_missing(reason: String)

const DISCOVERY_FILENAME := "host.json"
const DISCOVERY_DIR := "GodOnChain"
## Bumped only if the discovery file's shape changes incompatibly.
const DISCOVERY_VERSION := 1

const ENV_URL := "GODONCHAIN_IQ_URL"
const ENV_TOKEN := "GODONCHAIN_IQ_TOKEN"
const ENV_APP := "GODONCHAIN_IQ_APP"

## Seconds between /progress polls. Matches the host's own cadence.
const POLL_INTERVAL := 0.5

var base_url: String = ""
var token: String = ""
## How this app identifies itself in approval prompts, when the host told us.
var app_label: String = ""
## Populated whenever a call returns null / empty. Safe to show to a user.
var last_error: String = ""

var _available: bool = false


#region Discovery

## Absolute path of the discovery file a running GodOnChain publishes.
static func discovery_path() -> String:
	var dir := ""
	if OS.has_feature("windows"):
		dir = OS.get_environment("APPDATA")
	elif OS.has_feature("macos"):
		var home_mac := OS.get_environment("HOME")
		if not home_mac.is_empty():
			dir = home_mac + "/Library/Application Support"
	else:
		dir = OS.get_environment("XDG_DATA_HOME")
		if dir.is_empty():
			var home := OS.get_environment("HOME")
			if not home.is_empty():
				dir = home + "/.local/share"

	if dir.is_empty():
		# Last resort: our own user:// directory, which at least exists.
		return OS.get_user_data_dir().replace("\\", "/") + "/" + DISCOVERY_FILENAME

	return dir.replace("\\", "/") + "/" + DISCOVERY_DIR + "/" + DISCOVERY_FILENAME


## Locates a host and confirms it is answering. Returns false and sets
## last_error if there is nothing to talk to.
func discover() -> bool:
	_available = false
	last_error = ""

	var env_url := OS.get_environment(ENV_URL)
	var env_token := OS.get_environment(ENV_TOKEN)
	if not env_url.is_empty() and not env_token.is_empty():
		base_url = env_url.rstrip("/")
		token = env_token
		app_label = OS.get_environment(ENV_APP)
		if await _confirm_health():
			return true
		# Stale env from a host that has since exited; fall through to the file.

	if _load_discovery_file():
		if await _confirm_health():
			return true

	if last_error.is_empty():
		last_error = (
			"No GodOnChain host found. Launch this app from GodOnChain, "
			+ "or start GodOnChain alongside it."
		)
	host_missing.emit(last_error)
	return false


func is_available() -> bool:
	return _available


func _load_discovery_file() -> bool:
	var path := discovery_path()
	if not FileAccess.file_exists(path):
		last_error = "No host running (no discovery file at %s)." % path
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "Could not read the discovery file at %s." % path
		return false
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		last_error = "The discovery file at %s is malformed." % path
		return false

	var data: Dictionary = parsed
	if int(data.get("version", 0)) != DISCOVERY_VERSION:
		last_error = "The running GodOnChain publishes an incompatible host file."
		return false

	base_url = str(data.get("url", "")).rstrip("/")
	token = str(data.get("token", ""))
	app_label = ""
	if base_url.is_empty() or token.is_empty():
		last_error = "The discovery file at %s is missing url or token." % path
		return false
	return true


func _confirm_health() -> bool:
	var response: Dictionary = await _request("GET", "/health", {}, null, false)
	if not response.get("ok", false):
		last_error = "Host at %s is not answering." % base_url
		return false
	_available = true
	host_found.emit(base_url)
	return true

#endregion


#region Reads

## Fetches an inscription. Returns {metadata, data}, or null on failure.
## progress_callback receives a float from 0 to 100.
func read_code_in(
	signature: String, chain: String = "sol", progress_callback: Callable = Callable()
) -> Variant:
	if signature.is_empty():
		last_error = "Signature cannot be empty."
		return null
	var started: Dictionary = await _request(
		"GET", "/read", {"signature": signature, "chain": _normalize_chain(chain)}
	)
	return await _follow_job(started, progress_callback)


## Metadata only, with no chunk reconstruction, so this is cheap.
## Returns {} on failure.
func read_metadata(signature: String, chain: String = "sol") -> Dictionary:
	if signature.is_empty():
		last_error = "Signature cannot be empty."
		return {}
	var response: Dictionary = await _request(
		"GET", "/metadata", {"signature": signature, "chain": _normalize_chain(chain)}
	)
	if not response.get("ok", false):
		return {}
	var data: Variant = response.get("data")
	return data if data is Dictionary else {}


## Lists the tables under a dbRootId. Returns {} on failure.
func get_db_table_list(
	db_root_id: String, chain: String = "sol", progress_callback: Callable = Callable()
) -> Dictionary:
	if db_root_id.is_empty():
		last_error = "dbRootId cannot be empty."
		return {}
	var started: Dictionary = await _request(
		"GET",
		"/db/getTablelistFromRoot",
		{"dbRootId": db_root_id, "chain": _normalize_chain(chain)}
	)
	var result: Variant = await _follow_job(started, progress_callback)
	return result if result is Dictionary else {}


## Reads rows from a table. On SOL pass table_pda; on MON pass db_root_id plus
## table_name. Returns {} on failure.
func read_db_table_rows(
	table_pda: String = "",
	db_root_id: String = "",
	table_name: String = "",
	chain: String = "sol",
	limit: int = 20,
	before: String = "",
	progress_callback: Callable = Callable()
) -> Dictionary:
	var normalized := _normalize_chain(chain)
	var query := {"chain": normalized}

	if normalized == "mon":
		if db_root_id.is_empty() or table_name.is_empty():
			last_error = "MON row reads need both dbRootId and tableName."
			return {}
		query["dbRootId"] = db_root_id
		query["tableName"] = table_name
	else:
		if table_pda.is_empty():
			last_error = "SOL row reads need a tablePda."
			return {}
		query["tablePda"] = table_pda

	if limit > 0:
		query["limit"] = str(limit)
	if not before.is_empty():
		query["before"] = before

	var started: Dictionary = await _request("GET", "/db/readTableRows", query)
	var result: Variant = await _follow_job(started, progress_callback)
	return result if result is Dictionary else {}


## HanLock encode, using the passphrase the host holds. Returns "" on failure.
func han_encrypt(text: String) -> String:
	return await _han("/han_encrypt", text)


## HanLock decode. Returns "" on failure.
func han_decrypt(text: String) -> String:
	return await _han("/han_decrypt", text)


func _han(path: String, text: String) -> String:
	if text.is_empty():
		last_error = "Nothing to encode."
		return ""
	var response: Dictionary = await _request("POST", path, {}, {"data": text})
	if not response.get("ok", false):
		return ""
	return str(response.get("text", ""))

#endregion


#region Writes

## Inscribes data on-chain. This spends real funds, so unless the host has
## already granted this app write access it blocks while GodOnChain asks the
## user, and returns null if they decline.
##
## Returns the transaction signature (SOL) or hash (MON), or null.
func write_code_in(
	data: String,
	filename: String = "",
	filetype: String = "",
	chain: String = "sol",
	progress_callback: Callable = Callable()
) -> Variant:
	var payload := data.strip_edges()
	if payload.is_empty():
		last_error = "Cannot inscribe empty data."
		return null

	var started: Dictionary = await _request(
		"POST",
		"/write",
		{},
		{
			"data": payload,
			"filename": filename.strip_edges(),
			"filetype": filetype.strip_edges(),
			"chain": _normalize_chain(chain),
		}
	)
	return await _follow_job(started, progress_callback)

#endregion


#region Job polling

## Takes a {jobId} response and polls it to completion.
func _follow_job(started: Dictionary, progress_callback: Callable) -> Variant:
	if not started.get("ok", false):
		return null
	var data: Variant = started.get("data")
	if not data is Dictionary or not (data as Dictionary).has("jobId"):
		last_error = "Host did not return a jobId."
		return null
	return await poll_job(str((data as Dictionary)["jobId"]), progress_callback)


## Polls a job until it completes or fails. Returns its result, or null.
func poll_job(job_id: String, progress_callback: Callable = Callable()) -> Variant:
	while true:
		var response: Dictionary = await _request("GET", "/progress", {"jobId": job_id})
		if not response.get("ok", false):
			return null

		var data: Variant = response.get("data")
		if not data is Dictionary:
			last_error = "Malformed progress response."
			return null
		var job: Dictionary = data

		if progress_callback.is_valid():
			progress_callback.call(float(job.get("progress", 0)))

		match str(job.get("status", "")):
			"completed":
				return job.get("result")
			"error":
				last_error = str(job.get("error", "The job failed."))
				return null

		await get_tree().create_timer(POLL_INTERVAL).timeout

	return null

#endregion


#region HTTP

func _normalize_chain(chain: String) -> String:
	var c := chain.strip_edges().to_lower()
	if c == "monad" or c == "mon":
		return "mon"
	return "sol"


## Issues one request, returning
## {ok: bool, code: int, data: Variant, text: String, error: String}.
## authenticated is only false for the /health probe.
func _request(
	method: String,
	path: String,
	query: Dictionary = {},
	body: Variant = null,
	authenticated: bool = true
) -> Dictionary:
	if base_url.is_empty():
		last_error = "No host configured; call discover() first."
		return {"ok": false, "code": 0, "error": last_error}

	var url := base_url + path
	if not query.is_empty():
		var parts: PackedStringArray = []
		for key: String in query:
			parts.append("%s=%s" % [key, str(query[key]).uri_encode()])
		url += "?" + "&".join(parts)

	var headers: PackedStringArray = []
	if authenticated:
		headers.append("Authorization: Bearer " + token)
	var body_text := ""
	if body != null:
		headers.append("Content-Type: application/json")
		body_text = JSON.stringify(body)

	var http := HTTPRequest.new()
	# A write can sit for minutes while the user decides, so never time out.
	http.timeout = 0
	add_child(http)

	var verb := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var err := http.request(url, headers, verb, body_text)
	if err != OK:
		http.queue_free()
		last_error = "Could not reach the host (error %d)." % err
		return {"ok": false, "code": 0, "error": last_error}

	var result: Array = await http.request_completed
	http.queue_free()

	var request_result: int = result[0]
	var code: int = result[1]
	var raw: PackedByteArray = result[3]
	var text := raw.get_string_from_utf8()

	if request_result != HTTPRequest.RESULT_SUCCESS:
		_available = false
		last_error = "The host stopped responding (result %d)." % request_result
		host_missing.emit(last_error)
		return {"ok": false, "code": code, "error": last_error, "text": text}

	var parsed: Variant = JSON.parse_string(text)

	if code < 200 or code >= 300:
		var message := text
		if parsed is Dictionary and (parsed as Dictionary).has("error"):
			message = str((parsed as Dictionary)["error"])
		if code == 401:
			message = "This app is not authorised to use the on-chain host."
		elif code == 403 and message.is_empty():
			message = "The user declined this request."
		last_error = message
		return {"ok": false, "code": code, "error": message, "data": parsed, "text": text}

	return {"ok": true, "code": code, "data": parsed, "text": text, "error": ""}

#endregion
