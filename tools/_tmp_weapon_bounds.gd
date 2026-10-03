extends Node
## 临时验证（验证后删除）：打印武器场景里各 MeshInstance3D 的世界包围盒 + 模型子节点变换
## 运行：godot --headless --path . res://tools/_tmp_weapon_bounds.tscn

func _ready() -> void:
	for path in ["res://scenes/weapons/rifle.tscn", "res://scenes/weapons/usp.tscn",
			"res://scenes/weapons/grenade.tscn", "res://scenes/weapons/knife.tscn"]:
		var packed := load(path) as PackedScene
		if packed == null:
			print("[bounds] 加载失败 ", path)
			continue
		var inst := packed.instantiate() as Node3D
		add_child(inst)
		print("==== %s ====" % path.get_file())
		var meshes: Array[MeshInstance3D] = []
		_collect(inst, meshes)
		for m in meshes:
			var aabb: AABB = m.global_transform * m.get_aabb()
			print("  网格 %-16s 世界尺寸=%.3f x %.3f x %.3f 中心=(%.3f, %.3f, %.3f)" % [
				String(m.name), aabb.size.x, aabb.size.y, aabb.size.z,
				aabb.get_center().x, aabb.get_center().y, aabb.get_center().z])
		var model := inst.get_node_or_null("Model")
		if model != null:
			print("  Model 子节点变换：scale=%s rot(deg)=%s pos=%s 子节点数=%d" % [
				str(model.scale), str(model.rotation_degrees), str(model.position), model.get_child_count()])
			for c in model.get_children():
				if c is Node3D:
					var c3 := c as Node3D
					print("     - %s scale=%s rot=%s" % [String(c.name), str(c3.scale), str(c3.rotation_degrees)])
		inst.queue_free()
	get_tree().quit()


func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_collect(child, out)