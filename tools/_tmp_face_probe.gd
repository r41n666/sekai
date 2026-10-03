extends Node
## 临时排查（验证后删除）：列出角色模型每个网格的材质 / 贴图，用来定位「眼睛不见了」这类问题。
## 运行：xvfb-run -a /tmp/godotbin/Godot_v4.7.2-stable_linux.x86_64 --path . res://tools/_tmp_face_probe.tscn --rendering-driver opengl3

const OUT_DIR := "/tmp/face_probe"
const MODEL := "res://assets/models/miku_navy/miku_navy.glb"

var _cam: Camera3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_setup_env()
	_cam = Camera3D.new()
	_cam.current = true
	add_child(_cam)
	var packed := load(MODEL) as PackedScene
	var root := packed.instantiate() as Node3D
	add_child(root)
	var meshes := _collect_meshes(root)
	print("[probe] 网格数=%d" % meshes.size())
	var target: MeshInstance3D = meshes[0]
	for mesh in meshes:
		var array_mesh := mesh.mesh as ArrayMesh
		var surfaces := array_mesh.get_surface_count() if array_mesh != null else 0
		print("[probe]   %s 表面数=%d" % [mesh.name, surfaces])
		for s in surfaces:
			var mat := array_mesh.surface_get_material(s) as StandardMaterial3D
			var info := "(无材质)"
			if mat != null:
				var tex := mat.albedo_texture
				var tex_name := tex.resource_path.get_file() if tex != null else "(无贴图)"
				info = "%s | 透明=%d 双面=%d no_depth=%s 优先级=%d 反照=$(%.2f,%.2f,%.2f)" % [
					tex_name, mat.transparency, int(mat.cull_mode),
					mat.no_depth_test, mat.render_priority,
					mat.albedo_color.r, mat.albedo_color.g, mat.albedo_color.b]
			print("[probe]     [%d] %s" % [s, info])
	# 把「皮肤 / 脸」表面变透明，看眼睛网格是不是被脸挡在后面
	var ghost := StandardMaterial3D.new()
	ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost.albedo_color = Color(1, 1, 1, 0)
	ghost.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var head := root.global_position + Vector3(0, 19.6, 0.9) # PMX 单位：身高约 23.8，脸在 19.6 附近
	for hidden in [[0, 1], [0, 1, 4, 5], [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11]]:
		for s in hidden:
			target.set_surface_override_material(s, ghost)
		_aim(head + Vector3(0.9, 0.35, 3.2), head)
		await _capture("hide_%s" % str(hidden).replace("[", "").replace("]", "").replace(", ", "_"))
		for s in hidden:
			target.set_surface_override_material(s, null)
	# 正常渲染（对照）
	_aim(head + Vector3(0.9, 0.35, 3.2), head)
	await _capture("normal")
	# 灰模渲染：手臂上的彩色条纹如果是贴图问题，这里就会消失
	var clay := StandardMaterial3D.new()
	clay.albedo_color = Color(0.85, 0.85, 0.88)
	clay.roughness = 0.5
	for s in range(23):
		target.set_surface_override_material(s, clay)
	_aim(root.global_position + Vector3(2.0, 16.5, 4.5), root.global_position + Vector3(0.9, 16.0, 0))
	await _capture("clay_upper")
	# 贴图 V 方向对照：把 UV 的 V 再翻一次，看手臂的颜色条 / 脸是不是就对了
	for s in range(23):
		target.set_surface_override_material(s, null)
	_aim(root.global_position + Vector3(2.0, 16.5, 4.5), root.global_position + Vector3(0.9, 16.0, 0))
	await _capture("upper_normal")
	var flipped := ArrayMesh.new()
	for s in range(23):
		var arrays := target.get_mesh().surface_get_arrays(s)
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		for i in uvs.size():
			uvs[i] = Vector2(uvs[i].x, 1.0 - uvs[i].y)
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		flipped.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		flipped.surface_set_material(s, target.mesh.surface_get_material(s))
	target.mesh = flipped
	_aim(root.global_position + Vector3(2.0, 16.5, 4.5), root.global_position + Vector3(0.9, 16.0, 0))
	await _capture("upper_uv_flip")
	_aim(head + Vector3(0.9, 0.35, 3.2), head)
	await _capture("face_uv_flip")
	print("[probe] 完成")
	get_tree().quit()


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_meshes(child))
	return out


func _aim(from: Vector3, to: Vector3) -> void:
	_cam.global_position = from
	_cam.look_at(to, Vector3.UP)
	_cam.make_current()


func _capture(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT_DIR, tag])


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
	light.rotation_degrees = Vector3(-35, -25, 0)
	light.light_energy = 1.6
	add_child(light)