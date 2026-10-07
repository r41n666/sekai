extends SceneTree

const UalBoneMap := preload("res://scripts/entities/ual_bone_map.gd")
# tools/probe_ual_bonemap.gd
# 目的：自检 UalBoneMap 的映射表与两侧实际骨名是否一致，并输出完整映射报告。
# 用法：godot --headless --path . --script res://tools/probe_ual_bonemap.gd

func _init() -> void:
	var ual_inst: Node = (load("res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb") as PackedScene).instantiate()
	var cat_inst: Node = (load("res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb") as PackedScene).instantiate()
	var ual_skel: Skeleton3D = _find_skel(ual_inst)
	var cat_skel: Skeleton3D = _find_skel(cat_inst)
	if ual_skel == null or cat_skel == null:
		print("SKELETON_NOT_FOUND ual=%s cat=%s" % [ual_skel, cat_skel])
		quit(1)
		return

	print("=== SECTION 1: 映射表自检 ===")
	var r: Dictionary = UalBoneMap.verify(ual_skel, cat_skel)
	print("  ok = %s" % str(r.ok))
	print("  已映射条目 = %d ｜ UAL 总骨数 = %d ｜ cat 总骨数 = %d" % [
		r.mapped_count, r.ual_total, r.cat_total])
	print("  UAL 侧不存在的骨（表写了但骨架没有）= %d %s" % [
		r.ual_missing.size(), str(r.ual_missing)])
	print("  cat 侧不存在的骨（表写了但骨架没有）= %d %s" % [
		r.cat_missing.size(), str(r.cat_missing)])
	print("  cat 未被映射的骨 = %d 根：" % r.cat_unused.size())
	var i := 0
	for b in r.cat_unused:
		print("     - %s" % b)
		i += 1
		if i >= 100:
			break

	print("")
	print("=== SECTION 2: profile 槽位 → UAL 骨名（构建 BoneMap 用）===")
	var prof := SkeletonProfileHumanoid.new()
	print("  profile bone_size = %d" % prof.get_bone_size())
	var bm: BoneMap = UalBoneMap.build_bone_map(prof)
	var hit := 0
	for slot in UalBoneMap.PROFILE_TO_UAL:
		var v := String(UalBoneMap.PROFILE_TO_UAL[slot])
		if v == "":
			continue
		# 回读验证 BoneMap 真的写进去了
		var back := String(bm.get_skeleton_bone_name(slot))
		var mark := "OK " if back == v else "FAIL"
		if back == v:
			hit += 1
		print("  %s %-26s -> %-24s (回读 %s)" % [mark, slot, v, back])
	print("  BoneMap 回读一致 = %d / %d" % [hit, UalBoneMap.PROFILE_TO_UAL.size()])

	print("")
	print("=== SECTION 3: 骨长对比（重定向比例风险评估）===")
	# 关键：重定向时若两骨架骨长差异大，容易出现「手伸不到枪」/「穿模」。
	var pairs := [
		["upper_arm", "DEF-upper_arm.L", "upper_arm.L_68"],
		["forearm", "DEF-forearm.L", "lower_arm.L_67"],
		["hand", "DEF-hand.L", "hand.L_66"],
		["thigh", "DEF-thigh.L", "upper_leg.L_100"],
		["shin", "DEF-shin.L", "lower_leg.L_99"],
		["foot", "DEF-foot.L", "foot.L_97"],
		["spine_low", "DEF-spine.001", "spine_95"],
		["spine_up", "DEF-spine.002", "chest_94"],
	]
	print("  %-12s %10s %10s %8s" % ["部位", "UAL", "cat", "比值"])
	for p in pairs:
		var ui := ual_skel.find_bone(String(p[1]))
		var ci := cat_skel.find_bone(String(p[2]))
		if ui < 0 or ci < 0:
			print("  %-12s  BONE_NOT_FOUND" % String(p[0]))
			continue
		var ul := _chain_len(ual_skel, ui)
		var cl := _chain_len(cat_skel, ci)
		print("  %-12s %10.4f %10.4f %8.3f" % [String(p[0]), ul, cl, (ul / cl) if cl > 0.0 else 0.0])

	print("")
	print("=== SECTION 4: 身高与根骨高度 ===")
	print("  UAL  DEF-head  globalrest.y = %.4f" % ual_skel.get_bone_global_rest(ual_skel.find_bone("DEF-head")).origin.y)
	print("  cat  head_49   globalrest.y = %.4f" % cat_skel.get_bone_global_rest(cat_skel.find_bone("head_49")).origin.y)
	print("  UAL  DEF-hips  globalrest.y = %.4f" % ual_skel.get_bone_global_rest(ual_skel.find_bone("DEF-hips")).origin.y)
	print("  cat  hips_106  globalrest.y = %.4f" % cat_skel.get_bone_global_rest(cat_skel.find_bone("hips_106")).origin.y)

	ual_inst.free()
	cat_inst.free()
	quit(0)


func _chain_len(sk: Skeleton3D, idx: int) -> float:
	## 骨到「子骨中最远者」的链长（近似该骨所辖肢体长度）
	var best := 0.0
	for c in sk.get_bone_children(idx):
		var cl := _chain_len(sk, c)
		if cl > best:
			best = cl
	var own := sk.get_bone_rest(idx).origin.length()
	return own + best


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null
