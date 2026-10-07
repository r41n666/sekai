extends SceneTree
const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"
func _initialize() -> void:
	var inst := (load(UAL) as PackedScene).instantiate()
	root.add_child(inst)
	var ap := _find_ap(inst)
	var names: Array[String] = []
	for n in ap.get_animation_list():
		names.append(String(n))
	names.sort()
	print("UAL 剪辑总数 = %d" % names.size())
	print("\n== 所有名字含 crouch / walk / idle / jog / sprint 的 ==")
	for n in names:
		var low := n.to_lower()
		if low.contains("crouch") or low.contains("walk") or low.contains("idle") \
			or low.contains("jog") or low.contains("sprint") or low.contains("run"):
			var a := ap.get_animation(n)
			print("  %-24s len=%6.3f loop=%d tracks=%d" % [n, a.length, int(a.loop_mode), a.get_track_count()])
	print("\n== 全部剪辑名 ==")
	for n in names:
		var a := ap.get_animation(n)
		print("  %-24s len=%6.3f loop=%d" % [n, a.length, int(a.loop_mode)])
	quit(0)
func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer: return n
	for c in n.get_children():
		var f := _find_ap(c)
		if f != null: return f
	return null
