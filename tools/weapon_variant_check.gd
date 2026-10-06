extends Node
## 武器外观自检 / 校准工具（改完外观拿它核对；不是一次性脚本，先留着）
##
## 阶段 1（RAW）：把指定 glb 原始文件按三个投影面画 ASCII 剪影 + 列出每个 surface 的包围盒 ——
##    用来判断「文件空间里枪口朝哪 / 上方是哪根轴」，以及找「离群杂物几何」
##    （离群几何会把 AABB 撑大，按 AABB 算的缩放 / 对中就会错，USP 和 FPS 蝴蝶刀就是这么偏小的）。
## 阶段 2（变体）：对每个武器槽的每个外观，套到武器场景上打印包围盒 / Muzzle / 零件坐标 + 侧视剪影。
##
## 约定：武器空间里 +Z = 枪口方向、+Y = 上方；剪影右 = +Z、上 = +Y。
## 运行：godot --headless --path . res://tools/weapon_variant_check.tscn
## （要同时看变体阶段就把 RAW_ONLY 改成 false；RAW_MODELS 里放要单独检查的 glb）

const RAW_ONLY := false
const COLS := 108
const ROWS := 34
## 每个网格最多采样这么多面（点云画剪影用）
const MAX_FACES_PER_MESH := 400000

## 原始文件检查清单：[标签, glb 路径]
const RAW_MODELS := [
	["usp_cyrex", "res://assets/models/weapons/usp_cyrex.glb"],
	["knife_fps", "res://assets/models/weapons/knife_fps.glb"],
	["ak47", "res://assets/models/weapons/ak47.glb"],
	["grenade_pubg", "res://assets/models/weapons/grenade_pubg.glb"],
]

var _raw_cases: Array = []
var _cases: Array = []
var _phase := 0
var _raw_node: Node3D
var _weapon: Node3D
var _current_slot := ""
var _current_variant := ""


func _ready() -> void:
	_raw_cases = RAW_MODELS.duplicate()
	for slot in WeaponVariant.VARIANTS:
		for variant in WeaponVariant.VARIANTS[slot]:
			if not ResourceLoader.exists(String(variant.get("path", ""))):
				print("[chk] 跳过 %s/%s：模型文件还没有（%s）" % [slot, variant.get("id", "?"), variant.get("path", "")])
				continue
			_cases.append([String(slot), String(variant["id"])])
	_next_case()


func _process(_delta: float) -> void:
	if _raw_node != null:
		_phase += 1
		if _phase >= 3:
			_report_raw()
			_raw_node.queue_free()
			_raw_node = null
			_next_case()
	elif _weapon != null:
		_phase += 1
		if _phase >= 4:
			_report_variant()
			_weapon.queue_free()
			_weapon = null
			_next_case()


func _next_case() -> void:
	if not _raw_cases.is_empty():
		var entry: Array = _raw_cases.pop_front()
		var packed := load(String(entry[1])) as PackedScene
		if packed == null:
			print("[chk] 跳过 raw %s：文件不在（%s）" % [entry[0], entry[1]])
			_next_case()
			return
		_raw_node = packed.instantiate() as Node3D
		_raw_node.name = String(entry[0])
		add_child(_raw_node)
		_phase = 0
		return
	if RAW_ONLY or _cases.is_empty():
		print("[chk] 全部完成")
		get_tree().quit()
		return
	var slot_entry: Array = _cases.pop_front()
	_current_slot = String(slot_entry[0])
	_current_variant = String(slot_entry[1])
	var scene_path := String(WeaponSkin.WEAPON_SCENES[_current_slot])
	_weapon = (load(scene_path) as PackedScene).instantiate() as Node3D
	_weapon.set_process(false)
	_weapon.set_physics_process(false)
	add_child(_weapon)
	WeaponVariant.apply_to(_weapon, _current_slot, _current_variant)
	_phase = 0


func _report_raw() -> void:
	var points := _sample(_raw_node)
	if points.is_empty():
		print("[chk] raw %s 采样不到顶点" % _raw_node.name)
		return
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for point in points:
		lo = lo.min(point)
		hi = hi.max(point)
	print("[chk] ══ 原始文件 %s ══ 包围盒 x %.3f~%.3f y %.3f~%.3f z %.3f~%.3f 尺寸 %.3f x %.3f x %.3f" % [
		_raw_node.name, lo.x, hi.x, lo.y, hi.y, lo.z, hi.z,
		hi.x - lo.x, hi.y - lo.y, hi.z - lo.z])
	for mesh in _collect_meshes(_raw_node):
		var mesh_xform: Transform3D = _raw_node.global_transform.affine_inverse() * mesh.global_transform
		print("[chk]   网格 %s（%d 个 surface）" % [mesh.name, mesh.mesh.get_surface_count()])
		for index in mesh.mesh.get_surface_count():
			var surface_box := _surface_aabb(mesh.mesh, index)
			if surface_box.size == Vector3.ZERO:
				continue
			surface_box = mesh_xform * surface_box
			print("[chk]     surface %d 顶点 %-7d 中心 %s 尺寸 %s" % [
				index, mesh.mesh.surface_get_array_len(index),
				_format(surface_box.get_center()), _format(surface_box.size)])
	print(_project(points, lo, hi, Vector3.AXIS_Z, Vector3.AXIS_Y, "z-y 面（右=+Z 上=+Y）"))
	print(_project(points, lo, hi, Vector3.AXIS_X, Vector3.AXIS_Y, "x-y 面（右=+X 上=+Y）"))
	print(_project(points, lo, hi, Vector3.AXIS_X, Vector3.AXIS_Z, "x-z 面（右=+X 上=+Z）"))


func _report_variant() -> void:
	var variant := WeaponVariant.find_variant(_current_slot, _current_variant)
	var model := _weapon.get_node_or_null("Model")
	if model == null:
		var packed_probe := load(String(WeaponVariant.find_variant(_current_slot, _current_variant).get("path", ""))) as PackedScene
		var probe: Node = packed_probe.instantiate() if packed_probe != null else null
		print("[chk] %s/%s 没有 Model 子节点！武器现有子节点=%s；glb 根节点类型=%s" % [
			_current_slot, _current_variant, str(_weapon.get_children()),
			probe.get_class() if probe != null else "?"])
		if probe != null:
			probe.free()
		return
	# ⚠ 用**本地变换**，不要用 global_transform：headless 下刚 add_child 的节点还没走帧，
	# global_transform 还是单位阵，会把模型按原始尺度报出来（AK-47 会显示 x 3.7~5.6 这种文件空间数字）。
	# _sample(model) 已经按 model 的本地变换链把点云算到**武器空间**了（model 挂在 _weapon 下），
	# 所以这里直接用返回值，不要再乘 inv。
	var points := _sample(model)
	if points.is_empty():
		print("[chk] %s/%s 采样不到顶点" % [_current_slot, _current_variant])
		return
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for point in points:
		lo = lo.min(point)
		hi = hi.max(point)
	var basis := (model as Node3D).transform.basis
	print("[chk] ══ %s / %s ══" % [variant.get("name", "?"), _current_variant])
	print("[chk]   武器空间包围盒 z %.3f~%.3f（+z 是枪口端）| y %.3f~%.3f | x %.3f~%.3f 尺寸 %.3f x %.3f x %.3f" % [
		lo.z, hi.z, lo.y, hi.y, lo.x, hi.x, hi.x - lo.x, hi.y - lo.y, hi.z - lo.z])
	print("[chk]   轴映射 文件+X→%s 文件+Y→%s 文件+Z→%s" % [
		_format_dir(basis.x), _format_dir(basis.y), _format_dir(basis.z)])
	var muzzle := _weapon.get_node_or_null("Muzzle") as Node3D
	if muzzle != null:
		print("[chk]   Muzzle 在 %s（应落在包围盒 +z 端内侧）" % _format(muzzle.position))
	for mesh in _collect_meshes(model):
		var name_lower := String(mesh.name).to_lower()
		for keyword in ["barrel", "muzzle", "stock", "grip", "magazine", "silencer", "suppressor", "blade", "handle", "lever"]:
			if not name_lower.contains(keyword):
				continue
			# 从 get_faces() 自己算中心（get_aabb 在网格被 trim 重建后不刷新）
			var faces := mesh.mesh.get_faces()
			if faces.is_empty():
				break
			var mlo := Vector3(INF, INF, INF)
			var mhi := Vector3(-INF, -INF, -INF)
			for v in faces:
				mlo = mlo.min(v)
				mhi = mhi.max(v)
			# 网格中心换到武器空间：沿父链累积本地变换
			var chain := Transform3D.IDENTITY
			var cursor: Node = mesh
			while cursor != null and cursor != _weapon:
				if cursor is Node3D:
					chain = (cursor as Node3D).transform * chain
				cursor = cursor.get_parent()
			var center: Vector3 = chain * ((mlo + mhi) * 0.5)
			print("[chk]   零件 %-34s 中心 %s" % [String(mesh.name).substr(0, 34), _format(center)])
			break
	print(_project(points, lo, hi, Vector3.AXIS_Z, Vector3.AXIS_Y,
		"武器空间 z-y 面（右=+Z=枪口方向 上=+Y）",
		muzzle.position if muzzle != null else Vector3.INF))


func _surface_aabb(mesh: Mesh, index: int) -> AABB:
	var box := AABB()
	var first := true
	var arrays := mesh.surface_get_arrays(index)
	if arrays.is_empty():
		return box
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for vertex in vertices:
		if first:
			box = AABB(vertex, Vector3.ZERO)
			first = false
		else:
			box = box.expand(vertex)
	return box


func _sample(root: Node3D) -> PackedVector3Array:
	var points := PackedVector3Array()
	_sample_into(root, Transform3D.IDENTITY, points)
	return points


## 递归累积**本地**变换（不用 global_transform：headless 下没走帧，全局变换还是单位阵）。
func _sample_into(node: Node, acc: Transform3D, points: PackedVector3Array) -> void:
	var here := acc
	if node is Node3D:
		here = acc * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh := node as MeshInstance3D
		var faces := mesh.mesh.get_faces()
		if not faces.is_empty():
			var step := maxi(1, int(faces.size() / float(MAX_FACES_PER_MESH)))
			for i in range(0, faces.size(), step):
				points.append(here * faces[i])
	for child in node.get_children():
		_sample_into(child, here, points)


func _project(points: PackedVector3Array, lo: Vector3, hi: Vector3,
		horiz_axis: int, vert_axis: int, label: String, marker := Vector3.INF) -> String:
	var span_h := maxf(hi[horiz_axis] - lo[horiz_axis], 0.0001)
	var span_v := maxf(hi[vert_axis] - lo[vert_axis], 0.0001)
	var grid: Array = []
	for row in ROWS:
		var line := PackedStringArray()
		line.resize(COLS)
		for col in COLS:
			line[col] = " "
		grid.append(line)
	for point in points:
		var col := int(round((point[horiz_axis] - lo[horiz_axis]) / span_h * (COLS - 1)))
		var row := int(round((hi[vert_axis] - point[vert_axis]) / span_v * (ROWS - 1)))
		grid[row][col] = "#"
	if marker[horiz_axis] < INF:
		var mcol := int(round((marker[horiz_axis] - lo[horiz_axis]) / span_h * (COLS - 1)))
		var mrow := int(round((hi[vert_axis] - marker[vert_axis]) / span_v * (ROWS - 1)))
		if mcol >= 0 and mcol < COLS and mrow >= 0 and mrow < ROWS:
			grid[mrow][mcol] = "M"
	var out := "[chk]   剪影 %s\n" % label
	for row in ROWS:
		out += "       |" + "".join(grid[row]) + "|\n"
	return out


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_meshes(child))
	return out


func _format_dir(dir: Vector3) -> String:
	if dir.length() < 0.000001:
		return "(零)"
	return "%s·%.4f" % [_format(dir.normalized()), dir.length()]


func _format(value: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [value.x, value.y, value.z]