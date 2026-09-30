extends Node3D
class_name Weapon
## 占位步枪（阶段 2）
##
## 负责「开枪这件事」本身：全自动射击、弹匣 / 备弹、换弹、开镜（ADS）、hitscan 命中判定、
## 枪口火光、曳光弹、命中反馈；手感部分全部交给四个子系统：
##   RecoilSystem（三层后坐力 / 扩散值）、CameraSway（惯性）、ShakeCamera（屏幕震动）、GunAudio（3D 枪声）。
##
## 模型是几个方块拼的占位（真正武器模型留到后续阶段替换 rifle.tscn 的 MeshRoot 子节点）。

signal ammo_changed(mag: int, reserve: int)
signal fired()
signal reload_started(duration: float)
signal reload_finished()
signal reload_cancelled()
signal aiming_changed(aiming: bool)
## 命中反馈：目标名称 / 是否击杀（HUD 用来显示命中标记与击杀日志）
signal hit_confirmed(target_name: String, killed: bool)

@export_group("弹药")
@export var magazine_size := 30
@export var reserve_ammo := 120
## 换弹时间（秒）
@export var reload_time := 2.1
## 打空后是否自动换弹
@export var auto_reload := true

@export_group("射击")
@export var automatic := true
## 射速（发/分钟）
@export var rpm := 700.0
@export var damage := 25.0
## 射程（米）
@export var max_range := 200.0
@export var hip_fov := 75.0
@export var ads_fov := 55.0
@export var ads_speed := 9.0

@export_group("特效")
@export var tracer_lifetime := 0.045
@export var flash_time := 0.04
## 每发增加的屏幕震动（Trauma）
@export var shake_per_shot := 0.28
@export var impact_flash_time := 0.07

@onready var _muzzle: Marker3D = $Muzzle
@onready var _muzzle_light: OmniLight3D = $MuzzleLight
@onready var _muzzle_flash: MeshInstance3D = $MuzzleFlash
@onready var _audio: GunAudio = $GunAudio

var _player: CharacterBody3D
var _camera: Camera3D
var _recoil: RecoilSystem
var _shake: ShakeCamera

var _mag := 0
var _reserve := 0
var _fire_cooldown := 0.0
var _trigger_held := false
var _trigger_enabled := true
var _reloading := false
var _reload_timer := 0.0
var _aiming := false
var _flash_timer := 0.0
var _tracer_timer := 0.0
var _impact_timer := 0.0

var _tracer: MeshInstance3D
var _impact_light: OmniLight3D


func _ready() -> void:
	_mag = magazine_size
	_reserve = reserve_ammo
	if not is_in_group("weapon"):
		add_to_group("weapon") # 供 HUD 查找
	_build_effects()


## 由 player.gd 注入依赖
func setup(player: CharacterBody3D, camera: Camera3D, recoil: RecoilSystem, shake: ShakeCamera) -> void:
	_player = player
	_camera = camera
	_recoil = recoil
	_shake = shake
	ammo_changed.emit(_mag, _reserve)


## 玩家锁定/释放鼠标时调用：释放鼠标后不能开枪（避免点 UI 时走火）
func set_trigger_enabled(enabled: bool) -> void:
	_trigger_enabled = enabled
	if not enabled:
		_trigger_held = false


func _process(delta: float) -> void:
	if _player == null or _camera == null:
		return
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	_flash_timer = maxf(_flash_timer - delta, 0.0)
	_tracer_timer = maxf(_tracer_timer - delta, 0.0)
	_impact_timer = maxf(_impact_timer - delta, 0.0)
	if _flash_timer <= 0.0:
		_muzzle_light.visible = false
		_muzzle_flash.visible = false
	if _tracer_timer <= 0.0 and _tracer:
		_tracer.visible = false
	if _impact_timer <= 0.0 and _impact_light:
		_impact_light.visible = false

	if Input.is_action_just_pressed("reload"):
		start_reload()

	_update_aiming(delta)
	_update_reload(delta)
	_update_trigger()


## 是否正在开镜
func is_aiming() -> bool:
	return _aiming


func is_reloading() -> bool:
	return _reloading


## 换弹进度 0~1
func get_reload_progress() -> float:
	if not _reloading or reload_time <= 0.0:
		return 0.0
	return clampf(1.0 - _reload_timer / reload_time, 0.0, 1.0)


func get_mag() -> int:
	return _mag


func get_reserve() -> int:
	return _reserve


func start_reload() -> void:
	if _reloading or _mag >= magazine_size or _reserve <= 0:
		return
	_reloading = true
	_reload_timer = reload_time
	reload_started.emit(reload_time)
	_muzzle_light.visible = false
	_muzzle_flash.visible = false


func _update_reload(delta: float) -> void:
	if not _reloading:
		return
	_reload_timer -= delta
	if _reload_timer > 0.0:
		return
	_reloading = false
	var need := magazine_size - _mag
	var take := mini(need, _reserve)
	_mag += take
	_reserve -= take
	ammo_changed.emit(_mag, _reserve)
	reload_finished.emit()


func _update_aiming(delta: float) -> void:
	var want := Input.is_action_pressed("aim") and not _reloading
	if want != _aiming:
		_aiming = want
		aiming_changed.emit(_aiming)
		if _recoil:
			_recoil.set_aiming(_aiming)
		if _player.has_method("set_aiming"):
			_player.set_aiming(_aiming)
	var target_fov := ads_fov if _aiming else hip_fov
	_camera.fov = lerpf(_camera.fov, target_fov, clampf(ads_speed * delta, 0.0, 1.0))


func _update_trigger() -> void:
	var pressed := Input.is_action_pressed("shoot") and _trigger_enabled
	if not pressed:
		_trigger_held = false
		return

	var just_pressed := not _trigger_held
	_trigger_held = true
	if _reloading:
		return
	if not (automatic or just_pressed):
		return
	if _fire_cooldown > 0.0:
		return

	if _mag > 0:
		_fire()
	elif auto_reload and _reserve > 0:
		start_reload()
	else:
		_audio.play_empty()
		_fire_cooldown = 0.35


func _fire() -> void:
	_mag -= 1
	_fire_cooldown = 60.0 / maxf(rpm, 1.0)
	ammo_changed.emit(_mag, _reserve)
	fired.emit()

	if _recoil:
		_recoil.fire_shot()
	if _shake:
		_shake.add_trauma(shake_per_shot)
	_audio.play_shot()

	_show_muzzle_flash()
	_hitscan()


func _show_muzzle_flash() -> void:
	_flash_timer = flash_time
	_muzzle_light.visible = true
	_muzzle_flash.visible = true
	_muzzle_light.light_energy = randf_range(3.0, 5.5)
	_muzzle_flash.rotation.z = randf_range(0.0, TAU)
	_muzzle_flash.scale = Vector3.ONE * randf_range(0.8, 1.25)


func _hitscan() -> void:
	var space := get_world_3d().direct_space_state
	var origin := _camera.global_position
	var basis := _camera.global_transform.basis
	var direction := -basis.z.normalized()

	# 第 3 层扩散：在圆锥内随机偏移（开镜时扩散更小，由 RecoilSystem 统一控制）
	var deviation := 0.0 if _recoil == null else _recoil.get_bullet_deviation_radians()
	if deviation > 0.0:
		direction = direction.rotated(basis.x.normalized(), randf_range(-deviation, deviation))
		direction = direction.rotated(basis.y.normalized(), randf_range(-deviation, deviation))
		direction = direction.normalized()

	var end_point := origin + direction * max_range
	var query := PhysicsRayQueryParameters3D.create(origin, end_point)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [_player.get_rid()]
	var hit := space.intersect_ray(query)

	if not hit.is_empty():
		end_point = hit.position
		var collider = hit.collider
		if collider != null and collider.has_method("take_damage"):
			collider.take_damage(damage)
			var health = collider.get("health")
			var killed: bool = health != null and float(health) <= 0.0
			hit_confirmed.emit(_display_name_of(collider), killed)
		else:
			_show_impact(hit.position, hit.normal)

	if _tracer:
		_draw_tracer(_muzzle.global_position, end_point)


func _display_name_of(node: Object) -> String:
	var value = node.get("display_name")
	if value != null:
		return str(value)
	return str(node.name)


func _build_effects() -> void:
	# 曳光弹（复用一个节点，避免每发都创建对象）
	var tracer_mesh := CylinderMesh.new()
	tracer_mesh.top_radius = 0.012
	tracer_mesh.bottom_radius = 0.012
	tracer_mesh.height = 1.0
	tracer_mesh.radial_segments = 4
	tracer_mesh.rings = 0
	var tracer_mat := StandardMaterial3D.new()
	tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer_mat.albedo_color = Color(1.0, 0.92, 0.6, 0.85)
	tracer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_tracer = MeshInstance3D.new()
	_tracer.name = "Tracer"
	_tracer.mesh = tracer_mesh
	_tracer.material_override = tracer_mat
	_tracer.top_level = true
	_tracer.visible = false
	_tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_tracer)

	# 弹着点火花（灯 + 小球）
	_impact_light = OmniLight3D.new()
	_impact_light.name = "ImpactLight"
	_impact_light.light_color = Color(1.0, 0.8, 0.5)
	_impact_light.light_energy = 2.5
	_impact_light.omni_range = 2.5
	_impact_light.top_level = true
	_impact_light.visible = false
	add_child(_impact_light)


func _draw_tracer(from: Vector3, to: Vector3) -> void:
	if not _tracer:
		return
	var delta_vec := to - from
	var length := delta_vec.length()
	if length < 0.05:
		return
	var y_axis := delta_vec / length
	var helper := Vector3.UP if absf(y_axis.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x_axis := helper.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	var basis := Basis(x_axis, y_axis, z_axis).scaled(Vector3(1.0, length, 1.0))
	_tracer.global_transform = Transform3D(basis, (from + to) * 0.5)
	_tracer.visible = true
	_tracer_timer = tracer_lifetime


func _show_impact(point: Vector3, normal: Vector3) -> void:
	if _impact_light == null:
		return
	_impact_light.global_position = point + normal * 0.05
	_impact_light.visible = true
	_impact_light.light_energy = randf_range(1.8, 3.2)
	_impact_timer = impact_flash_time