extends TestSuite
## UAL locomotion 集成的回归锁（Spike 交付）。
##
## 背景：`cat_hatsune_miku` 自带 idle 剪辑是 **0.08 s 的 T-pose 定格**，而
## `MikuModel._start_procedural_pose` 是「全有或全无」⇒ 选定该模型后腿部完全不动。
## 本套件锁 UAL(Quaternius Universal Animation Library) locomotion 接入的**七组不变量**：
##   ① **只注册 4 条 locomotion 剪辑**，且范围规则真的挡得住枪械/死亡/大幅动作类。
##   ② **手臂排除**：手臂链与手指**不在**驱动集合里（让给 `WeaponHoldIK` + `HandGripModifier`）。
##   ③ **骨映射覆盖率**：驱动用的 12 根骨在两侧真实骨架里都存在。
##   ④ **拓扑序**：局部姿态换算要用父骨本帧姿态 ⇒ 配对必须父先于子（且与书写顺序无关）。
##   ⑤ **降级回退**：素材 / 骨架不匹配 ⇒ `valid=false`，且 MikuModel 回退程序化姿态（不出现「没腿」）。
##   ⑥ **接线口径**：新开关默认关；UAL 有效时与程序化姿态**互斥**；`miku.glb` 完全不受影响。
##   ⑦ **纯视觉**：不引入 RPC、不引入并行姿态系统。
##
## ## ⚠ 断言口径（控制清单 §4-16 双向）
## 一律按**行为 / 集合关系**断言，不锁字面量写法，避免误杀语义等价的改写；
## 守恒对照组见 `test_topological_order_is_independent_of_input_order` 与
## `test_bone_map_coverage_is_independent_of_dict_order`。
##
## ## ⚠ 本套件**不使用 `pending()`**
## `pending()` 是**用例级 note**，不影响断言计数与退出码（control_checklist §4-15）：
## 用它兜底会让用例「照常计入、什么都不验证」，伪装成绿灯。
## 素材类断言一律用**硬失败**表达缺失（`check_true(ps != null, ...)`），
## 因为 UAL 素材是本能力的**必需前提**，缺失本身就是缺陷。

const UalScript := preload("res://scripts/entities/ual_locomotion.gd")
const UalBoneMapScript := preload("res://scripts/entities/ual_bone_map.gd")
const HoldIKScript := preload("res://scripts/entities/weapon_hold_ik.gd")
const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const MIKU_MODEL := "res://assets/models/miku/miku.glb"
const UAL_GLB := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"

## MikuModel 既有默认（保住基线的前提）
const RUN_THRESHOLD := 0.62


# ---------------------------------------------------------------------------
# ① 剪辑范围：只 4 条，且规则挡得住越界类别
# ---------------------------------------------------------------------------

## 注册条数受控（范围锁）。⚠ 2026-10-07 由 4 改为 6（新增蹲姿两条），
## 数字本身就是「范围决策」的锚点 —— 增减都必须被看见（§4-15）。
func test_clip_table_has_exactly_four_locomotion_clips() -> void:
	var table: Dictionary = UalScript.verify_clip_table()
	check_true(bool(table["ok"]),
		"剪辑表必须合规（6 条 + 无越界）：%s" % str(table))
	check_eq(int(table["count"]), 6,
		"必须**只**注册 6 条 locomotion 剪辑（4 站立 + 2 蹲姿，范围已锁死）")


## 注册条数必须与实测选取的六条一一对应（2026-10-07 起含蹲姿两条）。
func test_clip_table_names_are_the_measured_six() -> void:
	var expected := ["Idle", "Walk", "Jog_Fwd", "Sprint", "Crouch_Idle", "Crouch_Fwd"]
	for clip in expected:
		check_true(String(clip) in UalScript.CLIPS.values(),
			"必须注册 %s（实测选取依据见 ual_locomotion.gd 的 CLIPS 注释）" % clip)
	check_eq(UalScript.CLIPS.size(), expected.size(),
		"注册条数必须与实测选取的六条一一对应")


## 范围规则的**反向验证**：把每个禁词拼成假剪辑名，必须**全部**被拒。
## ⚠ 这条是防「假绿」的关键：只断言「表里没有枪械类」是不够的 ——
##   若 `is_clip_allowed` 恒返回 true，表里恰好没写枪械类也会全绿。
func test_forbidden_clip_categories_are_actually_rejected() -> void:
	for kw in UalScript.FORBIDDEN_CLIP_KEYWORDS:
		check_false(UalScript.is_clip_allowed("Clip_%s" % String(kw)),
			"「%s」类剪辑必须被范围规则拒绝（枪械/死亡/大幅动作会穿帮，见评估报告）" % String(kw))


## 白名单语义：不在 4 条白名单里的 locomotion 类剪辑也不放行（默认拒绝）。
## 如 `Walk_Formal`（周期与 Walk 相同但手摆只有一半，端着手走，与持枪玩法错配）。
func test_non_whitelisted_locomotion_clip_is_rejected() -> void:
	check_false(UalScript.is_clip_allowed("Walk_Formal"),
		"Walk_Formal 不在白名单 ⇒ 必须拒绝（手摆幅度只有 Walk 的一半，会与持枪玩法错配）")
	check_true(UalScript.is_clip_allowed("Walk"), "白名单内的 Walk 必须放行")


## 真实素材里这 4 条剪辑确实存在（防止映射表与素材脱节 ⇒ 播不到却静默）。
func test_registered_clips_exist_in_real_asset() -> void:
	var ps: PackedScene = load(UAL_GLB)
	check_true(ps != null, "UAL 素材必须存在（res://assets/animations/ual/...glb）")
	if ps == null:
		return
	var inst: Node = ps.instantiate()
	add_child(inst)
	var ap := _find_ap(inst)
	check_true(ap != null, "UAL 必须含 AnimationPlayer")
	if ap == null:
		inst.queue_free()
		return
	for state in UalScript.CLIPS:
		check_true(ap.has_animation(String(UalScript.CLIPS[state])),
			"素材里必须有剪辑 %s（状态 %s）" % [String(UalScript.CLIPS[state]), String(state)])
	# 反向：素材里的死亡 / 枪械类**不得**出现在我们的注册表里
	for forbidden in ["Death01", "Pistol_Shoot", "Jump", "Roll"]:
		if ap.has_animation(forbidden):
			check_false(String(forbidden) in UalScript.CLIPS.values(),
				"%s 不得被注册（大幅动作 / 枪械类会穿帮）" % forbidden)
	inst.queue_free()


# ---------------------------------------------------------------------------
# ② 手臂排除（本能力最核心的纪律：两层不能抢同一批骨）
# ---------------------------------------------------------------------------

## 驱动集合与手臂链**完全不相交**。
func test_arm_chain_is_disjoint_from_drive_set() -> void:
	check_true(UalScript.leg_torso_and_arm_are_disjoint(),
		"手臂链（shoulder/upper_arm/lower_arm/hand ×2）绝不能出现在驱动集合里——否则与 TwoBoneIK3D 抢骨")


## 逐根手臂骨分类必须是 `"arm"`（正向锁定，不是只查一次不相交）。
func test_each_arm_bone_classifies_as_arm() -> void:
	for arm_bone in UalScript.ARM_CHAIN_UAL:
		check_eq(String(UalScript.classify_bone(String(arm_bone), false)), "arm",
			"%s 必须被分类为 arm（让给 IK）" % String(arm_bone))


## 手指骨不得被驱动（归 `HandGripModifier`）—— 用映射后的 **cat 骨名**判定，
## 因为「UAL 侧没写手指」与「cat 侧没写手指」是两件事，后者才决定实际写入。
func test_finger_bones_are_never_driven() -> void:
	check_true(UalScript.drive_has_no_fingers(),
		"驱动集合不得含任何手指骨（握枪手势由 HandGripModifier 独立驱动）")


## 守恒对照组：**手臂排除这条纪律不能靠"恰好没映射"蒙混**。
## 构造一个「含手臂」的假驱动集合，用**同一套判定语义**（逐骨查 `ARM_CHAIN_UAL` 成员）
## 验证它会被判为相交 —— 证明上面的不相交断言真的有鉴别力，不是恒真的假绿。
func test_arm_exclusion_check_has_discriminating_power() -> void:
	# 假驱动集合：故意混入两根手臂骨
	var fake_drive := ["DEF-hips", "DEF-upper_arm.L", "DEF-hand.R"]
	var intersects := false
	for b in fake_drive:
		if String(b) in UalScript.ARM_CHAIN_UAL:
			intersects = true
	check_true(intersects,
		"守恒对照：混入 UpperArm.L / Hand.R 的假驱动集合必须被判为相交（否则不相交断言是恒真的假绿）")
	# 反向：只含非手臂骨（真实形态）必须判为不相交
	var clean := ["DEF-hips", "DEF-thigh.L", "DEF-toe.R"]
	var clean_intersects := false
	for b in clean:
		if String(b) in UalScript.ARM_CHAIN_UAL:
			clean_intersects = true
	check_false(clean_intersects,
		"守恒对照：只含腿 / 躯干骨的集合必须判为不相交（证明判据不是「见任何骨都算相交」）")
	check_true(UalScript.leg_torso_and_arm_are_disjoint(),
		"守恒锚点：真实驱动集合仍必须是不相交的那一个（不被上面的假集合污染）")


## 手臂让出的**动机**要被锁住：空手时若无人接管，cat 的 rest 是 T-pose（穿帮）。
## 所以「UAL 不碰手臂」的前提是**程序化姿态接手**——由 ⑤ / ⑥ 的回退与互斥用例保证。
func test_arm_exclusion_is_backed_by_procedural_fallback() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = true
	add_child(model)
	check_true(model.is_ual_locomotion_active(), "cat + 开关打开 ⇒ UAL 应接管腿 + 躯干")
	# 持枪 / 空手两种手臂归属都必须存在：IK（持枪）与程序化姿态（空手）
	check_true(model.is_hold_ik_available(), "持枪手臂归属：IK 必须可用（否则 UAL 让出的手臂无人接管）")
	model.queue_free()


## 手臂归属切换：**空手时 UAL 必须驱动手臂**，否则 cat 的 rest = T-pose 穿帮。
## ⚠ 这条守护的是本轮**实测发现并修掉的真缺陷**：
##   最初设计是「UAL 无条件排除手臂，空手交给 MikuProceduralPose」，
##   但 UAL 有效时程序化姿态是**互斥关闭**的 ⇒ 空手**没有任何东西驱动手臂**
##   ⇒ 实拍 `tmp_spike/loco_ual_walk_1.png` 里手臂笔直平举（T-pose）。
func test_empty_hand_arms_are_driven_by_ual() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = true
	model.hold_ik_enabled = true
	add_child(model)
	check_true(model.is_ual_locomotion_active(), "前置：UAL 应已接管")
	# 空手（默认未持械）⇒ IK 不生效 ⇒ UAL 必须接管手臂，否则就是 T-pose
	check_false(model._hold_ik.is_enabled(), "空手时 IK 不应生效")
	check_true(model._ual_loco.arms_driven,
		"空手时 UAL 必须驱动手臂（否则无人驱动 = cat rest 的 T-pose，截图已证实是穿帮）")
	var sk := _find_skel(model.get_child(0))
	var written: Array = []
	for entry in model._ual_loco.debug_pairs:
		written.append(String(sk.get_bone_name(int(entry[1]))))
	check_true(written.has("upper_arm.L_68") and written.has("hand.R_85"),
		"空手时写入列表必须含手臂骨（实测写入 %s）" % str(written))
	model.queue_free()


## 持枪时 UAL 必须**让出**手臂（`arms_driven = false`），否则与 TwoBoneIK3D 抢同一批骨。
## 这是「两层不打架」的正向锁。
func test_armed_hands_yield_arms_to_ik() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = true
	model.hold_ik_enabled = true
	add_child(model)
	check_true(model.is_ual_locomotion_active(), "前置：UAL 应已接管")
	model.set_holding_weapon(true) # 持枪 ⇒ IK 生效 ⇒ UAL 让出手臂
	check_true(model._hold_ik.is_enabled(), "持枪时 IK 应生效")
	check_false(model._ual_loco.arms_driven,
		"持枪时 UAL 必须让出手臂（让给 TwoBoneIK3D，否则抢同一批骨）")
	var sk := _find_skel(model.get_child(0))
	var written: Array = []
	for entry in model._ual_loco.debug_pairs:
		written.append(String(sk.get_bone_name(int(entry[1]))))
	check_false(written.has("upper_arm.L_68"),
		"持枪时写入列表**不得**含手臂骨（实测 %s）" % str(written))
	# 腿仍然由 UAL 驱动（让出的只是手臂）
	check_true(written.has("upper_leg.L_100"), "持枪时 UAL 仍应驱动腿")
	model.queue_free()


## 归属切换的**往返**必须稳定（不残留、不累积）：持枪→空手→持枪。
func test_arm_ownership_toggles_both_ways() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = true
	model.hold_ik_enabled = true
	add_child(model)
	check_true(model._ual_loco.arms_driven, "起始（空手）⇒ UAL 驱动手臂")
	model.set_holding_weapon(true)
	check_false(model._ual_loco.arms_driven, "持枪 ⇒ 让出")
	model.set_holding_weapon(false)
	check_true(model._ual_loco.arms_driven, "空手 ⇒ 收回")
	model.set_holding_weapon(true)
	check_false(model._ual_loco.arms_driven, "再持枪 ⇒ 再让出")
	check_true(model.is_ual_locomotion_active(), "往返切换不得让 UAL 失效")
	model.queue_free()


## 切回手臂时**先复位**再重建（否则上一轮写过的肩/臂姿态会残留）。
## 用「配对表里手臂骨数量」验证重建发生，而不是靠肉眼。
func test_arm_ownership_switch_rebuilds_pairs() -> void:
	var loco = UalScript.new()
	var sk_ctx := _skel(CAT_MODEL)
	if sk_ctx == null:
		return
	var host := Node3D.new()
	add_child(host)
	if not loco.setup(sk_ctx, host):
		check_true(false, "cat 骨架必须能搭起 UAL locomotion")
		host.queue_free()
		return
	var legs_only: int = loco.debug_pairs.size()
	loco.set_arms_driven(true)
	var with_arms: int = loco.debug_pairs.size()
	check_eq(with_arms, legs_only + UalScript.ARM_CHAIN_UAL.size(),
		"开启手臂驱动后配对数应 +%d（%d → %d）" % [
			UalScript.ARM_CHAIN_UAL.size(), legs_only, with_arms])
	loco.set_arms_driven(false)
	check_eq(loco.debug_pairs.size(), legs_only, "关闭后配对数应回到原值")
	loco.teardown()
	host.queue_free()


## 手指骨**任何情况下**都不驱动（持枪 / 空手都一样）—— 手指归 HandGripModifier。
## 用 `driven_bones(true)`（空手、手臂最多的情形）验证，最严格。
func test_fingers_never_driven_even_when_arms_are() -> void:
	for ual_bone in UalScript.driven_bones(true):
		var cat_bone := String(UalBoneMapScript.UAL_TO_CAT.get(String(ual_bone), "")).to_lower()
		for kw in UalScript.FINGER_BONE_KEYWORDS:
			check_false(cat_bone.contains(String(kw)),
				"手指骨不得被驱动（%s 含 %s）" % [cat_bone, String(kw)])


## IK 的 influence 渐变：默认 blend_time=0（既有行为不变）；开启后能产生中间权重。
## 守护「切手臂归属不跳变」这个修复不被静默回退。
func test_ik_influence_blend_is_opt_in_and_works() -> void:
	var ik = HoldIKScript.new()
	check_true(is_zero_approx(ik.blend_time),
		"blend_time 默认必须 0（不改变既有 IK 行为 / 测试口径）")
	var sk := _make_arm_skeleton()
	var model := Node3D.new()
	check_true(ik.setup(sk, model), "标准骨架应能搭起 IK")

	# ① blend_time = 0（默认）⇒ set_enabled 立即给满权重（既有行为）
	ik.set_enabled(false)
	ik.set_enabled(true)
	check_near(ik.get_influence(), 1.0, 1e-6, "blend_time=0 时 enable 应立即满权重（既有行为）")
	check_near(ik.blend_time, 0.0, 1e-9, "默认 blend_time 仍为 0")

	# ② 开启渐变后，**从 0 起**的 0→1 过渡必须经过中间值
	#    （这才是「装备武器」的真实路径：influence 初始为 0）
	ik.blend_time = 0.2
	ik.set_enabled(false)
	ik.tick(1.0)              # 先让它归零
	check_near(ik.get_influence(), 0.0, 1e-6, "disable 后 influence 应归零")
	ik.set_enabled(true)      # 此刻 influence 仍是 0，target 变 1 ⇒ 必须渐变
	var seen_mid := false
	for i in 10:
		ik.tick(0.02)         # 0.02 / 0.2 = 每帧 10%
		var w := ik.get_influence()
		check_true(w <= 1.0 + 1e-6, "influence 不得 > 1（实际 %f）" % w)
		if w > 0.001 and w < 0.999:
			seen_mid = true
	check_true(seen_mid, "开启 blend_time 后 influence 必须经过中间值（否则等于硬切，跳变没被消除）")
	# 反向：1→0 也应渐变（卸枪时同样不能跳）
	var saw_descending := false
	var prev := ik.get_influence()
	ik.set_enabled(false)
	for i in 10:
		ik.tick(0.02)
		var w2 := ik.get_influence()
		if w2 < prev - 1e-6:
			saw_descending = true
		prev = w2
	check_true(saw_descending, "卸枪方向也必须渐变（1→0），否则来回切换仍有一半是硬切")
	ik.teardown()
	sk.free()
	model.free()


## 接线口径：UAL 生效时 MikuModel 必须给 IK 打开 influence 渐变（否则上面那个修复形同虚设）。
func test_ik_blend_is_enabled_when_ual_drives() -> void:
	var with_ual := MikuModel.new()
	with_ual.model_path = CAT_MODEL
	with_ual.ual_locomotion_enabled = true
	add_child(with_ual)
	check_true(with_ual.is_ual_locomotion_active(), "前置：UAL 应已接管")
	check_true(with_ual._hold_ik != null, "IK 应已搭建")
	if with_ual._hold_ik != null:
		check_true(with_ual._hold_ik.blend_time > 0.0,
			"UAL 接管时必须给 IK 开 influence 渐变（否则切手臂会跳变）")
	with_ual.queue_free()
	# 未启用 UAL 时保持 0（既有行为不变）
	var without_ual := MikuModel.new()
	without_ual.model_path = CAT_MODEL
	without_ual.ual_locomotion_enabled = false
	add_child(without_ual)
	if without_ual._hold_ik != null:
		check_true(is_zero_approx(without_ual._hold_ik.blend_time),
			"未启用 UAL 时 blend_time 必须仍为 0（既有 IK 行为不变）")
	without_ual.queue_free()

# ---------------------------------------------------------------------------
# ③ 骨映射覆盖率（真实资产）
# ---------------------------------------------------------------------------

## 驱动用的每一根骨，在 UAL 与 cat 两侧真实骨架里都必须存在（覆盖率 100%）。
func test_drive_bones_exist_on_both_real_skeletons() -> void:
	var usk := _skel(UAL_GLB)
	var csk := _skel(CAT_MODEL)
	if usk == null or csk == null:
		return
	var missing: Array[String] = []
	for ual_bone in UalScript.LEG_TORSO_UAL_BONES:
		var cat_bone := String(UalBoneMapScript.UAL_TO_CAT.get(String(ual_bone), ""))
		if cat_bone == "":
			missing.append("%s（无 cat 映射）" % String(ual_bone))
			continue
		if usk.find_bone(String(ual_bone)) < 0:
			missing.append("%s（UAL 侧无此骨）" % String(ual_bone))
		if csk.find_bone(cat_bone) < 0:
			missing.append("%s→%s（cat 侧无此骨）" % [String(ual_bone), cat_bone])
	check_eq(missing.size(), 0, "驱动骨必须在两侧都存在，缺失：%s" % str(missing))


## 骨映射表整体自检（沿用 ual_bone_map.gd 的 verify；52/53 是已知结论）。
func test_bone_map_self_check_passes() -> void:
	var usk := _skel(UAL_GLB)
	var csk := _skel(CAT_MODEL)
	if usk == null or csk == null:
		return
	var report: Dictionary = UalBoneMapScript.verify(usk, csk)
	check_true(bool(report["ok"]),
		"骨映射自检必须通过，UAL 缺 %s / cat 缺 %s" % [
			str(report["ual_missing"]), str(report["cat_missing"])])
	# 覆盖率：驱动骨必须 100% 命中（整体映射是 52/53，允许 1 处主链缺口）
	var drive := UalScript.LEG_TORSO_UAL_BONES.size()
	var mapped := 0
	for ual_bone in UalScript.LEG_TORSO_UAL_BONES:
		if String(UalBoneMapScript.UAL_TO_CAT.get(String(ual_bone), "")) != "":
			mapped += 1
	check_eq(mapped, drive, "驱动骨的映射覆盖率必须 100%%（%d/%d）" % [mapped, drive])


## 守恒对照组：骨映射自检**不依赖字典书写顺序**（语义等价的改写仍应全绿）。
## 把 UAL_TO_CAT 反转（键值对调书写）后自检结论必须不变 —— 防「按字面量顺序断言」的误杀。
func test_bone_map_coverage_is_independent_of_dict_order() -> void:
	var csk := _skel(CAT_MODEL)
	if csk == null:
		return
	var forward: Array = UalBoneMapScript.UAL_TO_CAT.keys()
	var backward: Array = forward.duplicate()
	backward.reverse()
	var count_a := 0
	var count_b := 0
	for k in forward:
		if String(UalBoneMapScript.UAL_TO_CAT[k]) != "":
			count_a += 1
	# 反序遍历同样应数到同样多的有效映射（证明统计与顺序无关）
	for k in backward:
		if String(UalBoneMapScript.UAL_TO_CAT[k]) != "":
			count_b += 1
	check_eq(count_a, count_b, "映射覆盖率不得依赖字典书写顺序（守恒对照）")
	# 覆盖率分母是 **UAL 侧**骨数（映射的源），不是 cat 侧骨数。
	# ⚠ 用 cat 骨数（111）当分母会把 52/53 算成 47% —— 那是分母选错，不是覆盖率真的掉了。
	var usk := _skel(UAL_GLB)
	if usk == null:
		return
	check_ge(count_a / float(maxf(usk.get_bone_count(), 1)), 0.9,
		"映射覆盖率（分母=UAL 骨数 %d）应 ≥ 90%%（实测 52/53 = 98.1%%）" % usk.get_bone_count())


# ---------------------------------------------------------------------------
# ④ 拓扑序（正确性关键：局部姿态换算依赖父骨本帧姿态）
# ---------------------------------------------------------------------------

## 真实 cat 骨架上，驱动配对必须父先于子。
## 用组件自己的排序函数 + 真实骨架，而不是断言列表字面量顺序。
func test_drive_pairs_are_topologically_sorted_on_real_skeleton() -> void:
	var csk := _skel(CAT_MODEL)
	if csk == null:
		return
	var count := csk.get_bone_count()
	var parents := PackedInt32Array()
	parents.resize(count)
	for i in count:
		parents[i] = csk.get_bone_parent(i)
	var ordered: Array = UalScript.sort_pairs_topologically(
		UalScript.LEG_TORSO_UAL_BONES, UalBoneMapScript.UAL_TO_CAT, parents,
		func(bone_name: String) -> int: return csk.find_bone(bone_name))
	check_eq(ordered.size(), UalScript.LEG_TORSO_UAL_BONES.size(),
		"排序后不得丢骨（%d → %d）" % [UalScript.LEG_TORSO_UAL_BONES.size(), ordered.size()])

	# 先算出「本轮会被写的 cat 骨集合」—— 只有它里面的父骨才构成拓扑约束。
	# ⚠ 不能拿整个 UAL_TO_CAT 当集合：`root`→`root_107` 在映射表里，但 root 被**刻意排除**
	#   （根骨位移会和贴地闭环打架）。它不是驱动骨，因此不参与排序约束。
	var driven := {}
	for ual_bone in ordered:
		driven[csk.find_bone(String(UalBoneMapScript.UAL_TO_CAT.get(String(ual_bone), "")))] = true

	var emitted := {}
	var violations: Array[String] = []
	for ual_bone in ordered:
		var cat_bone := String(UalBoneMapScript.UAL_TO_CAT.get(String(ual_bone), ""))
		var ci := csk.find_bone(cat_bone)
		var cp := csk.get_bone_parent(ci)
		# 只有「父骨也在本轮写入集合里」才要求它更早；父不在集合 ⇒ 它保持 rest，语义正确
		if cp >= 0 and driven.has(cp) and not emitted.has(cp):
			violations.append("%s 排在父骨 %s 之前" % [cat_bone, csk.get_bone_name(cp)])
		emitted[ci] = true
	check_eq(violations.size(), 0, "配对必须父先于子（局部姿态换算依赖它）：%s" % str(violations))
	# 至少要真正形成一条父子链（否则上面「无违规」是因为集合里全是根骨而空转）
	check_ge(driven.size(), 10, "驱动骨数量应 ≥ 10（实测 12：躯干 4 + 双腿 8），否则断言空转")


## 守恒对照组：**输入顺序不影响输出顺序**（语义等价的改写仍应通过）。
## 把 DRIVE_UAL_BONES 反序传入，结果集必须完全相同 —— 这是拓扑排序的正确性锚点。
func test_topological_order_is_independent_of_input_order() -> void:
	var csk := _skel(CAT_MODEL)
	if csk == null:
		return
	var count := csk.get_bone_count()
	var parents := PackedInt32Array()
	parents.resize(count)
	for i in count:
		parents[i] = csk.get_bone_parent(i)
	var resolve := func(bone_name: String) -> int: return csk.find_bone(bone_name)

	var forward_input: Array = UalScript.LEG_TORSO_UAL_BONES.duplicate()
	var reversed_input: Array = UalScript.LEG_TORSO_UAL_BONES.duplicate()
	reversed_input.reverse()

	var a: Array = UalScript.sort_pairs_topologically(
		forward_input, UalBoneMapScript.UAL_TO_CAT, parents, resolve)
	var b: Array = UalScript.sort_pairs_topologically(
		reversed_input, UalBoneMapScript.UAL_TO_CAT, parents, resolve)

	check_eq(a.size(), b.size(), "输入反序不得改变输出条数（守恒对照）")
	var same := true
	for i in mini(a.size(), b.size()):
		if String(a[i]) != String(b[i]):
			same = false
	check_true(same,
		"拓扑序必须由骨架父子关系唯一决定，与输入书写顺序无关（实际：%s vs %s）" % [str(a), str(b)])


## 含环输入必须被拒（返回空数组）而不是静默产出错误顺序。
## 没有这条，排序函数在环形骨架上会悄悄给出错序 ⇒ 表现为腿歪 / 滑步且极难定位。
func test_topological_sort_rejects_cyclic_input() -> void:
	# 人造一个环：cat_idx 1 的父是 2，2 的父是 1
	var parents := PackedInt32Array([-1, 2, 1])
	var mapping := {"A": "a", "B": "b"}
	var resolve := func(bone_name: String) -> int:
		return {"a": 1, "b": 2}.get(bone_name, -1)
	var out: Array = UalScript.sort_pairs_topologically(["A", "B"], mapping, parents, resolve)
	check_eq(out.size(), 0, "检测到环时必须返回空数组让调用方判失败（不得静默错序）")


## 无法解析的骨被丢弃（而不是塞进配对表写出错姿态）。
func test_topological_sort_drops_unresolvable_bones() -> void:
	var parents := PackedInt32Array([-1, -1])
	var mapping := {"A": "a", "GHOST": "not_here"}
	var resolve := func(bone_name: String) -> int:
		return {"a": 1, "not_here": -1}.get(bone_name, -1)
	var out: Array = UalScript.sort_pairs_topologically(["A", "GHOST"], mapping, parents, resolve)
	check_eq(out.size(), 1, "解析不到的骨必须被丢弃")
	check_eq(String(out[0]), "A", "剩下的是可解析的那根")


# ---------------------------------------------------------------------------
# ⑤ 状态选择（速度分档）
# ---------------------------------------------------------------------------

## 速度分档：站 / 走 / 跑 / 冲四档，且与本项目速度常量单调对应。
## ⚠ 2026-10-07：满速（ratio=1.0）现在落在 **"run"** 而不是 "sprint" ——
##   这是**用户明确要求**的（「开着但 sprint 够不到」，因Sprint 大动作会让双马尾穿帮）。
##   单独的可达性断言见 `test_sprint_band_is_intentionally_unreachable`。
func test_state_selection_covers_four_gait_bands() -> void:
	var st := func(moving: bool, ratio: float) -> String:
		return String(UalScript.select_state(moving, ratio, true,
			RUN_THRESHOLD, float(UalScript.SPRINT_THRESHOLD)))
	check_eq(st.call(false, 0.0), "idle", "静止 ⇒ idle")
	check_eq(st.call(true, 0.3), "walk", "低速移动 ⇒ walk")
	check_eq(st.call(true, 0.554), "walk",
		"player walk_speed 3.6 / sprint 6.5 = 0.554 ⇒ walk（实测值）")
	check_eq(st.call(true, 0.8), "run", "超过 run_threshold 0.62 ⇒ run")
	# 满速仍高于 run 阈值 ⇒ 进 run 档（**而不是**掉回 walk）
	check_eq(st.call(true, 1.0), "run",
		"满速（6.5/6.5=1.0）⇒ run 档：sprint 档被阈值 1.1 挡住（用户要求够不到）")
	# 守恒对照：显式给一个能到 sprint 的阈值时，满速**必须**能进 sprint
	#（证明上面那条不是「select_state 坏了」，而是阈值刻意挡住了它）
	check_eq(String(UalScript.select_state(true, 1.0, true, RUN_THRESHOLD, 0.9)), "sprint",
		"守恒对照：阈值改成 0.9 时满速必须能进 sprint（证明上条是阈值刻意为之，非逻辑损坏）")


## 不在地面时不切状态（返回空串 = 保持当前剪辑）⇒ 跳跃时腿不会突然僵住。
func test_state_selection_keeps_state_when_airborne() -> void:
	check_eq(String(UalScript.select_state(true, 1.0, false,
		RUN_THRESHOLD, float(UalScript.SPRINT_THRESHOLD))), "",
		"不在地面 ⇒ 返回空串（调用方保持当前剪辑，腿不僵）")
	# 蹲姿在空中同样不切（保持蹲姿剪辑，不回站姿）
	check_eq(String(UalScript.select_state(false, 0.0, false,
		RUN_THRESHOLD, float(UalScript.SPRINT_THRESHOLD), true)), "",
		"蹲姿 + 不在地面 ⇒ 同样返回空串（不会在跳跃中途弹回站姿）")


## 阈值单调性：冲刺阈值必须高于 run 阈值，且**必须高于 speed_ratio 的上界 1.0**
## ⇒「冲刺档够不到」是**结构上**保证的，而不是靠碰巧没人跑满速。
##
## ⚠ 2026-10-07 反转：原断言要求阈值 ≤ 1.0（那时 Sprint 可达）。
##   用户要求改为「sprint 够不到」⇒ 阈值必须 > 1.0。
##   `speed_ratio` 的上界来自 `player.gd:299` 的
##   `clampf(move_speed / sprint_speed, 0.0, 1.0)` —— clamp 到 1.0 ⇒ 不可能超过 1.0。
func test_sprint_band_is_intentionally_unreachable() -> void:
	check_true(float(UalScript.SPRINT_THRESHOLD) > RUN_THRESHOLD,
		"冲刺阈值(%.2f) 必须高于 run 阈值(%.2f)" % [float(UalScript.SPRINT_THRESHOLD), RUN_THRESHOLD])
	# ⭐ 核心断言：阈值高于 speed_ratio 的**数学上界** ⇒ 任何实机速度都进不了冲刺档
	#（本项目 TestSuite 只有 check_ge / check_le，没有 check_gt ⇒ 用 `not check_le` 表达「严格大于」）
	check_false(float(UalScript.SPRINT_THRESHOLD) <= 1.0,
		"冲刺阈值必须 > 1.0：speed_ratio 被 clamp 到 [0,1]（player.gd:299），故 1.0 是上界")
	# 对照：`MikuModel` 实际传给状态机的那个阈值也必须同样 > 1.0
	var model := MikuModel.new()
	check_false(model.ual_sprint_threshold <= 1.0,
		"MikuModel.ual_sprint_threshold 默认也必须 > 1.0（否则实机路径仍能进 sprint）")
	model.free()


# ---------------------------------------------------------------------------
# ⑥ 降级回退 + 接线口径（默认不破坏基线）
# ---------------------------------------------------------------------------

## UAL 开关默认**打开**（2026-10-07 按用户明确要求：「开着但 sprint 够不到」）。
##
## ⚠ 本用例的断言方向在 2026-10-07 **反转过**（这是需求变更，不是代码改动带来的）：
##   集成 UAL 之初默认false，用来保证「不破坏基线」；随后用户实机验收并要求开启
##   ——因为 cat 自带的 idle 是0.083 s 的 T-pose 定格，只有 UAL 能给它真实的腿动作。
##   ⇒ 默认值改为 true，但**开关本身保留**（可随时置 false 回退纯程序化步态）。
func test_ual_switch_defaults_on_per_user_request() -> void:
	var model := MikuModel.new()
	check_true(model.ual_locomotion_enabled,
		"ual_locomotion_enabled 默认必须 true（用户 2026-10-07 明确要求开启 UAL）")
	check_false(model.is_ual_locomotion_active(), "未载入模型时 UAL 不得「已激活」")
	# 开关仍可回退：置 false 后不应激活（证明保留回退能力，而不是写死）
	model.ual_locomotion_enabled = false
	check_false(model.ual_locomotion_enabled, "开关必须仍可运行时置 false（保留回退能力）")
	model.free()


## UAL 关闭时，cat 必须回退到**能动的**路径（不得停在 T-pose）。
##
## ⚠ 本用例在 2026-10-07 改过断言方向，原因是一次**真实缺陷**（不是重构）：
##   原断言是「UAL 默认关闭 ⇒ cat 仍走 AnimationPlayer、不建程序化姿态」，
##   而 cat 自带的 idle 剪辑经实测是 **0.083 s 的 T-pose 定格**
##   （98 条骨骼轨道只有 1 条会动，`chest_94` 偏航 0°→19.7°；双腿骨**一条轨道都没有**）。
##   那条断言等于把「T-pose 且纹丝不动」锁成正确行为 —— 用户实机报告的现象正是如此。
##   现在加了「退化剪辑」判据（见 `MikuModel.is_degenerate`），该 idle 被判退化
##   ⇒ 没有可用状态剪辑 ⇒ **回退 MikuProceduralPose**，腿才会动。
##   ⇒ 断言改为锁真正的不变量：**「有程序化姿态在驱动腿」**，
##      并且「退化剪辑绝不会被 play()」（后者是「轻微抽搐」的根因锁）。
func test_ual_off_falls_back_to_a_moving_path_for_cat() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = false
	add_child(model)
	check_false(model.is_ual_locomotion_active(), "UAL 关闭时不得接管")
	# cat 的唯一状态剪辑是退化的 ⇒ 必须有程序化姿态接管腿，否则角色 T-pose 不动
	check_true(model._procedural != null and model._procedural.valid,
		"UAL 关闭且唯一状态剪辑退化时，必须回退 MikuProceduralPose（否则 = T-pose 缺陷复现）")
	check_true(model._clip_is_degenerate(String(model._state_clips.get("idle", ""))),
		"cat 的 idle 必须被判为退化剪辑（0.083 s / 会动轨道占比 1.0%）")
	model.queue_free()


## 开关打开 + cat ⇒ UAL 接管腿 + 躯干，且**不建**程序化姿态（互斥，不抢同一批骨）。
func test_ual_and_procedural_pose_are_mutually_exclusive() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = true
	add_child(model)
	check_true(model.is_ual_locomotion_active(), "cat + 开关打开 ⇒ UAL 接管腿 + 躯干")
	check_true(model._procedural == null,
		"UAL 有效时**不得**同时建程序化姿态（两者都写腿骨 ⇒ 会打架）")
	model.queue_free()


## 降级回退（**绝不出现「没腿」**）：骨架不匹配的模型（乱码骨名的 miku.glb）
## ⇒ UAL 必然 valid=false，且**程序化姿态接管**（腿仍然会动）。
func test_falls_back_to_procedural_pose_when_skeleton_does_not_match() -> void:
	var model := MikuModel.new()
	model.model_path = MIKU_MODEL # 骨名乱码 ⇒ UAL 骨映射必然配不出驱动骨
	model.ual_locomotion_enabled = true
	add_child(model)
	check_false(model.is_ual_locomotion_active(),
		"骨架不匹配时 UAL 必须判定为不可用（不得半吊子生效）")
	check_true(model._procedural != null and model._procedural.valid,
		"必须自动回退 MikuProceduralPose —— 角色不能变成「没腿」")
	model.queue_free()


## 默认模型 `miku.glb` 的路径**完全不受影响**：开关开关都走既有兜底，UAL 不介入。
func test_default_miku_model_path_is_unaffected() -> void:
	var model := MikuModel.new() # 默认 model_path 就是 miku.glb
	add_child(model)
	check_false(model.is_ual_locomotion_active(), "默认模型下 UAL 不得激活")
	check_true(model._procedural != null and model._procedural.valid,
		"默认模型必须照旧由程序化姿态接管腿（基线行为）")
	check_eq(String(model.model_path), MIKU_MODEL, "默认模型路径未被本能力改动")
	model.queue_free()


## `miku.glb`（乱码骨名，默认模型）在开关**打开**时也不受 UAL 干扰。
## 与上一条对照：证明 UAL 对它「透明」—— 既不接管、也不破坏既有兜底。
func test_ual_switch_on_does_not_disturb_default_model() -> void:
	var model := MikuModel.new()
	model.ual_locomotion_enabled = true
	add_child(model)
	check_false(model.is_ual_locomotion_active(),
		"默认模型（乱码骨名）下 UAL 必须不激活 —— 它认不出驱动骨")
	check_true(model._procedural != null and model._procedural.valid,
		"开关打开也不得让默认模型失去腿部动作")
	model.queue_free()


## UAL 源实例必须被正确回收（它挂在 MikuModel 下，**不随模型骨架释放** ⇒ 需显式 teardown）。
## 残留会造成节点泄漏 + 隐藏的 mannequin 节点累积。
func test_ual_source_node_is_cleaned_up_on_model_reload() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = true
	add_child(model)
	check_true(model.is_ual_locomotion_active(), "前置：UAL 应已接管")
	check_eq(_count_ual_sources(model), 1, "UAL 源实例应恰好挂 1 个")
	# 重载模型（换路径）⇒ 必须走 teardown，不能留下旧源实例
	model.load_model(MIKU_MODEL)
	check_eq(_count_ual_sources(model), 0,
		"重载模型后 UAL 源实例必须被 teardown 掉（否则泄漏 + 隐藏节点累积）")
	check_false(model.is_ual_locomotion_active(), "重载到不匹配的模型后 UAL 应不再接管")
	check_true(model._procedural != null, "重载后仍必须有程序化姿态兜底（不出现没腿）")
	model.queue_free()


## 同上，但**反复重载** —— 这是泄漏的**判定性证据**：
## 只查一次可能碰巧过关（例：旧节点尚未释放），查 N 轮后仍为 0 才说明真的没累积。
## ⚠ 这条守护的是本轮实测修掉的两个真 bug：
##   `reset_bone_pose_rotation`（Skeleton3D 上不存在）抛错**中断 teardown** ⇒ `_source` 永不释放。
func test_ual_source_node_does_not_accumulate_across_reloads() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = true
	add_child(model)
	check_true(model.is_ual_locomotion_active(), "前置：UAL 应已接管")
	for i in 4:
		model.load_model(CAT_MODEL)
		model.load_model(MIKU_MODEL)
	check_eq(_count_ual_sources(model), 0,
		"反复重载 4 轮后 UAL 源节点必须仍为 0（若随轮数增长 = 真泄漏）")
	check_true(model.is_ual_locomotion_active() == false, "末轮停在 miku.glb ⇒ UAL 不接管")
	model.queue_free()


## 素材存在性（`asset_available`）与磁盘一致 —— 缺素材必须让 UAL 判定不可用而不是崩。
func test_asset_available_matches_real_file() -> void:
	check_true(UalScript.asset_available(), "UAL 素材应存在（%s）" % UalScript.UAL_SCENE)


# ---------------------------------------------------------------------------
# ⑦ 架构纪律：纯视觉 + 不另起并行姿态系统
# ---------------------------------------------------------------------------

## 纯视觉：不得走 RPC（各端本地自行摆姿势）。
## 用**计数**而不是逐行断言 —— 后者会让断言数随文件行数漂移（§4-15 要求断言数变化可解释）。
func test_ual_locomotion_is_pure_visual_no_rpc() -> void:
	for path in ["res://scripts/entities/ual_locomotion.gd", "res://scripts/entities/miku_model.gd"]:
		check_eq(_count_rpc(_read_source(path)), 0,
			"%s 不得含 @rpc：姿态是纯视觉表现" % path.get_file())


## 不得引入**第三条**姿态管线：UAL 只允许「腿 + 躯干」这一个职责，
## 且不得直接写手臂骨（否则与 IK 抢骨）。按骨集合断言，不按写法断言。
func test_ual_does_not_write_arm_bones_in_source() -> void:
	var src := _strip_comments(_read_source("res://scripts/entities/ual_locomotion.gd"))
	# 所有 set_bone_pose_rotation 的目标必须来自配对表（_cat_parents / _pairs），
	# 而配对表只收 DRIVE_UAL_BONES —— 这里锁「驱动集合」这一唯一入口。
	var pairs_from_drive := src.find("sort_pairs_topologically(") >= 0
	check_true(pairs_from_drive,
		"配对表必须由 sort_pairs_topologically(driven_bones(arms_driven), ...) 建立（唯一入口，无法绕过手臂归属规则）")
	# 且 DRIVE_UAL_BONES 的字面量里不得出现任何手臂 / 手指骨名
	var drive_block := src.substr(src.find("const LEG_TORSO_UAL_BONES"),
		src.find("const ARM_CHAIN_UAL") - src.find("const LEG_TORSO_UAL_BONES"))
	for forbidden in ["upper_arm", "forearm", "hand.", "thumb", "finger", "shoulder"]:
		check_false(drive_block.contains(forbidden),
			"LEG_TORSO_UAL_BONES 里不得出现 %s（手指归 HandGripModifier；手臂由 arms_driven 动态归属）" % forbidden)


## ---------------------------------------------------------------------------
# ⑧ 蹲姿通道（2026-10-07 新增）
# ---------------------------------------------------------------------------

## 蹲姿两条剪辑必须注册，且**必须真实存在于素材里**（否则静默播不到）。
func test_crouch_clips_exist_in_real_asset() -> void:
	var ps: PackedScene = load(UAL_GLB)
	check_true(ps != null, "UAL 素材必须存在")
	if ps == null:
		return
	var inst: Node = ps.instantiate()
	add_child(inst)
	var ap := _find_ap(inst)
	if ap == null:
		inst.queue_free()
		return
	for key in UalScript.CROUCH_CLIPS:
		var clip := String(UalScript.CLIPS.get(String(key), ""))
		check_true(clip != "", "状态键 %s 必须映射到一条剪辑" % String(key))
		check_true(ap.has_animation(clip), "素材里必须有蹲姿剪辑 %s" % clip)
	inst.queue_free()


## 蹲姿状态选择：蹲着 + 静止 ⇒ crouch_idle；蹲着 + 移动 ⇒ crouch_walk。
## ⚠ 蹲姿**优先于**速度分档：即使 speed_ratio 高于 run_threshold，蹲着也不进站立档。
func test_crouch_state_selection_covers_idle_and_walk() -> void:
	var sprint_th := float(UalScript.SPRINT_THRESHOLD)
	check_eq(String(UalScript.select_state(false, 0.0, true, RUN_THRESHOLD, sprint_th, true)),
		"crouch_idle", "蹲下 + 静止 ⇒ crouch_idle")
	check_eq(String(UalScript.select_state(true, 0.277, true, RUN_THRESHOLD, sprint_th, true)),
		"crouch_walk", "蹲下 + 移动 ⇒ crouch_walk（0.277 = 3.6×0.5 / 6.5 实测蹲行上限）")
	# 蹲姿优先：即便速度很高也**不得**跑进站立档（蹲行速度上限本就只有 0.277，
	# 但显式判蹲姿让语义无歧义，且将来调高蹲行速度也不会误进站立档）
	check_eq(String(UalScript.select_state(true, 1.0, true, RUN_THRESHOLD, sprint_th, true)),
		"crouch_walk", "蹲姿优先于速度分档：ratio=1.0 时仍必须是 crouch_walk")
	# 反向对照：不蹲 ⇒ 走站立分档（证明上面的判定确实是「蹲姿这个开关」起的作用）
	check_eq(String(UalScript.select_state(false, 0.0, true, RUN_THRESHOLD, sprint_th, false)),
		"idle", "守恒对照：不蹲 + 静止 ⇒ idle（证明蹲姿判定确实生效）")


## 蹲/站切换必须有**渐变**（否则大腿俯仰差约 90° 的硬切肉眼可见跳变）。
## 守护「蹲姿动画不跳变」这个修复不被静默回退成硬切。
func test_stance_switch_uses_blend_not_hard_cut() -> void:
	check_true(UalScript.STANCE_BLEND_TIME > 0.0,
		"蹲/站切换的渐变时长必须 > 0（硬切会跳变，见 ual_locomotion.gd 的 STANCE_BLEND_TIME 注释）")
	# 实例默认值也必须带渐变（接线口径：别只定义了常量却忘了用）
	var loco = UalScript.new()
	check_true(loco.stance_blend_time > 0.0,
		"UalLocomotion 实例的 stance_blend_time 默认必须 > 0（否则常量定义了却没接线）")
	check_near(loco.stance_blend_time, UalScript.STANCE_BLEND_TIME, 1e-6,
		"实例默认值应等于常量 STANCE_BLEND_TIME")


## `set_crouched` 只记录状态、**不立刻切剪辑** —— 切剪辑必须发生在下一次 update()，
## 且那时才带渐变。若在 set_crouched 里直接play()，就会绕过渐变而跳变。
func test_set_crouched_does_not_switch_clip_immediately() -> void:
	var loco = UalScript.new()
	var sk_ctx := _skel(CAT_MODEL)
	if sk_ctx == null:
		return
	var host := Node3D.new()
	add_child(host)
	if not loco.setup(sk_ctx, host):
		check_true(false, "cat 骨架必须能搭起 UAL locomotion")
		host.queue_free()
		return
	# 先让它进入站立 idle
	loco.update(1.0 / 60.0, 0.0, 0.0, false, true, RUN_THRESHOLD, float(UalScript.SPRINT_THRESHOLD))
	var before := loco.current_state()
	check_false(loco.is_crouched(), "起始应为站立")
	loco.set_crouched(true)
	check_true(loco.is_crouched(), "set_crouched(true) 后应记录为蹲姿")
	check_eq(loco.current_state(), before,
		"set_crouched 本身**不得**立刻切剪辑（否则绕过渐变 ⇒ 跳变）")
	# 下一次 update 才切（且此时状态键已是蹲姿）
	loco.update(1.0 / 60.0, 0.0, 0.0, false, true, RUN_THRESHOLD, float(UalScript.SPRINT_THRESHOLD))
	check_eq(loco.current_state(), "crouch_idle", "下一次 update 后应切到 crouch_idle")
	# 往返
	loco.set_crouched(false)
	loco.update(1.0 / 60.0, 0.0, 0.0, false, true, RUN_THRESHOLD, float(UalScript.SPRINT_THRESHOLD))
	check_eq(loco.current_state(), "idle", "取消蹲姿后应切回 idle")
	check_false(loco.is_crouched(), "往返后状态应复位")
	loco.teardown()
	host.queue_free()


## MikuModel 必须把「蹲姿」转发给 UAL（接线口径）。
func test_miku_model_forwards_crouch_to_ual() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	add_child(model)
	if not model.is_ual_locomotion_active():
		check_true(false, "前置：cat + UAL 默认开时应已接管")
		model.queue_free()
		return
	model.set_crouched(true)
	check_true(model._ual_loco.is_crouched(), "MikuModel.set_crouched 必须转发给 UAL")
	model.set_crouched(false)
	check_false(model._ual_loco.is_crouched(), "取消蹲姿必须能转发回 false")
	model.queue_free()


## 蹲姿**只**改姿态、位移仍归 `player.gd` 的 STANCE_HEIGHTS —— 两者不得打架。
## 锁「`player.gd::_update_stance` 必须调 `set_crouched`」这条接线：
## 漏调 ⇒ 蹲下时腿仍是站姿（动画与碰撞体各说各话）。
func test_player_stance_forwards_crouch_to_model() -> void:
	var src := _strip_comments(_read_source("res://scripts/player.gd"))
	check_true(src.find("set_crouched(") >= 0,
		"player.gd::_update_stance 必须调 _model.set_crouched()（否则蹲下时腿不换蹲姿剪辑）")
	# 位移常量必须仍在（动画不该接管位移）
	check_true(src.find("STANCE_HEIGHTS") >= 0,
		"STANCE_HEIGHTS 必须保留：蹲下的**位移/碰撞**仍由 player.gd 负责，与动画分工")


## ⭐ 「sprint 够不到」必须在**两个实机调用点**上都成立（不只是常量对）。
##
## `speed_ratio` 由调用方算好后传进 `update_animation`，所以光断言常量 > 1.0 不够——
## 只要**任何一个**调用点算出 > 1.0 的值，冲刺档就还能被碰到。实测两个调用点：
##   · `player.gd:299` `clampf(move_speed / sprint_speed, 0.0, 1.0)`（sprint_speed = 6.5）
##   · `bot.gd:135``clampf(move_speed / run_speed,  0.0, 1.0)`（run_speed   = 5.2）
## 两者都**clamp 到 1.0** ⇒ 值域上界恒为 1.0 ⇒ 阈值 1.1 永远达不到。
##⚠ 本条按**语义**断言（源码里存在 clamp 上界 1.0），不写死具体行号 ——
##   行号会随代码漂移，语义不会（§4-16「按语义而非字面量」）。
func test_speed_ratio_is_clamped_to_one_at_every_call_site() -> void:
	for path in ["res://scripts/player.gd", "res://scripts/entities/bot.gd"]:
		var code := _strip_comments(_read_source(path))
		var found := false
		for raw in code.split("\n"):
			var l := raw.strip_edges()
			# 找形如 clampf(<速度> / <速度>, 0.0, 1.0) 的调用（分母是速度常量）
			if l.find("clampf(") < 0 or l.find("update_animation") < 0:
				continue
			if l.find(", 0.0, 1.0)") >= 0:
				found = true
		check_true(found,
			"%s 传给 update_animation 的 speed_ratio 必须 clamp 到 [0,1]（上界 1.0）—— 否则 sprint 档仍可达" % path.get_file())


## 蹲姿两档的位移上限：蹲行最高 3.6 × STANCE_SPEED_SCALE[1] = 1.8 m/s
## ⇒ speed_ratio 上限 = 1.8 / 6.5 = 0.277，**本来就够不到 run/sprint 阈值**。
## 这条把「蹲姿只接两档、不接四档」的设计前提**量化锁住**：
## 万一将来调高蹲行速度，这条会提醒重新审视分档。
func test_crouch_speed_cap_stays_below_run_threshold() -> void:
	var crouch_speed := 3.6 * 0.5# walk_speed × STANCE_SPEED_SCALE[1]
	var crouch_ratio := crouch_speed / 6.5   # / sprint_speed
	check_lt_(crouch_ratio, RUN_THRESHOLD,
		"蹲行速度上限 %.2f m/s ⇒ ratio %.3f，必须低于 run 阈值 %.2f" % [
			crouch_speed, crouch_ratio, RUN_THRESHOLD])


## `check_lt_`：严格小于（TestSuite 只有 check_ge / check_le，故局部定义）。
func check_lt_(actual: float, threshold: float, message: String) -> void:
	check_true(actual < threshold, message)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

## 真实资产的骨架（实例挂在 suite 下，`after_each` 统一释放）。
var _skel_cache := {}

## 取真实资产的 Skeleton3D；缺失时**硬失败**（不使用 pending 兜底，见文件头）。
func _skel(path: String) -> Skeleton3D:
	if _skel_cache.has(path):
		return _skel_cache[path]
	var ps: PackedScene = load(path)
	check_true(ps != null, "资产必须存在：%s" % path)
	if ps == null:
		return null
	var inst: Node = ps.instantiate()
	add_child(inst)
	var sk := _find_skel(inst)
	_skel_cache[path] = sk
	return sk


## 造一个「标准人形」合成骨架（只含手臂链 + hips），供IK 渐变用例使用。
## 与 test_weapon_hold_ik.gd 的同名helper 同构（各 suite 自带，避免交叉依赖）。
func _make_arm_skeleton() -> Skeleton3D:
	var sk := Skeleton3D.new()
	var defs := [
		["hips", Vector3(0, 0.9, 0), -1],
		["upper_arm.L_1", Vector3(0.10, 1.10, 0.0), 0],
		["lower_arm.L_2", Vector3(0.32, 1.10, 0.0), 1],
		["hand.L_3", Vector3(0.54, 1.10, 0.0), 2],
		["upper_arm.R_4", Vector3(-0.10, 1.10, 0.0), 0],
		["lower_arm.R_5", Vector3(-0.32, 1.10, 0.0), 4],
		["hand.R_6", Vector3(-0.54, 1.10, 0.0), 5],
	]
	for d in defs:
		var idx := sk.add_bone(String(d[0]))
		sk.set_bone_rest(idx, Transform3D(Basis(), d[1]))
		if int(d[2]) >= 0:
			sk.set_bone_parent(idx, int(d[2]))
	return sk


func _count_ual_sources(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if String(c.name) == "UalLocomotionSource":
			n += 1
		n += _count_ual_sources(c)
	return n


func _count_rpc(src: String) -> int:
	var n := 0
	for raw in src.split("\n"):
		if _strip_comment(raw).find("@rpc") >= 0:
			n += 1
	return n


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


func _strip_comment(line: String) -> String:
	var i := line.find("#")
	return line if i < 0 else line.substr(0, i)


## 剥掉整段注释，只留代码（用于「按语义而非字面量」锁代码结构）。
func _strip_comments(src: String) -> String:
	var out: Array[String] = []
	for raw in src.split("\n"):
		out.append(_strip_comment(raw))
	return "\n".join(out)


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var f := _find_ap(c)
		if f != null:
			return f
	return null


func after_each() -> void:
	# 释放本轮实例化的真实资产（否则节点累积、拖慢后续用例）
	for path in _skel_cache.keys():
		var sk: Node = _skel_cache[path]
		if sk != null and is_instance_valid(sk):
			var inst := sk.get_parent()
			if inst != null and is_instance_valid(inst):
				inst.queue_free()
	_skel_cache.clear()