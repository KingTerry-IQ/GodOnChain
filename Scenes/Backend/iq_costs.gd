## What a write costs, in the chain's own units.
##
## One model, used by both the approval prompt and the activity log. They have
## to agree: a number quoted before the user says yes and a different number
## reported afterwards is worse than not quoting one at all.
##
## Every figure is an estimate of the protocol fee and excludes gas. The floor
## matters as much as the slope — a payload-free write still pays a base
## transaction, so there is deliberately no early return for zero bytes.

class_name IQCosts
extends RefCounted

## Solana charges a small fee per chunk on top of two fixed transactions.
const SOL_CHUNK_BYTES := 850
const SOL_INITIAL_TX := 0.0001
const SOL_PER_CHUNK := 0.000005
const SOL_FINAL_TX := 0.005005

## Monad charges per much larger chunk, and the base is the dominant term.
const MON_CHUNK_BYTES := 70656
const MON_PER_CHUNK := 0.415971708
const MON_BASIC_FEE := 6.5
const MON_FINAL_TX := 19.5

## Robinhood Chain prices by *which path* a write takes rather than by size:
## a payload that fits inline pays the basic fee, and anything larger is
## chunked into batches that each pay the linked-list fee. Fees are in ETH,
## which is also its gas token. Figures are the documented protocol fees.
const RH_INLINE_LIMIT := 700
const RH_CHUNK_BYTES := 98_304  # ~96 KB per batch
const RH_PER_CHUNK := 0.000036029400056
const RH_BASIC_FEE := 0.00012
const RH_LINKED_FEE := 0.00036


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


## The estimate as a number, in whole tokens.
static func estimate(chain: String, bytes: int) -> float:
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


## What a payload of this size costs, as words.
static func format(chain: String, bytes: int) -> String:
	return amount(chain, estimate(chain, bytes))
