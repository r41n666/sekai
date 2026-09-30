extends CharacterBody3D
class_name PlayerController
## 第三人称玩家控制器（阶段 1 移动 + 阶段 2 射击接入）
##
## 操作：WASD 移动 / 鼠标转视角 / Shift 加速 / Space 跳跃 / Esc 释放鼠标 / 左键射击 / 右键开镜 / R 换弹
##
## 摄像机链（阶段 2 加入后坐力与惯性）：
##   CameraPivot（鼠标 yaw）→ RecoilPivot（三层后坐力）→ SwayPivot（惯性/晃动）→ SpringArm3D（鼠标 pitch）→ Camera3D（屏幕震动）
##
## TODO(阶段 3)：接入 MultiplayerSynchronizer 同步本节点位置与朝向。
## TODO(阶段 4)：把 $MikuModel 的 CapsuleMesh 替换为 res://assets/models/miku/miku.glb（模型正面朝 +Z）。

signal health_changed(current: float, maximum: float)
signal died()

@export_group("移动")
## 正常行走速度（米/秒）
@export var walk_speed := 4.5
## 按住 sprint（Shift）时的速度
@export var sprint_speed := 8.0
## 地面加速度（越大越跟手）
@export var acceleration := 12.0
## 空中控制系数（相对地面加速度的比例）
@export var air_control := 0.35
## 起跳初速度
@export var jump_velocity := 5.0
## 角色模型转向速度
@export var model_turn_speed := 12.0
## 开镜时的移动速度倍率
@export var aim_speed_scale := 0.55

@export_group("视角")
## 鼠标灵敏度（弧度/像素）
@export var mouse_sensitivity := 0.0025
## 开镜时的鼠标灵敏度倍率
@export var aim_sensitivity_scale := 0.6
## 俯仰下限（负值 = 镜头抬高向下看）
@export var min_pitch_deg := -75.0
## 俯仰上限（正值 = 镜头压低向上看）
@export var max_pitch_deg := 55.0

@export_group("生命值")
@export var max_health := 100.0

@onready var _model: MeshInstance3D = $MikuModel
@onready var _camera_pivot: Node3D = $CameraPivot
@onready var _recoil: RecoilSystem = $CameraPivot/RecoilPivot
@onready var _sway: CameraSway = $CameraPivot/RecoilPivot/SwayPivot
@onready var _spring_arm: SpringArm3D = $CameraPivot/RecoilPivot/SwayPivot/SpringArm3D
@onready var _camera: ShakeCamera = $CameraPivot/RecoilPivot/SwayPivot/SpringArm3D/Camera3D
@onready var _weapon: Weapon = $MikuModel/Rifle

var health := 0.0
var _aiming := false
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


func _ready() -> void:
	health = max_health
	add_to_group("player")
	capture_mouse()
	_weapon.setup(self, _camera, _recoil, _camera)
	health_changed.emit(health, max_health)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_rotate_camera(event.relative)
		_sway.add_look_delta(event.relative)
		return

	if event is InputEventKey and event.echo:
		return

	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			release_mouse()
		else:
			capture_mouse()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		# 释放鼠标后，点击画面即可重新锁定
		capture_mouse()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := _get_move_direction(input_dir)

	var speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	if _aiming:
		speed *= aim_speed_scale
	var accel := acceleration if is_on_floor() else acceleration * air_control
	var blend := clampf(accel * delta, 0.0, 1.0)
	var target := direction * speed
	var horizontal := Vector2(velocity.x, velocity.z).lerp(Vector2(target.x, target.z), blend)
	velocity.x = horizontal.x
	velocity.z = horizontal.y

	if _aiming:
		# 开镜时人物（以及手里的枪）朝向跟随摄像机，避免枪口指向移动方向而不是准星方向
		var aim_yaw := _camera_pivot.rotation.y + PI
		_model.rotation.y = lerp_angle(_model.rotation.y, aim_yaw, clampf(model_turn_speed * delta, 0.0, 1.0))
	elif direction.length_squared() > 0.001:
		var target_yaw := atan2(direction.x, direction.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_yaw, clampf(model_turn_speed * delta, 0.0, 1.0))

	move_and_slide()
	_feed_subsystems()


## 把运动状态同步给后坐力与相机摇晃系统
func _feed_subsystems() -> void:
	var speed_ratio := clampf(velocity.length() / maxf(sprint_speed, 0.1), 0.0, 1.0)
	if not is_on_floor():
		speed_ratio = 0.0
	var camera_basis := _camera_pivot.global_transform.basis
	var local_velocity := camera_basis.inverse() * velocity
	_recoil.set_movement_amount(speed_ratio)
	_sway.set_motion(speed_ratio, local_velocity)


## 把输入方向转换成世界方向（只取摄像机的水平朝向）
func _get_move_direction(input_dir: Vector2) -> Vector3:
	var basis := _camera_pivot.global_transform.basis
	var direction := basis.x * input_dir.x + basis.z * input_dir.y
	direction.y = 0.0
	return direction.normalized() if direction.length_squared() > 0.0001 else Vector3.ZERO


func _rotate_camera(relative: Vector2) -> void:
	var sensitivity := mouse_sensitivity
	if _aiming:
		sensitivity *= aim_sensitivity_scale
	# 偏航（左右）：转 CameraPivot
	_camera_pivot.rotate_y(-relative.x * sensitivity)
	# 俯仰（上下）：转 SpringArm，并限制角度
	var pitch := _spring_arm.rotation.x - relative.y * sensitivity
	_spring_arm.rotation.x = clampf(pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))


## 由武器调用：切换开镜状态（影响移动速度与鼠标灵敏度）
func set_aiming(aiming: bool) -> void:
	_aiming = aiming


func is_aiming() -> bool:
	return _aiming


func take_damage(amount: float, _source: Node = null) -> void:
	if amount <= 0.0 or health <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	_camera.add_trauma(clampf(amount / maxf(max_health, 1.0) * 1.6, 0.1, 0.8))
	if health <= 0.0:
		died.emit()


func heal(amount: float) -> void:
	if amount <= 0.0:
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


func get_health() -> float:
	return health


func get_max_health() -> float:
	return max_health


func get_weapon() -> Weapon:
	return _weapon


func get_recoil() -> RecoilSystem:
	return _recoil


func get_camera() -> ShakeCamera:
	return _camera


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _weapon:
		_weapon.set_trigger_enabled(true)


func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _weapon:
		_weapon.set_trigger_enabled(false)