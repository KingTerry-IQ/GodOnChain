## An app's home on-chain: one database root, and every table it owns.
##
## The IQ database addresses a table by (root, name). Most apps want a single
## root of their own and many tables beneath it — one per user, per document,
## per whatever the app counts — so this binds the root and the chain once and
## offers the table operations without repeating them.
##
##     var space := IQSpace.new(iq, "GodOnChain-Acme-Notebook")
##     await space.create_table("notes_alice", ["id", "body"], "id")
##     await space.write_row("notes_alice", {"id": "1", "body": "hello"})
##     var rows := await space.read_rows("notes_alice")
##
## The root is bound because it is the app; the chain is not, because it is a
## property of the operation. An app that uses both keeps one space and says
## which chain per call:
##
##     await space.on("mon").write_row("notes_alice", row)
##
## The chain given to the constructor is only the default for the common case
## of an app that never leaves one.
##
## It also hides a real difference between the chains: Monad addresses a table
## by name, while Solana needs a program-derived address that only the root's
## table listing can give you. Callers should never have to know which chain
## they are on to read a row.
##
## ## Choosing a root
##
## A root is created by whoever first makes a table under it, and that creator
## is recorded on-chain. Two consequences worth deciding on deliberately, both
## of which follow from the program rather than from this class:
##
##   Fees.    `create_table` pays the root's creator. An app whose users all
##            build under one app-owned root routes those fees to the app; an
##            app where each user has their own root routes each user's fees
##            back to themselves.
##
##   Control. The root's creator may set a table-creation fee at any time, and
##            may restrict *who* can create tables under it. That second power
##            is a gate on the app's users: if your app's data only works when
##            a user can create their own table, an app-owned root means the
##            app can lock users out. Leave the creator list empty unless you
##            genuinely intend to hold that switch.
##
## A shared root also means a shared table namespace. Use scoped() to keep one
## user's tables from colliding with another's.

class_name IQSpace
extends RefCounted

## "chain/root/table" -> resolved Solana address. Resolution costs a round trip
## and the answer never changes, so it is worth keeping for the session.
static var _addresses: Dictionary = {}

var client: IQClient
## The database root every table here belongs to.
var root: String = ""
var chain: String = "sol"
var last_error: String = ""


func _init(iq: IQClient = null, app_root: String = "", target_chain: String = "sol") -> void:
	client = iq
	root = app_root.strip_edges()
	chain = target_chain.strip_edges().to_lower()


## The same root, on another chain.
##
## The root is the app and the chain is the operation, so an app that writes to
## both keeps one space and picks per call rather than juggling an object per
## chain. `chain` on the constructor is only a default for the common case of
## an app that never leaves one.
##
## Returns self when the chain already matches; otherwise a new space on the
## same root. A space is three fields over a shared address cache, so these are
## not worth pooling — and pooling them would create reference cycles between
## siblings for no gain.
##
## Because it may hand back a different object, hold what it returns when you
## intend to read `last_error` afterwards:
##
##     var here := space.on(chain)
##     if await here.write_row(...) == null:
##         push_error(here.last_error)   # not space.last_error
##
## Reading the error off the original is the mistake this is warning about: the
## failure was recorded on the space that did the work.
func on(target_chain: String) -> IQSpace:
	var wanted := target_chain.strip_edges().to_lower()
	if wanted.is_empty() or wanted == chain:
		return self
	return IQSpace.new(client, root, wanted)


static func is_monad(target_chain: String) -> bool:
	var c := target_chain.strip_edges().to_lower()
	return c == "mon" or c == "monad"


## A table name that will not collide with another owner's under a shared root.
##
## Under one app root every user's tables live in the same namespace, so a name
## built from the data alone ("flame_march") will eventually be claimed twice.
## Passing something unique to the owner — a wallet address, a handle — keeps
## them apart. Only the tail of `owner` is used: addresses are long, table names
## are not, and the tail of an address is as distinguishing as the head.
static func scoped(owner: String, name: String) -> String:
	var tag := owner.strip_edges()
	if tag.is_empty():
		return name
	tag = tag.substr(maxi(tag.length() - 8, 0)).to_lower()
	var safe := ""
	for i in tag.length():
		var c := tag[i]
		safe += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "_"
	return "%s_%s" % [name, safe]


#region Writing

## Creates one table under this root. Spends, so the user is asked first.
##
## `writers` is the list of wallets permitted to write to it. Leave it empty and
## the table accepts a row from anyone — which the program treats as deliberate,
## not as an oversight, and which cannot be tightened afterwards. Name the
## owner here for anything whose authorship matters.
func create_table(
	name: String,
	columns: PackedStringArray,
	id_col: String,
	writers: PackedStringArray = [],
	progress: Callable = Callable()
) -> Variant:
	if not _ready():
		return null

	var options := {}
	if not writers.is_empty():
		options["writers"] = Array(writers)

	var result = await client.create_table(
		root, name, columns, id_col, chain, options, progress
	)
	if result == null:
		last_error = client.last_error
	else:
		forget(name)
	return result


## Appends one row. Spends, so the user is asked first.
func write_row(name: String, row: Dictionary, progress: Callable = Callable()) -> Variant:
	if not _ready():
		return null
	var result = await client.write_row(root, name, row, chain, {}, progress)
	if result == null:
		last_error = client.last_error
	return result

#endregion


#region Reading

## Rows from one table, newest-first as the chain returns them, already
## unwrapped into plain dictionaries. Costs nothing.
##
## Returns [] both when the table does not exist and when it is empty: to a
## reader those are the same answer, and `error` carries the distinction for
## anyone who needs it.
##
## `with_signers` asks the host to resolve who signed each row, at the cost of
## one transaction lookup per signature. Rows then carry "__signer". Nothing
## else can tell you who really wrote a row: its own fields are written by
## whoever sent the transaction and can claim anything.
func read_rows(
	name: String,
	limit: int = 20,
	error: Array = [],
	progress: Callable = Callable(),
	with_signers: bool = false
) -> Array:
	if not _ready():
		error.append(last_error)
		return []

	var raw: Dictionary = {}
	if is_monad(chain):
		raw = await client.read_db_table_rows(
			"", root, name, chain, limit, "", progress, with_signers
		)
		if raw.is_empty():
			error.append(client.last_error)
	else:
		var address: String = await resolve_address(name, error)
		if address.is_empty():
			return []
		raw = await client.read_db_table_rows(
			address, "", "", chain, limit, "", progress, with_signers
		)
		if raw.is_empty():
			error.append(client.last_error)

	return rows_of(raw)


## Whether the table is actually on-chain.
##
## Worth asking after creating one: a write job reporting "completed" only means
## the host finished its work, and a reverted transaction looks the same from
## here.
func table_exists(name: String) -> bool:
	if not _ready():
		return false
	forget(name)
	if is_monad(chain):
		var rows: Dictionary = await client.read_db_table_rows("", root, name, chain, 1)
		return not rows.is_empty()
	var problem: Array = []
	return not (await resolve_address(name, problem)).is_empty()


## Every table under this root, by name. Costs nothing.
func table_names() -> PackedStringArray:
	var out: PackedStringArray = []
	if not _ready():
		return out
	var listing: Dictionary = await client.get_db_table_list(root, chain)
	for seed: Variant in listing.get("tableSeeds", []):
		out.append(_from_seed(str(seed)))
	return out

#endregion


#region Addressing

## A Solana table's on-chain address, found by matching its seed in the root's
## listing. Returns "" when the table has not been created yet.
func resolve_address(name: String, error: Array = []) -> String:
	var key := "%s/%s/%s" % [chain, root, name]
	if _addresses.has(key):
		return str(_addresses[key])

	var listing: Dictionary = await client.get_db_table_list(root, chain)
	if listing.is_empty():
		error.append(client.last_error)
		return ""

	var seeds: Array = listing.get("tableSeeds", [])
	var addresses: Array = listing.get("tablePdas", [])
	# The listing reports seeds hex-encoded, so compare in that form.
	var wanted := name.to_utf8_buffer().hex_encode()

	for i in mini(seeds.size(), addresses.size()):
		var seed := str(seeds[i]).to_lower()
		if seed == wanted or seed == name:
			_addresses[key] = str(addresses[i])
			return str(addresses[i])

	error.append("No '%s' table under %s yet." % [name, root])
	return ""


## Forgets a cached address, for when a table has just been created.
func forget(name: String) -> void:
	_addresses.erase("%s/%s/%s" % [chain, root, name])

#endregion


#region Row shapes

## One row, whichever chain it came from.
##
## The two SDKs disagree: Solana hands back the row's own fields at the top
## level, while Monad wraps them as {txHash, data}. Reading Monad rows as though
## they were flat finds no fields at all.
##
## The transaction id is normalised onto "__tx", and the signer — when it was
## asked for — onto "__signer". Both come from the wrapper rather than the
## payload, because a row's own fields can claim anything.
static func unwrap_row(entry: Variant) -> Dictionary:
	if not entry is Dictionary:
		return {}
	var row: Dictionary = entry

	if row.has("data"):
		var payload: Variant = row["data"]
		# Some paths hand the row back as a JSON string rather than an object.
		if payload is String:
			payload = JSON.parse_string(str(payload))
		if payload is Dictionary:
			var inner: Dictionary = (payload as Dictionary).duplicate()
			inner["__tx"] = str(row.get("txHash", row.get("signature", "")))
			inner["__signer"] = str(row.get("__signer", ""))
			return inner

	var flat := row.duplicate()
	flat["__tx"] = str(row.get("__txSignature", row.get("signature", row.get("txHash", ""))))
	flat["__signer"] = str(row.get("__signer", ""))
	return flat


## Every row from a raw result, already unwrapped.
static func rows_of(result: Dictionary) -> Array:
	var out: Array = []
	for entry: Variant in result.get("rows", []):
		var row := unwrap_row(entry)
		if not row.is_empty():
			out.append(row)
	return out

#endregion


func _from_seed(seed: String) -> String:
	# Seeds come back hex-encoded; anything else is already a name.
	var bytes := seed.hex_decode()
	return bytes.get_string_from_utf8() if not bytes.is_empty() else seed


func _ready() -> bool:
	if client == null or not client.is_available():
		last_error = "Not attached to a host."
		return false
	if root.is_empty():
		last_error = "No root is set for this space."
		return false
	return true
