extends Node3D
class_name CameraSway
## 相机摇晃 / 惯性平滑（阶段 2）
##
## 两种动感来源：
##   1. 鼠标转动时，摄像机滞后一点点（转动带惯性，停下后缓慢回正）
##   2. 移动时：横向速度产生侧倾（lean），上下产生行走晃动（bob）
##
## 本节点挂在摄像机链上：RecoilPivot → SwayPivot(本脚本) → SpringArm3D → Camera3D。
## 只写自己的 rotation / position，不改动父节点的鼠标控制。
##
## TODO(阶段2+)：想用 DampedSprings 插件时，把 _process 里的 lerp 换成弹簧节点即可（接口不变）。

## 鼠标转动的滞后强度（弧度 / 像素）
@export var look_sway := 0.0035
## 最大滞后角度
@export var max_sway := 0.045
## 跟随鼠标的速度
@export var follow_speed := 7.0
## 松开鼠标后回正的速度
@export var return_speed := 9.0
## 横向移动的侧倾（弧度 / (米/秒)）
@export var strafe_lean := 0.012
## 横向侧倾上限（弧度）
@export var max_lean := 0.05
## 行走上下晃动幅度（米）
@export var bob_amount := 0.035
## 行走晃动的步频
@export var bob_frequency := 9.0

var _mouse_offset := Vector2.ZERO
var _current_rot := Vector3.ZERO
var _base_position := Vector3.ZERO
var _local_velocity := Vector3.ZERO
var _move_amount := 0.0
var _bob_time := 0.0


func _ready() -> void:
	_base_position = position


## 玩家把鼠标增量交给这里，产生惯性滞后
func add_look_delta(relative: Vector2) -> void:
	_mouse_offset.x = clampf(_mouse_offset.x - relative.y * look_sway, -max_sway, max_sway)
	_mouse_offset.y = clampf(_mouse_offset.y - relative.x * look_sway, -max_sway, max_sway)


## 玩家每帧同步运动状态：move_amount 为 0~1 的速度比例，local_velocity 为玩家本地速度
func set_motion(move_amount: float, local_velocity: Vector3) -> void:
	_move_amount = clampf(move_amount, 0.0, 1.0)
	_local_velocity = local_velocity


func _process(delta: float) -> void:
	var follow_k := 1.0 - exp(-follow_speed * delta)
	_current_rot.x = lerpf(_current_rot.x, _mouse_offset.x, follow_k)
	_current_rot.y = lerpf(_current_rot.y, _mouse_offset.y, follow_k)
	var lean := clampf(-_local_velocity.x * strafe_lean, -max_lean, max_lean)
	_current_rot.z = lerpf(_current_rot.z, lean, follow_k)

	_mouse_offset = _mouse_offset.lerp(Vector2.ZERO, 1.0 - exp(-return_speed * delta))

	_bob_time += delta * bob_frequency * _move_amount
	var bob := sin(_bob_time) * bob_amount * _move_amount

	rotation = _current_rot
	position = _base_position + Vector3(0.0, bob, 0.0)