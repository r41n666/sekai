class_name WeaponVariant
extends RefCounted
## 武器外观（模型变体）：每个武器槽可以挂多个模型，Esc 菜单里切换；皮肤继续叠加在模型之上。
##
## 与 WeaponSkin 的分工：
##   - 这里换的是**模型本身**（glb + 在武器节点里的摆放 + 枪口位置 + 第一人称摆放 + 可选动画）；
##   - WeaponSkin 换的是**材质覆盖**（程序化贴图），换模型后会重新套一遍。
##
## 摆放约定：模型在武器空间里「正面朝 +Z（枪口方向）、上方 +Y、对中到原点」。
## ⚠ 注意 Transform3D 的两种写法**互为转置**（踩过坑）：
##   - GDScript 里 Transform3D(Vector3 x轴, Vector3 y轴, Vector3 z轴, Vector3 原点) 传的是**轴向量**（本文件用这种）；
##   - .tscn 里 Transform3D(9 个浮点, 3 个原点) 的 9 个浮点是按**矩阵行**读的（第一行 = 三根轴的 X 分量）。
##   也就是说同一组数字两种写法的结果不一样，手改 .tscn 时必须转置，否则模型会「左右/前后反」。
## 每个槽的第一条 = 默认外观；`player.gd` 装备武器时按静态选择套用。

## 每个槽的模型清单（第一条 = 默认外观）
## transform：Model 节点在武器根下的变换（含旋转 / 缩放 / 对中）
## muzzle：枪口在武器根下的位置（Muzzle / MuzzleLight / MuzzleFlash / GunAudio 会整体跟着挪）
## view_offset / view_yaw_deg：第一人称（V）时的摆放；anim：掏出时播放的动画名
## hide：模型里要删掉的杂项网格（按名字包含匹配）
## trim：按**网格本地坐标** AABB 裁掉离群三角形（[每轴 [min,max]，null=不限]）——
##     glTF 导入器会把 Sketchfab 的 ×100 缩放 / 换轴**烘进顶点**，所以这里用的是导入后的网格
##     本地坐标（可在 tools/weapon_variant_check 的「网格…surface」行或临时脚本里量到），
##     不是 glb 文件里的原始数字；两者差一个缩放+换轴。
## display：套用后写进武器的 display_name（HUD 上显示的名字）
##
## ⚠⚠ 陷阱：`transform` 必须与 `scenes/weapons/*.tscn` 里 Model 节点的占位 transform **一致**，
##   但两者的书写形式语义不同，非对称基会差一个**转置**：
##     · 本表用 `Transform3D(Vector3, Vector3, Vector3, Vector3)` —— 三个向量当**列**；
##     · `.tscn` 用 12 个浮点 —— 分量按**行**解释。
##   对角阵（纯缩放）时行=列所以看不出差别；`ak47` 是首个非对称基，踩过坑：
##   抄错转置会让枪渲染到角色 ~2m 外（实测枪世界 AABB 中心距角色 2.20 m）。
##   ⚠ 且 `.tscn` **不支持 `##` / `//` 注释**（那是 GDScript 的），写进去会 `Parse error`、
##     整个场景加载失败 —— 故说明只能写在这里。
##   ⇒ 改任一处的 transform，都要同步另一处，并用 `tools/weapon_variant_check.tscn` 复核
##     「武器空间包围盒」（ak47 应为 0.062 × 0.252 × 0.880、muzzle z=0.45）。
##   ⇒ 为什么 .tscn 里也要有一份：`apply_variant` 只在 `is_multiplayer_authority()` 时被调，
##     联机时**远端玩家的枪**走不到那条路，只能靠场景占位值。
const VARIANTS := {
	"Rifle": [
		{
			"id": "ak47", "name": "AK-47", "display": "AK-47 突击步枪",
			"path": "res://assets/models/weapons/ak47.glb",
			"transform": Transform3D(Vector3(0.0, 0.0, 0.4591), Vector3(0.0, 0.4591, 0.0),
					Vector3(-0.4591, 0.0, 0.0), Vector3(0.1813, -0.028, -2.148)),
			"muzzle": Vector3(0.0, 0.078, 0.45),
			"view_offset": Vector3(0.18, -0.17, -0.6),
		},
	],
	"USP": [
		{
			# 已校准（2026-10-07 修正「USP 没有枪管」）：
			# 旧版这里配过一条几何裁剪 `"trim": [null, null, [null, 11.0]]`，注释声称切掉「4 组浮空小圈」。
			# 但渲染对比（tools/weapon_render_compare）+ 探针实测推翻了该判断：那 4 组「小圈」其实是
			# **消音器上的环形分段**；裁掉本地 z>11 等于把整段消音器 + 枪管前端齐刷刷切掉
			# （裁剪后只剩套筒前半截，看着就像"没有枪管"）。⇒ 删掉 trim，整枪（含消音器）完整保留。
			# 长度复核：原文件全长 1782.64 单位；旧 scale=0.000232 是按**裁剪后**的 949 单位算的（0.22 m）。
			#   同 scale 下未裁剪全长 = 1782.64 × 0.000232 ≈ 0.4135 m —— 正是**带消音器的 USP-S 真实长度**，
			#   故 scale 保持不变，只用**未裁剪的完整包围盒**重新对中（origin 见下）。
			# 轴映射：after-inner X(枪管轴) → 武器 ∓Z、Y → +Y、Z → +X；消音器在武器 +Z 端，枪口落在 +Z 端内侧。
			# 实测（tools/_tmp_usp_probe，未裁剪整枪）：武器空间 bbox z −0.1102~0.3034（长 0.4136）、
			#   中心 z=0.0966 → 把 origin.z 减去 0.0966 即主体中心归零（新 bbox z ≈ −0.2068~0.2068）。
			#   消音器段（网格局部 z>11）bbox y 0.0392~0.0790（轴 y≈0.059）、z 0.1122~0.3034 → 是 0.04 径 × 0.19 长的圆筒。
			#   Muzzle 放消音器尖端（+z 端 0.2068）内侧 0.01 ≈ z 0.197、取消音器轴高 y 0.059。
			"id": "usp_cyrex", "name": "USP-S 赛睿", "display": "USP-S 手枪",
			"path": "res://assets/models/weapons/usp_cyrex.glb",
			"transform": Transform3D(Vector3(0.0, 0.0, -0.000232), Vector3(0.0, 0.000232, 0.0),
					Vector3(0.000232, 0.0, 0.0), Vector3(0.013168, -0.035667, -0.030127)),
			"muzzle": Vector3(0.0, 0.059, 0.197),
			"view_offset": Vector3(0.16, -0.16, -0.4),
		},
	],
	"Knife": [
		{
			# 已校准：文件里含**两组**网格 —— `Object_79` 是蝴蝶刀本体，`Object_65` 是 Sketchfab 打包时
			# 混进来的第一人称手臂/睫毛杂物（1.669 宽 = 两只手张开，六根 Mixamo 手臂骨）——它就是离群几何，
			# 旧 scale 0.15 是按它的 1.669 宽算的，所以刀偏小到只有 1/5。用 hide 删掉它。
			# ⚠ glTF 内层节点链（Sketchfab_model 的 -90° + fbx 的 ×0.01/换轴）**已经把刀摆成 +Z 朝向**：
			#   导入后 Object_79 的包围盒是 0.0106(x) × 0.0392(y) × 0.3072(z)，刀尖在 +Z 的 0.1245、
			#   刀尾在 -0.1826。所以 Model 根**只需要缩放 + 对中，不要再转**——
			#   之前那版带旋转的基（y_axis=(0,0,s)）等于在已经摆正的刀上又转了 90°，刀躺到了 +Y 轴上。
			#   按主体长 0.3072 重算 scale=0.9115（≈0.28 m，与已删除的 hudidao 蝴蝶刀一致），
			#   对中平移 z=+0.02648（把 [-0.1826, 0.1245] 的中点挪到原点）。
			"id": "knife_fps", "name": "FPS 蝴蝶刀（带翻刃）", "display": "蝴蝶刀",
			"path": "res://assets/models/weapons/knife_fps.glb",
			"transform": Transform3D(Vector3(0.9115, 0.0, 0.0), Vector3(0.0, 0.9115, 0.0),
					Vector3(0.0, 0.0, 0.9115), Vector3(0.0, 0.0, 0.02648)),
			"hide": ["Object_65"],
			"anim": "Scene",
			# 刀现在有正确的 0.28 m 长（旧值偏小到 1/5），原先 -0.32 的贴近摆法会让刀整个掉到画面
			# 右下角外，所以把摆放往后推远一点、略抬高，和 AK-47 的第一人称取景对齐。
			"view_offset": Vector3(0.18, -0.20, -0.56),
		},
	],
	"Grenade": [
		{
			"id": "grenade_pubg", "name": "M67 手雷", "display": "M67 手雷",
			"path": "res://assets/models/weapons/grenade_pubg.glb",
			"transform": Transform3D(Vector3(0.0132, 0.0, 0.0), Vector3(0.0, 0.0132, 0.0),
					Vector3(0.0, 0.0, 0.0132), Vector3(-0.0013, -0.058, 0.0157)),
			"view_offset": Vector3(0.16, -0.18, -0.36),
		},
	],
}

## 槽位 -> 变体 id
static var selected: Dictionary = {}


static func variants_for(slot: String) -> Array:
	return VARIANTS.get(slot, [])


static func find_variant(slot: String, variant_id: String) -> Dictionary:
	for variant in variants_for(slot):
		if String(variant.get("id", "")) == variant_id:
			return variant
	return {}


static func default_id(slot: String) -> String:
	var list := variants_for(slot)
	if list.is_empty():
		return ""
	return String(list[0].get("id", ""))


static func get_selected(slot: String) -> String:
	return String(selected.get(slot, default_id(slot)))


static func set_selected(slot: String, variant_id: String) -> void:
	selected[slot] = variant_id


## 当前武器身上的变体 id（首次装备时还没套过，返回的是菜单里选中的外观）
static func current_id(weapon: Node, slot: String) -> String:
	var value: Variant = weapon.get_meta("variant_id", "")
	if value is String and String(value) != "":
		return String(value)
	return get_selected(slot)


## Esc 菜单 / 3D 检视用：当前槽选中的外观名字（找不到就返回槽位名）
static func display_name(slot: String) -> String:
	var variant := find_variant(slot, get_selected(slot))
	return String(variant.get("name", slot))


## 把变体套到武器上：换 Model 子节点 + 挪枪口 + 设第一人称摆放 + 重新套皮肤
static func apply_to(weapon: Node, slot: String, variant_id: String) -> void:
	var variant := find_variant(slot, variant_id)
	if variant.is_empty() or weapon == null:
		return
	var applied := String(weapon.get_meta("variant_id", ""))
	if applied == variant_id and weapon.get_node_or_null("Model") != null:
		return # 已经是这个外观，不用重建（首次装备时 meta 为空，即使选的正是默认外观也要换掉场景里的旧模型）
	weapon.set_meta("variant_id", variant_id)

	var packed := load(String(variant["path"])) as PackedScene
	if packed == null:
		push_warning("WeaponVariant：模型加载失败 %s" % variant["path"])
		return
	var model := packed.instantiate() as Node3D
	if model == null:
		return
	model.name = "Model"
	var custom: Variant = variant.get("transform")
	if custom is Transform3D:
		model.transform = custom
	var hide: Variant = variant.get("hide", [])
	if hide is Array:
		for keyword in hide:
			_hide_nodes(model, String(keyword))
	# 几何裁剪：有些 Sketchfab 模型把离群杂物（浮空小圈 / 占位几何）和枪身塞进同一个 surface，
	# 没法按节点名删。`trim` 给一个**文件空间** AABB（每轴 [min, max]，null = 不限），
	# 只保留三个顶点都落在框内的三角形（重建 surface），用来剔掉撑大包围盒的离群几何。
	var trim: Variant = variant.get("trim")
	if trim is Array:
		_trim_meshes(model, trim)

	var old := weapon.get_node_or_null("Model")
	if old != null:
		old.name = "ModelOld" # 先改名，新模型才能叫 Model（WeaponSkin / 检视都按名字找）
		old.queue_free()
	weapon.add_child(model)

	# 枪口整体跟着新模型走（曳光弹 / 火光 / 枪声都挂在 Muzzle 上）
	var muzzle_pos: Variant = variant.get("muzzle")
	if muzzle_pos is Vector3 and weapon.get_node_or_null("Muzzle") != null:
		var delta: Vector3 = (muzzle_pos as Vector3) - (weapon.get_node("Muzzle") as Node3D).position
		for node_name in ["Muzzle", "MuzzleLight", "MuzzleFlash", "GunAudio"]:
			var node := weapon.get_node_or_null(node_name) as Node3D
			if node != null:
				node.position += delta

	# 第一人称摆放（枪长刀短，每个模型不一样）
	var view_offset: Variant = variant.get("view_offset")
	if view_offset is Vector3 and "view_offset" in weapon:
		weapon.set("view_offset", view_offset)
	var view_yaw: Variant = variant.get("view_yaw_deg")
	if view_yaw != null and "view_yaw_deg" in weapon:
		weapon.set("view_yaw_deg", float(view_yaw))
	# HUD 武器名
	var display: Variant = variant.get("display")
	if display is String and String(display) != "" and "display_name" in weapon:
		weapon.set("display_name", String(display))

	# 新网格没有材质覆盖，皮肤要重新套一遍
	if weapon.has_method("apply_skin"):
		weapon.apply_skin(WeaponSkin.get_selected(slot))


## 掏出武器时播放变体自带的动画（例如蝴蝶刀翻刃）；没有动画的变体什么都不做
static func play_intro(weapon: Node, slot: String) -> void:
	var variant := find_variant(slot, current_id(weapon, slot))
	var clip := String(variant.get("anim", ""))
	if clip == "":
		return
	var player := _find_animation_player(weapon.get_node_or_null("Model"))
	if player == null or not player.has_animation(clip):
		return
	player.stop()
	player.play(clip)


static func _hide_nodes(node: Node, keyword: String) -> void:
	if keyword == "":
		return
	if node != null and String(node.name).to_lower().contains(keyword.to_lower()):
		node.queue_free()
		return
	for child in node.get_children():
		_hide_nodes(child, keyword)


## 按**网格本地坐标** AABB 裁掉网格里落在框外的三角形（每个 surface 重建一份）。
## bounds 形如 [[min_x, max_x], [min_y, max_y], [min_z, max_z]]，任意一轴填 null 表示不限。
## ⚠ bounds 用的是 surface_get_arrays 里顶点的**本地坐标**——glTF 导入器会把 Sketchfab 的
## ×100 缩放 / 换轴烘进顶点，所以和 glb 文件里的原始数字差一个缩放+换轴，量的时候要看导入后的值。
## 用来剔除 Sketchfab 转出的「离群杂物几何」（浮空小圈 / 占位体）——它们和枪身同在一个
## surface 里，按名字删不掉，却会把 AABB 撑大、让按 AABB 算的缩放 / 对中全偏。
## 注意：ArrayMesh 的 get_aabb() 重建后**不会自动刷新**（会留着旧值），核对时要用 get_faces() 自己算。
static func _trim_meshes(root: Node, bounds: Array) -> void:
	for mesh in _collect_meshes(root):
		var count := mesh.mesh.get_surface_count()
		if count == 0:
			continue
		var arrays := mesh.mesh.surface_get_arrays(0)
		if arrays.is_empty() or not (arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array):
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			continue
		var kept := PackedInt32Array()
		for i in range(0, indices.size() - 2, 3):
			var a := indices[i]
			var b := indices[i + 1]
			var c := indices[i + 2]
			if _inside(vertices[a], bounds) and _inside(vertices[b], bounds) and _inside(vertices[c], bounds):
				kept.append(a)
				kept.append(b)
				kept.append(c)
		if kept.size() == indices.size():
			continue # 没裁掉任何东西
		var new_mesh := ArrayMesh.new()
		var new_arrays := arrays.duplicate()
		new_arrays[Mesh.ARRAY_INDEX] = kept
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, new_arrays)
		new_mesh.surface_set_material(0, mesh.mesh.surface_get_material(0))
		mesh.mesh = new_mesh


static func _inside(point: Vector3, bounds: Array) -> bool:
	for axis in 3:
		var range_value: Variant = bounds[axis] if axis < bounds.size() else null
		if range_value is Array and (range_value as Array).size() == 2:
			var lo: Variant = (range_value as Array)[0]
			var hi: Variant = (range_value as Array)[1]
			if lo != null and point[axis] < float(lo):
				return false
			if hi != null and point[axis] > float(hi):
				return false
	return true


static func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_meshes(child))
	return out


static func _find_animation_player(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	if root is AnimationPlayer:
		return root
	for child in root.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null