extends Node3D
## 双手持枪 IK —— 目视验证截图工具（走**真实**的 MikuModel / WeaponHoldIK 代码路径）
##
## 为什么必须窗口跑：`SkeletonModifier3D` 的形变在 headless（dummy 渲染）下
## **不触发**（`skeleton_updated` 信号不发、结果被丢弃），只能在真实渲染窗口里看/截图。
## 纯数学部分另有 `tests/suites/test_weapon_hold_ik.gd` 覆盖。
##
## 用法：
##   godot --path . --rendering-driver vulkan --resolution 900x700 res://tools/capture_hold_ik.tscn
## 产物：tmp_spike/hold_ik_0.png（关闭 IK = 旧单臂）/ _1.png（开启 IK，正面）
##       / _2.png（开启 IK，侧面）
##
## ⚠ 只用 cat_hatsune_miku（标准人形骨架）。默认模型 miku.glb 是乱码骨名，IK 自动不启用。

const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const RIFLE := "res://scenes/weapons/rifle.tscn"
const OUT_DIR := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"

var _model: MikuModel
var _frames := 0
var _ik_on := false


func _ready() -> void:
	var cam := Camera3D.new()
	cam.name = "Cam"
	cam.current = true
	cam.fov = 40.0
	add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-32, 35, 0)
	light.light_energy = 1.7
	add_child(light)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.15, 0.17, 0.21)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.55, 0.65)
	e.ambient_light_energy = 0.7
	we.environment = e
	add_child(we)

	# 真实的 MikuModel + WeaponMount/Rifle（与 player.tscn 同构）
	_model = MikuModel.new()
	_model.name = "MikuModel"
	_model.model_path = CAT_MODEL
	_model.hold_ik_enabled = false # 第一张截图 = 关闭 IK（旧行为）
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	_model.add_child(mount)
	mount.add_child((load(RIFLE) as PackedScene).instantiate())
	add_child(_model) # 触发 _ready → load_model → _start_hold_ik
	# 对齐游戏内站姿：player.gd 站立时把 MikuModel.position.y 抬到 0.9（使脚落地）
	_model.position.y = 0.9
	_model.set_holding_weapon(true)
	print("hold_ik_available=%s" % _model.is_hold_ik_available())


func _process(d: float) -> void:
	_frames += 1
	# 驱动状态机（cat_hatsune_miku 有 idle 剪辑 → 播 idle，与游戏内一致；手臂由 IK 叠加）
	_model.update_animation(d, 0.0, 0.0, false, true)
	# 帧 40：先截「关闭 IK」的旧行为；帧 42：打开 IK；帧 80 / 120：截两个机位
	if _frames == 40:
		await _shoot(0)
	elif _frames == 42:
		_model.set_hold_ik_enabled(true)
		_ik_on = true
		print("IK 已开启：hold_ik_enabled=%s" % _model.hold_ik_enabled)
	elif _frames == 80:
		await _shoot(1)
	elif _frames == 120:
		await _shoot(2)
		get_tree().quit(0)


func _shoot(shot: int) -> void:
	_aim_camera(shot)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path := "%s/hold_ik_%d.png" % [OUT_DIR, shot]
	img.save_png(path)
	print("saved %s（IK %s）" % [path, "on" if _ik_on else "off"])


func _aim_camera(shot: int) -> void:
	var cam := get_node("Cam") as Camera3D
	var focus := Vector3(0.0, 1.10, 0.2)
	match shot:
		0:
			cam.position = focus + Vector3(0.95, 0.28, 1.65)
		1:
			cam.position = focus + Vector3(-0.85, 0.22, 1.52)
		_:
			cam.position = focus + Vector3(1.30, 0.30, 0.55)
	cam.look_at(focus, Vector3.UP)
