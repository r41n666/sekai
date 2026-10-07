extends SceneTree
# tools/probe_cat_skeleton.gd
# 目的：实测目标角色 cat_hatsune_miku 的完整骨架，作为 UAL 骨映射的另一端。
# 纯只读探针。用法：godot --headless --path . --script res://tools/probe_cat_skeleton.gd

const CAT := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"


func _init() -> void:
	var ps: PackedScene = load(CAT) as PackedScene
	if ps == null:
		print("LOAD_FAIL")
		quit(1)
		return
	var inst: Node = ps.instantiate()
	var sks: Array = []
	var aps: Array = []
	_collect(inst, sks, aps)
	if sks.is_empty():
		print("NO_SKELETON")
		_dump_tree(inst, 0)
		inst.free()
		quit(1)
		return
	var sk: Skeleton3D = sks[0]
	print("=== cat_hatsune_miku 骨架：%d 骨 ｜ AnimationPlayer 数=%d ===" % [sk.get_bone_count(), aps.size()])
	for ap in aps:
		var p: AnimationPlayer = ap
		var l: Array = p.get_animation_list()
		for a in l:
			var an: Animation = p.get_animation(String(a))
			print("  剪辑 %s len=%.2f tracks=%d" % [String(a), an.length, an.get_track_count()])
	print("")
	for i in sk.get_bone_count():
		var bn := String(sk.get_bone_name(i))
		var p := sk.get_bone_parent(i)
		var pn := "(root)" if p < 0 else String(sk.get_bone_name(p))
		var g := sk.get_bone_global_rest(i)
		print("  %3d  %-34s <- %-30s globalrest=(%.4f, %.4f, %.4f)"
			% [i, bn, pn, g.origin.x, g.origin.y, g.origin.z])
	inst.free()
	quit(0)


func _dump_tree(n: Node, depth: int) -> void:
	var extra := ""
	if n is Skeleton3D:
		extra = "  [bones=%d]" % (n as Skeleton3D).get_bone_count()
	print("%s- %s (%s)%s" % ["  ".repeat(depth), n.name, n.get_class(), extra])
	for c in n.get_children():
		_dump_tree(c, depth + 1)


func _collect(n: Node, sks: Array, aps: Array) -> void:
	if n is Skeleton3D:
		sks.append(n)
	if n is AnimationPlayer:
		aps.append(n)
	for c in n.get_children():
		_collect(c, sks, aps)
