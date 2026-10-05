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
## display：套用后写进武器的 display_name（HUD 上显示的名字）
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
		{
			"id": "m4a4", "name": "M4A4", "display": "M4A4 突击步枪",
			"path": "res://assets/models/weapons/m4a4.glb",
			"transform": Transform3D.IDENTITY,
			"muzzle": Vector3(0.0, 0.12, 0.557),
			"view_offset": Vector3(0.17, -0.17, -0.55),
		},
	],
	"USP": [
		{
			"id": "usp_cyrex", "name": "USP-S 赛睿", "display": "USP-S 手枪",
			"path": "res://assets/models/weapons/usp_cyrex.glb",
			# 待校准（见 HANDOFF「已知问题」）：现在疑似前后反 + 偏小（模型里可能有离群杂物几何）
			"transform": Transform3D(Vector3(0.0, 0.0, 0.0001346), Vector3(0.0, 0.0001346, 0.0),
					Vector3(-0.0001346, 0.0, 0.0), Vector3(-0.0077, -0.0207, 0.0175)),
			"muzzle": Vector3(0.0, 0.033, 0.12),
			"view_offset": Vector3(0.16, -0.16, -0.4),
		},
		{
			"id": "pink", "name": "粉色 USP", "display": "粉色 USP",
			"path": "res://assets/models/weapons/pink_pistol.glb",
			"transform": Transform3D(Vector3(-0.08, 0.0, 0.0), Vector3(0.0, 0.08, 0.0),
					Vector3(0.0, 0.0, -0.08), Vector3.ZERO),
			"muzzle": Vector3(0.0, 0.0, 0.146),
			"view_offset": Vector3(0.16, -0.16, -0.4),
		},
	],
	"Knife": [
		{
			# 待校准（见 HANDOFF「已知问题」）：现在刀偏小，疑似 AABB 被杂物几何撑大导致缩放算小
			"id": "knife_fps", "name": "FPS 蝴蝶刀（带翻刃）", "display": "蝴蝶刀",
			"path": "res://assets/models/weapons/knife_fps.glb",
			"transform": Transform3D(Vector3(0.0, 0.0, 0.15), Vector3(0.15, 0.0, 0.0),
					Vector3(0.0, 0.15, 0.0), Vector3(0.0, 0.0, -0.06)),
			"anim": "Scene",
			"view_offset": Vector3(0.16, -0.15, -0.34),
		},
		{
			"id": "hudidao", "name": "蝴蝶刀（hudidao）", "display": "蝴蝶刀",
			"path": "res://assets/models/weapons/butterfly_knife.glb",
			"transform": Transform3D(Vector3(0.0, 0.0, 0.25), Vector3(0.25, 0.0, 0.0),
					Vector3(0.0, 0.25, 0.0), Vector3(0.0, 0.0, -0.125)),
			"view_offset": Vector3(0.16, -0.15, -0.32),
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
		{
			"id": "porcelain", "name": "青花瓷手雷", "display": "青花瓷手雷",
			"path": "res://assets/models/weapons/porcelain_grenade.glb",
			"transform": Transform3D(Vector3(0.6, 0.0, 0.0), Vector3(0.0, 0.6, 0.0),
					Vector3(0.0, 0.0, 0.6), Vector3.ZERO),
			"view_offset": Vector3(0.16, -0.18, -0.34),
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