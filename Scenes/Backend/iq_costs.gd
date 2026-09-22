## What a write costs, in the chain's own units.
##
## One model, used by both the approval prompt and the activity log. They have
## to agree: a number quoted before the user says yes and a different number
## reported afterwards is worse than not quoting one at all.
##
## Inscriptions (`codeIn` / `writeRow`) are protocol fees plus, on Solana, rent
## per chunk, and exclude gas. `createTable` is a different spend: Monad and
## Robinhood Chain charge a flat tableCreationFee that is entirely protocol
## revenue; Solana also inits two PDAs and the rent stays in those accounts.
## The floor still matters — a payload-free write pays a base transaction, so
## there is deliberately no early return for zero bytes.

class_name IQCosts
extends RefCounted

## Solana charges a small fee per chunk on top of two fixed transactions.
const SOL_CHUNK_BYTES := 3400
const SOL_INITIAL_TX := 0.0001
const SOL_PER_CHUNK := 0.000005
const SOL_FINAL_TX := 0.005005

## Rent locked in the two PDAs createTable inits. Measured on mainnet against
## program 9KLLchQVJpGkw4jPuUmnvqESdR7mtNCYr3qS4iQLabs (2026-09-17): table
## accounts are a fixed 2803 bytes, instruction-table accounts are 9 bytes
## (discriminator + bump; otherwise empty). At the live rent rate (5080
## lamports/byte after SIMD-0437-2) that is 0.01488948 + 0.00069596 S0OL.
## Older tables still hold ~0.020 SOL because they were funded at the pre-
## reduction rate. A dbRoot realloc is extra. This is not the 31/69 protocol
## split — those lamports never leave the PDAs.
const SOL_TABLE_RENT := 0.015585

## Monad charges per much larger chunk, and the base is the dominant term.
## MON_FINAL_TX is also the deployed tableCreationFee: the whole 19.5 MON lands
## in the IQ treasury or the dbRoot creator, with no extra account to fund.
const MON_CHUNK_BYTES := 131072
const MON_PER_CHUNK := 0.415971708
const MON_BASIC_FEE := 6.5
const MON_FINAL_TX := 19.5
const MON_TABLE_FEE := MON_FINAL_TX

## Robinhood Chain prices by *which path* a write takes rather than by size:
## a payload that fits inline pays the basic fee, and anything larger is
## chunked into batches that each pay the linked-list fee. Fees are in ETH,
## which is also its gas token. Figures are the documented protocol fees.
const RH_INLINE_LIMIT := 700
const RH_CHUNK_BYTES := 98304  # ~96 KB per batch
const RH_PER_CHUNK := 0.000036029400056
const RH_BASIC_FEE := 0.00012
const RH_LINKED_FEE := 0.00036
const RH_TABLE_FEE := RH_LINKED_FEE


static func is_monad(chain: String) -> bool:
	return chain.strip_edges().to_lower().begins_with("mon")


static func is_robinhood(chain: String) -> bool:
	var c := chain.strip_edges().to_lower()
	return c == "rh" or c == "rhc" or c == "robinhood" or c == "robinhood-chain"


## True for the chains that run the IQ Labs Ethereum SDK. They share a fee
## shape — a flat protocol fee per call — where Solana pays rent per chunk.
static func is_evm(chain: String) -> bool:
	return is_monad(chain) or is_robinhood(chain)


## The short code a chain is known by, whatever spelling arrived. Suitable as a
## dictionary key, and the same codes the sidecar accepts.
static func code(chain: String) -> String:
	if is_robinhood(chain):
		return "rh"
	if is_monad(chain):
		return "mon"
	return "sol"


## The token a chain's fees are denominated in. Robinhood Chain settles in ETH,
## so this is not simply the chain's own name.
static func token(chain: String) -> String:
	if is_robinhood(chain):
		return "ETH"
	if is_monad(chain):
		return "MON"
	return "SOL"


## True for the table-create action the sidecar names `createTable`.
static func is_create_table(action: String) -> bool:
	return action.strip_edges().to_lower() == "createtable"


## The estimate as a number, in whole tokens.
##
## `action` selects the spend: omit it (or pass anything other than
## `createTable`) and this is an inscription / row write. Table creation does
## not scale with payload bytes, so those are ignored for that action.
static func estimate(chain: String, bytes: int, action: String = "") -> float:
	if is_create_table(action):
		if is_robinhood(chain):
			return RH_TABLE_FEE
		if is_monad(chain):
			return MON_TABLE_FEE
		return SOL_TABLE_RENT

	var payload: int = maxi(bytes, 0)

	if is_robinhood(chain):
		if payload <= RH_INLINE_LIMIT:
			return RH_BASIC_FEE
		@warning_ignore("integer_division")
		var rh_batches: int = (payload + RH_CHUNK_BYTES - 1) / RH_CHUNK_BYTES
		return RH_LINKED_FEE + RH_PER_CHUNK * maxi(rh_batches, 1)

	if is_monad(chain):
		if payload <= RH_INLINE_LIMIT:
			return MON_BASIC_FEE
		@warning_ignore("integer_division")
		var mon_chunks: int = (payload + MON_CHUNK_BYTES - 1) / MON_CHUNK_BYTES
		return MON_FINAL_TX + mon_chunks * MON_PER_CHUNK

	@warning_ignore("integer_division")
	var sol_chunks: int = (payload + SOL_CHUNK_BYTES - 1) / SOL_CHUNK_BYTES
	return SOL_INITIAL_TX + sol_chunks * SOL_PER_CHUNK + SOL_FINAL_TX


## An amount already counted in tokens, written out at the precision that
## amount deserves: fractions of a SOL are meaningful at six places, fractions
## of a MON are not, and an ETH fee on Robinhood Chain is small enough that
## anything less than five places rounds it to nothing.
static func amount(chain: String, tokens: float) -> String:
	if is_robinhood(chain):
		return "~%.5f ETH" % tokens
	if is_monad(chain):
		return "~%.4f MON" % tokens
	return "~%.6f SOL" % tokens


## What this spend costs, as words. Pass `action` so a table create is not
## quoted as a payload-free inscription.
static func format(chain: String, bytes: int, action: String = "") -> String:
	return amount(chain, estimate(chain, bytes, action))
