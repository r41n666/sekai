extends Node3D
class_name Grenade
## 手雷（投掷物）：左键投掷，落地/到期后爆炸（范围伤害 + 冲击波视觉 + 屏幕震动）。
## 数量有限（默认 3 颗）；长按 R 3 秒把数量补满。多人时投掷通过 RPC 广播，各端各自模拟一个。

signal ammo_changed(count: int, reserve: int)

@export var display_name := "手雷"
@export var start_count := 3
@export var throw_speed := 9.0
@export var throw_up := 3.0
@export var throw_cooldown := 0.7

const PROJECTILE_SCENE := preload("res://scenes/weapons/grenade_projectile.tscn")

var active := true
var _player: CharacterBody3D
var _camera: Camera3D
var _count := 0
var _cooldown := 0.0
var _reset_hold := 0.0


func _ready() -> void:
	_count = start_count


func setup(player: CharacterBody3D, camera: Camera3D, _recoil: RecoilSystem, _shake: ShakeCamera) -> void:
	_player = player
	_camera = camera
	ammo_changed.emit(_count, 0)


func set_trigger_enabled(_enabled: bool) -> void:
	pass


func set_active(value: bool) -> void:
	active = value


## 供 HUD 显示（鸭子类型，和枪一致）
func get_mag() -> int:
	return _count


func get_reserve() -> int:
	return 0


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	if _player == null or _camera == null or not active:
		return
	if not _player.is_multiplayer_authority():
		return
	# 长按 R 3 秒：补满
	if Input.is_action_pressed("reload"):
		_reset_hold += delta
		if _reset_hold >= 3.0:
			_reset_hold = 0.0
			_count = start_count
			ammo_changed.emit(_count, 0)
	else:
		_reset_hold = 0.0
	if Input.is_action_pressed("shoot") and _cooldown <= 0.0:
		_throw()


func _throw() -> void:
	if _count <= 0:
		return
	_count -= 1
	_cooldown = throw_cooldown
	ammo_changed.emit(_count, 0)
	var origin := _camera.global_position + (-_camera.global_transform.basis.z) * 0.4
	var velocity := (-_camera.global_transform.basis.z.normalized() * throw_speed) + Vector3.UP * throw_up
	_spawn_projectile(origin, velocity)
	if NetworkManager.is_online:
		NetworkManager.net_grenade.rpc(origin, velocity)


## 在本端生成一个手雷投掷物（RPC 的另一端也会各自调用）
func _spawn_projectile(origin: Vector3, velocity: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		scene = get_tree().root # 兜底（例如自动化测试直接实例化场景时）
	var projectile: Node = PROJECTILE_SCENE.instantiate()
	scene.add_child(projectile)
	if projectile is RigidBody3D:
		(projectile as RigidBody3D).global_position = origin
		(projectile as RigidBody3D).linear_velocity = velocity