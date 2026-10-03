extends CharacterBody3D
class_name Bot
## 人机（阶段 5）：追踪玩家 + 周期射击 + 受击反馈（后仰 / 闪白 / 音效）
##
## 由 BotManager 在本端生成，**不参与联机同步**（联机时每端各自刷，见 README 已知限制）。
## 模型复用 MikuModel（自动尺寸适配 + 程序化步态），武器用玩家同款 rifle.tscn，
## 但只把它当外观：武器自身的输入逻辑会关闭，开火由本脚本接管。

signal died_bot(bot: Node)

## 击杀日志里显示的名字
@export var display_name := "人机"
@export var max_health := 100.0
## 模型路径（空 = MikuModel 默认的 miku.glb）
@export var model_path := ""

@export_group("移动")
## 与玩家保持的交战距离（小于它就不再靠近）
@export var keep_distance := 7.0
@export var walk_speed := 2.8
@export var run_speed := 5.2
@export var acceleration := 10.0
## 超过这个距离就跑步靠近
@export var run_distance := 15.0

@export_group("射击")
@export var shoot_range := 45.0
## 射击间隔（秒；实际间隔会 ±35% 随机）
@export var fire_interval := 1.5
## 散布角度（度）
@export var fire_spread_deg := 3.5
@export var damage_per_shot := 11.0
## 瞄准点高度（玩家胸口）
@export var aim_height := 1.2

@export_group("受击反馈")
## 受击后仰角度（弧度）
@export var hit_lean := -0.5
## 受击闪白强度（0~1）
@export var hit_flash_alpha := 0.8
@export var hit_sound_db := -8.0

@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _model: MikuModel = $MikuModel
@onready var _rifle: Node3D = $MikuModel/WeaponMount/Rifle
@onready var _muzzle: Marker3D = $MikuModel/WeaponMount/Rifle/Muzzle
@onready var _muzzle_flash: MeshInstance3D = $MikuModel/WeaponMount/Rifle/MuzzleFlash
@onready var _muzzle_light: OmniLight3D = $MikuModel/WeaponMount/Rifle/MuzzleLight
@onready var _gun_audio: GunAudio = $MikuModel/WeaponMount/Rifle/GunAudio

var health := 100.0
var alive := true

var _player: Node3D
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _fire_timer := 0.0
var _flash_timer := 0.0
var _flash_material: StandardMaterial3D
var _flash_alpha := 0.0
var _lean := 0.0
var _hit_audio: AudioStreamPlayer3D


func _ready() -> void:
	health = max_health
	add_to_group("enemy") # 小地图的敌人红点
	add_to_group("bot")
	# 武器只当外观：关掉它自己的输入逻辑，开火由本脚本处理
	_rifle.set_process(false)
	_rifle.set_physics_process(false)
	if _rifle.has_method("set_trigger_enabled"):
		_rifle.set_trigger_enabled(false)
	_muzzle_flash.visible = false
	_muzzle_light.visible = false
	if not model_path.is_empty():
		_model.model_path = model_path
		_model.load_model(model_path)
	_setup_hit_flash()
	_setup_hit_audio()
	_fire_timer = randf_range(0.3, 1.2) # 出生后不要立刻开枪
	_player = get_tree().get_first_node_in_group("player") as Node3D


func _physics_process(delta: float) -> void:
	_tick_flash(delta)
	if not alive:
		return
	if not is_on_floor():
		velocity.y -= _gravity * delta
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D
		if _player == null:
			move_and_slide()
			return

	var to_player: Vector3 = _player.global_position - global_position
	to_player.y = 0.0
	var distance := to_player.length()
	var direction := to_player.normalized() if distance > 0.001 else Vector3.ZERO

	var moving := distance > keep_distance
	var speed := 0.0
	if moving:
		speed = run_speed if distance > run_distance else walk_speed
		var target := direction * speed
		var blend := clampf(acceleration * delta, 0.0, 1.0)
		var horizontal := Vector2(velocity.x, velocity.z).lerp(Vector2(target.x, target.z), blend)
		velocity.x = horizontal.x
		velocity.z = horizontal.y
	else:
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta * walk_speed)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta * walk_speed)
	move_and_slide()

	# 面向玩家（模型正面 = +Z，和 player.gd 的约定一致）
	if direction.length_squared() > 0.001:
		var yaw := atan2(direction.x, direction.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, yaw, clampf(9.0 * delta, 0.0, 1.0))

	# 受击后仰回正
	_lean = lerpf(_lean, 0.0, 1.0 - exp(-9.0 * delta))
	_model.rotation.x = _lean

	var move_speed := Vector2(velocity.x, velocity.z).length()
	_model.update_animation(delta, move_speed, clampf(move_speed / maxf(run_speed, 0.1), 0.0, 1.0), move_speed > 0.2, is_on_floor())

	_update_fire(delta, distance)


## 周期射击：进入射程后按间隔朝玩家开火（带散布；命中玩家扣血）
func _update_fire(delta: float, distance: float) -> void:
	_flash_timer = maxf(_flash_timer - delta, 0.0)
	if _flash_timer <= 0.0:
		_muzzle_flash.visible = false
		_muzzle_light.visible = false
	_fire_timer -= delta
	if distance > shoot_range or _fire_timer > 0.0:
		return
	_fire_timer = fire_interval * randf_range(0.65, 1.35)
	_shoot()


func _shoot() -> void:
	var from := _muzzle.global_position
	var to := _player.global_position + Vector3.UP * aim_height
	var direction := (to - from).normalized()
	# 散布：绕随机的横轴偏一个角度
	var spread := deg_to_rad(fire_spread_deg)
	var axis := Vector3.UP.cross(direction).normalized()
	if axis.length_squared() > 0.001:
		direction = direction.rotated(axis, randf_range(-spread, spread))
	direction = direction.rotated(Vector3.UP, randf_range(-spread, spread)).normalized()

	var query := PhysicsRayQueryParameters3D.create(from, from + direction * shoot_range * 1.5)
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and hit.collider != null and hit.collider.has_method("take_damage"):
		hit.collider.take_damage(damage_per_shot, self)

	_muzzle_flash.visible = true
	_muzzle_flash.rotation.z = randf_range(0.0, TAU)
	_muzzle_flash.scale = Vector3.ONE * randf_range(0.8, 1.25)
	_muzzle_light.visible = true
	_muzzle_light.light_energy = randf_range(2.5, 4.5)
	_flash_timer = 0.05
	_gun_audio.play_shot()


## 被玩家武器命中（weapon.gd 通过 duck typing 调用）
func take_damage(amount: float, _source: Node = null) -> void:
	if not alive or amount <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	_flash_alpha = hit_flash_alpha
	_lean = hit_lean
	_hit_audio.pitch_scale = randf_range(0.9, 1.15)
	_hit_audio.play()
	if health <= 0.0:
		_die()


func get_health_ratio() -> float:
	return clampf(health / maxf(max_health, 1.0), 0.0, 1.0)


func _die() -> void:
	alive = false
	health = 0.0
	if is_in_group("enemy"):
		remove_from_group("enemy") # 小地图不再显示
	died_bot.emit(self)
	_collision.set_deferred("disabled", true)
	_muzzle_flash.visible = false
	_muzzle_light.visible = false
	# 倒地：向前扑倒 + 停一会儿再移除
	var tween := create_tween()
	tween.tween_property(_model, "rotation:x", -PI * 0.5, 0.3)
	tween.tween_interval(1.2)
	tween.tween_callback(queue_free)


## 受击闪白：给模型所有网格叠加一层白色材质，透明度随时间衰减
func _tick_flash(delta: float) -> void:
	if _flash_material == null or _flash_alpha <= 0.0:
		return
	_flash_alpha = maxf(_flash_alpha - delta * 3.2, 0.0)
	_flash_material.albedo_color.a = _flash_alpha


func _setup_hit_flash() -> void:
	_flash_material = StandardMaterial3D.new()
	_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_material.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
	_flash_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for mesh in _collect_meshes(self):
		mesh.material_overlay = _flash_material


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_meshes(child))
	return out


## 受击音效：程序化合成的短促「闷哼」（下滑音 + 噪声质感），参考 audio_3d.gd 的合成方式
func _setup_hit_audio() -> void:
	_hit_audio = AudioStreamPlayer3D.new()
	_hit_audio.name = "HitAudio"
	_hit_audio.unit_size = 8.0
	_hit_audio.max_distance = 60.0
	_hit_audio.volume_db = hit_sound_db
	_hit_audio.stream = _build_hit_sound()
	add_child(_hit_audio)


func _build_hit_sound() -> AudioStreamWAV:
	var rate := 44100
	var duration := 0.18
	var count := int(rate * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261003
	for i in count:
		var t := float(i) / float(rate)
		var progress := t / duration
		var pitch := lerpf(540.0, 210.0, progress) # 下滑音
		var tone := sin(TAU * pitch * t) * exp(-t * 20.0) * 0.55
		var grit := rng.randf_range(-1.0, 1.0) * exp(-t * 55.0) * 0.3
		var sample := clampf(tone + grit, -1.0, 1.0) * 0.85
		data.encode_s16(i * 2, int(sample * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav