extends Node3D
## 分层模式目视验证 + 触达误差测量（窗口工具，走**真实** MikuModel / WeaponHoldIK 代码路径）。
##
## 走真实路径：cat_hatsune_miku + procedural_legs_enabled=true + hold_ik_enabled=true，
## 每帧以 moving=true 驱动 update_animation → **腿在走**；双臂由 TwoBoneIK3D 拉到握持点。
##
## ⚠ 必须窗口跑：`SkeletonModifier3D`（IK）的形变在 headless 下不触发、结果被丢弃。
##
## 用法：
##   godot --path . --rendering-driver vulkan --resolution 900x760 res://tools/capture_layered_walk.tscn
## 可选：在 `--` 后加 `torso` 打开躯干锚点（对照基准冲突）：
##   godot --path . --rendering-driver vulkan res://tools/capture_layered_walk.tscn -- torso
## 产物：tmp_spike/layered_walk_<fixed|torso>_<shot>.png

const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const RIFLE := "res://scenes/weapons/rifle.tscn"
const OUT_DIR := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"

var _model: MikuModel
var _frames := 0
var _use_torso := false
var _reach_err_r := 0.0
var _reach_err_l := 0.0
var _reach_err_r_max := 0.0
var _reach_err_l_max := 0.0
var _skeleton: Skeleton3D
var _hand_r := -1
var _hand_l := -1


func _ready() -> void:
	_use_torso = "torso" in OS.get_cmdline_user_args()

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

	_model = MikuModel.new()
	_model.name = "MikuModel"
	_model.model_path = CAT_MODEL
	_model.procedural_legs_enabled = true
	_model.hold_ik_enabled = true
	_model.hold_ik_torso_anchor = _use_torso
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	_model.add_child(mount)
	mount.add_child((load(RIFLE) as PackedScene).instantiate())
	add_child(_model)
	_model.position.y = 0.9
	_model.set_holding_weapon(true)

	_skeleton = _find_skeleton(_model)
	if _skeleton != null:
		_skeleton.skeleton_updated.connect(_on_skeleton_updated)
		if _model._hold_ik != null:
			_hand_r = _model._hold_ik._skeleton.find_bone(String(_model._hold_ik.debug_names.get("hand_r", "")))
			_hand_l = _model._hold_ik._skeleton.find_bone(String(_model._hold_ik.debug_names.get("hand_l", "")))
	print("分层=%s  torso_anchor=%s  torso_attached=%s" % [
		_model._procedural != null, _use_torso,
		_model._hold_ik._torso_attached if _model._hold_ik != null else false])


func _on_skeleton_updated() -> void:
	if _model._hold_ik == null or not _model._hold_ik.is_enabled():
		return
	var sk: Skeleton3D = _model._hold_ik._skeleton
	if _hand_r >= 0 and _model._hold_ik._target_r != null:
		_reach_err_r = sk.get_bone_global_pose(_hand_r).origin.distance_to(
			sk.global_transform.affine_inverse() * _model._hold_ik._target_r.global_position)
	if _hand_l >= 0 and _model._hold_ik._target_l != null:
		_reach_err_l = sk.get_bone_global_pose(_hand_l).origin.distance_to(
			sk.global_transform.affine_inverse() * _model._hold_ik._target_l.global_position)
	# 只统计 warmup（前 60 帧，步态幅度还在爬升）之后的稳态峰值
	if _frames >= 60:
		_reach_err_r_max = maxf(_reach_err_r_max, _reach_err_r)
		_reach_err_l_max = maxf(_reach_err_l_max, _reach_err_l)


func _process(d: float) -> void:
	_frames += 1
	# 固定步长（1/60）推进：窗口模式不锁帧，用真实 delta 会让「第 N 帧」落在不同相位，截图不可复现。
	_model.update_animation(1.0 / 60.0, 2.0, 0.5, true, true)
	if _frames == 70:
		await _shoot(0)
	elif _frames == 100:
		await _shoot(1)
	elif _frames == 130:
		await _shoot(2)
	elif _frames == 160:
		await _shoot(3)
		print("触达误差（右/左）当前=(%.4f, %.4f)  峰值=(%.4f, %.4f) 单位=米" % [
			_reach_err_r, _reach_err_l, _reach_err_r_max, _reach_err_l_max])
		get_tree().quit(0)


func _shoot(shot: int) -> void:
	_aim_camera(shot)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var suffix := "torso" if _use_torso else "fixed"
	var path := "%s/layered_walk_%s_%d.png" % [OUT_DIR, suffix, shot]
	img.save_png(path)
	print("saved %s" % path)


func _aim_camera(shot: int) -> void:
	var cam := get_node("Cam") as Camera3D
	var focus := Vector3(0.0, 1.05, 0.15)
	match shot:
		0: # 前 3/4
			cam.position = focus + Vector3(-0.95, 0.30, 1.60)
		1: # 侧面
			cam.position = focus + Vector3(1.65, 0.20, 0.10)
		2: # 背后（第三人称过肩）
			cam.position = focus + Vector3(0.55, 0.55, -1.85)
		_: # 正面
			cam.position = focus + Vector3(0.05, 0.18, 2.00)
	cam.look_at(focus, Vector3.UP)


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for c in root.get_children():
		var f := _find_skeleton(c)
		if f != null:
			return f
	return null
