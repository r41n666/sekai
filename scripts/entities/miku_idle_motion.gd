class_name MikuIdleMotion
extends Node3D
## 程序化「待机微动作」（无骨骼 / 无动画剪辑的模型也能有生命感）。
##
## 为什么单独做一个节点：MikuModel 会把「站 / 蹲 / 趴」的旋转与高度作用在 MikuModel 节点本身
## （player.gd 的 _update_stance），所以待机微动不能再动 MikuModel；这里在 MikuModel 与
## 载入的模型之间插一层节点，微动只作用在这一层，和姿态系统互不打架。
##
## 三组基础动作（都用正弦，天然平滑、无接缝）：
##   1) 呼吸起伏：沿 Y 缓慢升沉 + 极轻微的整体缩放脉动（胸腔起伏）；
##   2) 重心微移：沿 X 的慢速左右摆动（像站立时把重心从一只脚挪到另一只脚）；
##   3) 上身摆动：绕 Y / Z 的轻微转动（躯干与头部的自然摇摆）。
## 关键：三条频率取**互不成整数比**的值，合成波长很长，肉眼看不出循环点（避免"生硬循环接缝"）；
## 每个通道再叠一个二次谐波（×2 频率、小振幅），让曲线不是纯正弦，更有机感。
##
## 用法：MikuModel 载入模型后
##   var idle := MikuIdleMotion.new(); idle.name = "IdleMotion"
##   add_child(idle); idle.setup(model_child, profile)
## profile = 该模型的参数（幅度 / 频率 / 相位），见 MikuModel.IDLE_PROFILES。

## 一次 setup 后，每帧自动在 _process 里更新（无需外部驱动）。
var _target: Node3D              ## 被驱动的模型节点（IdleMotion 的子节点）
var _base_position := Vector3.ZERO
var _base_rotation := Vector3.ZERO
var _base_scale := Vector3.ONE

## 幅度（米 / 弧度 / 比例）
var breath_amp := 0.012          ## 呼吸升沉（米）
var breath_scale_amp := 0.006    ## 呼吸缩放脉动（比例）
var sway_x_amp := 0.016          ## 重心左右微移（米）
var sway_z_amp := 0.010          ## 前后微移（米）
var yaw_amp := 0.030             ## 上身左右微转（弧度，≈1.7°）
var roll_amp := 0.010            ## 上身侧倾（弧度）
var pitch_amp := 0.008           ## 上身俯仰（弧度，≈0.5°）

## 频率（Hz，越低越舒缓）
var breath_freq := 0.22          ## 呼吸周期 ≈ 4.5 s
var sway_freq := 0.13            ## 重心周期 ≈ 7.7 s
var sway_roll_freq := 0.17       ## 摆动周期 ≈ 5.9 s
## 二次谐波占比（0=纯正弦；0.25 左右更自然）
var harmonic := 0.25

## 整体强度（0 关闭；1 正常；用于淡入 / 停用时收住）
var intensity := 1.0
var _enabled := true
var _time := 0.0

## 内部：三组相位错开，让三条曲线不同时归零
const PHASE_BREATH := 0.0
const PHASE_SWAY := 1.7
const PHASE_SWAY_ROLL := 3.4


func setup(target: Node3D, profile: Dictionary = {}) -> void:
	_target = target
	if _target == null:
		_enabled = false
		return
	# 把目标节点挂到本节点下，保留它自己原来的局部变换（缩放在这里、旋转在模型自身）
	if _target.get_parent() != self:
		var keep := _target.transform
		if _target.get_parent() != null:
			_target.get_parent().remove_child(_target)
		add_child(_target)
		_target.transform = keep
	_base_position = _target.position
	_base_rotation = _target.rotation
	_base_scale = _target.scale
	apply_profile(profile)
	_enabled = true


## 应用一套参数（幅度 / 频率）。未提供的键保持默认。
func apply_profile(profile: Dictionary) -> void:
	breath_amp = profile.get("breath_amp", breath_amp)
	breath_scale_amp = profile.get("breath_scale_amp", breath_scale_amp)
	sway_x_amp = profile.get("sway_x_amp", sway_x_amp)
	sway_z_amp = profile.get("sway_z_amp", sway_z_amp)
	yaw_amp = profile.get("yaw_amp", yaw_amp)
	roll_amp = profile.get("roll_amp", roll_amp)
	pitch_amp = profile.get("pitch_amp", pitch_amp)
	breath_freq = profile.get("breath_freq", breath_freq)
	sway_freq = profile.get("sway_freq", sway_freq)
	sway_roll_freq = profile.get("sway_roll_freq", sway_roll_freq)
	harmonic = profile.get("harmonic", harmonic)


## 外部可用来平滑启用 / 停用（例如趴下时收住）
func set_enabled(on: bool) -> void:
	_enabled = on


func _process(delta: float) -> void:
	if not _enabled or _target == null or not is_instance_valid(_target):
		return
	_time += delta
	var w := intensity
	# 1) 呼吸：主频 + 二次谐波
	var breath := sin(TAU * breath_freq * _time + PHASE_BREATH) \
		+ harmonic * sin(TAU * breath_freq * 2.0 * _time)
	# 2) 重心微移（左右 + 前后用不同相位，走一个小椭圆）
	var sway := sin(TAU * sway_freq * _time + PHASE_SWAY) \
		+ harmonic * sin(TAU * sway_freq * 2.0 * _time)
	var sway2 := cos(TAU * sway_freq * _time + PHASE_SWAY) \
		+ harmonic * cos(TAU * sway_freq * 2.0 * _time)
	# 3) 上身摆动：Y / Z / X 三轴，频率略不同
	var yaw := sin(TAU * sway_roll_freq * _time + PHASE_SWAY_ROLL) \
		+ harmonic * sin(TAU * sway_roll_freq * 2.0 * _time + 1.1)
	var roll := sin(TAU * sway_roll_freq * 0.83 * _time + PHASE_SWAY_ROLL + 0.9)
	var pitch := sin(TAU * sway_roll_freq * 1.19 * _time + PHASE_SWAY_ROLL + 2.3)

	_target.position = _base_position + Vector3(
		sway * sway_x_amp * w,
		breath * breath_amp * w,
		sway2 * sway_z_amp * w
	)
	_target.rotation = _base_rotation + Vector3(
		pitch * pitch_amp * w,
		yaw * yaw_amp * w,
		roll * roll_amp * w
	)
	if breath_scale_amp > 0.0:
		var s := 1.0 + breath * breath_scale_amp * w
		_target.scale = _base_scale * s
