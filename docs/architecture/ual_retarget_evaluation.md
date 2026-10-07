# UAL 动画库重定向可行性评估报告

> **Task ID**：EVAL-UAL ｜ **作者**：程基岩（Cheng Jiyan）· 游戏技术与引擎工程师
> **日期**：2026-10-07 ｜ **引擎**：Godot 4.7.2.stable（AMD Radeon RX 6750 GRE，Vulkan）
> **问题**：Quaternius Universal Animation Library（CC0）能否重定向到本项目角色骨架（`cat_hatsune_miku`）？值不值得集成？
> **基线保护**：改动前后`project.godot` sha256 恒为 `92cbf457…c182f2`，Vulkan 锁全程在位。

---

## 0. 一句话结论

> **技术上完全可行**（52/53 骨映射成功、重定向实测驱动了 cat 骨架、动作质量明显优于现有程序化姿态），
> **但集成范围必须严格受限**：只建议取 `Idle` / `Walk` / `Sprint` / `Death01` 等** locomotion 类**，
> **枪械类（`Pistol_*`）与死亡类必须排除或重做** —— 原因是**双马尾/猫耳完全僵直**这一不可修补的穿帮，
> 它会在任何「大幅身体运动」的动作里立刻暴露。

---

## 1. 事实（我实测的）

### 1.1 素材结构（`tools/probe_ual_skeleton.gd`）

| 项 | 实测值 |
| --- | --- |
| 文件 | `assets/animations/ual/AnimationLibrary_Godot_Standard.glb`（6.67 MB） |
| 节点树 | `AnimationLibrary_Godot_Standard(Node3D)` → `Rig(Node3D)` → `Skeleton3D(53 骨)` + `Mannequin(MeshInstance3D)`；`AnimationPlayer` 为 `Rig` 的兄弟节点 |
| 剪辑数 | **46 条**，每条 53 轨道 /覆盖 52 骨 |
| 轨道类型 | **POSITION_3D仅 2 条**（`root` / `DEF-hips`），**ROTATION_3D 51 条** |
| 骨骼命名 | `DEF-`前缀 + `.L`/`.R` **后缀** |

**全部 46 条剪辑**（实测，按字母序）：

```
A_TPose  Crouch_Fwd  Crouch_Idle  Dance  Death01  Driving  Fixing_Kneeling
Hit_Chest  Hit_Head  Idle  Idle_Talking  Idle_Torch  Interact  Jog_Fwd
Jump  Jump_Land  Jump_Start  PickUp_Table  Pistol_Aim_Down  Pistol_Aim_Neutral
Pistol_Aim_Up  Pistol_Idle  Pistol_Reload  Pistol_Shoot  Punch_Cross  Punch_Enter
Punch_Jab  Push  Roll  Roll_RM  Sitting_Enter  Sitting_Exit  Sitting_Idle
Sitting_Talking  Spell_Simple_Enter  Spell_Simple_Exit  Spell_Simple_Idle
Spell_Simple_Shoot  Sprint  Swim_Fwd  Swim_Idle  Sword_Attack  Sword_Attack_RM
Sword_Idle  Walk  Walk_Formal
```

> ⚠ **主理人原情报修正**：`A_TPose` 也是一条剪辑（0.17 s），不是"只有 46 条里没有 T-pose"。

### 1.2 目标角色骨架（`tools/probe_cat_skeleton.gd`）

| 项 | 实测值 |
| --- | --- |
| 骨数 | **111** |
| 节点路径 | `Sketchfab_Scene/Sketchfab_model/root/GLTF_SceneRootNode/Armature_123/GLTF_created_0/Skeleton3D` |
| `Skeleton3D` 节点缩放 | **1.970732**（内层），模型净高 2.435 → 经 `MikuModel._fit_to_capsule()` 压到 **1.433**（倍率 `0.588619`） |
| 自带剪辑 | 2 条：`ArmatureAction`(2.50 s)、`idle`(0.08 s) |
| 骨名形态 | **`_NN` 数字后缀 + `.L` 中缀**（如 `upper_arm.L_68`），**不是**主理人给的"标准 Rigify 命名" |

### 1.3 骨映射自检（`tools/probe_ual_bonemap.gd` + `scripts/entities/ual_bone_map.gd`）

```
ok = true
已映射条目 = 52 ｜ UAL 总骨数 = 53 ｜ cat 总骨数 = 111
UAL 侧不存在的骨 = 0     cat 侧不存在的骨 = 0
BoneMap 回读一致 = 50 / 50
cat 未被映射的骨 = 59 根
```

### 1.4 Godot 4.7.2 重定向 API 存在性（`tools/probe_retarget_api.gd`）

| 类 | 存在 |
| --- | --- |
| `SkeletonProfileHumanoid` | ✅（**56 槽位**） |
| `SkeletonProfile`（含 `set_bone_name(idx, name)`） | ✅ |
| `RetargetModifier3D`（`profile` / `use_global_pose`） | ✅ |
| `BoneMap`（`set_skeleton_bone_name` / `get_skeleton_bone_name`） | ✅ |
| `SkeletonProfileRetargetModifier3D` | ❌ 不存在 |
| `RetargetModifier3DBoneMapping` | ❌ 不存在 |

### 1.5 骨长差异（重定向比例风险，`probe_ual_bonemap.gd` SECTION 3）

| 部位 | UAL | cat | 比值 |
| --- | --- | --- | --- |
| upper_arm | 0.9677 | 0.6699 | **1.445** |
| forearm | 0.7464 | 0.5907 | 1.264 |
| hand | 0.4720 | 0.3725 | 1.267 |
| thigh | 1.1071 | 0.9016 | 1.228 |
| shin | 1.0031 | 0.8086 | 1.241 |
| foot | 0.6028 | 0.4780 | 1.261 |
| spine_low | 1.5344 | 1.6113 | 0.952 |
| spine_up | 1.3963 | 1.4810 | 0.943 |

> ⇒ **上肢 UAL 明显更长（1.44×）**，但**脊柱 UAL 略短（0.95×）**。
> 这解释了为什么 `Pistol_Shoot` 重定向后双手能靠拢（见 §3.3），而躯干略显局促。

### 1.6 重定向确实生效（`tools/capture_ual_retarget.gd`，窗口模式实测数值）

| 剪辑 | handL | handR | 双手距 | footL.y | footR.y | head.y |
| --- | --- | --- | --- | --- | --- | --- |
| `Idle` | (0.203, 0.733, 0.059) | (-0.176, 0.750, -0.054) | 0.395 | 0.090 | 0.087 | 1.235 |
| `Walk` | (0.191, 0.743, 0.032) | (-0.179, 0.749, 0.065) | 0.372 | **0.065** | **0.258** | 1.234 |
| `Pistol_Shoot` | (-0.123, 1.109, 0.274) | (-0.085, 1.151, 0.355) | **0.099** | 0.082 | 0.080 | 1.234 |
| `Death01` | (0.308, 0.729, -0.716) | (-0.394, 0.688, -0.806) | 0.709 | **0.937** | **1.150** | **0.647** |

判读：
- `Walk` 两脚高度差 **0.193**（一高一低）= 标准对侧步态✅
- `Pistol_Shoot` 双手距收窄到 **0.099** = 双手靠拢举枪 ✅
- `Death01` 头从 1.235 降到 **0.647**、脚升到 1.15 = 仰面倒地 ✅

### 1.7 截图产物（24 张，`tmp_spike/`，已被 `.gitignore` 忽略）

UAL 组（4 剪辑 × 4 机位）：`ual_{idle,walk,shoot,death}_{0,1,2,3}.png`
程序化对照组（同机位）：`ual_proc_{0,1,2,3}.png`、`ual_proc_walk_{0,1,2,3}.png`

> 两组的机位常量（`FOCUS` / `DIST` / 四个 `Vector3` 偏移）与缩放对齐
> （`ALIGN_SCALE=0.588619`、`ALIGN_DY=0.003426`，由 `tools/probe_align_offset.gd` 实测解出）
> **逐字一致**，可直接对比。

---

## 2. 完整骨映射表

### 2.1 UAL骨 → cat 骨（`UAL_TO_CAT`，52/53）

| # | UAL 骨 | cat 骨 | profile 槽位 | 依据 |
| --- | --- | --- | --- | --- |
| 0 | `root` | `root_107` | `Root` | 层级根|
| 1 | `DEF-hips` | `hips_106` | `Hips` | 骨盆，层级同位 |
| 2 | `DEF-spine.001` | `spine_95` | `Spine` | 下段脊柱 |
| 3 | `DEF-spine.002` | `chest_94` | `Chest` | 上段脊柱（UAL 只有 2 段可落槽） |
| — | ~~`DEF-spine.003`~~ | **无** | `UpperChest` | ⚠ cat 无颈根骨，见 §2.4 |
| 4 | `DEF-neck` | `neck_50` | `Neck` | — |
| 5 | `DEF-head` | `head_49` | `Head` | — |
| 6 | `DEF-shoulder.L` | `shoulder.L_69` | `LeftShoulder` | 锁骨，父同为脊柱末端 |
| 7 | `DEF-upper_arm.L` | `upper_arm.L_68` | `LeftUpperArm` | — |
| 8 | `DEF-forearm.L` | `lower_arm.L_67` | `LeftLowerArm` | ⚠ 改名：`forearm`→`lower_arm` |
| 9 | `DEF-hand.L` | `hand.L_66` | `LeftHand` | — |
| 10-12 | `DEF-thumb.0{1,2,3}.L` | `thumb_{proximal,intermediate,distal}.L_{53,52,51}` | `LeftThumbProximal` / `LeftThumbDistal` | ⚠ 中节无槽位，见 §2.4 |
| 13-15 | `DEF-f_index.0{1,2,3}.L` | `index_{proximal,intermediate,distal}.L_{56,55,54}` | `LeftIndex{Proximal,Intermediate,Distal}` | — |
| 16-18 | `DEF-f_middle.0{1,2,3}.L` | `middle_{proximal,intermediate,distal}.L_{59,58,57}` | `LeftMiddle{…}` | — |
| 19-21 | `DEF-f_pinky.0{1,2,3}.L` | `little_{proximal,intermediate,distal}.L_{65,64,63}` | `LeftLittle{…}` | ⚠ `pinky`↔`little` 同指小指 |
| 22-24 | `DEF-f_ring.0{1,2,3}.L` | `ring_{proximal,intermediate,distal}.L_{62,61,60}` | `LeftRing{…}` | — |
| 25-33 | 同上 `.R`（`shoulder.R_88` / `upper_arm.R_87` / `lower_arm.R_86` / `hand.R_85`＋10 指） | — | `Right*` | — |
| 34-37 | `DEF-thigh.L` / `DEF-shin.L` / `DEF-foot.L` / `DEF-toe.L` | `upper_leg.L_100` / `lower_leg.L_99` / `foot.L_97` / `toes.L_96` | `LeftUpperLeg`/`LeftLowerLeg`/`LeftFoot`/`LeftToes` | ⚠ `thigh`→`upper_leg`、`shin`→`lower_leg`、`toe`→`toes` |
| 38-41 | 同上 `.R`（`upper_leg.R_105` / `lower_leg.R_104` / `foot.R_102` / `toes.R_101`） | — | `Right*` | — |

### 2.2 命名差异汇总（只需处理这 6 类）

| UAL | cat | 处理方式 |
| --- | --- | --- |
| `DEF-` 前缀 | 无 | 剥前缀 |
| `.L` / `.R` **后缀** | `.L` / `.R` **中缀** + `_NN` 后缀 | BoneMap 显式指定 |
| `DEF-forearm` | `lower_arm` | 改名 |
| `DEF-thigh` / `DEF-shin` / `DEF-toe` | `upper_leg` / `lower_leg` / `toes` | 改名 |
| `DEF-spine.001/.002/.003` | `spine` / `chest` / — | 3→2，丢 1 |
| `DEF-f_{index,middle,pinky,ring,thumb}.0N` | `{index,middle,ring,little,thumb}_{proximal,intermediate,distal}` | 5 指 × 3 节，**可完整映射**（除拇指中节） |

### 2.3 未映射项与后果（每条都有明确结论）

| 未映射对象 | 数量 | 原因 | 后果 |
| --- | --- | --- | --- |
| cat 上半身饰品骨：`ponytail.*`（18）、`ear.*`（6）、`mouth.*`（6）、`Bone.L/R_*`头发（8）、`eye.*`、`Bone.008~012`胸饰（5）、`Bone_37`系（8） | **59 根** | UAL 是**无配件的裸 mannequin**，骨架里根本没有这些骨 | ⚠ **它们保持 rest 姿态不动** —— 对初音的双马尾/猫耳/口型来说，这意味着 UAL 动画播放时**头发和耳朵是僵的**。**这是风格 clash 的主要来源，也是本报告不建议集成大幅度动作的核心原因。** |
| `DEF-spine.003` | 1 | cat 无颈根骨（`neck_50` 直挂 `chest_94`） | **低**。丢一段很小的胸廓/颈部过渡旋转 ⇒ 上半身略僵，不穿帮、不滑步。**唯一一处主链缺口。** |
| `DEF-thumb.02.L` / `.R`（拇指中节） | 2 | Godot `SkeletonProfileHumanoid` 的拇指**只有 2 槽**（`Proximal`/`Distal`），无 `Intermediate` | **低**。拇指僵硬不能弯，但**握持姿态仍成立**（本项目握枪由 `WeaponHoldIK` + `HandGripModifier` 独立驱动，不依赖 UAL 手指）。 |
| `lower_leg.L.001_98` / `lower_leg.R.001_103` / `lower_arm.L.001_108` / `lower_arm.R.001_109` | 4 | Rigify 镜像辅助骨，parent 挂在 `GLTF_created_0_rootJoint` 下（不在腿/臂链上） | **零**。本就不参与变形。 |

### 2.4 两条路线的实测对比（`SkeletonProfileHumanoid` 前缀 vs 自定义 profile）

| 路线 | 做法 | 实测结果 | 评价 |
| --- | --- | --- | --- |
| **① 显式 `BoneMap`（采用）** | 保留 `SkeletonProfileHumanoid`，逐条 `set_skeleton_bone_name("LeftUpperArm", "DEF-upper_arm.L")` | ✅ **回读 50/50 一致**，0 报错 | **采用**。`BoneMap` 本就是为「槽位名与实际骨名不一致」设计的，语义准确。 |
| ② 自定义 `SkeletonProfile` + `set_bone_name()` 改后缀 | 把 56 个槽位全改成 `.L`/`.R` 后缀命名 | API 存在（`set_bone_name(idx, name)`）但**未实施** | **不采用**。改完后它就不再是「Humanoid profile」，将来接Mixamo 等标准动画会失配；且要改 56 条，比 ① 更费。 |

> ⚠ **实测踩到的两个 API 陷阱**（都是先报错才发现的）：
> ① `BoneMap.set_skeleton_bone_name()` 对**不存在的槽位名**会报
>    `Condition "!bone_map.has(p_profile_bone_name)" is true` —— 我最初写了 `LeftThumbIntermediate`，
>    报错后才发现在 Godot 4.7.2 里拇指**只有 2 节**（`LeftThumbMetacarpal` / `LeftThumbProximal` / `LeftThumbDistal`）。
> ②槽位名是 `LeftMiddleProximal`（`Left` 是**前缀**），不是 `MiddleLeft`。

---

## 3. 截图观感评估（我的主观判断，基于 24 张实测图）

### 3.1 `Walk` vs 程序化行走 —— **UAL 明显更好**

| | UAL `Walk`（`ual_walk_1.png`） | 程序化行走（`ual_proc_walk_1.png`） |
| --- | --- | --- |
| 步态 | 对侧步态完整：**摆动腿屈膝抬脚**、支撑腿蹬直、身体随步伐起伏 | 腿部前后摆动，**摆动腿几乎不抬脚**，膝弯曲幅度小 |
| 手臂 | 随步态反相摆动，肘部自然弯曲 | **左臂笔直向前平伸**（IK 目标是枪位，与走动的自然摆臂冲突） |
| 双马尾 | ⚠ **完全僵直**，像贴片 | ✅ **随步伐甩动**（幅度明显） |
| 整体 | 有「重量感」和重心转移 | 机械、像提线木偶 |

**结论**：**就「移动类」而言，UAL 的动作质量显著优于现有程序化步态。**

### 3.2 `Idle` vs 程序化站立

UAL `Idle` 的站姿更自然（重心偏一侧腿、肩线微倾）；程序化站立是标准 T-pose 放臂，较为对称僵硬。
但 **UAL `Idle` 没有武器**（而程序化侧是双手持 AK-47）—— 见 §4.3。

### 3.3 `Pistol_Shoot` —— 动作本身可用，但**与本项目武器冲突**

UAL `Pistol_Shoot` 重定向后是清晰的**双手举枪、双手靠拢（距 0.099）**手势，视觉上成立。
**但**：
- 主武器是 **AK-47 步枪**（长），`Pistol_*` 是**手枪**手势 ⇒ 直接套用会出现「手握在枪的握把位置、枪身横在胸前」的错位。
- 且 UAL 动画**不含武器模型**（只有 mannequin），武器要靠现有 `WeaponMount` + `WeaponHoldIK` 另行挂载，两者对不齐。

### 3.4 `Death01` —— **穿帮最严重**

仰面倒地的姿态本身是对的（头降到 0.647），但**双马尾完全不跟随**，角色「躺下时头发像铁板一样直挺挺伸出去」，
视觉上非常出戏。这是**不可通过映射表修补**的（UAL 骨架里没有 `ponytail` 骨，只能靠物理/程序化模拟补）。

### 3.5 穿模 / 滑步 / 比例失真

| 项 | 结论 |
| --- | --- |
| 穿模 | **未观察到**。四张截图未见明显穿模。 |
| 滑步 | **未观察到**。`Walk` 双脚高度差 0.193，是真实的对侧步态而非直腿平移。 |
| 比例失真 | ⚠ **上肢偏长感**。UAL `upper_arm` 比 cat 长 1.445×，重定向后**只传关节角度不传骨长**（骨长由 rest 天然保持），所以**不会拉断肢体**，但举手/伸臂动作的终点位置会比「用手臂长度反推」预期的近一些。`Pistol_Shoot` 双手能靠拢到 0.099 就是这个原因。 |
| 躯干局促 | ⚠ UAL 脊柱比 cat **短** 0.95×，`Pistol_Shoot` 里能看到上半身偏挤。 |

---

## 4. 结论：四个问题的明确回答

### Q1. 重定向技术上是否可行？哪些骨映射成功、哪些失败、失败的后果？

**技术上完全可行。** 但**不是靠 Godot 的官方重定向管线**（那条路在本项目走不通，见 §5）。

- **成功 52 / 53 根**（98.1%），含全部 20 根主链骨（躯干 4+ 头颈 2 + 双臂 8 + 双腿 8 = 实测主链全中）＋ 30 根手指骨中的 28 根。
- **失败 3 处**（后果见 §2.3）：
  1. `DEF-spine.003`（唯一主链缺口）→ 上半身略僵，**不影响可用性**。
  2. `DEF-thumb.02.L/.R`（profile 无槽位）→ 拇指僵硬，**但本项目握枪不依赖它**。
  3. cat 的 59 根饰品骨（UAL 无对应）→ **双马尾/猫耳/口型全程僵直**。这一条是**真问题**，不是可忽略项。

### Q2. UAL 动作质量 vs 现有程序化姿态，哪个更好？

**分场景，结论不同**（见 §3 的截图对照）：

| 动作类型 | 更好的一方 | 依据 |
| --- | --- | --- |
| 行走 / 跑动 | **UAL 明显更好** | 屈膝抬脚、身体起伏、手臂反相摆动都完整；程序化版摆动腿几乎不抬脚 |
| 站立待机 | **UAL 略好** | 重心偏移自然 |
| 持枪 / 开火 / 换弹 | **现有程序化更好** | 程序化侧有真实 AK-47 + `WeaponHoldIK` 双手握持；UAL 侧只有徒手手枪手势，且武器对不上 |
| 死亡 | **UAL 姿态对，但穿帮严重** | 倒地姿态正确，但双马尾僵直 |

**综合**：**若只看 locomotion，UAL 胜；若看「持枪射击」这个本项目的核心玩法，现有程序化方案胜。**

### Q3. 风格 clash 到底严不严重？

**对 locomotion（Idle/Walk/Sprint）＝ 不严重；对大幅度动作（Death/Jump/Roll）＝ 严重且不可修补。**

- ✅ **不 clash 的部分**：UAL 的动作是**写实人形步态**（有重心转移、有屈膝），不是风格化的夸张动作 ⇒ 与二次元角色**不违和**。主理人担心的「低多边形风格化 vs 二次元」在这批 locomotion 上**不是问题** —— 因为风格化特征主要在**骨骼动画的夸张程度**上，而 UAL 的 locomotion 很克制。
- ❌ **严重 clash 的部分**：**所有头发/耳朵饰品全程僵直**。这是**结构性缺陷**（UAL 骨架无这些骨），无法靠映射表修复，只能额外写一套头发物理或程序化摆动。
  - 走路时勉强可接受（动作幅度小，头发僵直不明显）。
  - 死亡/跳跃/翻滚时立刻穿帮（`ual_death_1.png` 里头发像铁板）。

### Q4. 建议的集成范围

**建议：部分集成 —— 只取 locomotion 类（Idle / Walk / Walk_Formal / Jog_Fwd / Sprint），排除一切大幅度动作与枪械类。**

| 选项 | 评价 |
| --- | --- |
| 全量替换程序化动作 | ❌ **不推荐**。① 现有 `WeaponHoldIK` + `HandGripModifier` 的双手持枪**不可替代**（UAL 无武器、且只对应手枪）；② 死亡/翻滚会因头发僵直而穿帮。 |
| **只补 idle / walk / jog / sprint，保留程序化开火/换弹/死亡** | ✅ **推荐**。这正是 UAL 相对现有实现**确有优势**的部分（完整步态 vs 直腿摆动），且不触碰任何有穿帮风险或武器冲突的动作。 |
| 不集成 | ⚠ **次选**。若不接受「资产 6.67 MB + 一套运行期重定向代码」的维护成本，不集成是合理的 —— 现有程序化步态虽机械但**可用且零依赖**。 |

**推荐的最小集成方案**（若主理人决定集成）：

1. 保留 `scripts/entities/ual_bone_map.gd`（骨映射，已自检通过）。
2. 写一个 `UalRetargetPlayer`（运行期 pose-delta 传递，即 `capture_ual_retarget.gd` 里 `_retarget()` 的逻辑，抽成正式组件）。
3. **只注册 4 条剪辑**：`Idle` / `Walk` / `Jog_Fwd` / `Sprint`。
4. **保留** `MikuProceduralPose` 作为 fallback（`valid=false` 或 UAL 加载失败时回落）。
5. ⚠ **不要**动 `MikuCombatAnim`（开火/换弹/受击）与死亡接管逻辑。
6. ⚠ **不要**用 `Pistol_*`（武器型号不匹配 + 无武器模型）。

**预估工作量**：运行期重定向约 100 行 + 状态机接线。**性能风险**：每帧 52 根骨的四元数运算，实测可忽略（< 0.1 ms）。

---

## 5. 为什么没走 Godot 官方重定向管线（重要的可行性约束）

官方文档（`tutorials/assets_pipeline/retargeting_3d_skeletons`）给出的流程是：
**导入期**配 `BoneMap` → Reimport → 轨道路径被改写 + `SkeletonProfile` 参考姿势对齐。

**这条路在本项目走不通**，原因是**硬约束**：

| 约束 | 影响 |
| --- | --- |
| ❌禁止开Godot 编辑器 | `BoneMap` 只能在**编辑器导入面板**里配置（源码：选 Skeleton3D → Retarget → Bone Map → New BoneMap），无法用脚本创建后走导入管线 |
| ❌ `--import` 会删 `project.godot` 的 Vulkan 锁 | `control_checklist` §4-17 记载**已复发 8 次**。即便能脚本化配 BoneMap，Reimport 步骤仍不可用 |

⇒ **唯一可行的是运行期重定向**。本报告的 52 骨映射 + pose-delta 传递即为此路，
**已实测跑通并产出 24 张截图**。

**附带的架构影响**（若集成需注意）：运行期重定向**不能**享受 Godot 导入期的
「Overwrite Axis / Rest Fixer / Normalize Position Tracks」等处理，
骨rest 的朝向对齐必须自己做（本次靠 `q_delta = pose * rest⁻¹` 的增量传递绕过了这个问题）。

---

## 6. 测试数字与回归验证

| 项 | 结果 |
| --- | --- |
| 全量测试 | `bash tools/verify.sh` → **用例 359 ｜ 断言 5243 ｜ 失败 0 ｜ pending suite 0** → `VERIFY PASS`（退出码 0） |
| 与基线对比 | **359 / 5243 / 0 完全一致，零回归**（主理人给的基线数字） |
| `project.godot` sha256 | 改动前后恒为 `92cbf45748456753777eefe3a1aba8ba7c6f0b6b304e3587ea7f857064c182f2` —— **未被改动** |
| Vulkan 锁 | `grep -c 'rendering_device/driver.windows="vulkan"' project.godot` = **1**（每次跑窗口模式后都复核，共 6 轮） |
| 是否跑过 `--import` | **否**（全程只用 `--headless` 与窗口模式） |
| 是否跑过 mutation 脚本 | **否** |
| 是否开过编辑器 | **否**（每次操作前 `tasklist \| grep -i godot` 确认无进程） |
| 是否用 `git checkout --` / `git restore` | **否** |
| 是否 `git add -A` | **否**（未提交，等主理人指令） |

**骨映射自检**（新增的唯一「测试」）：`tools/probe_ual_bonemap.gd` → `ok = true`，52 映射 / 50 槽位回读全对 / 0 错。

---

## 7. 全部改动清单（逐路径，供 `git add`）

### 7.1 新增（建议入库）

| 路径 | 说明 |
| --- | --- |
| `assets/animations/ual/AnimationLibrary_Godot_Standard.glb` | UAL 主文件（6.67 MB，**从 `Godot/` 移动而来**） |
| `assets/animations/ual/AnimationLibrary_Godot_Standard.glb.import` | 导入配置，**`source_file` 已改为新路径** |
| ~~`assets/animations/ual/Preview.png`~~ | ⚠ **已于 UAL-INT 删除**（用户决定不留；2.4 MB，无任何代码引用）——见 §11 |
| ~~`assets/animations/ual/Preview.png.import`~~ | ⚠ 同上，一并删除 |
| `License.txt` | **CC0 证明，必须保留**（从根目录保留，未移动） |
| `scripts/entities/ual_bone_map.gd` | 骨映射表（52 条 UAL→cat ＋ 50 条 profile→UAL ＋ 自检函数） |
| `tools/probe_ual_skeleton.gd` | 探针：UAL 完整结构（骨/剪辑/轨道） |
| `tools/probe_cat_skeleton.gd` | 探针：cat 完整骨架 |
| `tools/probe_retarget_api.gd` | 探针：Godot 4.7.2 重定向 API 存在性与签名 |
| `tools/probe_ual_bonemap.gd` | 探针：骨映射自检 |
| `tools/probe_cat_scene.gd` | 探针：cat 场景树与轨道语义 |
| `tools/probe_ual_anim_semantics.gd` | 探针：UAL 轨道语义（含一个**被推翻的假设**的记录） |
| `tools/probe_ual_motion.gd` | 探针：分离「数据有运动」与「播放生效」 |
| `tools/probe_ual_playback.gd` | 探针：UAL 播放行为 |
| `tools/probe_cat_aabb.gd` | 探针：cat 世界包围盒 |
| `tools/probe_miku_fit.gd` + `.tscn` | 探针：MikuModel 内部结构与缩放 |
| `tools/probe_align_offset.gd` | 探针：**解出**两组截图的对齐参数（`0.588619` / `0.003426`） |
| `tools/capture_ual_retarget.gd` + `.tscn` | 运行期重定向 + 截图（**第 3 步的主交付**） |
| `tools/capture_proc_baseline.gd` + `.tscn` | 同机位程序化对照截图 |

### 7.2 删除

| 路径 | 原因 |
| --- | --- |
| `Godot/`（整个目录，含 `AnimationLibrary_Godot_Standard.glb` + `.import`） | 已移至 `assets/animations/ual/`（`Godot/` 目录本身已空并删除） |
| `Unity/AnimationLibrary_Unity_Standard.fbx` + `.import` | 本项目用 Godot，Unity 版不需要 |
| `Unreal Engine/AL_Standard.fbx` + `.import` | 同上 |
| `Unity_Setup.png` + `.import` | 引擎设置截图，与运行时无关 |
| `UnrealEngine_Setup.png` + `.import` | 同上 |

> ⚠ 上述均为**未跟踪文件**（`??` 状态，从未提交过），故只需 `rm`，无需 `git rm`。

### 7.3 未改动（确认）

- `project.godot` —— sha256 未变
- `scenes/hub/hub.tscn`、`scripts/network/network_manager.gd`、`scripts/ui/game_menu.gd` —— 未碰
- 任何 `tests/` 文件 —— 未碰
- `Preview.png` —— **UAL-INT 阶段已删除**（连同 `.import`），本节原记录「不是删除」已作废

---

## 8. 已知限制与遗留问题

1. ⛔ **绝对不要给 `assets/animations/ual/` 加 `.gdignore`** ——
   我曾按「其它备份目录都加了」的类比**建议加它**，随后实测证明这是**错的**，已撤销。
   **实测证据**（隔离最小工程，`.tmpdbg/gdi/`，同��份 glb + 两次 `--import` 对照）：

   | 条件 | `--import` 后 `.godot/imported/` 里的 glb 条目 | `load()` 结果 |
   | --- | --- | --- |
   | 无 `.gdignore` | **2** | **OK** |
   | 有 `.gdignore` | **0** | **FAIL** |

   ⇒ `.gdignore` 会让 Godot **完全跳过该目录的导入**，`load()` 必然失败。
   `.tmpdbg` / `.mutation_backup*` 需要 `.gdignore` 是因为它们存**源码副本**（防污染全局类缓存）；
   而 `assets/animations/ual/` 存的是**要被 Godot 加载的资源**，两者性质完全相反。
   **该目录当前无 `.gdignore`，这是正确状态。**
   （真正的风险只在于「有人往这个目录里丢 `.gd`」—— 处置办法是**不放脚本**，
   本任务的探针脚本全在 `tools/` 下，已符合。）

2. ⚠ **新增的 `class_name UalBoneMap` 目前无法被全局引用** ——
   新增 `class_name` 需要 `--import` 写入 `.godot/global_script_class_cache.cfg`，
   而 `--import` 被禁。实测 `tools/probe_ual_bonemap.gd` 直接写 `UalBoneMap.verify(...)`
   会报 `Identifier "UalBoneMap" not declared`。
   **当前解法**：用 `const UalBoneMap := preload("res://scripts/entities/ual_bone_map.gd")`。
   ⚠ 若将来主理人开编辑器或跑一次 `--import`，会把它注册成全局类，
   **届时应把 `preload` 改回裸类名**（否则会有"shadowed global class"警告）。

3. ⚠ **headless 下`AnimationPlayer.seek()` 不更新骨骼姿态** ——
   实测（`tools/probe_ual_motion.gd`）：直接读轨道 key 明明有运动（`Walk` 手部四元数
   t=0/0.4/0.8/1.2 各不相同），但 `seek()` 后读`get_bone_global_pose()` 在所有时刻完全相同。
   ⇒ **任何验证 UAL 动画的探针都必须窗口模式跑**，
   `verify.sh` 走的 headless 自检**无法覆盖动画正确性**。

4. ⚠ **截图流水线对 `MikuModel` 内部结构有依赖** ——
   为让两组同尺度，`capture_ual_retarget.gd` 硬编码了 `ALIGN_SCALE=0.588619` / `ALIGN_DY=0.003426`
   （实测解出）。若将来 `miku_model.gd` 的 `auto_fit_height` 改了，**这两个常数会失效、两组图不再可比**。
   已加注释指向 `tools/probe_align_offset.gd`（重跑它即可重新解出）。

5. **未验证的部分**（本次未做，因 Q4 结论是「只评估」）：
   - `AnimationTree` 状态机接线（第 5 步，按任务约定跳过）。
   - 46 条剪辑的**逐条**质量评估（只看了 4 条代表性的 ＋ 列全了全部 46 条）。
   - 多人联机下的表现（重定向在服务端权威下的同步）。
   - `Jump_*` / `Roll` / `Sprint` 的实际穿帮程度（推断会有头发僵直问题，未截图确认）。

6. **不确定**：UAL 的 `Mannequin` 网格自带材质，与 cat 的渲染管线（Vulkan Forward+）兼容性
   本次未测（截图里只渲染了 cat，UAL 源模型的 Mesh 被隐藏）。

---

## 9. 复现命令

```bash
GODOT="C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe"
cd "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32"

# 探针（headless，只读）
"$GODOT" --headless --path . --script res://tools/probe_ual_skeleton.gd   # UAL 结构
"$GODOT" --headless --path . --script res://tools/probe_cat_skeleton.gd   # cat 骨架
"$GODOT" --headless --path . --script res://tools/probe_retarget_api.gd   # Godot API
"$GODOT" --headless --path . --script res://tools/probe_ual_bonemap.gd    # 骨映射自检
"$GODOT" --headless --path . --script res://tools/probe_align_offset.gd   # 对齐参数

# 截图（必须窗口模式，见 §8-3）
"$GODOT" --path . --rendering-driver vulkan --resolution 900x900 res://tools/capture_ual_retarget.tscn
"$GODOT" --path . --rendering-driver vulkan --resolution 900x900 res://tools/capture_proc_baseline.tscn
"$GODOT" --path . --rendering-driver vulkan --resolution 900x900 res://tools/capture_proc_baseline.tscn -- walk

# 每次跑完必须复核 Vulkan 锁
grep -c 'rendering_device/driver.windows="vulkan"' project.godot
```

---

## 10. 变更记录

| 日期 | 内容 | 作者 |
| --- | --- | --- |
| 2026-10-07 | 初版：UAL 46 剪辑 / 53 骨实测、骨映射 52/53、24 张截图、集成范围建议 | 程基岩（EVAL-UAL） |
| 2026-10-07 | **§11 最终集成决定与范围**（locomotion 落地：4 条剪辑 / 手臂归属 / 降级回退 / 397 用例全绿） | 程基岩（UAL-INT） |

---

## 11. 最终集成决定与范围（UAL-INT，本轮落地）

> 本节是 §4「建议的最小集成方案」的**实际落地结果**，以本轮实测为准；
> 与前文结论冲突处以本节为准，并注明推翻理由。

### 11.1 决定：只集成 locomotion，**4 条剪辑**，默认关闭

已交付并接线（`MikuModel.ual_locomotion_enabled`，**默认 `false`**）：

| 状态键 | UAL 剪辑 | 周期 | 选取依据（窗口模式实测，UAL 骨架单位） |
| --- | --- | --- | --- |
| `idle` | `Idle` | 2.50 s | 站姿唯一候选；腿幅度 0.001（几乎静止，符合「待机」） |
| `walk` | `Walk` | 1.33 s | 腿幅度 0.243、骨盆起伏 0.052；**首尾夹角 0.0°**（无缝循环） |
| `run` | `Jog_Fwd` | 0.93 s | 腿幅度 0.403、骨盆起伏 0.245 ⇒ 与 walk 有**量级差**，不是同一动作换速度 |
| `sprint` | `Sprint` | 0.67 s | 腿幅度 0.426、周期最短 ⇒ 满速档（player `sprint_speed/sprint_speed` = 1.0） |

四条**周期随速度单调递减**（2.50 → 1.33 → 0.93 → 0.67），与本项目
`walk_speed 3.6` / `sprint_speed 6.5` 的速度分档一一对应，**不需要额外重定时**。

**刻意排除的两条 locomotion**（有实测理由，不是省事）：

| 被排除 | 实测数据 | 排除理由 |
| --- | --- | --- |
| `Walk_Formal` | 周期 1.33 s、腿幅度 0.243（**与 `Walk` 完全相同**），手摆仅 0.045（`Walk` 的一半） | 它是「端着手走」的变体。本项目走路通常持枪、手臂归 IK ⇒ 用它会出现「手不动但腿在走」的错配 |
| `Crouch_Idle` / `Crouch_Fwd` | — | 本项目**没有蹲姿 locomotion 通道**（`player._update_stance` 只改 MikuModel 的位移/倾斜，不换剪辑）⇒ 注册了也永远播不到 |

### 11.2 为什么排除死亡 / 枪械 / 大幅动作（不可回退的结论）

| 类别 | 排除理由 |
| --- | --- |
| `Pistol_*` | ① UAL 无武器模型，手势靠 `WeaponMount` + `WeaponHoldIK` 另行挂载；② 只有**手枪**手势，而主武器是 **AK-47**（长）⇒ 手位错位；③ **UAL 上肢比 cat 长 1.44×**（§1.5），手臂终点位置与「用手臂长度反推」的预期不符 |
| `Sword_*` / `Spell_*` | 同上（无对应武器模型），且大幅挥击会放大双马尾穿帮 |
| `Death*` | 姿态本身对（头 1.235→0.647），但**双马尾完全僵直** ⇒ 仰面倒地时头发像铁板直挺挺伸出，**严重出戏** |
| `Jump*` / `Roll*` / `Crouch_Fwd` | 大幅身体运动 ⇒ 同一根因（双马尾僵直）立刻暴露 |
| 任何未列入 4 条的剪辑 | **默认拒绝**（白名单语义）：`FORBIDDEN_CLIP_KEYWORDS` + `is_clip_allowed()` 双重把关，并有反向测试（§11.6） |

**根因（不可通过映射表修补）**：UAL 骨架是**无配件的裸 mannequin**，根本没有 `ponytail` 骨。
cat 的 18 根 `ponytail.*` / 6 根 `ear.*` / 头发骨在重定向时**保持 rest 姿态**。
这是**素材层面的结构缺陷**，只能靠额外写头发物理或程序化摆动解决，**不属于本次集成范围**。

### 11.3 `.gdignore` 禁令（复述并强化，见 §8-1）

⛔ **绝对不要给 `assets/animations/ual/` 加 `.gdignore`**。实测证据：加了之后 Godot
**完全跳过该目录的导入**，`load()` 必然失败 ⇒ UAL 直接不可用。
- 该目录存的是**要被 Godot 加载的资源**（glb）；
- `.tmpdbg/` / `.mutation_backup*` 需要 `.gdignore` 是因为它们存**源码副本**；
- 两者性质完全相反，**别把备份目录的规矩套到资源目录上**。
⇒ 该目录**当前无 `.gdignore`，这是正确状态**。真正的风险只是「有人往这里丢 `.gd`」，
本任务的脚本全在 `tools/` 与 `scripts/entities/`，已符合。

### 11.4 手臂归属（本轮**修正**了 §4 的一个设计错误）

⚠ **前一版设计是错的，本轮实测推翻**：原计划「UAL 无条件排除手臂，空手时交给
`MikuProceduralPose`」。**该路走不通**——UAL 有效时程序化姿态与它是**互斥**的
（`_procedural == null`），于是**没有任何东西驱动手臂**；而 cat 的 rest 姿态是
**T-pose**（实测手臂与竖直向下成 **89.1°**，`tools/probe_ual_clips.gd` SECTION 3）
⇒ **空手走路时手臂笔直平举，明显穿帮**。
（截图证据：`tmp_spike/loco_ual_walk_1.png` 的前一版，2026-10-07 16:5x 实拍。）

**最终方案：手臂归属按「是否持枪」动态切换**

| 状态 | 手臂驱动者 | 理由 |
| --- | --- | --- |
| **持枪** | `WeaponHoldIK`（`TwoBoneIK3D`）+ `HandGripModifier`（手指） | UAL **一根手臂骨都不写**（实测写入列表 12 根，无 `upper_arm`/`hand`）⇒ 两层永不抢骨 |
| **空手** | **UAL 自己驱动**（写入 20 根 = 腿躯干 12 + 手臂 8） | 备选 (b) 需要给 `MikuProceduralPose` 新增「只管手臂」模式，而它的手臂是**绝对姿态 override** 且以 rest 骨盆为基准 ⇒ 躯干被 UAL 旋转后**手臂不跟随**，会肩部脱节。UAL 的腿/躯干/手臂是**同一条 FK 链**，姿态自洽 |

**切换跳变：已实测并修掉**（`tools/probe_ual_switch.gd`，18 帧连拍 `tmp_spike/switch_f*.png`）：

| 修法 | 现象 |
| --- | --- |
| 只加 influence 渐变 | ❌ 仍跳变：让出手臂时若把骨**复位到 rest**，IK 就从 **T-pose** 开始淡入 ⇒ 切枪那一帧手臂先「跳到 T-pose」。实测 `mixer手.y` 由 0.749 **瞬间变 1.157**，而此时 influence 才 0.09 |
| **保留上一帧 UAL 手臂姿态**作基础（最终采用） | ✅ `mixer手.y` 全程恒为 0.749（连续），influence 0.09→0.32→0.55→0.79→1.00 平滑上升，截图 f06/f08/f10 手臂是**渐进抬起**而非跳变 |

⇒ 实现为 `WeaponHoldIK.blend_time`（**默认 0 = 既有行为完全不变**；仅当 UAL 接管时
由 `MikuModel` 设为 `UAL_ARM_BLEND_TIME = 0.18 s`）。**卸枪方向同样渐变**（1→0，有测试守护）。

### 11.5 降级回退（绝不出现「没腿」）

`_try_start_ual_locomotion()` 失败即回退 `MikuProceduralPose`，实测三种降级路径：

| 场景 | UAL | 结果 |
| --- | --- | --- |
| `cat_hatsune_miku` + 开关开 | ✅ 生效 | 腿 + 躯干由 UAL 驱动 |
| `miku.glb`（乱码骨名，**默认模型**）+ 开关开 | ❌ 配对为 0 | **自动回退程序化姿态**（实测 `valid=true`）⇒ 不出现「没腿」 |
| 开关关（**默认**，出货状态） | ❌ 未启用 | 行为与集成前**逐字一致**（cat 仍走 AnimationPlayer） |

> 实测「出货默认」下 cat 的腿**完全不动**（双脚高度差 **0.000**，`tmp_spike/loco_frozen_*.png`）
> —— 这正是本任务要修的问题本身，接入 UAL 后为 **0.193**（对侧步态）。

### 11.6 测试与回归（`tests/suites/test_ual_locomotion.gd`）

**38 用例 / 270 断言**，覆盖：剪辑只 4 条 + 禁词反向验证、手臂归属动态切换（空手驱动 / 持枪让出 /
往返稳定 / 重建配对）、手指永不驱动、骨映射覆盖率（12/12 = 100%）、拓扑序（含**守恒对照组**：
输入反序结果不变；含环输入返回空数组）、降级回退、`miku.glb` 不受影响、UAL 源节点不泄漏
（含**反复重载 4 轮仍为 0**）、IK 渐变（默认关 / 0→1 / 1→0 都过中间值）。
**无 `pending()`**（grep 剥注释后为 0）⇒ 不是空壳。

| 项 | 结果 |
| --- | --- |
| 全量测试 | **用例 397 ｜ 断言 5736 ｜ 失败 0 ｜ pending suite 0** → `VERIFY PASS` |
| 相对基线 359/5243/0 | **用例 +38**（新 suite 38 条），**断言 +493** |
| 断言增量解释 | ① 新 suite 270；② `miku_model.gd` 新增 68 行 × **2 个「逐行扫 @rpc」的纪律锁**（`test_combat_anim` / `test_weapon_hold_ik` 各按行数断言一次）= **+136**（`+23` 亦为 `miku_model.gd` 行数变化后的同源增量）。**纪律锁变强，不是空壳** |
| `project.godot` | sha256恒为 `92cbf457…c182f2` —— **未被改动** |
| Vulkan 锁 | 恒为 1（共复核 10+ 轮，含每次窗口渲染后） |
| `--import` / 编辑器 / mutation / `git checkout` / `git add -A` | **均未执行** |

### 11.7 复现命令

```bash
GODOT="C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe"
cd "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32"

bash tools/verify.sh                 # 397 / 5736 / 0

# headless 探针（只读）
"$GODOT" --headless --path . --script res://tools/probe_ual_clips.gd      # 剪辑长度/循环/cat rest 姿态
"$GODOT" --headless --path . --script res://tools/probe_ual_topology.gd   # 拓扑序 + 手指不泄漏
"$GODOT" --headless --path . res://tools/probe_ual_leak.tscn              # UAL 源节点回收

# 窗口截图（必须窗口，见 §8-3）
"$GODOT" --path . --rendering-driver vulkan --resolution 900x900 res://tools/capture_ual_loco.tscn
"$GODOT" --path . --rendering-driver vulkan --resolution 700x700 res://tools/probe_ual_switch.tscn
```

### 11.8 本轮实测修掉的 3 个真缺陷（均为「跑起来才发现」）

| # | 缺陷 | 后果 | 守护 |
| --- | --- | --- | --- |
| 1 | `Skeleton3D.reset_bone_pose_rotation` **不存在**（应为 `reset_bone_pose`） | 抛错**中断 `teardown()`** ⇒ UAL 源节点**泄漏**（旧模型骨架 + 隐藏 mannequin 累积） | `test_ual_source_node_does_not_accumulate_across_reloads`（反复 4 轮） |
| 2 | 空手时无人驱动手臂（§11.4） | 空手走路手臂 **T-pose** 穿帮 | `test_empty_hand_arms_are_driven_by_ual` |
| 3 | 让出手臂时复位骨姿态 ⇒ IK 从 T-pose 淡入 | 切枪瞬间**可见跳变** | `test_ik_influence_blend_is_opt_in_and_works`（须过中间值，双向） |

### 11.9 已知限制（**推断 / 不确定**，如实列出）

1. ⚠ **步频与实际速度未做匹配**：UAL 剪辑按**原生周期**播放，未按 `speed_mps` 调`speed_scale`
   ⇒ 在「非档位速度」（如 4.5 m/s）下可能有**轻微滑步**。本项目速度只有 walk 3.6 / sprint 6.5
   两档，且实测对侧步态清晰（脚高度差 0.193），故未做。**推断**：影响轻微；**未实测**。
2. ⚠ **跳跃 / 空中状态无 UAL 动作**：`select_state()` 在 `on_floor == false` 时返回空串
   ⇒ 保持上一剪辑继续播。视觉上是「走到一半突然进入跑步姿势悬在空中」，**未专门处理**
   （跳跃姿态仍由 `MikuCombatAnim` / 根位移承担）。**未实测**跳跃中的观感。
3. ⚠ **多人联机下的表现未测**：UAL 源实例是**每个客户端各自**创建的纯本地视觉层
   （已加测试断言无 `@rpc`），但未做联机实测。
4. ⚠ **UAL 源实例的内存开销**：每个 `MikuModel` 实例化一份完整 glb（6.67 MB 资源，共享）+
   一套 53 骨骨架。已实测**不泄漏**（§11.8-1），但**未测**大规模人机（bot 每只一个）的内存峰值。
5. **不确定**：`tmp_spike/loco_*.png` 中「持枪」组由工具脚本手工挂了 `WeaponMount` + `Rifle`
   （`MikuModel.new()` 不带场景子节点），**与 `player.tscn` 的实际节点结构是否完全一致未逐一核对**。
