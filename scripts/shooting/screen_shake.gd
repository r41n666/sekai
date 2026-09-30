extends Camera3D
class_name ShakeCamera
## 屏幕震动：Trauma / Noise 系统（阶段 2）
##
## 不是简单随机抖动：用 FastNoiseLite 采样出连续平滑的噪声曲线驱动位移与翻滚，
## trauma 以固定速率衰减，实际幅度 = trauma²（小 trauma 很轻、大 trauma 明显）。
##
## 直接挂在 Camera3D 上，只改 h_offset / v_offset / rotation.z（roll），
## 不碰摄像机朝向，因此不会干扰瞄准与后坐力。
##
## TODO(阶段2+)：爆炸/受击的额外震动曲线、射击时的方向性冲量（按受击方向偏移）。

## trauma 每秒衰减量
@export var trauma_decay := 1.4
## 最大水平/垂直偏移
@export var max_offset := 0.035
## 最大翻滚角度（度）
@export var max_roll := 1.6
## 噪声采样速度（越大抖得越快）
@export var noise_speed := 30.0
## 噪声频率（越大越碎）
@export var noise_frequency := 0.6
## 归零速度（trauma 用完后平滑回正）
@export var settle_speed := 6.0

var _trauma := 0.0
var _time := 0.0
var _noise := FastNoiseLite.new()


func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = noise_frequency


## 增加震动强度（0~1，累加）
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func get_trauma() -> float:
	return _trauma


func _process(delta: float) -> void:
	if _trauma <= 0.0:
		var settle_k := 1.0 - exp(-settle_speed * delta)
		h_offset = lerpf(h_offset, 0.0, settle_k)
		v_offset = lerpf(v_offset, 0.0, settle_k)
		rotation.z = lerpf(rotation.z, 0.0, settle_k)
		return

	_time += delta * noise_speed
	var shake := _trauma * _trauma # trauma² 曲线
	h_offset = _noise.get_noise_2d(_time, 0.0) * max_offset * shake
	v_offset = _noise.get_noise_2d(_time, 137.0) * max_offset * shake
	rotation.z = deg_to_rad(_noise.get_noise_2d(_time, 271.0) * max_roll * shake)

	_trauma = maxf(_trauma - trauma_decay * delta, 0.0)