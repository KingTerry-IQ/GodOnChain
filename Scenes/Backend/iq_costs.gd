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
const MON_FINAL_TX := 6.51834143


static func is_monad(chain: String) -> bool:
	return chain.strip_edges().to_lower().begins_with("mon")


## The estimate as a number, in whole tokens.
static func estimate(chain: String, bytes: int) -> float:
	var payload: int = maxi(bytes, 0)

	if is_monad(chain):
		@warning_ignore("integer_division")
		var mon_chunks: int = (payload + MON_CHUNK_BYTES - 1) / MON_CHUNK_BYTES
		return MON_FINAL_TX + mon_chunks * MON_PER_CHUNK

	@warning_ignore("integer_division")
	var sol_chunks: int = (payload + SOL_CHUNK_BYTES - 1) / SOL_CHUNK_BYTES
	return SOL_INITIAL_TX + sol_chunks * SOL_PER_CHUNK + SOL_FINAL_TX


## The estimate as words, at the precision each chain deserves: fractions of a
## SOL are meaningful at six places, fractions of a MON are not.
static func format(chain: String, bytes: int) -> String:
	if is_monad(chain):
		return "~%.4f MON" % estimate(chain, bytes)
	return "~%.6f SOL" % estimate(chain, bytes)
