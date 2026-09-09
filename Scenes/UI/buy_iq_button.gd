extends Button

const BUY_URL := "https://dexscreener.com/solana/3uXACfojUrya7VH51jVC1DCHq3uzK4A7g469Q954LABS"

var _normal: StyleBoxFlat
var _hover: StyleBoxFlat
var _pressed: StyleBoxFlat
var _hovered := false


func _ready() -> void:
	_normal = (get_theme_stylebox("normal") as StyleBoxFlat).duplicate()
	_hover = (get_theme_stylebox("hover") as StyleBoxFlat).duplicate()
	_pressed = (get_theme_stylebox("pressed") as StyleBoxFlat).duplicate()
	add_theme_stylebox_override("normal", _normal)
	add_theme_stylebox_override("hover", _hover)
	add_theme_stylebox_override("pressed", _pressed)
	add_theme_stylebox_override("focus", _hover)
	mouse_entered.connect(func() -> void: _hovered = true)
	mouse_exited.connect(func() -> void: _hovered = false)
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	OS.shell_open(BUY_URL)


func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() * 0.001
	var speed := 10.0 if _hovered else 4.2
	var wave := 0.5 + 0.5 * sin(t * speed)
	_normal.shadow_size = int(8.0 + wave * 16.0)
	_normal.shadow_color = Color(0.15, 1.0, 0.2, 0.4 + wave * 0.55)
	_normal.bg_color = Color(0.08 + wave * 0.2, 0.82 + wave * 0.18, 0.08, 1)
	_normal.border_color = Color(1.0, 0.82 + wave * 0.18, 0.1, 1)
	_hover.shadow_size = _normal.shadow_size + 8
	_hover.shadow_color = Color(1.0, 0.9, 0.15, 0.5 + wave * 0.45)
	_hover.bg_color = Color(1.0, 0.88 + wave * 0.12, 0.12, 1)
	_hover.border_color = Color(0.2, 1.0, 0.3, 1)
	_pressed.shadow_size = 6
	_pressed.bg_color = Color(0.75, 0.85, 0.05, 1)
