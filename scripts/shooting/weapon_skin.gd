class_name WeaponSkin
extends RefCounted
## 武器皮肤（Esc 菜单里选 + 3D 检视预览）
##
## 皮肤不动模型几何，只给武器「Model」子树里的网格套一层材质覆盖：
##   原版 = 清掉覆盖，用模型自带贴图；
##   其它 = 程序化生成的贴图（伽玛多普勒 / 渐变之色 / 蓝钢）+ 金属 / 粗糙度参数，
##          参考 CS 那种「3D 检视」里的大理石纹宝石刀。
## 选择按武器槽存在静态字典里：player.gd 装备时套用，Esc 菜单切换时立即生效。

const SLOTS := ["Rifle", "USP", "Knife", "Grenade"]
const WEAPON_SCENES := {
	"Rifle": "res://scenes/weapons/rifle.tscn",
	"USP": "res://scenes/weapons/usp.tscn",
	"Knife": "res://scenes/weapons/knife.tscn",
	"Grenade": "res://scenes/weapons/grenade.tscn",
}
const WEAPON_NAMES := {
	"Rifle": "M4A4 步枪", "USP": "USP 手枪", "Knife": "蝴蝶刀", "Grenade": "手雷",
}
const TEXTURE_SIZE := 256

## 槽位 -> 皮肤 id（"" = 原版）
static var selected: Dictionary = {}
static var _material_cache: Dictionary = {}


## 皮肤清单（Esc 菜单列表用）
static func skins() -> Array[Dictionary]:
	return [
		{"id": "", "name": "原版（模型自带贴图）"},
		{"id": "gamma_doppler", "name": "伽玛多普勒 · 绿宝石"},
		{"id": "fade", "name": "渐变之色"},
		{"id": "blue_steel", "name": "蓝钢"},
	]


static func get_selected(slot: String) -> String:
	return String(selected.get(slot, ""))


static func set_selected(slot: String, skin_id: String) -> void:
	selected[slot] = skin_id


## 把皮肤套到武器上（skin_id 为空 = 恢复原版）
static func apply_to(weapon: Node, skin_id: String) -> void:
	var material := build_material(skin_id)
	for mesh in model_meshes(weapon):
		mesh.material_override = material


## 皮肤材质（原版返回 null；同一个皮肤只生成一次）
static func build_material(skin_id: String) -> StandardMaterial3D:
	if skin_id == "":
		return null
	if _material_cache.has(skin_id):
		return _material_cache[skin_id]
	var material := StandardMaterial3D.new()
	material.metallic = 0.9
	match skin_id:
		"gamma_doppler":
			material.albedo_texture = _texture(_gamma_doppler_image)
			material.roughness = 0.16
		"fade":
			material.albedo_texture = _texture(_fade_image)
			material.roughness = 0.28
		"blue_steel":
			material.albedo_texture = _texture(_blue_steel_image)
			material.roughness = 0.34
		_:
			return null
	_material_cache[skin_id] = material
	return material


## 武器「Model」子树里的网格（枪口火光 / 曳光弹这些特效网格不能被皮肤覆盖）
static func model_meshes(weapon: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child in weapon.get_children():
		if String(child.name) == "Model":
			_collect_meshes(child, out)
	return out


static func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_collect_meshes(child, out)


static func _texture(painter: Callable) -> ImageTexture:
	var image: Image = painter.call(TEXTURE_SIZE)
	return ImageTexture.create_from_image(image)


## 伽玛多普勒：黑绿底 + 涡旋状祖母绿 / 青绿大理石纹（相位被两层噪声扭过，像真的大理石）
static func _gamma_doppler_image(size: int) -> Image:
	var stops := [
		[0.0, Color(0.012, 0.028, 0.022)],
		[0.30, Color(0.02, 0.09, 0.07)],
		[0.50, Color(0.03, 0.40, 0.22)],
		[0.66, Color(0.10, 0.88, 0.48)],
		[0.82, Color(0.45, 1.00, 0.86)],
		[1.0, Color(0.86, 1.00, 0.96)],
	]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.009
	noise.fractal_octaves = 4
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var fx := float(x)
			var fy := float(y)
			var n1 := noise.get_noise_2d(fx, fy)
			var n2 := noise.get_noise_2d(fx * 2.3 + 41.0, fy * 2.3 - 17.0)
			var phase := fx * 0.05 + fy * 0.017 + n1 * 3.4 + n2 * 1.2
			var t := clampf(sin(phase) * 0.5 + 0.5, 0.0, 1.0)
			t = pow(t, 1.4)
			image.set_pixel(x, y, _sample(stops, t))
	return image


## 渐变之色：紫 → 粉 → 金 → 黄绿 的对角渐变
static func _fade_image(size: int) -> Image:
	var stops := [
		[0.0, Color(0.33, 0.14, 0.55)],
		[0.35, Color(0.72, 0.30, 0.62)],
		[0.58, Color(0.95, 0.58, 0.26)],
		[0.80, Color(0.93, 0.82, 0.24)],
		[1.0, Color(0.58, 0.80, 0.26)],
	]
	return _ramp_image(size, stops, 0.62, 0.05)


## 蓝钢：深蓝 → 钢蓝 → 亮蓝的斜向渐变
static func _blue_steel_image(size: int) -> Image:
	var stops := [
		[0.0, Color(0.03, 0.05, 0.13)],
		[0.45, Color(0.11, 0.23, 0.45)],
		[0.76, Color(0.38, 0.57, 0.78)],
		[1.0, Color(0.76, 0.86, 0.96)],
	]
	return _ramp_image(size, stops, 0.75, 0.04)


## 通用「斜向渐变 + 一点噪声」贴图
static func _ramp_image(size: int, stops: Array, span: float, jitter: float) -> Image:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.02
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var t := (float(x) + float(y) * 0.55) / float(size) * span
			t += noise.get_noise_2d(x, y) * jitter
			image.set_pixel(x, y, _sample(stops, clampf(t, 0.0, 1.0)))
	return image


## 在色带（[位置, 颜色] 列表，按位置升序）上取色
static func _sample(stops: Array, t: float) -> Color:
	for i in range(stops.size() - 1):
		var a: Array = stops[i]
		var b: Array = stops[i + 1]
		if t <= float(b[0]) or i == stops.size() - 2:
			var span := maxf(float(b[0]) - float(a[0]), 0.0001)
			var k := clampf((t - float(a[0])) / span, 0.0, 1.0)
			return (a[1] as Color).lerp(b[1] as Color, k)
	return stops[stops.size() - 1][1]