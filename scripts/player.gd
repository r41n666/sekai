extends CharacterBody3D
class_name PlayerController
## 第三人称玩家控制器（阶段 1 移动 + 阶段 2 射击接入 + 阶段 3 联机）
##
## 操作：WASD 移动 / 鼠标转视角 / Shift 加速 / Space 跳跃 / Esc 释放鼠标 / 左键射击 / 右键开镜 / R 换弹
##
## 摄像机链（阶段 2 加入后坐力与惯性）：
##   CameraPivot（鼠标 yaw）→ RecoilPivot（三层后坐力）→ SwayPivot（惯性/晃动）→ SpringArm3D（鼠标 pitch）→ Camera3D（屏幕震动）
##
## 阶段 3 联机：自己的端（multiplayer authority）响应输入、接管摄像机与鼠标；
## 位置与模型朝向按 ~30Hz 通过 NetworkManager 的普通 RPC 广播（不依赖场景缓存，迟到加入也能收到），
## 远端玩家的节点平滑跟随；其他玩家的节点以「队友」形式显示。
## 阶段 4：MikuModel（miku_model.gd）会自动加载 res://assets/models/miku/miku.glb（没有则保持占位胶囊），
## 并驱动 Idle / Walk / Run / Jump 动画；模型带骨骼时武器会自动挂到右手骨骼上。

signal health_changed(current: float, maximum: float)
signal died()
## 切换武器 / 空手时发出（HUD 用来重新绑定）
signal weapon_changed(weapon: Node)

@export_group("移动")
## 正常行走速度（米/秒，与行走动画步频匹配调过）
@export var walk_speed := 3.6
## 按住 sprint（Shift）时的速度
@export var sprint_speed := 6.5
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

@onready var _model: MikuModel = $MikuModel
@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _camera_pivot: Node3D = $CameraPivot
@onready var _recoil: RecoilSystem = $CameraPivot/RecoilPivot
@onready var _sway: CameraSway = $CameraPivot/RecoilPivot/SwayPivot
@onready var _free_look_pivot: Node3D = $CameraPivot/RecoilPivot/SwayPivot/FreeLookPivot
@onready var _spring_arm: SpringArm3D = $CameraPivot/RecoilPivot/SwayPivot/FreeLookPivot/SpringArm3D
@onready var _camera: ShakeCamera = $CameraPivot/RecoilPivot/SwayPivot/FreeLookPivot/SpringArm3D/Camera3D
@onready var _weapon_mount: Node3D = $MikuModel/WeaponMount

## 数字键 → 武器槽
const SLOT_FOR_ACTION := {
	"weapon_1": "Rifle", "weapon_2": "USP", "weapon_3": "Knife", "weapon_4": "Grenade",
}
## 姿态：0 站立 / 1 蹲下（按住 Ctrl）/ 2 趴下（Z 切换）
const STANCE_HEIGHTS := [1.8, 1.2, 0.8]
const STANCE_CAMERA_Y := [1.6, 1.05, 0.35]
const STANCE_SPEED_SCALE := [1.0, 0.5, 0.25]

var health := 0.0
## 出生点（重生用，_ready 时按生成位置记录）
var spawn_position := Vector3.ZERO
## 菜单 / 死亡界面打开时屏蔽移动、跳跃、开火（由界面调用 set_input_blocked）
var input_blocked := false
## 联机：由主场景生成时写入的昵称（队友图标 / 击杀日志显示用）
var player_name := ""
var _weapons: Dictionary = {}
var _current_slot := ""
var _current_weapon: Node
var _stance := 0
var _prone := false
var _first_person := false
var _free_look_yaw := 0.0
var _free_look_pitch := 0.0
var _aiming := false
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

## 联机状态同步：广播间隔（秒）与远端平滑速度
const NET_SYNC_INTERVAL := 0.033
const NET_SMOOTH_SPEED := 14.0
var _net_accum := 0.0
var _net_target_position := Vector3.ZERO
var _net_target_yaw := 0.0
var _net_has_target := false


func _ready() -> void:
	health = max_health
	spawn_position = global_position
	# 每个玩家实例独立一份碰撞形状（蹲下 / 趴下要改高度）
	var capsule := _collision.shape as CapsuleShape3D
	if capsule != null:
		_collision.shape = capsule.duplicate()
	_build_weapons()
	if is_multiplayer_authority():
		_setup_local_player()
	else:
		_setup_remote_player()


## 收集武器槽（WeaponMount 下的 Rifle / USP / Knife / Grenade）
func _build_weapons() -> void:
	for child in _weapon_mount.get_children():
		if not (child is Node3D):
			continue
		_weapons[String(child.name)] = child
		(child as Node3D).visible = false
		if child.has_method("set_active"):
			child.set_active(false)
		if child.has_method("setup"):
			child.setup(self, _camera, _recoil, _camera)


## 自己控制的玩家：注册到 HUD / 小地图查找用的组，接管摄像机与鼠标
func _setup_local_player() -> void:
	add_to_group("player")
	_recoil.add_to_group("recoil")
	_camera.add_to_group("camera")
	_camera.current = true
	capture_mouse()
	_equip_slot("Rifle")
	health_changed.emit(health, max_health)


## 远端玩家：当作「队友」显示（屏幕图标 / 小地图绿点），换个颜色方便区分
func _setup_remote_player() -> void:
	add_to_group("friendly")
	_camera.current = false
	# 远端玩家固定显示主武器（不参与槽位切换）
	var rifle: Node = _weapons.get("Rifle")
	if rifle != null:
		(rifle as Node3D).visible = true
	# 占位胶囊换个颜色；载入真实模型后不动模型材质
	var placeholder := _model.get_node_or_null("Placeholder") as MeshInstance3D
	if placeholder != null and placeholder.visible:
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.42, 0.68, 0.95)
		material.roughness = 0.6
		placeholder.material_override = material


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if input_blocked:
		return # 菜单 / 死亡界面打开时不响应操作
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if Input.is_action_pressed("free_look"):
			# Alt 自由视角：只转镜头，不影响人物朝向与瞄准方向
			_free_look_yaw = clampf(_free_look_yaw - event.relative.x * mouse_sensitivity, -2.44, 2.44)
			_free_look_pitch = clampf(_free_look_pitch - event.relative.y * mouse_sensitivity, -1.05, 1.05)
		else:
			_rotate_camera(event.relative)
			_sway.add_look_delta(event.relative)
		return

	if event is InputEventKey and event.echo:
		return

	# 1 主武器 / 2 副武器 / 3 蝴蝶刀 / 4 手雷；同一键再按一次 = 空手
	for action in SLOT_FOR_ACTION:
		if event.is_action_pressed(action):
			_equip_slot(SLOT_FOR_ACTION[action])
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("view_toggle"):
		_toggle_first_person()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("prone"):
		_prone = not _prone
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		# 释放鼠标后，点击画面即可重新锁定（Esc 菜单的开关由 game_menu.gd 接管）
		capture_mouse()


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		_follow_network_state(delta)
		return # 远端玩家由广播状态驱动
	if not is_on_floor():
		velocity.y -= _gravity * delta

	if not input_blocked and Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := Vector2.ZERO if input_blocked else Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := _get_move_direction(input_dir)

	var speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	if _aiming:
		speed *= aim_speed_scale
	speed *= STANCE_SPEED_SCALE[_stance]
	var accel := acceleration if is_on_floor() else acceleration * air_control
	var blend := clampf(accel * delta, 0.0, 1.0)
	var target := direction * speed
	var horizontal := Vector2(velocity.x, velocity.z).lerp(Vector2(target.x, target.z), blend)
	velocity.x = horizontal.x
	velocity.z = horizontal.y

	# 人物与武器始终朝向准星的水平方向：按移动键只改变位移，不再让枪口跟着移动方向转
	var aim_yaw := _camera_pivot.rotation.y + PI
	_model.rotation.y = lerp_angle(_model.rotation.y, aim_yaw, clampf(model_turn_speed * delta, 0.0, 1.0))

	move_and_slide()
	_feed_subsystems()
	_update_stance(delta)
	_update_free_look(delta)
	_update_view(delta)

	# 阶段 4：把移动状态交给模型（有动画剪辑播动画；没有就跑程序化姿态，步频按实际速度自适应）
	var move_speed := Vector2(velocity.x, velocity.z).length()
	var anim_ratio := clampf(move_speed / maxf(sprint_speed, 0.1), 0.0, 1.0)
	_model.update_animation(delta, move_speed, anim_ratio, direction.length_squared() > 0.001, is_on_floor())

	# 联机：按固定频率把自己的位置 / 朝向广播给其他端
	if NetworkManager.is_online:
		_net_accum += delta
		if _net_accum >= NET_SYNC_INTERVAL:
			_net_accum = 0.0
			NetworkManager.net_player_state.rpc(global_position, _model.rotation.y)


## 姿态：按住 Ctrl 蹲下，Z 切换趴下（趴下时把模型放平，碰撞体用矮胶囊）
func _update_stance(delta: float) -> void:
	_stance = 2 if _prone else (1 if Input.is_action_pressed("crouch") and not input_blocked else 0)
	var k := 1.0 - exp(-10.0 * delta)
	var capsule := _collision.shape as CapsuleShape3D
	if capsule != null:
		capsule.height = lerpf(capsule.height, STANCE_HEIGHTS[_stance], k)
		_collision.position.y = capsule.height * 0.5
	_camera_pivot.position.y = lerpf(_camera_pivot.position.y, STANCE_CAMERA_Y[_stance], k)
	var target_tilt := -1.45 if _stance == 2 else 0.0
	var target_y := 0.25 if _stance == 2 else 0.9
	_model.rotation.x = lerpf(_model.rotation.x, target_tilt, k)
	_model.position.y = lerpf(_model.position.y, target_y, k)


## 自由视角（Alt）：松开后自动回正
func _update_free_look(delta: float) -> void:
	if not Input.is_action_pressed("free_look"):
		var k := 1.0 - exp(-12.0 * delta)
		_free_look_yaw = lerpf(_free_look_yaw, 0.0, k)
		_free_look_pitch = lerpf(_free_look_pitch, 0.0, k)
	_free_look_pivot.rotation = Vector3(_free_look_pitch, _free_look_yaw, 0.0)


## 第一人称 / 第三人称（V）：弹簧臂长度 0 = 第一人称
func _update_view(delta: float) -> void:
	var target_length := 0.0 if _first_person else 3.5
	_spring_arm.spring_length = lerpf(_spring_arm.spring_length, target_length, 1.0 - exp(-14.0 * delta))


func _toggle_first_person() -> void:
	_first_person = not _first_person
	_model.set_first_person(_first_person)


## 远端玩家：平滑跟随广播过来的位置 / 朝向，并按位移估算速度驱动模型姿态
func _follow_network_state(delta: float) -> void:
	if not _net_has_target:
		return
	var before := global_position
	var k := 1.0 - exp(-NET_SMOOTH_SPEED * delta)
	global_position = global_position.lerp(_net_target_position, k)
	_model.rotation.y = lerp_angle(_model.rotation.y, _net_target_yaw, k)
	var moved := global_position.distance_to(before) / maxf(delta, 0.0001)
	_model.update_animation(delta, moved, clampf(moved / maxf(sprint_speed, 0.1), 0.0, 1.0), moved > 0.08, true)


## 联机：收到其他端广播的位置 / 朝向（由 NetworkManager.net_player_state 调用）
func apply_network_state(pos: Vector3, yaw: float) -> void:
	_net_target_position = pos
	_net_target_yaw = yaw
	_net_has_target = true


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


## 联机：被其他玩家的子弹命中（由射击者 RPC 发到本端，只有自己端会真正扣血）
@rpc("any_peer", "call_remote", "reliable")
func apply_network_damage(amount: float, _shooter: String) -> void:
	take_damage(amount)


func take_damage(amount: float, _source: Node = null) -> void:
	if amount <= 0.0 or health <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	_camera.add_trauma(clampf(amount / maxf(max_health, 1.0) * 1.6, 0.1, 0.8))
	if health <= 0.0:
		died.emit()
		_enter_dead_state()


## 阵亡：屏蔽输入并释放鼠标（死亡界面要能点「重生」按钮）
func _enter_dead_state() -> void:
	set_input_blocked(true)


## 重生：回满血 + 回到出生点 + 恢复输入（由死亡界面调用）
func respawn() -> void:
	health = max_health
	velocity = Vector3.ZERO
	_prone = false
	global_position = spawn_position
	set_input_blocked(false)
	capture_mouse()
	health_changed.emit(health, max_health)


## 菜单 / 死亡界面 / 人机面板打开时调用：屏蔽移动、跳跃与开火
func set_input_blocked(blocked: bool) -> void:
	input_blocked = blocked
	if blocked:
		release_mouse()
	else:
		velocity.x = 0.0
		velocity.z = 0.0


func heal(amount: float) -> void:
	if amount <= 0.0:
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


func get_health() -> float:
	return health


func get_max_health() -> float:
	return max_health


func get_weapon() -> Node:
	return _current_weapon


func get_recoil() -> RecoilSystem:
	return _recoil


func get_camera() -> ShakeCamera:
	return _camera


## 切换武器槽：同一键再按一次 = 收起（空手状态）
func _equip_slot(slot: String) -> void:
	if not _weapons.has(slot):
		return
	var next: Node = null if _current_slot == slot else _weapons[slot]
	if _current_weapon != null and is_instance_valid(_current_weapon):
		(_current_weapon as Node3D).visible = false
		if _current_weapon.has_method("set_active"):
			_current_weapon.set_active(false)
		if _current_weapon.is_in_group("weapon"):
			_current_weapon.remove_from_group("weapon")
	_current_weapon = next
	_current_slot = "" if next == null else slot
	if next != null:
		(next as Node3D).visible = true
		if next.has_method("set_active"):
			next.set_active(true)
		if is_multiplayer_authority():
			next.add_to_group("weapon") # HUD 查找用
	weapon_changed.emit(_current_weapon)


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _current_weapon != null and _current_weapon.has_method("set_trigger_enabled"):
		_current_weapon.set_trigger_enabled(true)


func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _current_weapon != null and _current_weapon.has_method("set_trigger_enabled"):
		_current_weapon.set_trigger_enabled(false)