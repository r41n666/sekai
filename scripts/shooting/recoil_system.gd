extends Node3D
class_name RecoilSystem
## 三层后坐力系统（阶段 2）
##
## 第 1 层 · 视觉后坐力：每一发的瞬时摄像机抖动（上抬 + 随机左右），lerp 快速归零。
## 第 2 层 · 弹道偏移模式：固定、可学习的喷射弹道（先垂直爬升、再左右漂移），停火后慢慢归零。
## 第 3 层 · 扩散值：连射 / 移动时增大、静止时收缩，驱动「动态准星大小」与「实际弹道随机散布」。
##
## 本节点挂在摄像机链上：CameraPivot(鼠标 yaw) → RecoilPivot(本脚本) → SwayPivot → SpringArm3D(鼠标 pitch)。
## 每帧只把自己的 rotation 写成后坐力偏移量，因此与鼠标输入互不干扰（叠加关系）。

## 扩散值变化通知（HUD 也可以直接用 get_spread() 轮询）
signal spread_changed(spread: float)

@export_group("第 1 层：视觉后坐力")
## 每发向上抬起的角度（度）
@export var visual_kick_pitch := 0.55
## 每发随机左右抖动的幅度（度）
@export var visual_kick_yaw := 0.22
## 归零速度，越大恢复越快
@export var visual_recovery := 14.0

@export_group("第 2 层：弹道偏移模式")
@export var pattern_enabled := true
## 固定的随机种子：同一个种子 → 同一套可学习弹道
@export var pattern_seed := 20260930
## 一个完整弹道的发数
@export var pattern_length := 30
## 起始每发上抬（度）
@export var pattern_kick_start := 0.22
## 末段每发上抬（度）
@export var pattern_kick_end := 0.5
## 每发横向漂移（度）
@export var pattern_side_kick := 0.3
## 停火后弹道偏移归零速度
@export var pattern_recovery := 7.0
## 停火多久后开始归零 / 重置弹道序号
@export var pattern_reset_delay := 0.35

@export_group("第 3 层：扩散值")
## 静止站立时的基础扩散（0~1）
@export var base_spread := 0.12
## 每发增加的扩散
@export var per_shot_spread := 0.16
@export var max_spread := 1.0
## 每秒恢复的扩散值（指数收敛速率，越大回得越快）
@export var spread_recovery := 3.0
## 开镜（ADS）时的扩散倍率
@export var ads_spread_scale := 0.4
## 全速移动时的额外扩散
@export var move_spread := 0.45
## 扩散值 = 1.0 时对应的最大弹道偏离角度（度）
@export var spread_deg_max := 3.6

@export_group("第 4 层（预留）：呼吸/受伤抖动")
## TODO(阶段2+)：呼吸摆动、受伤时的镜头颤抖、压制（suppression）模糊

var _visual_pitch := 0.0
var _visual_yaw := 0.0
var _pattern_pitch := 0.0
var _pattern_yaw := 0.0
var _spread := 0.0
var _shot_index := 0
var _since_shot := 999.0
var _pattern: Array[Vector2] = []
var _ads := false
var _move_amount := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	if not is_in_group("recoil"):
		add_to_group("recoil") # 供 HUD 读取扩散值
	_build_pattern()


## 开火一发：三层同时作用
func fire_shot() -> void:
	_shot_index += 1
	_since_shot = 0.0

	# 第 1 层：视觉后坐力
	_visual_pitch += deg_to_rad(visual_kick_pitch)
	_visual_yaw += deg_to_rad(_rng.randf_range(-visual_kick_yaw, visual_kick_yaw))

	# 第 2 层：弹道偏移模式
	if pattern_enabled and not _pattern.is_empty():
		var step := _pattern[mini(_shot_index - 1, _pattern.size() - 1)]
		_pattern_pitch += step.x
		_pattern_yaw += step.y

	# 第 3 层：扩散值
	# 开镜时每发增量也变小，因此连射时开镜明显比腰射精准
	var gain := per_shot_spread * (ads_spread_scale if _ads else 1.0)
	_spread = minf(_spread + gain, max_spread)
	spread_changed.emit(get_spread())


func _process(delta: float) -> void:
	_since_shot += delta

	# 第 1 层：始终快速归零
	var visual_k := 1.0 - exp(-visual_recovery * delta)
	_visual_pitch = lerpf(_visual_pitch, 0.0, visual_k)
	_visual_yaw = lerpf(_visual_yaw, 0.0, visual_k)

	# 第 2 层：停火一小会儿后才开始归零，并最终重置弹道序号
	if _since_shot > pattern_reset_delay:
		var pattern_k := 1.0 - exp(-pattern_recovery * delta)
		_pattern_pitch = lerpf(_pattern_pitch, 0.0, pattern_k)
		_pattern_yaw = lerpf(_pattern_yaw, 0.0, pattern_k)
		if _since_shot > pattern_reset_delay * 4.0:
			_shot_index = 0

	# 第 3 层：向目标扩散值指数收敛（连射涨、静止收缩）
	# 指数收敛 = 停火后先快后慢地回正，手感比线性 move_toward 更接近战地
	var target_spread := base_spread + move_spread * _move_amount
	if _ads:
		target_spread *= ads_spread_scale
	target_spread = clampf(target_spread, 0.0, max_spread)
	_spread = lerpf(_spread, target_spread, 1.0 - exp(-spread_recovery * delta))

	rotation = Vector3(_visual_pitch + _pattern_pitch, _visual_yaw + _pattern_yaw, 0.0)


## 归一化扩散值（0~1），供动态准星使用
func get_spread() -> float:
	return clampf(_spread / max_spread, 0.0, 1.0)


## 当前实际弹道最大偏离角度（弧度），供 hitscan 随机散布使用
func get_bullet_deviation_radians() -> float:
	return deg_to_rad(lerpf(0.0, spread_deg_max, get_spread()))


## 开镜时扩散更小
func set_aiming(aiming: bool) -> void:
	_ads = aiming


## 移动量（0~1）：移动时扩散更大
func set_movement_amount(amount: float) -> void:
	_move_amount = clampf(amount, 0.0, 1.0)


## 给 HUD / 调试用：当前三层偏移（度）
func get_debug_offsets_deg() -> Vector3:
	return Vector3(
		rad_to_deg(_visual_pitch + _pattern_pitch),
		rad_to_deg(_visual_yaw + _pattern_yaw),
		0.0
	)


func _build_pattern() -> void:
	_pattern.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = pattern_seed
	var yaw := 0.0
	var direction := 1.0
	for i in pattern_length:
		var t := float(i) / maxf(float(pattern_length - 1), 1.0)
		var pitch := deg_to_rad(lerpf(pattern_kick_start, pattern_kick_end, t))
		if i % 7 == 6:
			direction = -direction # 每隔几发反向漂移，形成左右摆动
		yaw += deg_to_rad(rng.randf_range(0.4, 1.0) * pattern_side_kick * direction)
		_pattern.append(Vector2(pitch, yaw))