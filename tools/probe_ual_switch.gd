extends Node3D
## 持枪 ⇄ 空手**来回切换**的跳变实测（窗口模式）。
##
## ## 要回答的问题（任务书明确要求）
##   「空手时手臂归谁？」选了 (a) UAL 驱动手臂 ⇒ 持枪↔空手切换时手臂会**换驱动者**
##   （UAL ↔ WeaponHoldIK）。**必须实测有无跳变。**
##
## ## 怎么测才算「实测」而不是「推断」
## 逐步推进动画，在**同一帧**里切换 `set_holding_weapon`，然后**逐帧连拍**，
## 同时打印 IK 的 `influence` 权重。用「相邻帧之间手的像素位置是否突跳」判断。
## ⚠ 注意：`TwoBoneIK3D` 的结果**不会**出现在 `get_bone_global_pose()` 里（官方设计：
##   modification 应用到皮肤后立即丢弃），所以**不能**靠读骨骼坐标判断 IK 手臂 ⇒ 只能看图。
##   但 UAL 手臂**可以**读（走 mixer 通道），所以两条证据互补。
##
## 用法：godot --path . --rendering-driver vulkan --resolution 700x700 res://tools/probe_ual_switch.tscn

const MikuModelScript := preload("res://scripts/entities/miku_model.gd")
const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const RIFLE := "res://scenes/weapons/rifle.tscn"
const OUT := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"

## 切换发生在第几帧
const TOGGLE_FRAME := 6
## 连拍帧数
const FRAMES := 18

var _cam: Camera3D
var _model: Node3D
var _frame := 0
var _busy := false
var _plan: Array = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	_setup_env()
	_model = MikuModelScript.new()
	_model.name = "MikuModel"
	_model.model_path = CAT_MODEL
	_model.ual_locomotion_enabled = true
	_model.hold_ik_enabled = true
	_model.hand_grip_enabled = true
	add_child(_model)
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	_model.add_child(mount)
	var rifle: Node = (load(RIFLE) as PackedScene).instantiate()
	rifle.name = "Rifle"
	mount.add_child(rifle)
	_model.set_holding_weapon(false) # 从**空手**开始（UAL 驱动手臂）
	print("起始：UAL生效=%s  arms_driven=%s  IK influence=%.2f" % [
		str(_model.is_ual_locomotion_active()), str(_model._ual_loco.arms_driven),
		_model._hold_ik.get_influence()])
	# 预热：让 UAL 真正开始播放
	for i in 20:
		_model.update_animation(1.0 / 60.0, 3.6, 0.554, true, true)
	for i in FRAMES:
		_plan.append(i)


func _process(_d: float) -> void:
	if _busy or _plan.is_empty():
		if _plan.is_empty() and not _busy:
			print("SWITCH_DONE")
			get_tree().quit(0)
		return
	if _busy:
		return
	_busy = true
	var idx := int(_plan.pop_front())
	# —— 到点就切手持械状态 ——
	if idx == TOGGLE_FRAME:
		_model.set_holding_weapon(true)
		print("  >>> 第 %d 帧：切到【持枪】（手臂驱动者应从 UAL 交给 IK）" % idx)
	# 推进一帧动画（真实出货路径）
	_model.update_animation(1.0 / 60.0, 3.6, 0.554, true, true)
	_model._hold_ik.tick(1.0 / 60.0)
	# 确定性时刻
	var loco = _model._ual_loco
	if loco != null and loco.valid and loco._ual_ap != null:
		loco._ual_ap.seek(0.33, true, true)
		loco._ual_skel.force_update_all_bone_transforms()
		loco._sample_and_apply()
	var sk := _find_skel(_model)
	var hand := sk.get_bone_global_pose(sk.find_bone("hand.R_85")).origin
	var foot := sk.get_bone_global_pose(sk.find_bone("foot.R_102")).origin
	print("[f%02d] arms_driven=%-5s influence=%.2f | mixer手.y=%.3f 脚.y=%.3f" % [
		idx, str(_model._ual_loco.arms_driven), _model._hold_ik.get_influence(),
		hand.y, foot.y])
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/switch_f%02d.png" % [OUT, idx])
	_busy = false


func _setup_env() -> void:
	_cam = Camera3D.new()
	_cam.current = true
	_cam.fov = 40.0
	add_child(_cam)
	_cam.position = Vector3(2.6, 0.25, 0.9)
	_cam.look_at(Vector3(0.0, -0.05, 0.0), Vector3.UP)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 40, 0)
	key.light_energy = 1.5
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, -140, 0)
	fill.light_energy = 0.55
	add_child(fill)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.18, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.7)
	e.ambient_light_energy = 0.8
	we.environment = e
	add_child(we)


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null