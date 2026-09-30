extends StaticBody3D
class_name TrainingTarget
## 训练靶（阶段 2 占位）
##
## 这不是真正的敌人 AI，只是给阶段 2 的手感 / HUD 提供数据源的标靶：
## 可被击中、有血量、会闪白、被击毁后过几秒自动复活（方便反复测试）。
## 阶段 3/4 之后用真正的敌人替换它。

signal died(target_name: String)

## 靶子显示名（击杀日志里显示）
@export var display_name := "训练靶"
@export var max_health := 100.0
@export var respawn_time := 3.0
## 受击闪白强度
@export var hit_flash_energy := 2.5

var health := 100.0
var alive := true

@onready var _mesh: MeshInstance3D = get_node_or_null("MeshInstance3D")
@onready var _shape: CollisionShape3D = get_node_or_null("CollisionShape3D")

var _material: StandardMaterial3D
var _flash_tween: Tween


func _ready() -> void:
	health = max_health
	alive = true
	if not is_in_group("enemy"):
		add_to_group("enemy")
	if _mesh and _mesh.material_override is StandardMaterial3D:
		_material = _mesh.material_override.duplicate()
		_material.emission_enabled = true
		_mesh.material_override = _material


## 被武器命中时调用（weapon.gd 通过 duck typing 调用）
func take_damage(amount: float, _source: Node = null) -> void:
	if not alive:
		return
	health = maxf(health - amount, 0.0)
	if health <= 0.0:
		_die()
	else:
		_flash()


func get_health_ratio() -> float:
	return clampf(health / maxf(max_health, 1.0), 0.0, 1.0)


func _flash() -> void:
	if _material == null:
		return
	_material.emission_energy_multiplier = hit_flash_energy
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_property(_material, "emission_energy_multiplier", 0.15, 0.18)


func _die() -> void:
	alive = false
	health = 0.0
	visible = false
	if _shape:
		_shape.set_deferred("disabled", true)
	died.emit(display_name)
	_respawn_later()


func _respawn_later() -> void:
	await get_tree().create_timer(respawn_time).timeout
	if not is_instance_valid(self):
		return
	health = max_health
	alive = true
	visible = true
	if _shape:
		_shape.set_deferred("disabled", false)
	if _material:
		_material.emission_energy_multiplier = 0.15