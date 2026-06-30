extends CanvasLayer
class_name ProgressSpinner

@export var phrases: Array[String] = [
	"Decentralizing the world...",
	"Reticulating splines...",
	"Spinning the hamster...",
	"Computing chance of success...",
	"Loading the enchanted bunny...",
	"Granting wishes...",
	"Adjusting flux capacitor...",
	"Bending the spoon...",
	"Tokenizing real life...",
	"We're testing your patience",
	"Feeding the pixels...",
	"Summoning more RAM...",
	"Polishing the graphics...",
	"Don't panic...",
	"Fulfilling Satoshi's Vision...",
	"Raising IQ...",
	"/DEV_IS_POOPING",
	"Syncing with the longest chain...",
	"Convincing nodes to agree...",
	"Waiting for the next block party...",
	"Proving we’re not evil...",
	"Handing out private keys to the void...",
	"Gas price negotiating with itself...",
	"Rolling up the layer 2...",
	"Bridging to the promised chain...",
	"Oracles are consulting the stars...",
	"Finality is taking its sweet time...",
	"Dusting off the mempool...",
	"Reorg protection engaged...",
	"Sharding your expectations...",
	"Zero-knowledge proof loading...",
	"Whispering to the beacon chain...",
	"Uncle blocks sulking in the corner...",
	"Merkle roots growing branches...",
	"State trie pruning in progress...",
	"Validating your right to exist...",
	"Gossiping with fellow nodes...",
	"Fork choice rule having an existential crisis...",
	"Compiling the future of finance...",
	"Inflating the token supply...",
	"Airdropping pixels to your screen...",
	"Rug-pull prevention protocol active...",
	"Liquidity mining for bandwidth...",
	"Yield farming your patience...",
	"Staking RAM on faster load times...",
	"Moon math in progress...",
	"Lambo engine warming up...",
	"HODLing the render queue...",
	"FOMO levels stabilizing...",
	"Wen load? Wen load...",
	"Satoshi is rolling in his vault...",
	"Nakamoto coefficient rising...",
	"Byzantine generals finally agreeing...",
	"Halving the wait time...",
	"Proof-of-stake dreaming of PoW glory...",
	"Sidechain loading sideways...",
	"Cross-chain message passing the vibe check...",
	"Immutable boredom incoming...",
	"Censorship-resistant spinning wheel...",
	"Trustless verification of your scroll...",
	"Distributed denial of boredom...",
	"Token-gating the DOM...",
	"Wrapping your request in layers...",
	"Unwrapping the future, slowly...",
	"Block time teasing eternity...",
	"Assembling the decentralized orchestra...",
	"Mining for that one last hash...",
	"Convincing the network you're not a bot...",
	"Waiting for 12 confirmations...",
	"Rebasing the loading bar...",
	"Deploying the frontend contract...",
	"Verifying your wallet isn't empty...",
	"ZK-rollup compressing your wait...",
	"Validating the blockchain prophecy...",
	"Consulting the whitepaper...",
	"Bootstrapping from genesis block...",
	"Paying relayers in hopes...",
	"Executing the loading script on-chain...",
	"Waiting for the halving hype to die down...",
	"Distributing shards of content...",
	"Proving work for your pixels...",
	"Staking your attention...",
	"Harvesting DeFi patience yields...",
	"Bridging assets (and time)...",
	"Oracles delivering the truth, eventually...",
	"Slashing slow validators...",
	"Composability loading modules...",
	"MEV bots bidding on your load time...",
	"Flashbot protecting your sanity...",
	"Phantom wallet connecting spirits...",
	"Curve pooling resources...",
	"Balancing the stablecoin of time...",
	"Snapshot voting on faster loads...",
	"Proof of history sequencing events...",
	"Solana slots spinning...",
	"Phantom threads weaving...",
	"Compiling HolyC...",
	"Building the Third Temple...",
	"Building the Third Temple...",
	"Consulting Terry's wisdom...",
	"Activating God mode...",
	"Locking 640x480 resolution...",
	"Rendering in 16 holy colors...",
	"Entering Ring 0...",
	"Spinning the Temple hypervisor...",
	"Randomizing divine scriptures...",
	"Blessing every single bit...",
	"Channeling pure Terry energy...",
	"Terry's kernel awakening...",
	"God himself compiling...",
	"Raising IQ to Terry levels...",
	"Summoning TempleOS...",
	"Holy-rolling the render queue...",
	"Divine intervention buffering...",
	"Temple bells tolling loudly...",
	"Writing psalms in x86...",
	"Terry A. Davis signing off...",
	"Smarter-than-silicon loading...",
	"HolyC interpreter awakening...",
	"Bootstrapping from heaven...",
	"Anointing the pixels...",
	"Praying for instant load...",
	"Third Temple reaching consensus...",
	"Ring-zero communion active...",
	"16 shades of divine light...",
	"640x480 portal opening...",
	"Flipping bits for the Lord...",
	"Assembly psalms chanting...",
	"King Terry holding court...",
	"Heavenly OS descending...",
	"God told me this is fine...",
	"TempleOS scriptures unfolding...",
	"Holy random seed generating...",
	"Solo-devving the cosmos...",
	"Based genius overclocking...",
	"Divine stack trace resolving...",
	"Prayer-powered CPU boost...",
	"Temple keyboard symphony...",
	"Holy debugger sanctifying...",
	"God debugging the universe...",
	"Terry's legacy eternalizing...",
	"Ascending to TempleOS...",
	"HolyC syntax glowing...",
	"Bit-flipping in His name...",
	"Divine boot sequence engaged...",
	"Temple construction at warp speed...",
	"God's chosen operating system..."
]

@onready var phrase_label: Label = $CenterContainer/VBoxContainer/PhrasesLabel
@onready var progress_bar: ProgressBar = $CenterContainer/VBoxContainer/ProgressBar

var phrase_index: int = randi() % phrases.size()
var phrase_timer: Timer
var phrase_tween: Tween

func set_progress(percent: int) -> void:
	progress_bar.value = percent

func _ready() -> void:
	phrase_timer = Timer.new()
	phrase_timer.one_shot = false
	phrase_timer.wait_time = 2.5  # Time per phrase (includes fade)
	phrase_timer.timeout.connect(_change_phrase)
	add_child(phrase_timer)
	phrase_timer.start()
	
	# Start with first phrase visible
	if not phrases.is_empty():
		phrase_label.text = phrases[0]

func show_spinner() -> void:
	visible = true
	phrase_timer.start()
	phrase_label.modulate.a = 1.0

func hide_spinner() -> void:
	phrase_timer.stop()
	if phrase_tween:
		phrase_tween.kill()
	var tween = create_tween()
	tween.parallel().tween_property(self, "modulate:a", 0.0, 0.5)
	tween.tween_callback(func(): visible = false)
	tween.parallel().tween_property(phrase_label, "modulate:a", 0.0, 0.5)
	self.modulate.a = 1.0  # Reset

func _change_phrase() -> void:
	if phrase_tween:
		phrase_tween.kill()
	phrase_tween = create_tween()
	phrase_tween.tween_property(phrase_label, "modulate:a", 0.0, 0.3)
	phrase_tween.tween_callback(_set_new_phrase)
	phrase_tween.tween_property(phrase_label, "modulate:a", 1.0, 0.3)

func _set_new_phrase() -> void:
	if phrases.is_empty():
		return
	phrase_index = randi() % phrases.size()
	phrase_label.text = phrases[phrase_index]
