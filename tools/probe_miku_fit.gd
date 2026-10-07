extends Node3D
## 诊断：MikuModel 内部到底有哪些子节点、缩放实际是多少。
## 用途：让 capture_ual_retarget.gd 的「缩放对齐」能拿到真实值（此前 get_node("Miku") 失败）。
## 用法：godot --path . --rendering-driver vulkan res://tools/probe_miku_fit.tscn

const OUT := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"


func _ready() -> void:
	var m := MikuModel.new()
	m.model_path = "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
	add_child(m)
	await get_tree().process_frame
	print("=== MikuModel 子节点树 ===")
	_dump(m, 0)
	# 直接量世界 AABB，与裸 glb 对比
	print("")
	print("=== 关键数值 ===")
	print("  auto_fit_height = %s" % str(m.auto_fit_height))
	print("  model_scale     = %s" % str(m.model_scale))
	for c in m.get_children():
		var n3 := c as Node3D
		if n3 == null:
			continue
		print("  子节点 %-14s (%s) scale=%s pos=%s" % [
			String(c.name), c.get_class(), str(n3.scale), str(n3.position)])
		var sk := _find_skel(n3)
		if sk != null:
			var aabb := _aabb(n3)
			print("      └ 骨架世界高度：脚y=%.4f 头顶y=%.4f  AABB y[%.4f, %.4f] 尺寸y=%.4f" % [
				sk.get_bone_global_pose(sk.find_bone("toes.L_96")).origin.y,
				sk.get_bone_global_pose(sk.find_bone("head_49")).origin.y,
				aabb.position.y, aabb.position.y + aabb.size.y, aabb.size.y])
	get_tree().quit(0)


func _dump(n: Node, d: int) -> void:
	var extra := ""
	if n is Node3D:
		extra = "  scale=%s pos=%s" % [(n as Node3D).scale, (n as Node3D).position]
	elif n is Skeleton3D:
		extra = "  [bones=%d]" % (n as Skeleton3D).get_bone_count()
	print("%s- %s (%s)%s" % ["  ".repeat(d), n.name, n.get_class(), extra])
	for c in n.get_children():
		_dump(c, d + 1)


func _aabb(n: Node) -> AABB:
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	for m in _meshes(n):
		var mi := m as MeshInstance3D
		var a: AABB = mi.get_aabb()
		a = mi.global_transform * a
		lo = lo.min(a.position)
		hi = hi.max(a.position + a.size)
	if lo.x > hi.x:
		return AABB()
	return AABB(lo, hi - lo)


func _meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null
