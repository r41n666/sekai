extends TestSuite
## 手指抓握（HandGrip）回归基线。
##
## 背景：用户抱怨「人物姿势都不是正常拿枪的」。上一轮的双臂 IK 只驱动每臂 3 根骨
## （上臂 / 前臂 / 手），**手指没被驱动** ⇒ 截图里手是**五指大张「拍」在枪上**。
## 本能力新增手指抓握层，把 15 根指骨弯到「握住枪」的角度。
##
## 本 suite 锁六组不变量：
##   ① **弯曲轴与符号（实测，非推测）**：绕**局部 X** 轴弯曲（绕局部 Z 是侧摆）；
##      左右手符号**同为负**（本模型 Rigify 导出未镜像局部 X）。判据：弯曲旋转下
##      手指 +Y 轴无 X 分量、且指尖朝掌心侧（-Z）偏转。
##   ② **角度表**：五根手指 × 三关节齐全；主握（握把）比副握（护木）弯得多；角度在合理区间。
##   ③ **骨名解析**：按前缀解析出 15 根指骨；左右不串；缺骨返回 -1 且判为不完整。
##   ④ **链式应用**：在**合成骨架**上 apply_chain 真的让指尖离开 +Y、朝掌心侧弯；
##      骨链不全时安全无操作。
##   ⑤ **接线口径**：默认关闭；grip **仅在 IK 生效时**应用；grip modifier 在两条 IK **之后**
##      add_child（运行顺序）；纯视觉不走 RPC。
##   ⑥ **不抢骨骼**：`MikuProceduralPose` 从不碰指骨（源里不出现 proximal/intermediate/distal）。
##
## 断言口径（控制清单 §4-16 双向）：几何类按**语义**写（绕哪根轴 / 朝哪侧偏转），
## 不锁具体公式；源扫描一律用**计数**而非逐行断言（避免断言数随文件行数漂移，§4-15）。
## 守恒对照：`test_rotation_representation_is_equivalent` 断言「Basis 一次旋转」与
## 「两次半角旋转之积」等价 —— 语义等价的改写必须仍通过。

const GripScript := preload("res://scripts/entities/hand_grip.gd")
const ModifierScript := preload("res://scripts/entities/hand_grip_modifier.gd")
const HoldIKScript := preload("res://scripts/entities/weapon_hold_ik.gd")

const GRIP_SRC := "res://scripts/entities/hand_grip.gd"
const MOD_SRC := "res://scripts/entities/hand_grip_modifier.gd"
const HOLD_SRC := "res://scripts/entities/weapon_hold_ik.gd"
const MODEL_SRC := "res://scripts/entities/miku_model.gd"
const POSE_SRC := "res://scripts/entities/miku_procedural_pose.gd"

## cat_hatsune_miku 右手拇指 + 中指 + 无名指的若干真实骨名（用于解析用例）。
const REAL_NAMES := [
	"hips_106", "spine_95", "chest_94",
	"shoulder.R_88", "upper_arm.R_87", "lower_arm.R_86", "hand.R_85",
	"thumb_proximal.R_72", "thumb_intermediate.R_71", "thumb_distal.R_70",
	"index_proximal.R_75", "index_intermediate.R_74", "index_distal.R_73",
	"middle_proximal.R_78", "middle_intermediate.R_77", "middle_distal.R_76",
	"ring_proximal.R_81", "ring_intermediate.R_80", "ring_distal.R_79",
	"little_proximal.R_84", "little_intermediate.R_83", "little_distal.R_82",
	"hand.L_66",
	"thumb_proximal.L_53", "thumb_intermediate.L_52", "thumb_distal.L_51",
	"index_proximal.L_56", "index_intermediate.L_55", "index_distal.L_54",
	"middle_proximal.L_59", "middle_intermediate.L_58", "middle_distal.L_57",
	"ring_proximal.L_62", "ring_intermediate.L_61", "ring_distal.L_60",
	"little_proximal.L_65", "little_intermediate.L_64", "little_distal.L_63",
]


# ---------------------------------------------------------------------------
# ① 弯曲轴与符号（实测锁定）
# ---------------------------------------------------------------------------

## 弯曲轴必须是**局部 X**：绕它转时手指 +Y 不产生 X 分量；绕 Z 才会产生 X 分量。
func test_flex_axis_is_local_x() -> void:
	check_near(GripScript.FLEX_AXIS.normalized().distance_to(Vector3(1, 0, 0)), 0.0, 1e-6,
		"实测弯曲轴必须是局部 +X")
	var rot: Basis = GripScript.flex_rotation("index", "proximal", GripScript.Role.GRIP, "r")
	var tilted: Vector3 = rot * Vector3.UP # 手指沿局部 +Y
	check_near(tilted.x, 0.0, 1e-6, "绕局部 X 弯曲：+Y 旋转后不得有 X 分量")
	check_true(absf(tilted.z) > 1e-3, "弯曲必须让指尖离开 +Y 轴（真的弯了）")


## 符号：左右手实测**同为负**（本模型局部 X 未镜像）。
func test_flex_sign_negative_on_both_sides() -> void:
	check_true(GripScript.flex_sign("r") < 0.0, "右手弯曲符号实测为负")
	check_true(GripScript.flex_sign("l") < 0.0, "左手弯曲符号实测为负")
	check_true(is_equal_approx(GripScript.flex_sign("r"), GripScript.flex_sign("l")),
		"本模型左右手局部 X 未镜像 → 符号相同（若换模型需重测）")


## 语义：测得符号下，直指（+Y）弯后指尖朝 **-Z**（掌心侧）偏转——两手一致。
func test_curl_points_toward_palm_side() -> void:
	for side in ["l", "r"]:
		var rot: Basis = GripScript.flex_rotation("middle", "intermediate", GripScript.Role.GRIP, side)
		var tip: Vector3 = rot * Vector3.UP
		check_true(tip.z < -1e-3,
			"%s：弯曲后指尖必须朝掌心侧（-Z）偏转（朝手背 = 符号反了）" % side)


## 带符号角 = 符号 × 无符号角。
func test_signed_angle_applies_flex_sign() -> void:
	for side in ["l", "r"]:
		var raw: float = GripScript.grip_angle("index", "proximal", GripScript.Role.GRIP)
		var signed: float = GripScript.signed_angle("index", "proximal", GripScript.Role.GRIP, side)
		check_near(signed, raw * GripScript.flex_sign(side), 1e-9,
			"带符号角必须 = flex_sign × 无符号角（%s）" % side)


## 守恒对照：`Basis(axis, a)` 与「两次半角旋转之积」必须等价（语义等价的改写仍应通过）。
func test_rotation_representation_is_equivalent() -> void:
	var straight: Basis = GripScript.flex_rotation("ring", "distal", GripScript.Role.FOREGRIP, "l")
	var angle: float = GripScript.signed_angle("ring", "distal", GripScript.Role.FOREGRIP, "l")
	var half := Basis(GripScript.FLEX_AXIS, angle * 0.5)
	var split: Basis = half * half
	check_near(straight.x.distance_to(split.x), 0.0, 1e-6, "两种等价写法 X 轴一致")
	check_near(straight.y.distance_to(split.y), 0.0, 1e-6, "两种等价写法 Y 轴一致")
	check_near(straight.z.distance_to(split.z), 0.0, 1e-6, "两种等价写法 Z 轴一致")


# ---------------------------------------------------------------------------
# ② 角度表
# ---------------------------------------------------------------------------

## 五根手指 × 三关节齐全，且角度为正、在合理区间（不锁具体数值）。
func test_grip_angles_cover_all_fingers() -> void:
	var table: Dictionary = GripScript.grip_angles(GripScript.Role.GRIP)
	for finger in ["thumb", "index", "middle", "ring", "little"]:
		check_true(table.has(finger), "角度表必须含 %s" % finger)
		var angles: Array = table.get(finger, [])
		check_eq(angles.size(), 3, "%s 必须有三关节角度" % finger)
		for a in angles:
			check_true(float(a) > 0.0, "%s 的弯曲角必须为正" % finger)
			check_true(float(a) <= 1.6, "%s 的弯曲角不得超过 ≈92°（自然握持上限）" % finger)


## 主握（右手握把）必须比副握（左手护木）弯得更多——握把半径小、手指闭合更紧。
func test_grip_is_tighter_than_foregrip() -> void:
	var grip_sum := _sum_angles(GripScript.Role.GRIP)
	var fore_sum := _sum_angles(GripScript.Role.FOREGRIP)
	check_true(grip_sum > fore_sum,
		"主握（握把）总弯曲角必须大于副握（护木）：握把更细、握得更紧")


func _sum_angles(role: int) -> float:
	var total := 0.0
	var table: Dictionary = GripScript.grip_angles(role)
	for finger in table.keys():
		for a in table[finger]:
			total += float(a)
	return total


## 四种角色/手指组合都能取到单关节角（grip_angle 不返回异常值）。
func test_grip_angle_lookup_is_stable() -> void:
	check_ge(GripScript.grip_angle("middle", "intermediate", GripScript.Role.GRIP), 0.0,
		"中指近节弯曲角应为非负")
	check_eq(GripScript.grip_angle("nope", "proximal", GripScript.Role.GRIP), 0.0,
		"未知手指应返回 0（安全兜底，不报错）")


# ---------------------------------------------------------------------------
# ③ 骨名解析
# ---------------------------------------------------------------------------

## 该侧 15 根指骨前缀齐全（供 applicator 按前缀匹配）。
func test_finger_bone_names_returns_15() -> void:
	var names: Array = GripScript.finger_bone_names("l")
	check_eq(names.size(), 15, "每只手 15 根指骨")
	check_true("index_proximal.l" in names, "应含 index_proximal.l")
	check_true("thumb_distal.r" in GripScript.finger_bone_names("r"), "应含 thumb_distal.r")


## 在真实（cat）骨名上解析出全部 15 根，且左右不串。
func test_resolve_finger_bones_on_real_names() -> void:
	var names := PackedStringArray(REAL_NAMES)
	var r: Dictionary = GripScript.resolve_finger_bones(names, "r")
	check_true(GripScript.resolved_is_complete(r), "右手 15 根应全部解析到")
	check_eq(int(r["index:proximal"]), 10, "右手食指近节应是第 10 根")
	check_eq(int(r["little:distal"]), 21, "右手小指远节应是第 21 根")
	var l: Dictionary = GripScript.resolve_finger_bones(names, "l")
	check_true(GripScript.resolved_is_complete(l), "左手 15 根应全部解析到")
	check_eq(int(l["middle:intermediate"]), 30, "左手中指中节应是第 30 根")
	check_true(int(r["index:proximal"]) != int(l["index:proximal"]), "左右手不得解析到同一根骨")


## 缺骨时返回 -1 且整体判为「不完整」（modifier 据此不启用）。
func test_resolve_reports_incomplete_when_missing() -> void:
	var names := PackedStringArray(["hand.R_85", "index_proximal.R_75"])
	var r: Dictionary = GripScript.resolve_finger_bones(names, "r")
	check_true(int(r["index:proximal"]) >= 0, "存在的指骨应解析到")
	check_eq(int(r["thumb:distal"]), -1, "缺失的指骨应返回 -1")
	check_false(GripScript.resolved_is_complete(r), "缺骨时必须判为不完整")


# ---------------------------------------------------------------------------
# ④ 链式应用（合成骨架集成，headless 可读 set/get_bone_global_pose）
# ---------------------------------------------------------------------------

## 造一只「手 + 食指三节」的合成骨架（沿 +Y 延伸），供 apply_chain 用。
func _make_finger_rig() -> Skeleton3D:
	var sk := Skeleton3D.new()
	add_child(sk) # 入树：global pose 的读写在树内更稳
	var defs := [
		["hand.R_1", Vector3(0, 0.0, 0), -1],
		["index_proximal.R_2", Vector3(0, 0.1, 0), 0],
		["index_intermediate.R_3", Vector3(0, 0.2, 0), 1],
		["index_distal.R_4", Vector3(0, 0.3, 0), 2],
	]
	for d in defs:
		var idx := sk.add_bone(String(d[0]))
		sk.set_bone_rest(idx, Transform3D(Basis(), d[1]))
		if int(d[2]) >= 0:
			sk.set_bone_parent(idx, int(d[2]))
	return sk


## 链式合成（纯数学）：直指沿 +Y，逐节绕局部 X 咬合后，指尖 origin/朝向必须朝掌心侧 -Z。
## ⚠ 用纯函数（local_of / next_bone_pose）而不是骨架 global-pose 往返 ——
##   后者的结果只在 SkeletonModifier3D 管线内保证可读（headless 场景外会读到未刷新的值）。
func test_chain_composition_curls_toward_palm() -> void:
	var hand := Transform3D.IDENTITY
	var prox := Transform3D(Basis(), Vector3(0, 0.1, 0))
	var inter := Transform3D(Basis(), Vector3(0, 0.2, 0))
	var dist := Transform3D(Basis(), Vector3(0, 0.3, 0))
	var rp: Basis = GripScript.flex_rotation("index", "proximal", GripScript.Role.GRIP, "r")
	var ri: Basis = GripScript.flex_rotation("index", "intermediate", GripScript.Role.GRIP, "r")
	var rd: Basis = GripScript.flex_rotation("index", "distal", GripScript.Role.GRIP, "r")
	# 用「原始父 + 原始子」求局部偏移，再挂到**已更新**的父上（与 apply_chain 同构）。
	var p: Transform3D = GripScript.next_bone_pose(hand, GripScript.local_of(hand, prox), rp)
	var i: Transform3D = GripScript.next_bone_pose(p, GripScript.local_of(prox, inter), ri)
	var d: Transform3D = GripScript.next_bone_pose(i, GripScript.local_of(inter, dist), rd)
	check_true(d.origin.z < dist.origin.z - 1e-4, "指尖 origin 必须朝掌心侧 -Z 收拢")
	check_true(d.origin.y < dist.origin.y, "指尖应更低（向掌心卷），而不是更远离手掌")
	var tip_dir: Vector3 = d.basis * Vector3.UP
	check_true(tip_dir.z < 0.0, "指尖朝向必须朝掌心侧（-Z），朝手背 = 符号反了")


## 集成：`apply_chain` 必须真的改写指骨的**局部姿态**（证明它写了骨骼，而非空转）。
func test_apply_chain_writes_bone_pose() -> void:
	var sk := _make_finger_rig()
	var names := PackedStringArray()
	for i in sk.get_bone_count():
		names.append(sk.get_bone_name(i))
	var resolved: Dictionary = GripScript.resolve_finger_bones(names, "r")
	var prox := sk.find_bone("index_proximal.R_2")
	var inter := sk.find_bone("index_intermediate.R_3")
	var distal := sk.find_bone("index_distal.R_4")
	var before := [sk.get_bone_pose(prox), sk.get_bone_pose(inter), sk.get_bone_pose(distal)]
	GripScript.apply_chain(sk, sk.find_bone("hand.R_1"), resolved, GripScript.Role.GRIP, "r")
	var changed: bool = sk.get_bone_pose(prox) != before[0] \
		or sk.get_bone_pose(inter) != before[1] \
		or sk.get_bone_pose(distal) != before[2]
	check_true(changed, "apply_chain 必须改写至少一节指骨的局部姿态（真的写了骨骼）")
	sk.free()


## 骨链不全时 apply_chain 安全无操作（不崩、不改骨）。
func test_apply_chain_is_safe_when_incomplete() -> void:
	var sk := _make_finger_rig()
	var resolved := {"index:proximal": -1, "index:intermediate": -1, "index:distal": -1}
	var distal := sk.find_bone("index_distal.R_4")
	var before: Transform3D = sk.get_bone_pose(distal)
	GripScript.apply_chain(sk, sk.find_bone("hand.R_1"), resolved, GripScript.Role.GRIP, "r")
	check_eq(sk.get_bone_pose(distal), before, "骨链缺失时不得改动任何骨")
	sk.free()


# ---------------------------------------------------------------------------
# ⑤ 接线口径：默认关 + 仅在 IK 生效时应用 + modifier 顺序 + 不走 RPC
# ---------------------------------------------------------------------------

## 造一个含左右手臂链 + 双手 15 指骨的合成骨架（供 IK + grip 接线用例）。
## ⚠ 保持**未入树**：入树后 `TwoBoneIK3D` 会被处理管线驱动，headless 下会让测试不稳/挂起。
func _make_full_rig() -> Skeleton3D:
	var sk := Skeleton3D.new()
	var defs: Array = [
		["hips_1", Vector3(0, 0.9, 0), -1],
		["upper_arm.L_2", Vector3(0.10, 1.10, 0), 0],
		["lower_arm.L_3", Vector3(0.32, 1.10, 0), 1],
		["hand.L_4", Vector3(0.54, 1.10, 0), 2],
		["upper_arm.R_5", Vector3(-0.10, 1.10, 0), 0],
		["lower_arm.R_6", Vector3(-0.32, 1.10, 0), 4],
		["hand.R_7", Vector3(-0.54, 1.10, 0), 5],
	]
	var n := 10
	for side in ["L", "R"]:
		var hand_parent := 3 if side == "L" else 6
		for finger in ["thumb", "index", "middle", "ring", "little"]:
			for joint in ["proximal", "intermediate", "distal"]:
				defs.append(["%s_%s.%s_%d" % [finger, joint, side, n], Vector3(0, 1.1, 0), hand_parent])
				n += 1
	for d in defs:
		var idx := sk.add_bone(String(d[0]))
		sk.set_bone_rest(idx, Transform3D(Basis(), d[1]))
		if int(d[2]) >= 0:
			sk.set_bone_parent(idx, int(d[2]))
	return sk


func test_grip_off_by_default_and_toggle() -> void:
	var model := MikuModel.new()
	check_false(model.hand_grip_enabled, "hand_grip_enabled 默认必须是 false（保基线）")
	model.set_hand_grip_enabled(true)
	check_true(model.hand_grip_enabled, "set_hand_grip_enabled(true) 应写开关")
	model.toggle_hand_grip()
	check_false(model.hand_grip_enabled, "toggle 应能关回去")
	model.free()


## grip **仅在 IK 生效时**应用：IK 关闭时即便 grip 开关打开也不生效（gating 只看开关语义）。
func test_grip_gated_on_ik_enabled() -> void:
	var sk := _make_full_rig()
	var model := Node3D.new()
	var ik = HoldIKScript.new()
	check_true(ik.setup(sk, model), "合成骨架应能搭起 IK + grip")
	ik.set_grip_enabled(true)
	check_false(ik.is_grip_enabled(), "IK 未生效时 grip 不得生效（否则空手也握拳）")
	ik.set_enabled(true)
	check_true(ik.is_enabled(), "IK 打开后应生效")
	check_true(ik.is_grip_enabled(), "IK 生效后 grip 才生效")
	ik.set_enabled(false)
	check_false(ik.is_grip_enabled(), "IK 关闭后 grip 不得再生效")
	ik.teardown() # WeaponHoldIK 是 RefCounted（自动释放，无需 free），只需拆掉它建的节点
	sk.free()
	model.free()


## 单手合成骨架（**入树**：grip modifier 的 get_skeleton() 需要节点在树内）。
func _make_hand_rig() -> Skeleton3D:
	var sk := Skeleton3D.new()
	add_child(sk)
	var hand := sk.add_bone("hand.R_1")
	sk.set_bone_rest(hand, Transform3D(Basis(), Vector3(0, 0, 0)))
	var n := 2
	for finger in ["thumb", "index", "middle", "ring", "little"]:
		var parent := hand
		var y := 0.02
		for joint in ["proximal", "intermediate", "distal"]:
			var idx := sk.add_bone("%s_%s.R_%d" % [finger, joint, n])
			sk.set_bone_rest(idx, Transform3D(Basis(), Vector3(0, y, 0)))
			sk.set_bone_parent(idx, parent)
			parent = idx
			y += 0.02
			n += 1
	return sk


## 集成：grip modifier 在真实（合成）骨架上解析出完整骨链，且处理时**真的写骨**（局部姿态改变）。
func test_grip_modifier_resolves_and_applies() -> void:
	var sk := _make_hand_rig()
	var mod = ModifierScript.new()
	mod.name = "HandGripTest"
	sk.add_child(mod)
	check_true(mod.configure("r", GripScript.Role.GRIP, "hand.R_1"),
		"应能解析出完整 15 根指骨（够用即 valid）")
	check_true(mod.is_valid(), "解析完整后 should is_valid()=true")
	var prox := sk.find_bone("index_proximal.R_5")
	check_true(prox >= 0, "应能找到食指近节")
	var before: Transform3D = sk.get_bone_pose(prox)
	mod._process_modification_with_delta(0.0) # 直接触发一次处理（等价于管线里那一帧）
	check_true(sk.get_bone_pose(prox) != before,
		"处理时必须改写指骨姿态（真的把角度写到了骨骼上）")
	sk.free()


## grip modifier 必须**排在两条 IK 之后**（子节点顺序 = modifier 执行顺序 ⇒ 在 IK 之后弯手指）。
func test_grip_modifiers_ordered_after_ik() -> void:
	var sk := _make_full_rig()
	var model := Node3D.new()
	var ik = HoldIKScript.new()
	ik.setup(sk, model)
	var ik_r := -1
	var grip_r := -1
	for i in sk.get_child_count():
		var c := sk.get_child(i)
		if String(c.name) == "HoldIK_R":
			ik_r = i
		elif String(c.name) == "HandGrip_R":
			grip_r = i
	check_true(ik_r >= 0, "应建 HoldIK_R")
	check_true(grip_r >= 0, "应建 HandGrip_R")
	check_true(grip_r > ik_r, "HandGrip_R 必须排在 HoldIK_R 之后（运行顺序在 IK 之后）")
	sk.free() # WeaponHoldIK 是 RefCounted（自动释放）；拆 sk 即连带释放它建的子节点
	model.free()


## modifier 必须继承 SkeletonModifier3D（在 AnimationMixer 之后、按子序运行）。
func test_modifier_extends_skeleton_modifier() -> void:
	check_true(ModifierScript.new() is SkeletonModifier3D,
		"HandGripModifier 必须继承 SkeletonModifier3D")


## 纯视觉：抓握相关脚本不得含 @rpc（用计数，避免断言数随文件行数漂移）。
func test_grip_is_pure_visual_no_rpc() -> void:
	for path in [GRIP_SRC, MOD_SRC]:
		check_eq(_count_rpc(_read_source(path)), 0, "%s 不得含 @rpc" % path.get_file())


# ---------------------------------------------------------------------------
# ⑥ 不抢骨骼：程序化姿态从不碰指骨
# ---------------------------------------------------------------------------

## MikuProceduralPose 源里不得出现指骨关节词（它只驱动腿 / 躯干 / 头 / 手臂）。
func test_procedural_pose_never_touches_fingers() -> void:
	var src := _read_source(POSE_SRC)
	for token in ["proximal", "intermediate", "distal"]:
		check_eq(src.to_lower().count(token), 0,
			"MikuProceduralPose 不得引用指骨关节词 %s（避免与抓握层抢骨骼）" % token)


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


func _strip_comment(line: String) -> String:
	var i := line.find("#")
	return line if i < 0 else line.substr(0, i)


func _count_rpc(src: String) -> int:
	var n := 0
	for raw in src.split("\n"):
		if _strip_comment(raw).find("@rpc") >= 0:
			n += 1
	return n
