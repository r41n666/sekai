extends Node3D
## [临时只读探针] 验证 MikuProceduralPose 的骨骼覆写在 **headless** 下是否可读（决定测试可写性），
## 以及走路时大腿骨是否真的在动。
##
## 用法：godot --headless --path . res://tools/probe_legs_move.tscn

const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"

var _model: MikuModel
var _frames := 0


func _ready() -> void:
	_model = MikuModel.new()
	_model.name = "MikuModel"
	_model.model_path = CAT_MODEL
	add_child(_model)
	_model.position.y = 0.9


func _process(_d: float) -> void:
	_frames += 1
	if _frames < 3:
		return
	_run()
	get_tree().quit(0)


func _run() -> void:
	var sk := _find_skeleton(_model)
	var pose := MikuProceduralPose.new()
	pose.setup(sk, _model)
	print("")
	print("==================== LEGS-MOVE PROBE ====================")
	print("valid=%s thigh_r=%d knee_r=%d" % [
		pose.valid, int(pose.debug_indices["thigh_r"]), int(pose.debug_indices["knee_r"])])

	var thigh := int(pose.debug_indices["thigh_r"])
	var knee := int(pose.debug_indices["knee_r"])
	var rest_t := sk.get_bone_global_pose(thigh).origin
	var rest_k := sk.get_bone_global_pose(knee).origin
	print("rest  thigh=%s  knee=%s" % [rest_t, rest_k])

	# 走：多帧推进相位，观察大腿骨 global pose 是否变化
	var seen: Array[Vector3] = []
	for step in 12:
		pose.update(0.1, 2.0, true, false, true)
		# 覆写是否可读？读 get_bone_global_pose
		var gp := sk.get_bone_global_pose(thigh).origin
		var lp := sk.get_bone_pose(thigh).origin
		seen.append(gp)
		print("step %2d  phase=%5.3f  thigh_global=%s  local_origin=%s  amp=%5.3f" % [
			step, pose._phase, gp, lp, pose._leg_amplitude])
	var min_d := INF
	for i in seen.size():
		for j in range(i + 1, seen.size()):
			min_d = minf(min_d, seen[i].distance_to(seen[j]))
	print("大腿骨 global origin 逐帧最大位移（pairwise max）= %s" % _max_pairwise(seen))
	print("  → 若 > 0 说明 set_bone_global_pose_override 在 headless 下可读（测试可写）")

	# 对照：显式测试「覆写是否真的改变了 global pose」
	sk.set_bone_global_pose_override(thigh, Transform3D(), 0.0, false) # 清空
	# 需要触发一次骨架更新
	print("  清空覆写后 thigh_global=%s" % sk.get_bone_global_pose(thigh).origin)
	print("=========================================================")
	print("")


func _max_pairwise(v: Array[Vector3]) -> float:
	var m := 0.0
	for i in v.size():
		for j in range(i + 1, v.size()):
			m = maxf(m, v[i].distance_to(v[j]))
	return m


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for c in root.get_children():
		var f := _find_skeleton(c)
		if f != null:
			return f
	return null
