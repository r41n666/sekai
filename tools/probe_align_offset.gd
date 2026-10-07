extends SceneTree
# tools/probe_align_offset.gd
# 目的：**一次算准** UAL 组裸 glb 相对 MikuModel 的缩放 + 垂直偏移，避免靠截图试错。
# 做法：同进程内同时实例化 MikuModel 组与裸 glb 组，各自量「脚底世界 y」与「头顶世界 y」，
#      用两者之差直接解出裸 glb 需要的 scale 与 position.y。
# 用法：godot --headless --path . --script res://tools/probe_align_offset.gd

const CAT := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"

var _miku: Node3D
var _bare: Node3D
var _done := false


func _init() -> void:
	var host := Node3D.new()
	host.name = "Host"
	get_root().add_child.call_deferred(host)

	_miku = MikuModel.new()
	_miku.model_path = CAT
	_miku.position.y = 0.9   # 与 capture_proc_baseline.gd 一致
	host.add_child(_miku)

	_bare = (load(CAT) as PackedScene).instantiate() as Node3D
	_bare.name = "Bare"
	host.add_child(_bare)

	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if _done:
		return
	_done = true
	await process_frame
	await process_frame
	_report()
	quit(0)


func _report() -> void:
	var m_bones := _bone_y(_miku, "toes.L_96", "toes.R_101", "head_49")
	var b_bones := _bone_y(_bare, "toes.L_96", "toes.R_101", "head_49")
	print("=== MikuModel 组（position.y=0.9）骨世界高度 ===")
	for k in m_bones:
		print("  %-12s y = %.5f" % [k, m_bones[k]])
	print("  脚底 = %.5f 头顶 = %.5f 身高 = %.5f" % [
		m_bones["foot"], m_bones["head"], m_bones["head"] - m_bones["foot"]])

	print("=== 裸 glb 组（无变换）骨世界高度 ===")
	for k in b_bones:
		print("  %-12s y = %.5f" % [k, b_bones[k]])
	print("  脚底 = %.5f 头顶 = %.5f 身高 = %.5f" % [
		b_bones["foot"], b_bones["head"], b_bones["head"] - b_bones["foot"]])

	var m_h: float = m_bones["head"] - m_bones["foot"]
	var b_h: float = b_bones["head"] - b_bones["foot"]
	var k := m_h / b_h
	var dy: float = m_bones["foot"] - b_bones["foot"] * k
	print("")
	print("=== 裸 glb 对齐到 MikuModel 组所需的变换 ===")
	print("  scale        = %.6f（各轴相同）" % k)
	print("  position.y   = %.6f" % dy)
	print("  自检：应用后脚底应= %.5f（目标 %.5f）、头顶应= %.5f（目标 %.5f）" % [
		b_bones["foot"] * k + dy, m_bones["foot"], b_bones["head"] * k + dy, m_bones["head"]])


func _bone_y(root: Node, toe: String, toe_r: String, head: String) -> Dictionary:
	var sk := _find_skel(root)
	if sk == null:
		return {"foot": 0.0, "head": 0.0}
	#⚠ get_bone_global_pose() 返回**骨架局部空间**坐标，**不含**节点链的 scale/offset
	#   （实测 MikuModel 组与裸 glb 组读出完全相同的 1.23563）。必须再乘 global_transform。
	var gt := sk.global_transform
	var l: float = (gt * sk.get_bone_global_pose(sk.find_bone(toe)).origin).y
	var r: float = (gt * sk.get_bone_global_pose(sk.find_bone(toe_r)).origin).y
	var h: float = (gt * sk.get_bone_global_pose(sk.find_bone(head)).origin).y
	return {"foot": minf(l, r), "head": h}


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null
