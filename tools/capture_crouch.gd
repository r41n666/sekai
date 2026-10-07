extends Node3D
## 窗口模式：蹲/站切换的**连拍**验证（证明不跳变）+ 蹲姿各档实拍。
##
## ## 为什么必须窗口模式
## headless（dummy 渲染）下 AnimationPlayer 不推进、seek 不更新骨骼
## （见 ual_locomotion.gd 文件头 §8-3）⇒ UAL 驱动的姿态**只能**在窗口模式看。
##
## ## 相机按包围盒自动取景且**固定不动**（连拍可比；硬编码机位会拍空，见 capture_tpose_verify）
##
## ## 拍摄计划
##   · `stand`：站立 Idle × N帧
##   · `crouch`：切到蹲下，**连拍每一帧**（关键：看切换瞬间有没有跳变）
##   · `crouch_walk`：蹲下 + 移动（走 Crouch_Fwd）
##   · `stand_again`：切回站立，连拍（看回切有没有跳变）
##
## ##跳变的量化
## 大腿骨世界朝向的**逐帧角变化**（度/帧）。硬切会在切的那一帧出现一个大尖峰；
## 有渐变时尖峰被摊到多帧上，单帧变化显著变小。
## 运行：
##   godot --path . --rendering-driver vulkan --resolution 700x700 res://tools/capture_crouch.tscn

const MikuModelScript := preload("res://scripts/entities/miku_model.gd")
const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const OUT := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"
const FPS := 30.0
const DT := 1.0 / FPS

## 每段拍多少帧。切换段要够长才能看出渐变（STANCE_BLEND_TIME = 0.18 s ≈ 5.4 帧 @30fps）
const FRAMES_PER_SEG := 18

## 拍摄计划：[段名, 是否蹲下, 是否移动, speed_ratio, 标签]
const SEGMENTS := [
	["stand", false, false, 0.0, "站立"],
	["to_crouch", true, false, 0.0, "蹲下切换"],
	["crouch_hold", true, false, 0.0, "蹲姿保持"],
	["crouch_walk", true, true, 0.277, "蹲姿行走"],
	["to_stand", false, false, 0.0, "站起切换"],
	["stand2", false, true, 0.554, "站立行走"],
]

var _cam: Camera3D
var _model: Node3D
var _skel: Skeleton3D
var _seg := 0
var _frame := 0
var _busy := false
var _cam_locked := false
## 逐帧大腿朝向（度），用于量化「跳变」
var _blend_override := -1.0
var _seg_q: Array[Quaternion] = []
var _seg_head: Array[float] = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	_setup_env()
	_model = MikuModelScript.new()
	_model.name = "MikuModel"
	_model.model_path = CAT_MODEL
	# ⚠ 开关必须在 add_child 之前设好（_ready 里就会 load_model）
	_model.ual_locomotion_enabled = true
	# `-- hardcut` 时把渐变设为 0⇒ **硬切基线**，用来与渐变版做数值对照
	# （证明「不跳变」是有对比数据的结论，而不是嘴上说说）。
	if OS.get_cmdline_user_args().has("hardcut"):
		_blend_override = 0.0
		print("[对照] **硬切基线**模式：stance_blend_time = 0")
	_model.hold_ik_enabled = true
	_model.hand_grip_enabled = true
	add_child(_model)
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	_model.add_child(mount)
	var rifle: Node = (load("res://scenes/weapons/rifle.tscn") as PackedScene).instantiate()
	rifle.name = "Rifle"
	mount.add_child(rifle)
	rifle.visible = true
	_model.set_holding_weapon(true)
	_skel = _find_skel(_model)
	if _blend_override >= 0.0 and _model._ual_loco != null:
		_model._ual_loco.stance_blend_time = _blend_override
	print("[蹲姿] UAL生效=%s  IK=%s  骨数=%d  渐变时长=%.2fs" % [
		str(_model.is_ual_locomotion_active()),
		str(_model._hold_ik != null and _model._hold_ik.is_enabled()),
		_skel.get_bone_count() if _skel != null else -1,
		_model._ual_loco.stance_blend_time if _model._ual_loco != null else -1.0])


func _process(_delta: float) -> void:
	if _busy:
		return
	if _seg >= SEGMENTS.size():
		print("ALL_SHOTS_DONE")
		get_tree().quit(0)
		return
	var s: Array = SEGMENTS[_seg]
	# —— 走**出货路径**：蹲下经 player.gd → set_crouched → UAL ——
	_model.set_crouched(bool(s[1]))
	_model.update_animation(DT, float(s[3]) * 6.5, float(s[3]), bool(s[2]), true)
	if _skel != null and is_instance_valid(_skel):
		_skel.force_update_all_bone_transforms()
	_frame += 1
	_sample(String(s[0]))
	_shoot_async(String(s[0]), int(_seg))


## 记一条大腿骨的**世界朝向四元数** + 头高。
##
## ⚠⚠ 姿态变化必须用 `Quaternion.angle_to()` 量，**不能**用 `euler.y`：
##   欧拉角在 ±180° 处会**回绕**（实测第一段出现「Δ=+344.8°」的假跳变，
##   其实是 -180° → +165° 的跨零），而且蹲姿主要是**俯仰**（pitch）运动，
##   `euler.y` 会随万向节耦合乱跳（一度量到「单帧 -85°」的假尖峰）。
##   `angle_to` 无回绕、且量的是真实的骨骼夹角，正是「有没有跳变」该问的问题。
func _sample(seg_name: String) -> void:
	if _skel == null or not is_instance_valid(_skel):
		return
	var i := _skel.find_bone("upper_leg.L_100")
	var h := _skel.find_bone("head_49")
	if i < 0 or h < 0:
		return
	var q := _skel.get_bone_global_pose(i).basis.orthonormalized().get_rotation_quaternion()
	var hy := _skel.get_bone_global_pose(h).origin.y
	var ang := 0.0
	if not _seg_q.is_empty():
		ang = rad_to_deg(_seg_q[_seg_q.size() - 1].angle_to(q))
	if _seg_q.is_empty():
		print("[%s] 第 %2d 帧大腿=%s头高=%.4f" % [seg_name, _frame, _fmt_q(q), hy])
	else:
		print("[%s] 第 %2d 帧大腿=%s (Δ夹角=%.3f°)  头高=%.4f" % [
			seg_name, _frame, _fmt_q(q), ang, hy])
	_seg_q.append(q)
	_seg_head.append(hy)


## 便于人读的简短四元数表示。
func _fmt_q(q: Quaternion) -> String:
	var e := q.get_euler()
	return "(pitch=%6.2f yaw=%7.2f roll=%6.2f) " % [
		rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)]


## 逐段报告：每段给出「单帧最大夹角变化」—— **硬切会在切的那一帧出现大尖峰**。
##
## ⚠⚠ **只有第0 段（`stand`）才跳过前 3 帧**，后续段**一律不跳**。
##   理由：UAL 的 AnimationPlayer 需要几帧才产出第一个真实姿态，所以**首段**开头
##   量到的是 rest 姿态 → 首个真实姿态，那是**启动假象**（实测 stand 段 Δ=26.5°）。
##   但**切换段恰恰不能跳** —— 硬切的跳变就发生在该段的第 1~2 帧！
##   ⚠ 本轮踩过：先给所有段都加了「跳 3 帧」，结果硬切基线量出「to_crouch Δ=0.125°」
##   （比渐变版的 12.6° 还小）—— **因为跳变正好被跳过了**，险些得出「硬切更平滑」的
##   荒谬结论。这正是§4-16「弱断言两个方向都要测」的同类陷阱。
func _finish_seg() -> void:
	var name := String(SEGMENTS[_seg][0])
	# 只有首段跳过启动帧；切换段（_seg >= 1）从第 0 帧就开始量
	var skip := 3 if _seg == 0 else 0
	if _seg_q.size() >= skip + 2:
		var max_step := 0.0
		var at_frame := 0
		for i in range(skip + 1, _seg_q.size()):
			var d := rad_to_deg(_seg_q[i - 1].angle_to(_seg_q[i]))
			if d > max_step:
				max_step = d
				at_frame = i + 1
		var head_lo := INF
		var head_hi := -INF
		for i in range(skip, _seg_head.size()):
			head_lo = minf(head_lo, _seg_head[i])
			head_hi = maxf(head_hi, _seg_head[i])
		print("[统计 %-13s] 有效帧=%2d  **单帧最大夹角变化=%6.3f°（第%d帧）**  头高 %.3f~%.3f (Δ=%.3f)" % [
			name, _seg_q.size() - skip, max_step, at_frame, head_lo, head_hi, head_hi - head_lo])
	_seg_q.clear()
	_seg_head.clear()


func _shoot_async(seg_name: String, seg_idx: int) -> void:
	_busy = true
	_frame_camera()
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var suffix := "" if _blend_override <= 0.0 else "_hardcut"
	var path := "%s/crouch_%02d_%s%s_f%02d.png" % [OUT, seg_idx, seg_name, suffix, _frame]
	img.save_png(path)
	_busy = false
	if _frame >= FRAMES_PER_SEG:
		_finish_seg()
		_frame = 0
		_seg += 1
	print("saved %s" % path)


## —— 相机按包围盒自动取景（**只算一次**，之后固定；连拍必须可比）——
func _frame_camera() -> void:
	if _cam_locked:
		return
	_cam_locked = true
	var box := _model_box()
	if box.size.length() < 0.01:
		_cam.position = Vector3(-1.45, 0.40, 2.95)
		_cam.look_at(Vector3.ZERO, Vector3.UP)
		return
	var center := box.get_center()
	var radius := maxf(box.size.length() * 0.5, 0.2)
	var dist := radius / tan(deg_to_rad(_cam.fov) * 0.5) * 1.25
	# 正面偏侧 25°，能同时看清蹲下的屈膝与前后身
	var dir := Vector3(0.42, 0.0, 1.0).normalized()
	var eye := center + dir * dist + Vector3(0.0, radius * 0.16, 0.0)
	_cam.position = eye
	_cam.look_at(center, Vector3.UP)
	print("[相机] 中心=%s 半径=%.3f 机位=%s（固定）" % [str(center), radius, str(_cam.position)])


func _model_box() -> AABB:
	var box := AABB()
	var first := true
	for m in _collect_meshes(_model):
		var mb := (m as MeshInstance3D).get_aabb()
		var xf := (m as Node3D).global_transform
		for c in 8:
			var corner := mb.position + Vector3(
				mb.size.x * float(c & 1), mb.size.y * float((c >> 1) & 1),
				mb.size.z * float((c >> 2) & 1))
			var p := xf * corner
			if first:
				box = AABB(p, Vector3.ZERO)
				first = false
			else:
				box = box.expand(p)
	return box


func _setup_env() -> void:
	_cam = Camera3D.new()
	_cam.name = "Cam"
	_cam.current = true
	_cam.fov = 40.0
	add_child(_cam)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-25, 40, 0)
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


func _collect_meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_collect_meshes(c))
	return out


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null