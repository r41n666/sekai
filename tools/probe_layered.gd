extends Node3D
## [临时只读探针] 分层模式接线验证（真实 MikuModel 路径，headless）。
## procedural_legs_enabled=true + hold_ik_enabled=true。
## 用法：godot --headless --path . res://tools/probe_layered.tscn

const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"

var _model: MikuModel
var _frames := 0
var _thigh_samples: Array[Vector3] = []


func _ready() -> void:
	_model = MikuModel.new()
	_model.name = "MikuModel"
	_model.model_path = CAT_MODEL
	_model.procedural_legs_enabled = true
	_model.hold_ik_enabled = true
	add_child(_model)
	_model.position.y = 0.9
	_model.set_holding_weapon(true)


func _process(_d: float) -> void:
	_frames += 1
	if _frames < 3:
		return
	_model.update_animation(0.05, 2.0, 0.5, true, true)
	var sk := _find_skeleton(_model)
	if sk != null and _model._procedural != null:
		_thigh_samples.append(sk.get_bone_global_pose(int(_model._procedural.debug_indices["thigh_r"])).origin)
	if _frames < 40:
		return
	_report()
	get_tree().quit(0)


func _report() -> void:
	print("")
	print("==================== LAYERED PROBE ====================")
	var proc: MikuProceduralPose = _model._procedural
	var ik = _model._hold_ik
	print("procedural set = %s" % (proc != null))
	if proc != null:
		print("  valid=%s  pose_arms=%s  _controlled=%s" % [proc.valid, proc.pose_arms, proc._controlled])
		print("  debug_names=%s" % proc.debug_names)
		print("  手臂索引是否在 _controlled 内：arm_r=%s arm_l=%s elbow_r=%s elbow_l=%s" % [
			proc.debug_indices["arm_r"] in proc._controlled,
			proc._arm_l in proc._controlled,
			int(proc.debug_indices["elbow_r"]) in proc._controlled,
			proc._elbow_l in proc._controlled])
	print("hold_ik set = %s" % (ik != null))
	if ik != null:
		print("  valid=%s  enabled=%s  attach_targets_to_torso=%s  _torso_attached=%s" % [
			ik.valid, ik.is_enabled(), ik.attach_targets_to_torso, ik._torso_attached])
	var m := 0.0
	for i in _thigh_samples.size():
		for j in range(i + 1, _thigh_samples.size()):
			m = maxf(m, _thigh_samples[i].distance_to(_thigh_samples[j]))
	print("大腿骨逐帧最大位移 = %s（>0 说明分层下腿在动）" % m)
	print("=======================================================")
	print("")


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for c in root.get_children():
		var f := _find_skeleton(c)
		if f != null:
			return f
	return null
