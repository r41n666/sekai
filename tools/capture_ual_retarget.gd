extends Node3D
## UAL → cat 骨架**运行期重定向** + 截图（窗口工具，Vulkan）。
##
## 为什么不用导入期 BoneMap：官方导入期重定向要在编辑器导入面板里配 BoneMap 再 Reimport
## （docs: tutorials/assets_pipeline/retargeting_3d_skeletons），而本项目**禁止开编辑器**
## （会掉 Vulkan 锁 + 污染全局类缓存，见 control_checklist §4-17）。故走运行期。
##
## 为什么不用 RetargetModifier3D：它的输入是「导入期已被 BoneMap 改写过轨道路径的动画库」，
## 也就是说它**仍以导入期 BoneMap 为前置**。本工具改为**逐帧采样 + 姿态增量传递**，
## 完全绕开导入期，语义等价且可 headless 自检。
##
## 重定向算法（标准 pose-delta retarget）：
##   1. UAL 骨架实例保留在场景里（Mesh 隐藏），AnimationPlayer 播 UAL 剪辑；
##   2. 每帧对每根映射骨算全局旋转增量 `q_delta = pose_global * rest_global⁻¹`；
##   3. 把该增量施加到**cat 骨的 rest 朝向**上，再换算回 cat 的**局部**姿态写入。
##   ⇒ 只传「关节角度」，不传「骨长」（骨长差异由 rest 天然保持，不会拉断肢体）。
##
## ⚠ headless 下 `AnimationPlayer.seek()` **不更新骨骼姿态**（实测：seek 到t=0/0.4/0.8/1.2
##   读到的 global_pose 完全相同，而直接读轨道 key 明明有运动）⇒ 本工具**必须窗口跑**。
##
## 用法：
##   godot --path . --rendering-driver vulkan --resolution 900x900 res://tools/capture_ual_retarget.tscn
##   可选：`-- proc` 额外拍「当前程序化姿态」同机位对照图
## 产物：tmp_spike/ual_<clip>_<机位>.png / tmp_spike/ual_proc_<机位>.png

const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"
const CAT := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const RIFLE := "res://scenes/weapons/rifle.tscn"
const OUT := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"
const UalBoneMap := preload("res://scripts/entities/ual_bone_map.gd")

## 拍摄计划：[UAL 剪辑名, 采样时刻, 标签]
const SHOTS := [
	["Idle", 0.60, "idle"],
	["Walk", 0.33, "walk"],
	["Pistol_Shoot", 0.10, "shoot"],
	["Death01", 1.20, "death"],
]
## 机位（0 前3/4 ｜ 1 侧面 ｜ 2 背后 ｜ 3 正面）—— **UAL 与程序化对照必须用同一组**
const VIEWS := [0, 1, 2, 3]
## cat 模型世界 AABB 实测（probe_cat_aabb.gd）：x[-1.41,1.41] y[-0.04,2.98] z[-0.51,0.39]
const FOCUS := Vector3(0.0, 0.75, 0.0)
const DIST := 2.6
## 裸 glb 对齐到 MikuModel 组所需的缩放 / 垂直偏移（实测解出，见 _align_to_miku_scale 注释
## 与 tools/probe_align_offset.gd）。**必须与 capture_proc_baseline.gd 的实际取值一致**。
const ALIGN_SCALE := 0.588619
const ALIGN_DY := 0.003426

var _ual_root: Node3D
var _ual_skel: Skeleton3D
var _ual_ap: AnimationPlayer
var _cat_root: Node3D
var _cat_skel: Skeleton3D
var _pairs: Array = []

## 拍摄状态机：_plan 是所有待拍项，_sub 0=摆姿势 1=截屏
var _plan: Array = []
var _sub := 0
var _cam: Camera3D
var _want_proc := false
var _busy := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	_want_proc = "proc" in OS.get_cmdline_user_args()
	_setup_env()

	# —— UAL 源（Mesh 隐藏，只当姿态数据源）——
	_ual_root = (load(UAL) as PackedScene).instantiate() as Node3D
	_ual_root.name = "UalSource"
	add_child(_ual_root)
	_ual_skel = _find_skel(_ual_root)
	_ual_ap = _find_ap(_ual_root)
	for m in _find_meshes(_ual_root):
		(m as MeshInstance3D).visible = false
	if _ual_skel == null or _ual_ap == null:
		print("FATAL: UAL 骨架或 AnimationPlayer 未找到")
		get_tree().quit(1)
		return

	# —— cat 目标（正常渲染）——
	_cat_root = (load(CAT) as PackedScene).instantiate() as Node3D
	_cat_root.name = "CatTarget"
	add_child(_cat_root)
	_cat_skel = _find_skel(_cat_root)
	if _cat_skel == null:
		print("FATAL: cat 骨架未找到")
		get_tree().quit(1)
		return
	var cat_ap := _find_ap(_cat_root)
	if cat_ap != null:
		cat_ap.active = false  # cat 自带 2 条 clip 会覆盖我们的姿态

	_build_pairs()
	_build_plan()
	_align_to_miku_scale()
	print("骨映射配对数 = %d ｜ 待拍 %d 张（UAL %d 组 × %d 机位%s）" % [
		_pairs.size(), _plan.size(), SHOTS.size(), VIEWS.size(),
		"，含程序化对照" if _want_proc else ""])


## MikuModel 会用 `_fit_to_capsule()` 把模型**自动缩放到 `auto_fit_height`**
## （cat_hatsune：裸骨架高 2.435 → 1.433）。裸 glb 不走这段，
## 若不同步，两组截图的角色高度差 1.7 倍、完全无法对比。
func _align_to_miku_scale() -> void:
	# MikuModel 把模型自动缩放到 auto_fit_height（cat_hatsune：裸高 2.435 → 1.433）。
	# 裸 glb 不走 `_fit_to_capsule()`，若不同步，两组截图的角色高度差 1.7倍、完全无法对比。
	#
	# ⚠ 这两个常数是**实测解出来的**，不是估算（tools/probe_align_offset.gd，同进程内
	#   同时实例化两组、量各自骨骼的**世界**高度后解方程）：
	#     MikuModel 组（position.y=0.9）：脚底 y=0.00343、头顶 y=1.43677、身高 1.43335
	#     裸 glb 组（无变换）：        脚底 y=0.00000、头顶 y=2.43510、身高 2.43510
	#     ⇒ scale = 1.43335 / 2.43510 = 0.588619
	#     ⇒ position.y = 0.00343 - 0.0 * 0.588619 = 0.003426
	#   （该探针同时纠正了一个易错点：`Skeleton3D.get_bone_global_pose()` 返回的是
	#     **骨架局部空间**坐标，**不含**节点链的 scale/offset —— 不乘 `global_transform`
	#     的话两组会读出完全相同的 1.23563，对齐会静默失效。）
	# 曾试过「查 MikuModel 内部节点的 scale」自动同步，已放弃：`Miku` 是**孙**节点
	#   （MikuModel / IdleMotion / Miku，见 probe_miku_fit.gd），且它只带 scale 不带净位移，
	#   直接取会差一个 -0.9 ⇒ 改为上面的实测常数。
	_cat_root.scale = Vector3(ALIGN_SCALE, ALIGN_SCALE, ALIGN_SCALE)
	_cat_root.position.y = ALIGN_DY
	print("缩放对齐：scale=%.6f position.y=%.6f（实测对齐 MikuModel 组，见 probe_align_offset.gd）"
		% [ALIGN_SCALE, ALIGN_DY])


func _build_pairs() -> void:
	_pairs.clear()
	for ual_bone in UalBoneMap.UAL_TO_CAT:
		var cat_bone := String(UalBoneMap.UAL_TO_CAT[ual_bone])
		if cat_bone == "":
			continue
		var ui := _ual_skel.find_bone(String(ual_bone))
		var ci := _cat_skel.find_bone(cat_bone)
		if ui < 0 or ci < 0:
			continue
		_pairs.append([ui, ci])


func _build_plan() -> void:
	_plan.clear()
	for s in SHOTS:
		for v in VIEWS:
			_plan.append({"kind": "ual", "clip": String(s[0]), "at": float(s[1]),
				"tag": String(s[2]), "view": int(v)})
	if _want_proc:
		for v in VIEWS:
			_plan.append({"kind": "proc", "tag": "proc", "view": int(v)})


func _process(_d: float) -> void:
	if _busy or _plan.is_empty():
		if _plan.is_empty() and not _busy:
			print("ALL_SHOTS_DONE")
			get_tree().quit(0)
		return

	var job: Dictionary = _plan[0]

	if _sub == 0:
		# —— 摆姿势 ——
		if String(job.kind) == "ual":
			_ual_ap.play(String(job.clip))
			_ual_ap.seek(float(job.at), true, true)
			_ual_skel.force_update_all_bone_transforms()
			_retarget()
			_measure(String(job.tag))
		_aim_camera(int(job.view))
		_sub = 1
		return

	# —— 截屏（必须等一帧真正画完）——
	_sub = 0
	_plan.pop_front()
	_busy = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/ual_%s_%d.png" % [OUT, String(job.tag), int(job.view)]
	img.save_png(path)
	_busy = false
	print("saved %s" % path)


## 逐帧姿态增量传递（见文件头算法说明）
func _retarget() -> void:
	for p in _pairs:
		var ui := int(p[0])
		var ci := int(p[1])
		var u_pose := _ual_skel.get_bone_global_pose(ui)
		var u_rest := _ual_skel.get_bone_global_rest(ui)
		var c_rest := _cat_skel.get_bone_global_rest(ci)

		var q_delta := u_pose.basis.orthonormalized().get_rotation_quaternion() \
			* u_rest.basis.orthonormalized().get_rotation_quaternion().inverse()
		var q_target := q_delta * c_rest.basis.orthonormalized().get_rotation_quaternion()

		var cp := _cat_skel.get_bone_parent(ci)
		var q_parent := Quaternion.IDENTITY
		if cp >= 0:
			q_parent = _cat_skel.get_bone_global_pose(cp).basis.orthonormalized().get_rotation_quaternion()
		_cat_skel.set_bone_pose_rotation(ci, q_parent.inverse() * q_target)
	_cat_skel.force_update_all_bone_transforms()


## 量化「动作是否真的驱动了 cat 骨架」+ 有无穿模/比例失真
func _measure(tag: String) -> void:
	var hl := _pose("hand.L_66")
	var hr := _pose("hand.R_85")
	var fl := _pose("foot.L_97")
	var fr := _pose("foot.R_102")
	var hd := _pose("head_49")
	print("[%-6s] handL=(%.3f,%.3f,%.3f) handR=(%.3f,%.3f,%.3f) 双手距=%.3f | footL.y=%.3f footR.y=%.3f | head.y=%.3f" % [
		tag, hl.x, hl.y, hl.z, hr.x, hr.y, hr.z, hl.distance_to(hr), fl.y, fr.y, hd.y])


func _pose(bone: String) -> Vector3:
	var i := _cat_skel.find_bone(bone)
	if i < 0:
		return Vector3.ZERO
	return _cat_skel.get_bone_global_pose(i).origin


func _aim_camera(view: int) -> void:
	match view:
		0: _cam.position = FOCUS + Vector3(-0.95, 0.28, 1.95)
		1: _cam.position = FOCUS + Vector3(2.20, 0.18, 0.18)
		2: _cam.position = FOCUS + Vector3(0.55, 0.55, -2.05)
		_: _cam.position = FOCUS + Vector3(0.06, 0.15, 2.25)
	_cam.look_at(FOCUS, Vector3.UP)


func _setup_env() -> void:
	_cam = Camera3D.new()
	_cam.name = "Cam"
	_cam.current = true
	_cam.fov = 40.0
	add_child(_cam)
	_aim_camera(0)

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


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var f := _find_ap(c)
		if f != null:
			return f
	return null


func _find_meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_find_meshes(c))
	return out
