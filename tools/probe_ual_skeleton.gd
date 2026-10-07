extends SceneTree
# tools/probe_ual_skeleton.gd
# 目的：实测 UAL(Quaternius Universal Animation Library) 的完整结构 —— 节点树/骨名/层级/剪辑。
# 纯只读探针：不写任何项目文件，不改 project.godot。
# 用法：godot --headless --path . --script res://tools/probe_ual_skeleton.gd

const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"


func _init() -> void:
	var ps: PackedScene = load(UAL) as PackedScene
	if ps == null:
		print("LOAD_FAIL")
		quit(1)
		return
	var inst: Node = ps.instantiate()

	print("=== SECTION 0: 完整节点树 ===")
	_dump_tree(inst, 0)

	var aps: Array = []
	var sks: Array = []
	_collect(inst, aps, sks)
	print("")
	print("AnimationPlayer 数 = %d ｜ Skeleton3D 数 = %d" % [aps.size(), sks.size()])
	if aps.is_empty() or sks.is_empty():
		print("STRUCT_FAIL")
		inst.free()
		quit(1)
		return

	var ap: AnimationPlayer = aps[0]
	var sk: Skeleton3D = sks[0]

	print("AnimationPlayer 路径 = %s ｜ root_node = %s" % [str(ap.get_path()), str(ap.root_node)])

	print("")
	print("=== SECTION B: 全部剪辑（%d 条）===" % ap.get_animation_list().size())
	var list: Array = ap.get_animation_list()
	var rows: Array = []
	for a in list:
		var anim: Animation = ap.get_animation(String(a))
		rows.append("%s(%.2fs)" % [String(a), anim.length])
	for i in range(0, rows.size(), 4):
		var chunk: Array = rows.slice(i, mini(i + 4, rows.size()))
		print("  " + " | ".join(PackedStringArray(chunk)))

	print("")
	print("=== SECTION C: 骨骼层级（%d 骨）===" % sk.get_bone_count())
	for i in sk.get_bone_count():
		var bn := String(sk.get_bone_name(i))
		var p := sk.get_bone_parent(i)
		var pn := "(root)" if p < 0 else String(sk.get_bone_name(p))
		var g := sk.get_bone_global_rest(i)
		print("  %2d  %-26s <- %-22s  globalrest=(%.4f, %.4f, %.4f)"
			% [i, bn, pn, g.origin.x, g.origin.y, g.origin.z])

	print("")
	print("=== SECTION D: 每条剪辑的轨道/骨覆盖 ===")
	for a in list:
		var anim: Animation = ap.get_animation(String(a))
		var uniq: Dictionary = {}
		for t in range(anim.get_track_count()):
			var pth := String(anim.track_get_path(t))
			if pth.contains("Skeleton3D:"):
				uniq[pth.get_file()] = true
		print("  %-24s len=%.2f tracks=%3d bones=%2d loop=%d"
			% [String(a), anim.length, anim.get_track_count(), uniq.size(), int(anim.loop_mode)])

	inst.free()
	quit(0)


func _dump_tree(n: Node, depth: int) -> void:
	var extra := ""
	if n is Skeleton3D:
		extra = "  [bones=%d]" % (n as Skeleton3D).get_bone_count()
	elif n is AnimationPlayer:
		extra = "  [anims=%d]" % (n as AnimationPlayer).get_animation_list().size()
	elif n is MeshInstance3D:
		var mi := n as MeshInstance3D
		extra = "  [mesh=%s]" % ("null" if mi.mesh == null else str(mi.mesh.get_class()))
	print("%s- %s (%s)%s" % ["  ".repeat(depth), n.name, n.get_class(), extra])
	for c in n.get_children():
		_dump_tree(c, depth + 1)


func _collect(n: Node, aps: Array, sks: Array) -> void:
	if n is AnimationPlayer:
		aps.append(n)
	if n is Skeleton3D:
		sks.append(n)
	for c in n.get_children():
		_collect(c, aps, sks)
