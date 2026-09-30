extends AudioStreamPlayer3D
class_name GunAudio
## 3D 枪声 / 音效（阶段 2）
##
## 用 AudioStreamPlayer3D 播放，每发随机化音高与音量（±5%），避免连发时听出重复感。
## 目前没有枪声素材，枪声是**程序化合成**的占位音（噪声爆音 + 低频冲击 + 余响），
## 音高 / 音量随机、3D 衰减、距离感都已就位。
##
## TODO(阶段2+)：把 _build_gunshot() 换成真实 .ogg 枪声采样（load("res://audio/rifle_shot.ogg")），
##              并区分室内混响（AudioEffectReverb + Area3D）与远处枪声的低频衰减。

## 基础音量（dB）
@export var base_volume_db := -4.0
## 音高随机范围 ±（0.05 = ±5%）
@export var pitch_variation := 0.05
## 音量随机范围 ±（dB，0.45 dB 约等于 ±5%）
@export var volume_variation_db := 0.45
## 3D 衰减起点（米）
@export var unit_size_m := 12.0
## 可听距离（米）
@export var max_hear_distance := 150.0

var _shot_stream: AudioStreamWAV
var _empty_stream: AudioStreamWAV


func _ready() -> void:
	unit_size = unit_size_m
	max_distance = max_hear_distance
	_shot_stream = _build_gunshot()
	_empty_stream = _build_empty_click()


func play_shot() -> void:
	_play_randomized(_shot_stream)


## 弹匣打空时的空仓咔哒声
func play_empty() -> void:
	_play_randomized(_empty_stream)


func get_last_pitch_scale() -> float:
	return pitch_scale


func _play_randomized(stream: AudioStreamWAV) -> void:
	if stream == null:
		return
	self.stream = stream
	pitch_scale = randf_range(1.0 - pitch_variation, 1.0 + pitch_variation)
	volume_db = base_volume_db + randf_range(-volume_variation_db, volume_variation_db)
	play()


## 程序化合成枪声（占位素材，可整体替换为真实采样）
func _build_gunshot() -> AudioStreamWAV:
	var rate := 44100
	var duration := 0.22
	var count := int(rate * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7777
	for i in count:
		var t := float(i) / float(rate)
		var crack := rng.randf_range(-1.0, 1.0) * exp(-t * 260.0) # 起始爆音
		var noise := rng.randf_range(-1.0, 1.0) * exp(-t * 38.0) * 0.75 # 主体噪声
		var body := sin(TAU * 80.0 * t) * exp(-t * 26.0) * 0.55 # 低频冲击
		var tail := rng.randf_range(-1.0, 1.0) * exp(-t * 9.0) * 0.18 * (1.0 - exp(-t * 120.0)) # 余响
		var sample := clampf(crack + noise + body + tail, -1.0, 1.0) * 0.9
		data.encode_s16(i * 2, int(sample * 32000.0))
	return _wrap_wav(data, rate)


func _build_empty_click() -> AudioStreamWAV:
	var rate := 44100
	var duration := 0.06
	var count := int(rate * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	for i in count:
		var t := float(i) / float(rate)
		var click := rng.randf_range(-1.0, 1.0) * exp(-t * 420.0)
		var tick := sin(TAU * 1200.0 * t) * exp(-t * 180.0) * 0.35
		var sample := clampf(click + tick, -1.0, 1.0) * 0.6
		data.encode_s16(i * 2, int(sample * 32000.0))
	return _wrap_wav(data, rate)


func _wrap_wav(data: PackedByteArray, rate: int) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav