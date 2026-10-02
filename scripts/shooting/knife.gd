extends Node3D
class_name Knife
## 蝴蝶刀（近战）：左键挥刀，短距离 hitscan 造成伤害；没有弹药 / 换弹 / 开镜。
## 与枪一样通过 player.gd 的 setup() 注入依赖，命中反馈走 hit_confirmed（HUD 命中标记）。

signal hit_confirmed(target_name: String, killed: bool)

@export var display_name := "蝴蝶刀"
@export var damage := 65.0
@export var range_m := 2.2
@export var swing_time := 0.22

var active := true
var _player: CharacterBody3D
var _camera: Camera3D
var _cooldown := 0.0
var _swing_t := -1.0
var _base_rotation := Vector3.ZERO


func _ready() -> void:
	_base_rotation = rotation


func setup(player: CharacterBody3D, camera: Camera3D, _recoil: RecoilSystem, _shake: ShakeCamera) -> void:
	_player = player
	_camera = camera


func set_trigger_enabled(_enabled: bool) -> void:
	pass


func set_active(value: bool) -> void:
	active = value


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	_update_swing(delta)
	if _player == null or _camera == null or not active:
		return
	if not _player.is_multiplayer_authority():
		return
	if Input.is_action_pressed("shoot") and _cooldown <= 0.0:
		_slash()


## 挥刀动画：快速绕本地 X 轴甩一下
func _update_swing(delta: float) -> void:
	if _swing_t < 0.0:
		return
	_swing_t += delta
	var t := clampf(_swing_t / swing_time, 0.0, 1.0)
	rotation.x = _base_rotation.x - sin(t * PI) * 1.5
	if t >= 1.0:
		_swing_t = -1.0
		rotation.x = _base_rotation.x


func _slash() -> void:
	_cooldown = swing_time + 0.08
	_swing_t = 0.0
	var space := get_world_3d().direct_space_state
	var origin := _camera.global_position
	var direction := -_camera.global_transform.basis.z.normalized()
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * range_m)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [_player.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var collider = hit.collider
	if collider == null or not collider.has_method("take_damage"):
		return
	var hp_before = collider.get("health")
	if hp_before != null and float(hp_before) <= 0.0:
		return
	var killed: bool = hp_before != null and float(hp_before) - damage <= 0.0
	if NetworkManager.is_online and collider is Node:
		if collider.is_in_group("friendly"):
			collider.apply_network_damage.rpc_id(
				collider.get_multiplayer_authority(), damage, NetworkManager.get_my_name()
			)
		else:
			NetworkManager.apply_damage_to_target.rpc(
				str(collider.get_path()), damage, NetworkManager.get_my_name()
			)
	else:
		collider.take_damage(damage)
	var value = collider.get("display_name")
	hit_confirmed.emit(str(value) if value != null else String((collider as Node).name), killed)