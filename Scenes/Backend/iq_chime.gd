## The sound of an app asking to spend your money.
##
## Rings whenever an approval prompt is raised, whichever app raised it. That
## is why it lives here and not in any one app: the prompt belongs to the host,
## so the alert does too, and every launched app gets it without shipping any
## audio of its own.
##
## Synthesised rather than shipped as a file — a struck tone is a handful of
## sine waves, and generating it costs nothing on disk and nothing to export.
##
## Deliberately not mutable. An app is about to move funds, or open something
## addressed to you, and the request may well have arrived while you were
## looking at a different window.

class_name IQChime
extends AudioStreamPlayer

## Fire is not the point here; a clean tone needs a little more bandwidth.
const MIX_RATE := 32000.0
const BUFFER_SECONDS := 0.2

## Quiet. It is a notification, not an alarm.
const VOLUME_DB := -14.0

## Two strikes, so it reads as a summons rather than an incidental click.
const FIRST_HZ := 660.0
const SECOND_HZ := 880.0
const SECOND_DELAY := 0.16
## Roughly a second of ring-out.
const DECAY := 0.99988

var _playback: AudioStreamGeneratorPlayback

var _envelope := 0.0
var _phase := 0.0
var _frequency := FIRST_HZ
## Counts down to the second strike, in samples. Negative means none pending.
var _pending := -1


func _ready() -> void:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = MIX_RATE
	generator.buffer_length = BUFFER_SECONDS
	stream = generator
	volume_db = VOLUME_DB

	play()
	_playback = get_stream_playback()
	# Headless runs and machines without an audio device have no playback.
	set_process(_playback != null)


## Rings once. Safe to call again while still ringing — it simply restrikes.
func ring() -> void:
	if _playback == null:
		return
	_envelope = 1.0
	_phase = 0.0
	_frequency = FIRST_HZ
	_pending = int(SECOND_DELAY * MIX_RATE)


func _process(_delta: float) -> void:
	if _playback == null:
		return

	var frames := _playback.get_frames_available()
	if frames <= 0:
		return

	var buffer := PackedVector2Array()
	buffer.resize(frames)

	for i in frames:
		buffer[i] = _next_sample()

	_playback.push_buffer(buffer)


func _next_sample() -> Vector2:
	if _pending > 0:
		_pending -= 1
		if _pending == 0:
			# The second strike lands on top of whatever is left of the first.
			_envelope = maxf(_envelope, 0.85)
			_frequency = SECOND_HZ
			_phase = 0.0

	if _envelope <= 0.0005:
		return Vector2.ZERO

	_phase += TAU * _frequency / MIX_RATE
	# The fifth above gives it a struck, bell-like quality rather than a beep.
	var value := (sin(_phase) + 0.45 * sin(_phase * 1.5)) * 0.5 * _envelope
	_envelope *= DECAY

	return Vector2(value, value)
