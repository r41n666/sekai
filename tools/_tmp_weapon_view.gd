extends Node
## 临时渲染（验证后删除）：单件武器多角度出图，用来确认模型朝向 / 尺寸 / 材质。
## 运行：xvfb-run -a /tmp/godotbin/Godot_v4.7.2-stable_linux.x86_64 --path . res://tools/_tmp_weapon_view.tscn --rendering-driver opengl3

const OUT_DIR := "/tmp/weapon_shots"

var _cam: Camera3D
var _pivot: Node3D


func _ready() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_setup_env()
	_pivot = Node3D.new()
	add_child(_pivot)
	_cam = Camera3D.new()
	_cam.current = true
	add_child(_cam)

	var entries := [
		["knife", "res://scenes/weapons/knife.tscn"],
		["rifle", "res://scenes/weapons/rifle.tscn"],
		["usp", "res://scenes/weapons/usp.tscn"],
		["grenade", "res://scenes/weapons/grenade.tscn"],
	]
	for entry in entries:
		var inst := (load(entry[1]) as PackedScene).instantiate() as Node3D
		inst.name = entry[0]
		_pivot.add_child(inst)
		inst.set_process(false)
		inst.set_physics_process(false)
		await _wait(0.25)
		print("[view] %s 可见网格 AABB=%s" % [entry[0], _aabb_of(inst)])
		for tag in [["front", Vector3(0, 0.12, 0.7)], ["side", Vector3(0.7, 0.12, 0)], ["quarter", Vector3(0.5, 0.42, 0.5)]]:
			_aim(tag[1], Vector3(0, 0.12, 0))
			await _capture("%s_%s" % [entry[0], tag[0]])
		# 灰模渲染：只看形状 / 朝向（贴图验证用上面的彩色图）
		var clay := StandardMaterial3D.new()
		clay.albedo_color = Color(0.82, 0.82, 0.86)
		clay.roughness = 0.55
		for mesh in _collect_meshes(inst):
			if mesh.visible:
				mesh.material_override = clay
		for tag in [["clay_side", Vector3(0.7, 0.12, 0)], ["clay_quarter", Vector3(0.5, 0.42, 0.5)]]:
			_aim(tag[1], Vector3(0, 0.12, 0))
			await _capture("%s_%s" % [entry[0], tag[0]])
		_pivot.remove_child(inst)
		inst.queue_free()
	print("[view] 完成")
	get_tree().quit()


func _aabb_of(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mesh in _collect_meshes(node):
		var b: AABB = mesh.get_aabb()
		var corners: Array[Vector3] = []
		for i in 8:
			corners.append(mesh.global_transform * (b.position + Vector3(
				b.size.x * (i & 1), b.size.y * ((i >> 1) & 1), b.size.z * ((i >> 2) & 1)
			)))
		for c in corners:
			if first:
				box = AABB(c, Vector3.ZERO)
				first = false
			else:
				box = box.expand(c)
	return box


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D and node.visible:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_meshes(child))
	return out


func _setup_env() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.19, 0.24)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.85, 0.88, 0.95)
	e.ambient_light_energy = 1.2
	env.environment = e
	add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -35, 0)
	light.light_energy = 1.8
	add_child(light)
	var light2 := DirectionalLight3D.new()
	light2.rotation_degrees = Vector3(-20, 150, 0)
	light2.light_energy = 0.7
	add_child(light2)


func _aim(from: Vector3, to: Vector3) -> void:
	_cam.global_position = from
	_cam.look_at(to, Vector3.UP)
	_cam.make_current()


func _capture(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT_DIR, tag])


func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame