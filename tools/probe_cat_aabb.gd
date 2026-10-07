extends SceneTree
# tools/probe_cat_aabb.gd
# 目的：量 cat 模型的真实世界包围盒，用于正确摆放截图相机。
#⚠ 必须在场景树就绪后测量（`_init` 里 add_child 后 get_global_transform 仍报
#    "is_inside_tree()"），故用 process_frame 回调延后一帧。
const CAT := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"

var _cat: Node
var _done := false


func _init() -> void:
	_cat = (load(CAT) as PackedScene).instantiate()
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if _done:
		return
	_done = true
	get_root().add_child.call_deferred(_cat)
	# 延后两帧，确保 transform 已生效
	await process_frame
	await process_frame
	_measure()
	quit(0)


func _measure() -> void:
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	var meshes := 0
	for m in _meshes(_cat):
		meshes += 1
		var mi := m as MeshInstance3D
		var aabb: AABB = mi.get_aabb()
		aabb = mi.global_transform * aabb
		lo = lo.min(aabb.position)
		hi = hi.max(aabb.position + aabb.size)
	print("MeshInstance3D 数 = %d" % meshes)
	print("世界 AABB min  = %s" % str(lo))
	print("世界 AABB max  = %s" % str(hi))
	print("尺寸           = %s" % str(hi - lo))
	print("中心           = %s" % str((lo + hi) * 0.5))
	var sk := _find_skel(_cat)
	if sk != null:
		print("Skeleton3D.global_transform = %s" % str(sk.global_transform))
		for bn in ["foot.L_97", "toes.L_96", "head_49", "hand.R_85"]:
			var i := sk.find_bone(bn)
			if i >= 0:
				print("  %-12s 世界位置 = %s" % [bn, str(sk.get_bone_global_pose(i).origin)])


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
