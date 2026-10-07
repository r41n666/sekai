class_name UalBoneMap
extends RefCounted
## UAL(Quaternius Universal Animation Library) → cat_hatsune_miku 的骨映射表（**纯数据 + 查询，无副作用**）。
##
## 事实基础（tools/probe_ual_skeleton.gd / tools/probe_cat_skeleton.gd 于 Godot 4.7.2 headless 实测）：
##   UAL：53 骨，骨名 `DEF-` 前缀 + `.L`/`.R` **后缀**（root / DEF-hips / DEF-spine.001..003 / DEF-neck /
##        DEF-head / DEF-shoulder.L / DEF-upper_arm.L / DEF-forearm.L / DEF-hand.L /
##        DEF-f_{index,middle,pinky,ring,thumb}.0{1,2,3}.L / DEF-thigh.L / DEF-shin.L / DEF-foot.L / DEF-toe.L）
##   cat：111 骨，骨名 **带 `_NN` 数字后缀**且左右是 `.L` **中缀**（hips_106 / spine_95 / chest_94 /
##        neck_50 / head_49 / shoulder.L_69 / upper_arm.L_68 / lower_arm.L_67 / hand.L_66 /
##        {thumb,index,middle,ring,little}_{proximal,intermediate,distal}.L_NN /
##        upper_leg.L_100 / lower_leg.L_99 / foot.L_97 / toes.L_96）
##   ⇒ 两边都用 `.L/.R`，**左右约定一致**（这是本映射能成立的根本原因）。
##
## 三类映射槽位（对应 SkeletonProfileHumanoid 的槽位语义）：
##   ① 全身主链（18 根）—— 决定姿态质量，**必须全中**。
##   ② 手指（30 根）—— UAL 与 cat 都是 5 指 × 3 节，**可完整映射**。
##   ③ 未映射 —— cat 上半身饰品骨（ponytail / ear / mouth / Bone.NN 头发 / Bone.008~012 胸饰 /
##      lower_leg.L.001 / lower_arm.L.001 等），UAL 里根本没有对应 ⇒ **重定向后保持rest 姿态（不动）**。
##      这是「不穿帮」的关键：它们必须保持 T-pose 静默，而不是被错误地跟随身体。
##
## 设计取舍（重要）：
##   **不建自定义 SkeletonProfile，而是保留 SkeletonProfileHumanoid + 显式 BoneMap。**
##   理由：`SkeletonProfileHumanoid` 的槽位名带 `Left/Right` **前缀**（`LeftUpperArm`），
##   而两边骨名都是 `.L/.R` 后缀。实测两条路都可行：
##     路① 显式 BoneMap：`bone_map.set_skeleton_bone_name("LeftUpperArm", "DEF-upper_arm.L")`逐条写。
##     路② 自定义 profile + `set_bone_name()` 改名：要把 56 个槽位全改成后缀命名。
##   **选路①**：BoneMap 本来就是为「槽位名与实际骨名不一致」设计的，语义更准确；
##   路② 改profile 槽位名会让profile 偏离 Godot 的标准人形定义（profile 是可复用资产，
##   改名后它就不再是「Humanoid profile」了，将来若要接Mixamo/其他标准动画会失配）。
##   代价：需要写56 条 `set_skeleton_bone_name()`，但这是一张静态表、一次性成本。

## UAL 骨名 → cat 骨名（未命中的键表示「该 UAL 骨无对应」，会被丢弃）
const UAL_TO_CAT := {
	# —— 主链：躯干 ——
	"root": "root_107",
	"DEF-hips": "hips_106",
	"DEF-spine.001": "spine_95",
	"DEF-spine.002": "chest_94",
	# ⚠ UAL 的 DEF-spine.003（颈根）**无对应**：cat 的 neck_50 直接挂在 chest_94 下。
	#   后果见UNMAPPED_NOTES。
	"DEF-neck": "neck_50",
	"DEF-head": "head_49",
	# —— 主链：左臂 ——
	"DEF-shoulder.L": "shoulder.L_69",
	"DEF-upper_arm.L": "upper_arm.L_68",
	"DEF-forearm.L": "lower_arm.L_67",
	"DEF-hand.L": "hand.L_66",
	# —— 主链：右臂 ——
	"DEF-shoulder.R": "shoulder.R_88",
	"DEF-upper_arm.R": "upper_arm.R_87",
	"DEF-forearm.R": "lower_arm.R_86",
	"DEF-hand.R": "hand.R_85",
	# —— 主链：左腿 ——
	"DEF-thigh.L": "upper_leg.L_100",
	"DEF-shin.L": "lower_leg.L_99",
	"DEF-foot.L": "foot.L_97",
	"DEF-toe.L": "toes.L_96",
	# —— 主链：右腿 ——
	"DEF-thigh.R": "upper_leg.R_105",
	"DEF-shin.R": "lower_leg.R_104",
	"DEF-foot.R": "foot.R_102",
	"DEF-toe.R": "toes.R_101",
	# —— 左手 15 指（UAL `f_pinky` ↔ cat `little`；两者同为小指）——
	"DEF-thumb.01.L": "thumb_proximal.L_53",
	"DEF-thumb.02.L": "thumb_intermediate.L_52",
	"DEF-thumb.03.L": "thumb_distal.L_51",
	"DEF-f_index.01.L": "index_proximal.L_56",
	"DEF-f_index.02.L": "index_intermediate.L_55",
	"DEF-f_index.03.L": "index_distal.L_54",
	"DEF-f_middle.01.L": "middle_proximal.L_59",
	"DEF-f_middle.02.L": "middle_intermediate.L_58",
	"DEF-f_middle.03.L": "middle_distal.L_57",
	"DEF-f_pinky.01.L": "little_proximal.L_65",
	"DEF-f_pinky.02.L": "little_intermediate.L_64",
	"DEF-f_pinky.03.L": "little_distal.L_63",
	"DEF-f_ring.01.L": "ring_proximal.L_62",
	"DEF-f_ring.02.L": "ring_intermediate.L_61",
	"DEF-f_ring.03.L": "ring_distal.L_60",
	# —— 右手 15 指 ——
	"DEF-thumb.01.R": "thumb_proximal.R_72",
	"DEF-thumb.02.R": "thumb_intermediate.R_71",
	"DEF-thumb.03.R": "thumb_distal.R_70",
	"DEF-f_index.01.R": "index_proximal.R_75",
	"DEF-f_index.02.R": "index_intermediate.R_74",
	"DEF-f_index.03.R": "index_distal.R_73",
	"DEF-f_middle.01.R": "middle_proximal.R_78",
	"DEF-f_middle.02.R": "middle_intermediate.R_77",
	"DEF-f_middle.03.R": "middle_distal.R_76",
	"DEF-f_pinky.01.R": "little_proximal.R_84",
	"DEF-f_pinky.02.R": "little_intermediate.R_83",
	"DEF-f_pinky.03.R": "little_distal.R_82",
	"DEF-f_ring.01.R": "ring_proximal.R_81",
	"DEF-f_ring.02.R": "ring_intermediate.R_80",
	"DEF-f_ring.03.R": "ring_distal.R_79",
}

## SkeletonProfileHumanoid 槽位名（实测 56 槽，Godot 4.7.2）→ UAL 骨名。
## 用途：构建 `BoneMap`（profile 槽位 → 实际骨名）。
## ⚠ 人形 profile 的手指槽位命名实测（Godot 4.7.2，`SkeletonProfileHumanoid` 共 56 槽）有两个陷阱，
##   都是**实测撞到报错才发现**的（`BoneMap.set_skeleton_bone_name()` 对不存在的槽位名会报
##   `Condition "!bone_map.has(p_profile_bone_name)" is true`）：
##   ① 拇指只有 **2 节**（`LeftThumbProximal` / `LeftThumbDistal`，另有 `LeftThumbMetacarpal` 掌骨），
##      **没有 `LeftThumbIntermediate`**；而其余 4 指是 3 节（Proximal/Intermediate/Distal）。
##      ⇒ UAL 的 `DEF-thumb.02.L/.R`（拇指中节）**无profile 槽位可落**。
##   ② 槽位名是 `LeftMiddleProximal`（不是 `MiddleLeft`），`Left/Right` 是**前缀**。
##   因此 UAL 53 骨 → profile 槽位只能落 50 条（52 条映射 − 2 条拇指中节）。
##   拇指中节未落槽的后果见 UNMAPPED_NOTES。
const PROFILE_TO_UAL := {
	"Root": "root",
	"Hips": "DEF-hips",
	"Spine": "DEF-spine.001",
	"Chest": "DEF-spine.002",
	# "UpperChest" → 无（见 UNMAPPED_NOTES）
	"Neck": "DEF-neck",
	"Head": "DEF-head",

	"LeftShoulder": "DEF-shoulder.L",
	"LeftUpperArm": "DEF-upper_arm.L",
	"LeftLowerArm": "DEF-forearm.L",
	"LeftHand": "DEF-hand.L",
	"RightShoulder": "DEF-shoulder.R",
	"RightUpperArm": "DEF-upper_arm.R",
	"RightLowerArm": "DEF-forearm.R",
	"RightHand": "DEF-hand.R",

	"LeftUpperLeg": "DEF-thigh.L",
	"LeftLowerLeg": "DEF-shin.L",
	"LeftFoot": "DEF-foot.L",
	"LeftToes": "DEF-toe.L",
	"RightUpperLeg": "DEF-thigh.R",
	"RightLowerLeg": "DEF-shin.R",
	"RightFoot": "DEF-foot.R",
	"RightToes": "DEF-toe.R",

	"LeftThumbProximal": "DEF-thumb.01.L",
	"LeftThumbDistal": "DEF-thumb.03.L",
	"LeftIndexProximal": "DEF-f_index.01.L",
	"LeftIndexIntermediate": "DEF-f_index.02.L",
	"LeftIndexDistal": "DEF-f_index.03.L",
	"LeftMiddleProximal": "DEF-f_middle.01.L",
	"LeftMiddleIntermediate": "DEF-f_middle.02.L",
	"LeftMiddleDistal": "DEF-f_middle.03.L",
	"LeftRingProximal": "DEF-f_ring.01.L",
	"LeftRingIntermediate": "DEF-f_ring.02.L",
	"LeftRingDistal": "DEF-f_ring.03.L",
	"LeftLittleProximal": "DEF-f_pinky.01.L",
	"LeftLittleIntermediate": "DEF-f_pinky.02.L",
	"LeftLittleDistal": "DEF-f_pinky.03.L",

	"RightThumbProximal": "DEF-thumb.01.R",
	"RightThumbDistal": "DEF-thumb.03.R",
	"RightIndexProximal": "DEF-f_index.01.R",
	"RightIndexIntermediate": "DEF-f_index.02.R",
	"RightIndexDistal": "DEF-f_index.03.R",
	"RightMiddleProximal": "DEF-f_middle.01.R",
	"RightMiddleIntermediate": "DEF-f_middle.02.R",
	"RightMiddleDistal": "DEF-f_middle.03.R",
	"RightRingProximal": "DEF-f_ring.01.R",
	"RightRingIntermediate": "DEF-f_ring.02.R",
	"RightRingDistal": "DEF-f_ring.03.R",
	"RightLittleProximal": "DEF-f_pinky.01.R",
	"RightLittleIntermediate": "DEF-f_pinky.02.R",
	"RightLittleDistal": "DEF-f_pinky.03.R",
}

## 未映射项的**后果说明**（每条都要有明确结论，不留「以后再说」）
const UNMAPPED_NOTES := [
	[
		"DEF-spine.003",
		"cat 无颈根骨（neck_50 直挂 chest_94）",
		"低。UAL 的 spine.003 只承载极小的胸廓/颈部过渡旋转；丢它≈丢掉一段很小的脊柱弯曲，"
		+ "表现为上半身略僵，但不穿帮、不滑步。**这是唯一一处主链缺口。**",
	],
	[
		"DEF-thumb.02.L / DEF-thumb.02.R（拇指中节）",
		"Godot `SkeletonProfileHumanoid` 的拇指只有 2 个槽位（Proximal/Distal），无 Intermediate",
		"低。丢掉拇指中节的一节旋转 ⇒ 拇指僵硬、不能弯曲，但**握持姿态仍成立**"
		+ "（本项目的握枪由 `WeaponHoldIK` + `HandGripModifier` 独立驱动，不依赖 UAL 手指）。",
	],
	[
		"cat 上半身饰品骨（ponytail / ear / mouth / Bone.NN 头发 / Bone.008~012 胸饰，共约 45 根）",
		"UAL 是无配件的裸 mannequin，骨架里根本没有这些骨",
		"**零影响（设计如此）**。它们保持 rest 姿态不动 —— 对初音的双马尾/猫耳/口型来说，"
		+ "这意味着 UAL 动画播放时头发和耳朵是「僵的」，不会跟着身体甩。**这是风格 clash 的主要来源之一。**",
	],
	[
		"cat lower_leg.L.001_98 / lower_leg.R.001_103 / lower_arm.L.001_108 / lower_arm.R.001_109（4 根）",
		"Rigify 的镜像辅助骨，parent 挂在 GLTF_created_0_rootJoint 下（不在腿/臂链上）",
		"零影响。它们本就不参与正常变形（是给 IK/镜像用的辅助点），保持 rest 即可。",
	],
]


## 构建 Godot `BoneMap`（profile 槽位 → 实际 UAL 骨名）。
## @param profile 共享的 SkeletonProfile（一般是 SkeletonProfileHumanoid）
## @return 配置好的 BoneMap
static func build_bone_map(profile: SkeletonProfile) -> BoneMap:
	var bm := BoneMap.new()
	bm.profile = profile
	for slot in PROFILE_TO_UAL:
		var ual_bone := String(PROFILE_TO_UAL[slot])
		if ual_bone == "":
			continue  # 占位/无对应
		# UAL 骨名就是「实际骨名」——本映射表以 UAL 为源，故填 UAL 名。
		bm.set_skeleton_bone_name(slot, ual_bone)
	return bm


## 自检：核对映射表与两侧实际骨名是否一致（防「表写错但没人发现」）。
## @param ual_skel UAL 的 Skeleton3D
## @param cat_skel cat 的 Skeleton3D
## @return {ok: bool, ual_missing: Array[String], cat_missing: Array[String], cat_unused: Array[String]}
static func verify(ual_skel: Skeleton3D, cat_skel: Skeleton3D) -> Dictionary:
	var ual_names := {}
	for i in ual_skel.get_bone_count():
		ual_names[ual_skel.get_bone_name(i)] = true
	var cat_names := {}
	for i in cat_skel.get_bone_count():
		cat_names[cat_skel.get_bone_name(i)] = true

	var ual_missing: Array = []
	var cat_missing: Array = []
	var used_cat: Dictionary = {}
	var mapped := 0
	for ual_bone in UAL_TO_CAT:
		var cat_bone := String(UAL_TO_CAT[ual_bone])
		if cat_bone == "":
			continue  # 故意留空
		mapped += 1
		if not ual_names.has(ual_bone):
			ual_missing.append(ual_bone)
		if not cat_names.has(cat_bone):
			cat_missing.append(cat_bone)
		used_cat[cat_bone] = true

	var cat_unused: Array = []
	for cn in cat_names:
		if not used_cat.has(cn):
			cat_unused.append(cn)

	return {
		"ok": ual_missing.is_empty() and cat_missing.is_empty(),
		"ual_missing": ual_missing,
		"cat_missing": cat_missing,
		"cat_unused": cat_unused,
		"mapped_count": mapped,
		"ual_total": ual_skel.get_bone_count(),
		"cat_total": cat_skel.get_bone_count(),
	}
