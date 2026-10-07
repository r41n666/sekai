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
## 远端玩家的节点平滑跟随；FFA 个人死斗下其他玩家按「敌对目标」渲染（归 enemy 组，见 _setup_remote_player）。
## 远端模型或占位胶囊（没有则保持占位胶囊），并
## 驱动 Idle / Walk / Run / Jump 动画；模型带骨骼时武器会自动挂到右手骨骼上。

## ── 信号 ──
## 联机击杀确认：**本端**确认自己击倒了一个远端玩家（由受害端 `net_confirm_kill` 回传触发）。
##   载荷为被击倒者的节点名（= peer id）。EP-4 击杀播报 / 观测层日志据此接线。
##   ⚠ 联机对局中击杀只在射手端触发一次（权威端则由 `weapon._report_kill_if_player` 直调路径）。
signal remote_kill_confirmed(victim_peer_name: String)

signal health_changed(current: float, maximum: float)
signal died()

## 远端玩家血量**显示态**变化（联机下受害端才是唯一真值，本端只接收并显示）。
## ⚠ 与 `health_changed` **刻意分成两个信号**（不是同一个信号加 flag）：
##   `health_changed` 的语义是「**本地权威**血量真值变了」，被本地 HUD 血条 / 死亡界面
##   当真值消费。若把远端显示值也塞进它，任何按「血量真值变了」行事的消费方
##   就会把「显示态」误读成「本端结算」，等于把 C-18 的两套口径重新引进来。
##   独立信号让**来源在类型上就不可混淆**（与 A.5「不扩既有信号签名」同源裁定）。
signal remote_health_changed(current: float, maximum: float)
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
## 受击音效音量（dB）。玩家侧原本**没有任何受击音**（被敌人打中时静音），本次补上；
## 素材与 `bot.gd` 共用同一 wav（用户要求两端都用 hit_f_01.wav）。
@export var hit_sound_db := -8.0

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

## 受击音效：**每次受击从 `sfx/hit_female/` 的素材池里随机取一条**播放（与 bot.gd 同一素材池）。
## ⚠ 必须用 preload 引用，不能依赖全局 `class_name`（control_checklist §4-17 类缓存坑）。
const HitSounds := preload("res://scripts/shooting/hit_sounds.gd")
## 受击音的随机音高范围（连续受击不单调）
const HIT_PITCH_MIN := 0.9
const HIT_PITCH_MAX := 1.15

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
## 受击音播放节点（3D，跟随玩家位置；玩家侧原本没有）
var _hit_audio: AudioStreamPlayer3D

## 联机状态同步：广播间隔（秒）与远端平滑速度
const NET_SYNC_INTERVAL := 0.033
const NET_SMOOTH_SPEED := 14.0
var _net_accum := 0.0
var _net_target_position := Vector3.ZERO
var _net_target_yaw := 0.0
var _net_has_target := false

## ── 远端血量「显示态」（联机射手端）────────────────────────────────────────
## ⚠ 这是**纯显示副本**，不是本端血量真值：
##   · 权威永远在**受害端**（`apply_network_damage` 只在受害端结算，C-18 修复口径）；
##   · 本端**不因远端掉血而本地扣血**（不写 `health`、不调 `take_damage`）；
##   · 本端**不驱动本地死亡流程**（不发 `died`、不进 `_enter_dead_state`）——
##     死亡/重生是受害端的权威流程，射手端不替它决定。
## 负值 = 「尚未收到过有效广播」（此时 HUD 不画血条，避免开局先显示一条假血）。
var _display_health := -1.0


func _ready() -> void:
	health = max_health
	spawn_position = global_position
	# 每个玩家实例独立一份碰撞形状（蹲下 / 趴下要改高度）
	var capsule := _collision.shape as CapsuleShape3D
	if capsule != null:
		_collision.shape = capsule.duplicate()
	_build_weapons()
	_setup_hit_audio()
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
	# 第一人称（V）时武器贴着这台相机显示，做成「手持视角模型」
	_model.view_camera = _camera
	capture_mouse()
	_equip_slot("Rifle")
	health_changed.emit(health, max_health)


## 远端玩家：FFA 个人死斗下即「敌对目标」，按敌对渲染（小地图红点 / 无队友图标）。
## 组归属只影响显示（enemy），伤害路由靠能力探测 apply_network_damage（ADR-007），两者正交。
func _setup_remote_player() -> void:
	add_to_group("enemy")
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


## 受击音节点（玩家侧原本没有，被敌人打中是静音的）：3D 播放，位置跟随玩家。
## 素材**不在这里固定** —— 每次受击由 `_play_hit_sound()` 从 `HitSounds` 素材池随机取一条。
func _setup_hit_audio() -> void:
	_hit_audio = AudioStreamPlayer3D.new()
	_hit_audio.name = "HitAudio"
	_hit_audio.unit_size = 8.0
	_hit_audio.max_distance = 60.0
	_hit_audio.volume_db = hit_sound_db
	add_child(_hit_audio)


## 每次受击调用：**随机**取一条素材播放。
## 素材池为空（目录不存在 / 全部加载失败）时 `stream` 保持 null → 静默跳过（降级）。
func _play_hit_sound() -> void:
	if _hit_audio == null:
		return
	var stream: AudioStream = HitSounds.pick_random()
	if stream == null:
		return # 降级：素材不可用 ⇒ 静音（玩家侧原始行为）
	_hit_audio.stream = stream
	_hit_audio.pitch_scale = randf_range(HIT_PITCH_MIN, HIT_PITCH_MAX)
	_hit_audio.play()


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

	# T：切换「双手持枪 IK」（Spike 能力开关，用来对比新旧两种持械姿势）。
	# ⚠ 这是**裸键**、不是 [input] 动作 —— 因此不改 project.godot 的输入映射表
	#   （项目铁律：project.godot 内含 Vulkan 锁，见 control_checklist §4-17）。
	#   纯本地视觉开关，不走 RPC。
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_T:
		_model.toggle_hold_ik()
		get_viewport().set_input_as_handled()
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
	# 换弹 / 倒地时移动变慢（纯表现层的速度系数，不改角色真实速度上限之外的任何逻辑）
	speed *= _model.combat_movement_scale()
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

	# 联机：按固定频率把自己的位置 / 朝向 / 血量**显示值**广播给其他端
	#   ⚠ 血量走**同一条** 30Hz 包（不额外发包，见 ADR-008），且本端是权威 → 广播的是真值。
	#   ⚠ 频率**不得**因为加了血量而提高（`test_health_sync.gd::test_sync_interval_unchanged` 锁死）。
	if NetworkManager.is_online:
		_net_accum += delta
		if _net_accum >= NET_SYNC_INTERVAL:
			_net_accum = 0.0
			NetworkManager.net_player_state.rpc(global_position, _model.rotation.y, health)


## 姿态：按住 Ctrl 蹲下，Z 切换趴下（趴下时把模型放平，碰撞体用矮胶囊）
func _update_stance(delta: float) -> void:
	_stance = 2 if _prone else (1 if Input.is_action_pressed("crouch") and not input_blocked else 0)
	var k := 1.0 - exp(-10.0 * delta)
	var capsule := _collision.shape as CapsuleShape3D
	if capsule != null:
		capsule.height = lerpf(capsule.height, STANCE_HEIGHTS[_stance], k)
		_collision.position.y = capsule.height * 0.5
	_camera_pivot.position.y = lerpf(_camera_pivot.position.y, STANCE_CAMERA_Y[_stance], k)
	# 趴下：绕 X 轴 +90° 把模型「向前压平」——
	#   模型正面 +Z 转到 -Y（脸朝下 ✓），头顶转到 +Z（头朝前 ✓）= 向前趴下、正面朝下。
	#   之前是 -1.45（≈ -83°），会把正面转到 +Y、头转到 -Z（仰面朝天、头朝后），方向整个反了。
	var target_tilt := PI * 0.5 if _stance == 2 else 0.0
	_model.rotation.x = lerpf(_model.rotation.x, target_tilt, k)
	if _stance == 2:
		# 贴地：各模型厚度 / 程序化姿态 / 骨骼差异太大，写死常数会悬空或穿地。
		# 闭环修正——量出「当前模型最低点相对玩家原点的高度差」，直接把 MikuModel 推回去。
		# （gap 本身就是绝对量：本帧量出来是多少就修正多少，一步到位、不会来回抖。）
		_model.position.y -= _model.ground_gap()
		_model.position.y = clampf(_model.position.y, 0.05, 2.2)
	else:
		_model.position.y = lerpf(_model.position.y, 0.9, k)


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


## 联机：收到其他端广播的位置 / 朝向 / 血量显示值（由 NetworkManager.net_player_state 调用）
##
## ⚠ **签名必须与 `network_manager.gd::net_player_state` 的调用端逐字一致**（3 个实参）。
##   两处不一致 → `rpc_id` 实参个数不匹配 → **运行时才炸**（GDScript 不做跨文件形参校验）。
##   `tests/suites/test_health_sync.gd::test_send_and_receive_arity_matches` 已把这条钉死。
##
## ⚠ **三条不可越界的边界**（每条都有测试锁住，见 ADR-008）：
##   ① 只写 `_display_health`（显示副本），**不写 `health`、不调 `take_damage`** ——
##      射手端本地扣血就是 C-18 重演（两套血量口径打架）。
##   ② **不发 `died`、不调 `_enter_dead_state`** —— 死亡 / 重生是受害端的权威流程。
##   ③ 非法值（NaN / INF / 负数 / 超 `max_health`）**整个丢弃并保持上一有效值**，
##      而不是 clamp —— clamp 会把「协议被污染」伪装成「合理数值」，反而掩盖 bug。
func apply_network_state(pos: Vector3, yaw: float, health_value: float) -> void:
	_net_target_position = pos
	_net_target_yaw = yaw
	_net_has_target = true
	_apply_display_health(health_value)


## 接收远端血量显示值。**纯显示**：不写 `health`、不发 `died`、不参与任何胜负判定。
func _apply_display_health(value: float) -> void:
	var maximum := get_display_max_health()
	if not _is_valid_display_health(value, maximum):
		return # 非法值 → 丢弃，保持上一有效值（不清零、不 clamp 成「看起来合法」的错值）
	var clamped := clamp_display_health(value, maximum)
	if is_equal_approx(clamped, _display_health):
		return # 无变化不发信号（HUD 无谓刷新）
	_display_health = clamped
	remote_health_changed.emit(clamped, maximum)


## 远端血量显示值的合法性守卫（静态纯函数 → headless 可直接断言）。
##   NaN / ±INF 由 `is_finite` 覆盖；负数与**超上限**同样判非法 ——
##   超上限只可能来自协议被污染 / 两端配置分叉，此时显示一个被 clamp 过的值 =
##   把 bug 伪装成合理数值（宁可这一帧不更新，下一包正常值自然会纠正）。
static func _is_valid_display_health(value: float, maximum: float) -> bool:
	if not is_finite(value):
		return false
	return value >= 0.0 and value <= maximum


## 把显示值夹到 `[0, maximum]`（静态纯函数）。
##   守卫已在**上游**挡住越界值，这里是写库前的最后一道夹取（纵深防御：
##   万一将来有人绕过守卫直接调它，也不会把显示值写成负数 / 超上限）。
static func clamp_display_health(value: float, maximum: float) -> float:
	return clampf(value, 0.0, maxf(maximum, 0.0))


## 远端血量显示值的上限来源。
##
## ## ⚠ D2-04：`max_health` 变成「可配置的全局规则」后，本方法的**前提变了**
## 原注释的前提是「双方 `max_health` 来自同一份 `player.tscn` 的 export 默认值
##（场景未覆盖它）→ 跨端一致」。规则配置化后该前提**不再自动成立**：
## 房主配 200 血而配置未同步到对端时，对端 `max_health` 仍是 100，
## 而它会把收到的 200 判成「超max_health = 协议污染」→ **整条丢弃** →
## **血条永远不动且不报错**（形态与 C-18「比分永远 0」同源）。
##
## ## 采纳方案（规格 §6.4 冲突 1）
##   ① `max_health` 视为**必须跨端一致的全局规则**，随 `sync_ruleset` 开局前下发两端；
##   ② 本方法读「**本端已应用的本局配置值**」（`apply_player_stats` 会写 `max_health`，
##      并连带同步 `health`）—— 即仍读本端 `max_health`，但现在两端保证相同；
##   ③ **守卫语义一字未改**：`value > max_health` 仍判协议污染、仍整条丢弃
##      （ADR-008 铁律 + `test_health_sync.gd:350/351` 用 `10000.0` / `100.5` 钉死）。
##
## → 所以本方法**逻辑不变**、只是它读取的 `max_health` 现在**两端必然相同**
##   （由 `sync_ruleset` 保证，而非由「场景没覆盖它」保证）。
func get_display_max_health() -> float:
	return maxf(max_health, 1.0)


## 远端血量显示值（<0 = 尚未收到过有效广播）。**只给 HUD 显示用**，不参与判定。
func get_display_health() -> float:
	return _display_health


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
	_model.set_view_aiming(aiming) # 第一人称下武器跟着收进画面中心


func is_aiming() -> bool:
	return _aiming


## 联机：被其他玩家的子弹命中（由射击者 RPC 发到本端，只有自己端会真正扣血）
##
## ⚠ 本方法是「玩家身份契约」（ADR-007）：`weapon.gd` / `knife.gd` 的伤害路由靠
##    `collider.has_method("apply_network_damage")` 判定「这是远程玩家」。请勿给
##    任何非玩家节点（bot / 场景物件 / UI）添加同名方法，否则会被误判为玩家、走错路由。
##
## `shooter_peer_id`：开火者的 peer id（由 `weapon/knife` 用 `_player.get_multiplayer_authority()`
##   传入）。**本端是全场唯一知道血量真值的地方**（远端玩家的血量从不在射手端结算），
##   所以「这一枪是否致死」只能在这里判定 → 归零时用 `net_confirm_kill` 回传射手端。
@rpc("any_peer", "call_remote", "reliable")
func apply_network_damage(amount: float, shooter_peer_id: int) -> void:
	var was_alive := health > 0.0
	take_damage(amount)
	# 致死确认（回传给射手端）：`was_alive` 保证一个死亡周期只发一次确认（重复命中已被
	# `take_damage` 的 `health <= 0.0` 早退挡掉），故不会重复计分。
	if was_alive and health <= 0.0 and shooter_peer_id > 0:
		net_confirm_kill.rpc_id(shooter_peer_id)


## 射手端收到「你把我打死了」的确认 → 走既有 A.4 归因路径上报（不改 A.4 契约、不改房主信任模型）。
##
## ⚠ 为什么确认要绕一跳回射手端，而不是由受害端直接找房主上报：
##   A.4 `report_kill(victim_id)` 的语义是「**击杀者**上报，房主用 `get_remote_sender_id()`
##   反查击杀者」。若改由受害端上报，房主会把 sender 当成击杀者 → 归因反了。
##   回传确认后，「谁开的枪」由射手端自己说，与 A.4 契约一致，房间信任面不变。
@rpc("authority", "call_remote", "reliable")
func net_confirm_kill() -> void:
	remote_kill_confirmed.emit(String(name))
	var score := _score_manager()
	if score == null:
		return # 场景未挂 ScoreManager：静默跳过，不影响伤害结算
	var victim_id := ScoreManager.resolve_victim_id(self)
	if victim_id < 0:
		return # 双保险：节点名不是 peer id（非玩家节点）→ 不上报
	score._report_local_kill(victim_id)


func take_damage(amount: float, _source: Node = null) -> void:
	if amount <= 0.0 or health <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	_camera.add_trauma(clampf(amount / maxf(max_health, 1.0) * 1.6, 0.1, 0.8))
	# 受击 / 死亡动作（纯视觉，各端本地播放，不走 RPC）。
	# ⚠ 联机口径：**只有受害端会走到这里**（远程伤害走 apply_network_damage，见 C-18），
	#   所以「谁死了谁自己播倒地」，射手端永远不会替别人播——位置广播会自然同步过去。
	#   ⛔ 绝不可让射手端按 `_display_health <= 0` 播死亡：那是**显示副本**，不是血量真值
	#   （control_checklist §4-9 同源纪律）。
	_model.play_hit()
	# 受击音（玩家侧原本没有，被敌人打中是静音的）：与受击动作同一权威判定点；
	# **每次随机**从 `sfx/hit_female/` 素材池取一条；随机音高（0.9~1.15）避免连续受击单调。
	# 素材不可用时静默跳过（降级）。
	_play_hit_sound()
	if health <= 0.0:
		_model.play_death()
		died.emit()
		_enter_dead_state()


## 取本场景的 ScoreManager（未挂载时返回 null；与 weapon.gd::_score_manager 同一取法）。
func _score_manager() -> ScoreManager:
	var scene := get_tree().current_scene if is_inside_tree() else null
	if scene == null:
		return null
	return scene.get_node_or_null("ScoreManager") as ScoreManager


## 阵亡：屏蔽输入并释放鼠标（死亡界面要能点「重生」按钮）
func _enter_dead_state() -> void:
	set_input_blocked(true)


## 重生：回满血 + 回到出生点 + 恢复输入（由死亡界面调用）
func respawn() -> void:
	health = max_health
	velocity = Vector3.ZERO
	_prone = false
	global_position = spawn_position
	# 程序化通道的死亡是**不可逆**的（倒地后不恢复），重生必须显式复位
	_model.reset_pose()
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
		if is_multiplayer_authority() and next.has_method("apply_variant"):
			next.apply_variant(WeaponVariant.get_selected(slot)) # 用 Esc 菜单里选的模型外观（会重套皮肤）
		if next.has_method("set_active"):
			next.set_active(true) # 掏出时才播「翻刃」这类开场动画，所以要放在换外观之后
		if next.has_method("apply_skin") and is_multiplayer_authority():
			next.apply_skin(WeaponSkin.get_selected(slot)) # 用 Esc 菜单里选的皮肤
		if is_multiplayer_authority():
			next.add_to_group("weapon") # HUD 查找用
	# 抬手 / 放手：持械时模型右手抬到身前（程序化姿态），武器才不垂在腿边
	_model.set_holding_weapon(next != null)
	weapon_changed.emit(_current_weapon)


## 由 Esc 菜单调用：切换某个武器槽的皮肤并立即生效（只影响本端）
func set_weapon_skin(slot: String, skin_id: String) -> void:
	WeaponSkin.set_selected(slot, skin_id)
	var weapon: Node = _weapons.get(slot)
	if weapon != null and weapon.has_method("apply_skin"):
		weapon.apply_skin(skin_id)


## 由 Esc 菜单调用：切换某个武器槽的模型外观并立即生效（只影响本端）
func set_weapon_variant(slot: String, variant_id: String) -> void:
	WeaponVariant.set_selected(slot, variant_id)
	var weapon: Node = _weapons.get(slot)
	if weapon != null and weapon.has_method("apply_variant"):
		weapon.apply_variant(variant_id)


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _current_weapon != null and _current_weapon.has_method("set_trigger_enabled"):
		_current_weapon.set_trigger_enabled(true)


func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _current_weapon != null and _current_weapon.has_method("set_trigger_enabled"):
		_current_weapon.set_trigger_enabled(false)