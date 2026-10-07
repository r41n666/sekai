class_name UalLocomotion
extends RefCounted
## UAL(Quaternius Universal Animation Library) locomotion 驱动 —— **运行期 pose-delta 重定向**。
##
## ## 它解决什么
## `cat_hatsune_miku` 自带的 idle 剪辑是 **0.08 s 的 T-pose 定格**（实测播完手部位移 0.0000），
## 而 `MikuModel._start_procedural_pose` 是「全有或全无」：有 idle 剪辑就永不启用程序化姿态
## ⇒ 选定该模型后腿部完全不动。UAL 补上了**真实人形步态**（屈膝抬脚 + 身体起伏）。
##
## ## 为什么是「运行期重定向」而不是 Godot 官方管线
## 官方要在**编辑器导入面板**配 `BoneMap` 再 Reimport（`tutorials/assets_pipeline/retargeting_3d_skeletons`），
## 而本项目**禁止开编辑器**、**禁止 `--import`**（会删 `project.godot` 的 Vulkan 锁，已复发 8 次；
## 见 `control_checklist.md` §4-17/§4-18）。故本类走运行期：
##   1. UAL 骨架实例常驻场景（Mesh 隐藏，只当姿态数据源），AnimationPlayer 播 UAL 剪辑；
##   2. 每帧对每根映射骨算全局旋转增量 `q_delta = pose_global · rest_global⁻¹`；
##   3. 把增量施加到 **cat 骨的 rest 朝向**上，换算回 cat 的**局部**姿态写入。
## ⇒ 只传「关节角度」，不传「骨长」（骨长差异由 rest 天然保持 ⇒ 不会拉断肢体）。
## 算法与 `tools/capture_ual_retarget.gd::_retarget()`（本类的原始验证原型）**数学等价**。
##
## ## ⚠ 手臂所有权（本类最重要的设计约束）
## UAL 的 Idle/Walk/Jog/Sprint **自带手臂摆动**（实测：Walk 剪辑手部轨迹幅度是腿的 **54%**），
## 若本类在持枪时驱动手臂，会与 `WeaponHoldIK` 的 `TwoBoneIK3D` 抢**同一批骨**。
## ⇒ 手臂归属是**动态**的，由 `arms_driven` 决定（`MikuModel` 按「是否持枪」设置）：
##   · **持枪**（`arms_driven = false`）→ 手臂**完全让给** `WeaponHoldIK`（双臂）
##     + `HandGripModifier`（手指）。本类一根手臂骨都不写 ⇒ 两层永不抢骨。
##   · **空手**（`arms_driven = true`）→ 由**本类**驱动手臂。
## ## 为什么空手也交给本类（这是**实测 + 截图**驱动的决策，不是拍脑袋）
##   ⚠ 曾经的错误设计：本类无条件排除手臂，空手时打算让 `MikuProceduralPose` 接管。
##      **实测证明那条路走不通** —— 因为本类有效时 MikuModel 与程序化姿态是**互斥**的
##      （`_procedural == null`），于是**根本没有任何东西驱动手臂**；
##      而 cat 的 rest 姿态是 **T-pose**（实测手臂与竖直向下成 89.1°，
##      `tools/probe_ual_clips.gd` SECTION 3）⇒ 空手走路时手臂笔直平举，明显穿帮。
##      截图证据：`tmp_spike/loco_ual_walk_1.png`（本轮实拍，空手 UAL 行走 = T-pose 手臂）。
##   ⇒ 空手必须有人驱动手臂。两个候选：
##      (a) 本类驱动 —— UAL 自带自然摆臂，且与腿/躯干是**同一条 FK 链**（姿态自洽）；
##      (b) 程序化姿态驱动 —— 需要给 `MikuProceduralPose` 新增「只管手臂」模式
##          （它目前只有 `pose_arms=false` 这一个反向开关），而它的手臂姿态是
##          `set_bone_global_pose_override`（**绝对**姿态）且以 rest 骨盆为基准算的
##          ⇒ 躯干被本类旋转后，手臂**不会跟随躯干**，会出现肩部脱节。
##   ⇒ **选 (a)**。代价是持枪↔空手切换时手臂会换驱动者，
##      该跳变由 `WeaponHoldIK` 的 **influence 渐变**（`blend_time`）消除（见 weapon_hold_ik.gd）。
##
## ## 骨骼写入方式：mixer 通道（`set_bone_pose_rotation`），**不用** override
## `MikuProceduralPose` 用的是 `set_bone_global_pose_override`，而 override 的优先级
## **高于** mixer 写入。本类走 mixer 通道，且 MikuModel 保证「躯干/腿驱动者二选一、互斥」
## （UAL 有效 ⇒ 不建程序化姿态；UAL 无效 ⇒ 回退程序化姿态），因此两层永不同时写同一批骨。
## `WeaponHoldIK` 的 `TwoBoneIK3D` 是 SkeletonModifier3D，在 mixer **之后**运行且只改手臂 ⇒ 天然不打架。
##
## ## 降级（绝不出现「没腿」）
## `setup()` 在下列任一情况返回 false、`valid` 保持 false：
##   · UAL glb 不存在 / `load()` 失败 / 实例化失败；
##   · UAL 骨架或 AnimationPlayer 找不到；
##   · 骨映射配对数为 0。
## 调用方（`MikuModel`）在 `valid == false` 时**必须回退 `MikuProceduralPose`**。
##
## ## headless 限制（重要，影响测试写法）
## **headless（dummy 渲染）下 `AnimationPlayer.seek()` 不更新骨骼姿态** —— 实测 seek 到
## t=0/0.4/0.8/1.2 读 `get_bone_global_pose()` 完全相同，而直接读轨道 key 明明有运动
## （`tools/probe_ual_motion.gd`，评估报告 §8-3）。
## ⇒ **「重定向真的驱动了骨骼」只能在窗口模式验证**（截图工具）。
## 本类的**纯逻辑部分**（剪辑表、骨集合划分、状态选择、拓扑排序）刻意做成不依赖场景的
## 静态函数，好让 headless 测试逐值断言（见 `tests/suites/test_ual_locomotion.gd`）。

## UAL 源资源路径（CC0；`License.txt` 是授权证明，必须随素材一起保留）
const UAL_SCENE := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"

## 骨映射表（preload 而非全局 class_name：全局名依赖导入缓存，headless 首次运行解析不到）
const UalBoneMapScript := preload("res://scripts/entities/ual_bone_map.gd")

## ── locomotion + 蹲姿剪辑（范围由主理人拍板锁死）────────────────────────
## 选取依据（实测，`tools/probe_ual_clips.gd` + `tools/probe_ual_arms.gd` 窗口模式）：
##   clip          周期      首尾夹角   腿幅度   骨盆起伏  手摆幅度
##   Idle          2.50 s    0.0°       0.001    0.008     0.024
##   Walk          1.33 s    0.0°       0.243    0.052     0.091
##   Jog_Fwd       0.93 s    0.0°       0.403    0.245     0.401
##   Sprint        0.67 s    0.0°       0.426    0.138     0.298
##   （幅度单位 = UAL 骨架单位）
##   · 四条**首尾夹角均 0.0°** ⇒ 全部可无缝循环（loop_mode 已是 LOOP_LINEAR）。
##   · 周期随速度递减（2.50 → 1.33 → 0.93 → 0.67）⇒ 与本项目 walk 3.6 / sprint 6.5 m/s
##     的速度分档**单调对应**，不需额外重定时。
##   · 腿幅度单调递增 ⇒ 站→走→跑→冲四档有真实区分度，不是同一动作换速度。
##   · **排除 `Walk_Formal`**：周期与 `Walk` 完全相同（1.33 s）、腿幅度相同（0.243），
##     但手摆只有 0.045（Walk 的 1/2）—— 它是「端着手走」的变体，而本项目走路通常持枪
##     （手臂归 IK），用它会出现「手不动但腿在走」的错配。
##   · **绝对排除** `Pistol_*` / `Sword_*` / `Death*` / `Jump*` / `Roll*` 等：
##     ① 枪械类只有手枪手势且 UAL 无武器模型，主武器是 AK-47（长）⇒ 手位错；
##     ② 大幅动作会让双马尾「铁板式」穿帮（UAL 骨架无 ponytail 骨，**不可修补**，见评估报告 §2.3）。
##
## ## 蹲姿两条（2026-10-07 新增，`tools/probe_crouch_motion.gd` 实测依据）
##   clip          周期      loop   全轨迹会动   腿角幅度
##   Crouch_Idle   2.933 s   1      45/53 (85%)  10.8°
##   Crouch_Fwd    2.000 s   1      18/53 (34%)  **96.4°**
##   对照：Idle 腿角 8.6° / Walk 腿角 76.4° / Jog_Fwd 129.1°。
##   · **「蹲下静止」→ `Crouch_Idle`**：85% 轨道在动，但腿角仅 10.8° ⇒ 是**蹲姿呼吸**，
##     不是走姿。语义正确。
##   · **「蹲下移动」→ `Crouch_Fwd`（实测决策，不是复用 Crouch_Idle）**：
##     它的腿角幅度 96.4°，与 `Walk` 的 76.4° 同量级 ⇒ 是一条**真正的蹲姿行走**，
##     骨骼全程保持蹲姿（下肢角度大）。
##     ⚠ 早期考虑过「蹲下移动复用 Crouch_Idle 循环」，实测后**否决**：
##     Crouch_Idle 腿角只有 10.8°（≈静止），拿它播移动会出现「人在平移但腿几乎不动」的滑步，
##     比用 Walk 更假。而 UAL 里**确实有** `Crouch_Fwd`，没有理由不用。
##   · 两条 loop_mode 都已是 LOOP_LINEAR ⇒ 可无缝循环。
const CLIPS := {
	"idle": "Idle",
	"walk": "Walk",
	"run": "Jog_Fwd",
	"sprint": "Sprint",
	"crouch_idle": "Crouch_Idle",
	"crouch_walk": "Crouch_Fwd",
}

## 蹲姿两条的键（供 `select_state` 与测试按「集合」而非字面量引用）。
const CROUCH_CLIPS := ["crouch_idle", "crouch_walk"]

## 本类**驱动**的 UAL 骨（腿 + 躯干），**按拓扑序书写**（父先于子）。
## ⚠ 这是「手臂让给 IK」的执行点：不在此集合里的骨，本类**永不调用 set_bone_pose_rotation**。
##   （`setup()` 还会用 `sort_pairs_topologically()` 按 cat 骨架的实际父子关系**重新排序**，
##     所以即使日后有人改动本列表的书写顺序也不会算错。）
##   刻意**不含** `root`：根骨位移会让整个角色在世界空间平移（UAL 的 root 有 POSITION 轨道），
##   与 MikuModel 的移动 / 贴地闭环（`ground_gap()`）打架。
##   刻意**不含** `DEF-head`：cat 的头骨留给程序化姿态（受击抬头）；UAL 头动幅度极小
##   （0.008~0.052），放弃它不损失观感。
##   刻意**不含** 30 根手指骨：手指归 `HandGripModifier`。
const LEG_TORSO_UAL_BONES := [
	# 躯干（根→颈，父先于子）
	"DEF-hips", "DEF-spine.001", "DEF-spine.002", "DEF-neck",
	# 左腿（髋→膝→踝→趾）
	"DEF-thigh.L", "DEF-shin.L", "DEF-foot.L", "DEF-toe.L",
	# 右腿
	"DEF-thigh.R", "DEF-shin.R", "DEF-foot.R", "DEF-toe.R",
]

## UAL 侧的手臂链（8 根）。
## **归属是动态的**（见 `arms_driven`）：
##   · `arms_driven == false`（持枪时）→ **让给** `WeaponHoldIK`，本类一根都不写；
##   · `arms_driven == true`（空手时）→ 由本类驱动，否则手臂会是 T-pose（见文件头实测）。
## ⚠ 手指骨**任何情况下都不驱动**（归 `HandGripModifier`）。
const ARM_CHAIN_UAL := [
	"DEF-shoulder.L", "DEF-upper_arm.L", "DEF-forearm.L", "DEF-hand.L",
	"DEF-shoulder.R", "DEF-upper_arm.R", "DEF-forearm.R", "DEF-hand.R",
]

## cat 侧手指骨的判定关键字（**不**驱动 ⇒ 归 `HandGripModifier`）。
const FINGER_BONE_KEYWORDS := ["thumb", "index", "middle", "ring", "little", "finger"]

## 绝不允许注册的剪辑关键词（把评估报告的结论**固化成代码**，防止将来被"顺手"扩大范围）。
##
## ⚠ 2026-10-07：`crouch` 已**移出**本表 —— 蹲姿有了正式通道（`Crouch_Idle` / `Crouch_Fwd`，
##   见 CLIPS 注释的实测依据），继续禁着会让范围规则与实际注册表自相矛盾。
const FORBIDDEN_CLIP_KEYWORDS := [
	"pistol", "sword", "death", "jump", "roll", "spell", "punch", "push", "swim",
	"sitting", "driving", "dance", "interact", "pickup", "hit_", "fixing",
]

## 冲刺阈值（speed_ratio）。
##
## ⚠ **1.1 = 故意让冲刺档够不到**（2026-10-07 按用户要求：「开着但 sprint 够不到」，
##   因为 Sprint 的大幅动作会让双马尾穿帮，且 UAL 骨架无 ponytail 骨**不可修补**）。
## 依据：`speed_ratio` 由 `player.gd:299` 计算并 **clamp 到 [0, 1]**
##   （`clampf(move_speed / sprint_speed, 0.0, 1.0)`）⇒ 值域上界恒为 **1.0**。
##   阈值 1.1 > 1.0 ⇒ `speed_ratio >= sprint_threshold` **永远为假**
##   ⇒ Sprint 剪辑仍在表里（可随时调回 ≤ 1.0 启用），但实机路径到不了。
const SPRINT_THRESHOLD := 1.1

## 蹲/站切换的**渐变时长**（秒）。蹲姿与站姿的腿部姿态差异大（大腿俯仰差 ~90°），
## 硬切会看到明显跳变。取 0.18 与 `MikuModel.fade_time` / `UAL_ARM_BLEND_TIME` 一致。
const STANCE_BLEND_TIME := 0.18

## UAL 素材路径是否可用（**不加载、只查存在性**）——
## 供 MikuModel 在建实例**之前**快速判断能否降级（避免无谓的 load）。
static func asset_available() -> bool:
	return ResourceLoader.exists(UAL_SCENE)


## 「这个 UAL 剪辑名是否被范围规则允许」。**纯逻辑**，headless 可断言。
## @param clip_name UAL 剪辑名（如 "Walk"）
## @return true = 允许注册
static func is_clip_allowed(clip_name: String) -> bool:
	if clip_name.strip_edges() == "":
		return false
	# 白名单里的 4 条必须放行（防止分类逻辑把它们误杀）
	if clip_name in CLIPS.values():
		return true
	var low := clip_name.to_lower()
	for bad in FORBIDDEN_CLIP_KEYWORDS:
		if low.contains(String(bad)):
			return false
	# 未被禁词命中、也不在白名单里 ⇒ 不允许（**默认拒绝**，白名单语义）
	return false


## 校验本类的剪辑表自身合规。**纯逻辑**，headless 可断言。
## @return {ok: bool, count: int, bad: Array[String], rejected: int, forbidden: int}
static func verify_clip_table() -> Dictionary:
	var bad: Array[String] = []
	for state in CLIPS:
		var clip := String(CLIPS[state])
		if not is_clip_allowed(clip):
			bad.append(clip)
	# 反向验证：每个禁词拼一条假剪辑名，必须全部被拒（证明禁词真的生效，
	# 而不是「表里恰好没有这些剪辑」这种假绿）。
	var rejected := 0
	for bad_kw in FORBIDDEN_CLIP_KEYWORDS:
		if not is_clip_allowed("Probe_%s" % String(bad_kw)):
			rejected += 1
	return {
		"ok": bad.is_empty() and CLIPS.size() == 6 and rejected == FORBIDDEN_CLIP_KEYWORDS.size(),
		"count": CLIPS.size(),
		"bad": bad,
		"rejected": rejected,
		"forbidden": FORBIDDEN_CLIP_KEYWORDS.size(),
	}


## 本类**实际会驱动**的 UAL 骨名列表。**纯逻辑**，headless 可断言。
## @param arms_driven 是否驱动手臂（空手 = true，持枪 = false）
static func driven_bones(arms_driven: bool) -> Array:
	if not arms_driven:
		return LEG_TORSO_UAL_BONES.duplicate()
	var out: Array = LEG_TORSO_UAL_BONES.duplicate()
	out.append_array(ARM_CHAIN_UAL)
	return out


## 把 UAL 骨名分类：`"drive_leg_torso"`（必驱动）/ `"arm"`（**条件**驱动）/ `"other"`。
## **纯逻辑** —— 「持枪时手臂让给 IK」这条纪律的**正向锁**就靠
## `driven_bones(false)` 不含任何 `"arm"` 骨来表达。
## @param ual_bone UAL 骨名
## @param arms_driven 当前是否驱动手臂
static func classify_bone(ual_bone: String, arms_driven: bool = false) -> String:
	if ual_bone in LEG_TORSO_UAL_BONES:
		return "drive_leg_torso"
	if ual_bone in ARM_CHAIN_UAL:
		return "arm"
	return "other"


## **持枪时**（`arms_driven = false`）驱动集合与手臂链是否完全不相交 —— 两层永不抢骨。
static func leg_torso_and_arm_are_disjoint() -> bool:
	for arm_bone in ARM_CHAIN_UAL:
		if arm_bone in LEG_TORSO_UAL_BONES:
			return false
	return true


## 手指骨是否**任何情况下都不会**被驱动（纯逻辑；必须为 true —— 手指归 HandGripModifier）。
static func drive_has_no_fingers() -> bool:
	for ual_bone in LEG_TORSO_UAL_BONES:
		var cat_bone := String(UalBoneMapScript.UAL_TO_CAT.get(ual_bone, "")).to_lower()
		for kw in FINGER_BONE_KEYWORDS:
			if cat_bone.contains(String(kw)):
				return false
	return true


## 依据移动状态选择状态键（`CLIPS` 的键）。**纯逻辑**，headless 可断言。
## 语义与 MikuModel 既有状态机一致，只是多了 sprint 档与蹲姿两档：
##   · 不在地面 → 返回空串（调用方保持上一状态）；
##   · **蹲着** → 移动中 "crouch_walk"，否则 "crouch_idle"
##     （蹲姿**优先于**速度分档：蹲着跑不起来，`STANCE_SPEED_SCALE[1] = 0.5`
##       ⇒ 蹲行最高 3.6×0.5 = 1.8 m/s ⇒ speed_ratio 上限 1.8/6.5 = 0.277
##       ⇒ 本来就够不到 run/sprint 阈值，但**显式判蹲姿**能让语义无歧义、
##       且万一将来调高蹲行速度也不会误进站立档）；
##   · 站着 → ratio >= sprint_threshold → "sprint"；>= run_threshold → "run"；
##     移动中 → "walk"；否则 "idle"。
## @param moving 是否在移动
## @param speed_ratio 速度比例（0~1）
## @param on_floor 是否在地面
## @param run_threshold 跑动阈值（沿用 MikuModel.run_threshold = 0.62）
## @param sprint_threshold 冲刺阈值
## @param crouched 是否处于蹲姿
static func select_state(moving: bool, speed_ratio: float, on_floor: bool,
		run_threshold: float, sprint_threshold: float, crouched: bool = false) -> String:
	if not on_floor:
		return ""
	if crouched:
		return "crouch_walk" if (moving or speed_ratio > 0.05) else "crouch_idle"
	if speed_ratio >= sprint_threshold:
		return "sprint"
	if speed_ratio >= run_threshold:
		return "run"
	if moving or speed_ratio > 0.05:
		return "walk"
	return "idle"


## 把「UAL 骨名列表」按 **cat 骨架的实际父子关系**排成拓扑序（父先于子）。
## **纯逻辑**（只吃一个 parent 数组），headless 可断言。
##
## 为什么需要（正确性关键）：局部姿态换算要用**父骨本帧的全局旋转**
## （`q_local = q_parent⁻¹ · q_target`）。若子骨排在父骨之前，父骨此刻还是旧姿态 ⇒ 算错。
## 组件里不依赖 `DRIVE_UAL_BONES` 的书写顺序，而是运行时按真实骨架重排 —— 更抗改动。
## @param ual_bones UAL 骨名数组（顺序无所谓）
## @param ual_to_cat Dictionary UAL→cat 映射
## @param cat_parents PackedInt32Array cat 骨架的父索引数组（长度 = 骨数）
## @param resolve_cat Callable 骨名→cat 索引（找不到返回 -1）
## @return 排好序的 UAL 骨名数组；无法解析的骨被丢弃；检测到环时返回空数组
static func sort_pairs_topologically(ual_bones: Array, ual_to_cat: Dictionary,
		cat_parents: PackedInt32Array, resolve_cat: Callable) -> Array:
	# 解析出 (cat_idx → ual_bone)，并按 cat_idx 升序（保证结果稳定、可复现）
	var by_cat := {}
	for ual_bone in ual_bones:
		var cat_bone := String(ual_to_cat.get(ual_bone, ""))
		if cat_bone == "":
			continue
		var ci: int = int(resolve_cat.call(cat_bone))
		if ci < 0:
			continue
		by_cat[ci] = String(ual_bone)
	var indices: Array = by_cat.keys()
	indices.sort()

	var out: Array = []
	var emitted := {}
	# 反复扫描：把「父已发出（或父不在本集合内）」的骨发出来。O(n²) 但 n=12，无所谓。
	var progress := true
	while progress and out.size() < indices.size():
		progress = false
		for ci in indices:
			if emitted.has(ci):
				continue
			var parent: int = cat_parents[ci] if ci < cat_parents.size() else -1
			if parent < 0 or not by_cat.has(parent) or emitted.has(parent):
				out.append(String(by_cat[ci]))
				emitted[ci] = true
				progress = true
	# 还有没发出来的 ⇒ 骨架里有环（不该发生）。返回空数组让调用方判定失败，而不是静默算错。
	if out.size() != indices.size():
		return []
	return out


## ---------------------------------------------------------------------------
## 实例部分：加载 / 采样 / 应用（需要场景，不能 headless 断言）
## ---------------------------------------------------------------------------

## 是否已成功搭建（= 素材在、骨映射有效）。false ⇒ 调用方必须回退程序化姿态。
var valid := false
## 配对表（每项 `[ual_idx, cat_idx]`，已按拓扑序）。调试用。
var debug_pairs: Array = []
var debug_names := {}

## 本类当前是否驱动手臂。
## ⚠ **默认 false = 持枪语义**（手臂让给 `WeaponHoldIK`），是安全的默认值。
##   MikuModel 在**空手**时置 true —— 否则手臂没人驱动 = cat 的 rest = T-pose（穿帮）。
var arms_driven := false

var _source: Node3D
var _ual_skel: Skeleton3D
var _ual_ap: AnimationPlayer
var _target_skel: Skeleton3D
## 每根被驱动的 cat 骨的 rest 全局旋转 + 父索引（建配对时算好，避免每帧重算）。
var _cat_parents: PackedInt32Array = PackedInt32Array()
var _cat_rest_rot: Array[Quaternion] = []
var _pairs: Array = []
## 本帧各 cat 骨的**新**全局旋转（父→子传播用）。每帧复用，零分配。
var _new_global_rot: Dictionary = {}
var _state := ""


## 搭建：加载 UAL 源 + 解析骨映射 + 建驱动配对。
## @param target_skeleton 目标（cat）Skeleton3D
## @param host 挂载 UAL 源实例的父节点（通常是 MikuModel）
## @return true = 可用；false = 调用方**必须**回退 MikuProceduralPose
func setup(target_skeleton: Skeleton3D, host: Node) -> bool:
	valid = false
	teardown()   # 幂等清理（重复 setup 时先复位上一轮写过的骨骼姿态）
	if target_skeleton == null or host == null:
		return false
	if not asset_available():
		push_warning("UalLocomotion：UAL 素材不存在，回退程序化姿态（%s）" % UAL_SCENE)
		return false
	var packed := load(UAL_SCENE) as PackedScene
	if packed == null:
		push_warning("UalLocomotion：UAL 场景加载失败，回退程序化姿态")
		return false
	var inst := packed.instantiate()
	if inst == null:
		return false
	inst.name = "UalLocomotionSource"
	host.add_child(inst)
	_source = inst as Node3D
	_ual_skel = _find_skeleton(_source)
	_ual_ap = _find_animation_player(_source)
	if _ual_skel == null or _ual_ap == null:
		push_warning("UalLocomotion：UAL 骨架或 AnimationPlayer 未找到，回退程序化姿态")
		teardown()
		return false
	# 隐藏 UAL 的 Mesh：它只是姿态数据源，不能被看见（否则场上多一个人形）
	for mesh in _collect_meshes(_source):
		(mesh as MeshInstance3D).visible = false
	_target_skel = target_skeleton
	_build_pairs()
	if _pairs.is_empty():
		push_warning("UalLocomotion：骨映射配对为 0，回退程序化姿态")
		teardown()
		return false
	valid = true
	_state = ""
	debug_names = {
		"source_skeleton_bones": _ual_skel.get_bone_count(),
		"target_skeleton_bones": _target_skel.get_bone_count(),
		"drive_pairs": _pairs.size(),
		"ual_scene": UAL_SCENE,
	}
	return true


## 运行时切换手臂归属。持枪 ⇄ 空手时由 MikuModel 调用。
## 切换会**重建配对表**（多 / 少 8 根手臂骨）。
##
## ⚠⚠ **刻意不复位**手臂姿态，理由是实测出来的（`tools/probe_ual_switch.gd`）：
##   `SkeletonModifier3D` 的修改是作用在「当前基础姿态」上的，`influence` 只缩放**修改量**。
##   若让出手臂时把骨复位到 rest，IK 就会**从 T-pose 开始渐变**，
##   于是切枪那一帧手臂会先「跳到 T-pose」再淡入握枪姿势 —— 实测 f05(垂臂) → f06(臂已抬起)
##   而此时 influence 才0.09 ⇒ **仍有可见跳变**。
##   保留最后 一帧的 UAL 手臂姿态作为基础，IK 才能真正从「UAL 手臂」交叉淡入「握枪姿势」。
## @param on true = 本类驱动手臂（空手）；false = 让给 IK（持枪）
func set_arms_driven(on: bool) -> void:
	if arms_driven == on:
		return
	arms_driven = on
	if valid:
		_build_pairs()


## 建配对表：只收 `driven_bones(arms_driven)`（**手指骨任何情况下都不收**），
## 再按 cat 骨架的真实父子关系排成拓扑序。
func _build_pairs() -> void:
	_pairs.clear()
	_cat_parents = PackedInt32Array()
	_cat_rest_rot.clear()
	var target := _target_skel
	if target == null:
		return
	var count := target.get_bone_count()
	var all_parents := PackedInt32Array()
	all_parents.resize(count)
	for i in count:
		all_parents[i] = target.get_bone_parent(i)

	var ordered := sort_pairs_topologically(
		driven_bones(arms_driven), UalBoneMapScript.UAL_TO_CAT, all_parents,
		func(bone_name: String) -> int: return target.find_bone(bone_name))
	if ordered.is_empty():
		return
	for ual_bone in ordered:
		var cat_bone := String(UalBoneMapScript.UAL_TO_CAT.get(String(ual_bone), ""))
		var ui := _ual_skel.find_bone(String(ual_bone))
		var ci := target.find_bone(cat_bone)
		if ui < 0 or ci < 0:
			continue
		_pairs.append([ui, ci])
		_cat_parents.append(target.get_bone_parent(ci))
		_cat_rest_rot.append(_ortho_rot(target.get_bone_global_rest(ci)))
	debug_pairs = _pairs.duplicate()


## 每帧推进：选状态 → 切剪辑 → 采样 UAL 姿态 → 写回 cat 骨骼。
##
## ⚠ **不**手动 `advance()`：UAL 的 AnimationPlayer 已在场景树里自行推进，
## 再手动 advance 会让它**双倍速**（实测隐患，故明确不这么做）。
## @param delta 帧时长（保留参数以便将来做步频自适应；当前不需要）
## @param speed_mps 实际速度（米/秒，同上）
## @param speed_ratio 速度比例 0~1
## @param moving 是否在移动
## @param on_floor 是否在地面
## @param run_threshold 跑动阈值
## @param sprint_threshold 冲刺阈值
func update(delta: float, speed_mps: float, speed_ratio: float, moving: bool, on_floor: bool,
		run_threshold: float, sprint_threshold: float) -> void:
	if not valid:
		return
	var want := select_state(moving, speed_ratio, on_floor, run_threshold, sprint_threshold, _crouched)
	if want == "":
		# 不在地面（如跳跃）：保持当前剪辑并继续采样 ⇒ UAL 的腿不会突然僵住。
		want = _state if _state != "" else "idle"
	_play_if_needed(want)
	_sample_and_apply()


## 是否处于蹲姿（由 MikuModel 从 player.gd 的 `_update_stance` 转发，见 `set_crouched`）。
var _crouched := false

## 蹲/站切换的**渐变**时长（秒）。0 = 硬切（不建议：蹲姿大腿俯仰与站姿差约 90°，硬切肉眼可见跳变）。
var stance_blend_time := STANCE_BLEND_TIME


## 运行时切蹲/站（由 MikuModel 转发 player.gd 的 `_stance`）。
##
## ⚠ 只记状态，**不**立刻切剪辑 —— 真正的切发生在下一次 `update()`，
##   且那时才带 `stance_blend_time` 渐变（见 `_play_if_needed`）。
##   职责因此单一：蹲下键按下 → 本帧只记录 → 下一帧状态机带着渐变切过去。
## @param on true = 蹲下；false = 站立
func set_crouched(on: bool) -> void:
	_crouched = on


## 当前是否处于蹲姿（调试 / 测试用）。
func is_crouched() -> bool:
	return _crouched


## 当前正在播的状态键（调试 / 测试用；空串 = 还没开始播）。
func current_state() -> String:
	return _state


## 切剪辑（同一状态不重播 ⇒ 不会每帧重置播放头）。
##
## ⚠ **带 `stance_blend_time` 渐变**（`AnimationPlayer.play(name, blend)`）：
##   蹲姿与站姿的腿部姿态差异大（大腿俯仰约 90°），硬切会看到明显跳变。
##   其它切换（走↔跑↔蹲）一并给渐变，代价只是几十毫秒交叉淡入，
##   换来「任何状态切换都不跳变」这一条简单可依赖的不变量。
func _play_if_needed(state_key: String) -> void:
	if state_key == _state:
		return
	_state = state_key
	var clip := String(CLIPS.get(state_key, ""))
	if clip == "" or not _ual_ap.has_animation(clip):
		return
	if stance_blend_time > 0.0:
		_ual_ap.play(clip, stance_blend_time)
	else:
		_ual_ap.play(clip)


## 采样 UAL 当前姿态，把旋转增量写进 cat 骨骼（**只写驱动集合**）。
##
## 与原型 `capture_ual_retarget.gd::_retarget()` **数学等价**，但每帧只调一次
## `force_update_all_bone_transforms()`（原型是每根骨调一次，12 根就是 12 次全骨架更新）。
## 关键：原型靠「写完一根就 force_update，再读父骨 global_pose」拿到父骨新姿态；
## 这里改成**自己把父骨的新全局旋转沿链传下去**（`_new_global_rot`），因而可以最后统一更新一次。
func _sample_and_apply() -> void:
	if _ual_ap.current_animation == "":
		# 首帧还没有任何剪辑在播 ⇒ 播 idle，避免第一帧是 rest 姿态（= T-pose）。
		_play_if_needed(_state if _state != "" else "idle")
		if _ual_ap.current_animation == "":
			return
	_ual_skel.force_update_all_bone_transforms()
	_new_global_rot.clear()
	for n in _pairs.size():
		var ui := int(_pairs[n][0])
		var ci := int(_pairs[n][1])
		# q_delta = pose · rest⁻¹（只取关节角度增量，不含位移 / 骨长）
		var q_delta := _ortho_rot(_ual_skel.get_bone_global_pose(ui)) \
			* _ortho_rot(_ual_skel.get_bone_global_rest(ui)).inverse()
		# 施加到 cat 的 rest 朝向上 ⇒ 得到本帧的目标全局旋转
		var q_target := q_delta * _cat_rest_rot[n]
		var cp := _cat_parents[n]
		var q_parent := Quaternion.IDENTITY
		if cp >= 0:
			if _new_global_rot.has(cp):
				q_parent = _new_global_rot[cp]   # 父骨本帧的新姿态（拓扑序保证已算）
			else:
				# 父骨不在驱动集合内 ⇒ 它的全局姿态仍是 rest（IK 只碰手臂、程序化姿态此刻未启用）
				q_parent = _ortho_rot(_target_skel.get_bone_global_rest(cp))
		_target_skel.set_bone_pose_rotation(ci, q_parent.inverse() * q_target)
		_new_global_rot[ci] = q_target
	_target_skel.force_update_all_bone_transforms()


## 拆掉 UAL 源实例，并把写过的骨骼姿态复位（模型重载 / 关闭能力时调用）。
## ⚠ 复位很重要：不清的话，本类留下的姿态会**残留**在骨架上（切回程序化姿态时腿会歪）。
## ⚠ 用 `reset_bone_pose`（整骨复位到 rest），**不是** `reset_bone_pose_rotation` ——
##   后者在 Skeleton3D 上**不存在**，调用会抛 "Nonexistent function" 并**中断本函数**，
##   导致后面的 `_source` 清理**不执行** ⇒ UAL 源节点泄漏（实测踩过，见 probe_ual_leak.gd）。
##   ⇒ 清理顺序刻意把「复位」放最前、且复位与释放互不依赖：即使复位失败，释放也要能走到。
func teardown() -> void:
	var pairs_snapshot := _pairs.duplicate()
	var target := _target_skel
	var source := _source
	# 先清引用与状态（无论后续是否出错，组件自身回到「未启用」）
	_pairs.clear()
	_cat_parents = PackedInt32Array()
	_cat_rest_rot.clear()
	_new_global_rot.clear()
	_state = ""
	valid = false
	_source = null
	_ual_skel = null
	_ual_ap = null
	_target_skel = null
	# 再复位骨骼姿态（失败也不影响下面的释放）
	if target != null and is_instance_valid(target):
		for entry in pairs_snapshot:
			target.reset_bone_pose(int(entry[1]))
	# 最后释放源实例
	if source != null and is_instance_valid(source):
		if source.get_parent() != null:
			source.get_parent().remove_child(source)
		source.free()


## Basis → 去掉缩放的旋转四元数（动画数据可能带缩放，直接 get_rotation_quaternion() 会污染结果）。
static func _ortho_rot(xform: Transform3D) -> Quaternion:
	return xform.basis.orthonormalized().get_rotation_quaternion()


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skeleton(c)
		if f != null:
			return f
	return null


func _find_animation_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var f := _find_animation_player(c)
		if f != null:
			return f
	return null


func _collect_meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_collect_meshes(c))
	return out