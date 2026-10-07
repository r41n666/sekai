extends Node3D
## 武器外观渲染对比工具（正式版）——把任意「武器槽 + 变体 id」渲染成侧视 PNG，
## 用于肉眼复核武器外观：裁剪（trim）有没有切掉不该切的东西、比例对不对、枪口位置是否合理。
##
## 由来：本工具的前身是临时诊断脚本 `_usp_compare.gd`（回答「为什么 USP 没有枪管」）。
## 那次发现 `usp_cyrex` 的 `"trim": [null, null, [null, 11.0]]` 把整段消音器切掉了，故转正留用。
##
## 用法：
##   godot --path . --rendering-driver vulkan --resolution 1000x420 res://tools/weapon_render_compare.tscn
##   （无头机加 xvfb-run -a；本机 Windows 直接跑）
##
## 产物（OUT_DIR 下）：
##   <OUT_TAG>.png          变体表「原样」：套用 transform + trim（= 游戏里实际用的样子）
##   <OUT_TAG>_notrim.png   禁用 trim（= 模型原始几何，用来对比「trim 到底切掉了什么」）
##   变体没有 trim 时，两张图相同。
##
## 改下面三个常量即可对比任意武器外观；相机按模型包围盒自动取景（大小自适应，换枪不用改代码）。

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"
## 要渲染的槽位 + 变体 id（见 scripts/shooting/weapon_variant.gd 的 VARIANTS）
const SLOT := "USP"
const VARIANT_ID := "usp_cyrex"
## 输出文件名前缀（产物 = <OUT_TAG>.png / <OUT_TAG>_notrim.png）
const OUT_TAG := "usp_fixed"
## 是否额外渲染「禁用 trim」的原始几何
const RENDER_NOTRIM := true
## 相机参数：竖直视野角（度）与取景留白倍率
const FOV_DEG := 30.0
const MARGIN := 1.25
## 每个网格采样顶点上限（算包围盒用）
const MAX_FACES_PER_MESH := 400000

var _cam: Camera3D
var _root: Node3D


func _ready() -> void:
	_cam = Camera3D.new()
	_cam.name = "Cam"
	_cam.current = true
	_cam.fov = FOV_DEG
	add_child(_cam)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-25, 40, 0)
	light.light_energy = 1.8
	add_child(light)
	var light2 := DirectionalLight3D.new()
	light2.rotation_degrees = Vector3(20, -130, 0)
	light2.light_energy = 0.9
	add_child(light2)

	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.18, 0.19, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.68)
	e.ambient_light_energy = 0.8
	we.environment = e
	add_child(we)

	_run()


func _run() -> void:
	var variant: Dictionary = WeaponVariant.find_variant(SLOT, VARIANT_ID)
	if variant.is_empty():
		push_error("找不到变体 %s/%s" % [SLOT, VARIANT_ID])
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	# 原样（套 trim）
	_spawn(variant, true)
	await _shoot(OUT_TAG)
	if RENDER_NOTRIM:
		_spawn(variant, false)
		# 重建后多等两帧，确保新网格已上传、旧网格已释放
		await get_tree().process_frame
		await get_tree().process_frame
		await _shoot("%s_notrim" % OUT_TAG)
	print("[render] 完成，图在 %s/%s*.png" % [OUT_DIR, OUT_TAG])
	get_tree().quit(0)


## 生成模型：按变体表套 transform，并按 with_trim 决定是否套 trim（几何裁剪）
func _spawn(variant: Dictionary, with_trim: bool) -> void:
	if _root != null and is_instance_valid(_root):
		_root.free()
	var packed := load(String(variant["path"])) as PackedScene
	if packed == null:
		push_error("模型加载失败 %s" % variant["path"])
		get_tree().quit(1)
		return
	_root = packed.instantiate() as Node3D
	var xform: Variant = variant.get("transform")
	if xform is Transform3D:
		_root.transform = xform
	if with_trim:
		var trim: Variant = variant.get("trim")
		if trim is Array:
			WeaponVariant._trim_meshes(_root, trim)
	add_child(_root)
	_frame_camera()
	print("[render] 已生成（套 trim = %s）%s/%s" % ["开" if with_trim else "关", SLOT, VARIANT_ID])


## 把相机摆到 +X 正对模型（画面横轴 = 武器空间 Z，纵轴 = Y），按包围盒自动取景
func _frame_camera() -> void:
	var points := _sample(_root)
	if points.is_empty():
		_cam.position = Vector3(0.6, 0.0, 0.0)
		_cam.rotation_degrees = Vector3(0, 90, 0)
		return
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p in points:
		lo = lo.min(p)
		hi = hi.max(p)
	var center := (lo + hi) * 0.5
	var size := hi - lo
	var aspect := 1.0
	var vp := get_viewport()
	if vp != null:
		var s := vp.get_visible_rect().size
		if s.y > 0.0:
			aspect = maxf(s.x / s.y, 0.0001)
	var tan_v := tan(deg_to_rad(FOV_DEG) * 0.5)
	var d_v := (size.y * 0.5) / maxf(tan_v, 0.0001)
	var d_h := (size.z * 0.5) / maxf(tan_v * aspect, 0.0001)
	var dist := maxf(d_v, d_h) * MARGIN
	_cam.position = Vector3(center.x + dist, center.y, center.z)
	_cam.rotation_degrees = Vector3(0, 90, 0)


func _shoot(name_tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name_tag]
	img.save_png(path)
	print("[render] saved %s" % path)


## 采样模型顶点到「武器空间」（递归累乘本地变换，避免 headless 下 global_transform 未传播）
func _sample(root: Node3D) -> PackedVector3Array:
	var points := PackedVector3Array()
	_sample_into(root, Transform3D.IDENTITY, points)
	return points


func _sample_into(node: Node, acc: Transform3D, points: PackedVector3Array) -> void:
	var here := acc
	if node is Node3D:
		here = acc * (node as Node3D).transform
	if node is MeshInstance3D:
		var faces := (node as MeshInstance3D).mesh.get_faces()
		if not faces.is_empty():
			var step := maxi(1, int(faces.size() / float(MAX_FACES_PER_MESH)))
			for i in range(0, faces.size(), step):
				points.append(here * faces[i])
	for child in node.get_children():
		_sample_into(child, here, points)
