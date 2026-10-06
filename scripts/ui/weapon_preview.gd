class_name WeaponPreview
extends SubViewportContainer
## 武器 3D 检视（Esc 菜单右侧）：SubViewport 里放一把武器慢慢自转，像 buff / CS 的 3D 检视。
##
## - 自带独立 3D 世界（own_world_3d）+ 程序化天空，金属皮肤才有反射；
## - 换武器时按模型包围盒自动取景（步枪 0.9 米、手雷 0.1 米都能拍全）；
## - 只有菜单打开时才转（show_weapon / set_preview_active 控制）。

## 自转速度（弧度/秒）
@export var rotate_speed := 0.9

var _pivot: Node3D
var _camera: Camera3D
var _weapon: Node3D


func _ready() -> void:
	stretch = true
	var viewport := SubViewport.new()
	viewport.name = "Viewport"
	viewport.size = Vector2i(380, 240)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.16, 0.2, 0.28)
	sky_material.sky_horizon_color = Color(0.3, 0.34, 0.42)
	sky_material.ground_bottom_color = Color(0.06, 0.07, 0.09)
	sky_material.ground_horizon_color = Color(0.24, 0.26, 0.3)
	sky.sky_material = sky_material
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.7, 0.82)
	env.ambient_light_energy = 0.9
	world_env.environment = env
	viewport.add_child(world_env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, -42, 0)
	key.light_energy = 1.9
	viewport.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-12, 145, 0)
	rim.light_color = Color(0.75, 0.85, 1.0)
	rim.light_energy = 0.8
	viewport.add_child(rim)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 40.0
	viewport.add_child(_camera)

	_pivot = Node3D.new()
	viewport.add_child(_pivot)
	set_process(false)


## 显示指定武器 + 外观（当前槽选中的模型变体）+ 皮肤（皮肤 id 为空 = 原版）
func show_weapon(slot: String, skin_id: String) -> void:
	if _weapon != null and is_instance_valid(_weapon):
		_weapon.queue_free()
		_weapon = null
	_pivot.rotation = Vector3.ZERO
	_pivot.position = Vector3.ZERO
	var path := String(WeaponSkin.WEAPON_SCENES.get(slot, ""))
	if path == "" or not ResourceLoader.exists(path):
		return
	_weapon = (load(path) as PackedScene).instantiate() as Node3D
	_weapon.set_process(false)
	_weapon.set_physics_process(false)
	# 先换外观（会顺带重套皮肤），这样检视里看到的就是手上的那把
	if _weapon.has_method("apply_variant"):
		_weapon.apply_variant(WeaponVariant.get_selected(slot))
	if _weapon.has_method("apply_skin"):
		_weapon.apply_skin(skin_id)
	_pivot.add_child(_weapon)
	WeaponVariant.play_intro(_weapon, slot) # 有开场动画的外观（蝴蝶刀翻刃）在检视里也演一遍
	await get_tree().process_frame # 等旧模型真正释放后再按包围盒取景
	if is_instance_valid(_weapon):
		_frame()


## 菜单打开 / 关闭时开关自转
func set_preview_active(active: bool) -> void:
	set_process(active)


func _process(delta: float) -> void:
	if _pivot != null:
		_pivot.rotate_y(delta * rotate_speed)


## 按包围盒取景：把模型中心挪到原点，相机从右上前方看过去
func _frame() -> void:
	_weapon.position = Vector3.ZERO
	var box := _weapon_aabb()
	if box.size.length() <= 0.0001:
		_camera.position = Vector3(0.5, 0.4, 0.7)
		_camera.look_at(Vector3.ZERO, Vector3.UP)
		return
	var center := box.get_center()
	_weapon.position -= center
	var radius := maxf(box.size.length() * 0.5, 0.04)
	var distance := radius * 2.4
	_camera.position = Vector3(distance * 0.6, distance * 0.42, distance * 0.72)
	_camera.look_at(Vector3.ZERO, Vector3.UP)


func _weapon_aabb() -> AABB:
	var box := AABB()
	var first := true
	for mesh in _collect_meshes(_weapon):
		if not mesh.visible:
			continue
		var local := mesh.get_aabb()
		var transform := _pivot.global_transform.affine_inverse() * mesh.global_transform
		for corner_index in 8:
			var corner := local.position + Vector3(
				local.size.x * (corner_index & 1),
				local.size.y * ((corner_index >> 1) & 1),
				local.size.z * ((corner_index >> 2) & 1)
			)
			var point := transform * corner
			if first:
				box = AABB(point, Vector3.ZERO)
				first = false
			else:
				box = box.expand(point)
	return box


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_meshes(child))
	return out