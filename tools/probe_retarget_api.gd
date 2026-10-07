extends SceneTree
# tools/probe_retarget_api.gd
# 目的：核实 Godot 4.7.2 实际提供哪些重定向相关 API/类与方法签名，避免臆造。
# 用法：godot --headless --path . --script res://tools/probe_retarget_api.gd

func _init() -> void:
	print("=== SECTION A: 类存在性 ===")
	for c in ["SkeletonProfileHumanoid", "SkeletonProfile", "RetargetModifier3D", "BoneMap",
			"SkeletonModifier3D", "Skeleton3D", "AnimationPlayer", "AnimationTree"]:
		print("  %-32s exists=%s" % [c, str(ClassDB.class_exists(c))])

	print("")
	print("=== SECTION B: SkeletonProfileHumanoid 全部方法 ===")
	_dump_methods("SkeletonProfileHumanoid")
	print("")
	print("=== SECTION B2: SkeletonProfile 全部方法 ===")
	_dump_methods("SkeletonProfile")

	print("")
	print("=== SECTION C: RetargetModifier3D 属性 + 方法 ===")
	for p in ClassDB.class_get_property_list("RetargetModifier3D"):
		print("  prop %-36s type=%d" % [p.name, p.type])
	_dump_methods("RetargetModifier3D")

	print("")
	print("=== SECTION D: BoneMap 属性 + 方法 ===")
	for p in ClassDB.class_get_property_list("BoneMap"):
		print("  prop %-36s type=%d" % [p.name, p.type])
	_dump_methods("BoneMap")

	print("")
	print("=== SECTION E: SkeletonProfileHumanoid 槽位探测 ===")
	var prof := SkeletonProfileHumanoid.new()
	if prof.has_method("get_root_bone"):
		print("  get_root_bone() = %s" % str(prof.get_root_bone()))
	var humanoid_names := [
		"Root", "Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "HeadTop",
		"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
		"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
		"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
		"RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes",
		"LeftEye", "RightEye", "Jaw",
	]
	if prof.has_method("find_bone"):
		for bn in humanoid_names:
			print("  find_bone(%-18s) = %d" % [bn, prof.find_bone(bn)])
	if prof.has_method("get_bone_name"):
		for i in range(0, 60):
			var nm := String(prof.get_bone_name(i))
			if nm != "":
				print("  get_bone_name(%2d) = %s" % [i, nm])
	if prof.has_method("get_persistent_bone_count"):
		print("  persistent_bone_count = %d" % prof.get_persistent_bone_count())

	quit(0)


func _dump_methods(cls: String) -> void:
	for m in ClassDB.class_get_method_list(cls):
		var n := String(m.name)
		if n.begins_with("_"):
			continue
		print("  %s(%s) -> %s" % [n, _argnames(m), type_string(m.return["type"])])


func _argnames(m: Dictionary) -> String:
	var out: Array = []
	for a in m.get("args", []):
		out.append(String(a.name))
	var joined: String = ""
	for i in range(out.size()):
		if i > 0:
			joined += ", "
		joined += String(out[i])
	return joined
