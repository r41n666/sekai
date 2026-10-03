extends Node
## 临时截图工具（验证后删除）：离屏渲染武器 / 角色模型，输出多角度 PNG 到 /tmp/shots
## 运行：xvfb-run -a godot --path . res://tools/_tmp_shots.tscn --rendering-driver opengl3

const OUT_DIR := "/tmp/shots"

const ITEMS := {
	"rifle": "res://scenes/weapons/rifle.tscn",
	"usp": "res://scenes/weapons/usp.tscn",
	"grenade": "res://scenes/weapons/grenade.tscn",
	"knife": "res://scenes/weapons/knife.tscn",
	"char_miku": "res://assets/models/miku/miku.glb",
	"char_navy": "res://assets/models/miku_navy/miku_navy.glb",
	"char_maid": "res://assets/models/miku_maid/miku_maid.glb",
	"char_maid2": "res://assets/models/miku_maid/miku_maid2.glb",
}


func _ready() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.19, 0.24)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.8, 0.85)
	e.ambient_light_energy = 1.1
	env.environment = e
	add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -35, 0)
	light.light_energy = 1.7
	add_child(light)

	var cam := Camera3D.new()
	cam.current = true
	add_child(cam)

	for key in ITEMS:
		if not only.is_empty() and not String(key).begins_with(only):
			continue
		var packed := load(ITEMS[key]) as PackedScene
		if packed == null:
			print("[shoot] 加载失败：", ITEMS[key])
			continue
		var holder := Node3D.new()
		add_child(holder)
		var inst := packed.instantiate() as Node3D
		holder.add_child(inst)
		await get_tree().process_frame
		await get_tree().process_frame
		var box := _world_bounds(inst)
		var center := box.get_center()
		var extent: float = maxf(maxf(box.size.x, box.size.y), box.size.z)
		print("[shoot] %s 尺寸=%.3f x %.3f x %.3f" % [key, box.size.x, box.size.y, box.size.z])
		var dirs := [
			Vector3(0.75, 0.45, 1.0), # 前方偏右上（游戏视角）
			Vector3(0.0, 0.25, 1.2),  # 正前方
			Vector3(1.2, 0.25, 0.0),  # 正右侧
		]
		for i in dirs.size():
			var dir: Vector3 = dirs[i].normalized()
			cam.global_position = center + dir * extent * 1.6
			cam.look_at(center, Vector3.UP)
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var path := "%s/%s_%d.png" % [OUT_DIR, key, i]
			img.save_png(path)
			print("[shoot] 已保存 ", path)
		holder.queue_free()
		await get_tree().process_frame

	print("[shoot] 全部完成")
	get_tree().quit()


## 合并节点树里所有 MeshInstance3D 的世界空间包围盒
func _world_bounds(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var meshes: Array[MeshInstance3D] = []
	_collect(root, meshes)
	for m in meshes:
		var aabb: AABB = m.global_transform * m.get_aabb()
		if first:
			box = aabb
			first = false
		else:
			box = box.merge(aabb)
	return box


func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_collect(child, out)