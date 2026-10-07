extends SceneTree
## [临时只读探针] 审计全部角色模型的「骨骼可重定向性」。
## 判据：骨骼名是否为标准人形命名（可被 Mixamo/UE/Blender 动画重定向），
##      还是乱码 MMD 名（只能几何启发式硬猜）。
## 用法：godot --headless --path . -s tools/audit_bone_names.gd

## 标准人形骨骼关键字（Blender Rigify / Mixamo / UE Mannequin 常见命名）
const STD_KEYWORDS := [
	"hips", "pelvis", "spine", "chest", "neck", "head",
	"shoulder", "upper_arm", "lower_arm", "forearm", "hand",
	"thigh", "shin", "calf", "foot", "toe",
]
## 辅助骨排除词 —— 这类骨骼名字是英文但**不是形变骨**，不能算「可重定向」
## （本项目实测：miku.glb 的形变骨全是乱码 MMD 名，只有 CL_*Collider* 辅助骨是英文，
##   若不过滤会把「不可重定向」误判成「可重定向」）
const HELPER_KEYWORDS := ["collider", "_const", "const_", "limit_", "twist", "dummy",
	"shadow", "rigid", "joint", "ik_", "_ik", "helper", "locator", "nub"]
## MMD 日文标准名（未被破坏时可用）
const MMD_KEYWORDS := ["センター", "上半身", "下半身", "右腕", "左腕", "右手首", "左手首"]


func _is_helper(nm: String) -> bool:
	var low := nm.to_lower()
	for kw in HELPER_KEYWORDS:
		if low.contains(kw):
			return true
	return false


func _init() -> void:
	var models := _collect()
	print("=== 角色模型骨骼可重定向性审计（%d 个） ===" % models.size())
	print("%-26s %6s %8s %8s %-10s %s" % ["模型", "骨骼", "标准名", "可读名", "结论", "样例"])
	print("-".repeat(118))
	var std_list: Array = []
	var garbled_list: Array = []
	for p in models:
		var ps: PackedScene = load(p) as PackedScene
		if ps == null:
			print("%-26s 加载失败" % p.get_file())
			continue
		var inst: Node = ps.instantiate()
		var sk: Skeleton3D = _find(inst)
		if sk == null:
			print("%-26s %6s %8s %8s %-10s %s" % [p.get_file(), "-", "-", "-", "无骨骼", ""])
			inst.free()
			continue
		var n: int = sk.get_bone_count()
		var std_hits: Array = []
		var readable := 0
		var garbled := 0
		var samples: Array = []
		for i in n:
			var nm := String(sk.get_bone_name(i))
			var low := nm.to_lower()
			# 乱码判定：含替换字符或非 ASCII 且非日文/中文可读
			if nm.contains("\uFFFD") or nm.contains("?"):
				garbled += 1
			else:
				readable += 1
			# 辅助骨（collider / const / limit / twist…）名字是英文但不是形变骨，不算可重定向
			if _is_helper(nm):
				continue
			for kw in STD_KEYWORDS:
				if low.contains(kw):
					std_hits.append(kw)
					if samples.size() < 4:
						samples.append(nm)
					break
		var verdict := "乱码MMD"
		if std_hits.size() >= 8:
			verdict = "★可重定向"
			std_list.append(p.get_file())
		elif std_hits.size() >= 3:
			verdict = "部分可用"
			std_list.append(p.get_file())
		else:
			garbled_list.append(p.get_file())
		print("%-26s %6d %8d %8d %-10s %s" % [p.get_file(), n, std_hits.size(), readable,
			verdict, ", ".join(samples)])
		inst.free()
	print("-".repeat(118))
	print("★可重定向/部分可用: %s" % (", ".join(std_list) if std_list.size() > 0 else "无"))
	print("✗ 仅乱码MMD（只能程序化摆姿）: %s" % (", ".join(garbled_list) if garbled_list.size() > 0 else "无"))
	quit(0)


func _collect() -> Array:
	return _walk("res://assets/models")


func _walk(dir_path: String) -> Array:
	var out: Array = []
	var da := DirAccess.open(dir_path)
	if da == null:
		return out
	da.list_dir_begin()
	var n := da.get_next()
	while n != "":
		if da.current_is_dir():
			if not n.begins_with("."):
				out.append_array(_walk(dir_path.path_join(n)))
		elif n.to_lower().ends_with(".glb") or n.to_lower().ends_with(".fbx"):
			# 只要角色模型（含骨骼的），武器另算
			out.append(dir_path.path_join(n))
		n = da.get_next()
	da.list_dir_end()
	return out


func _find(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var f: Skeleton3D = _find(c)
		if f != null:
			return f
	return null