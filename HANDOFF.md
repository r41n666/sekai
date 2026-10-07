# 交接说明（HANDOFF）

> 最后更新：**2026-10-07 20:30**
> 本文覆盖「项目现状」+「**如何在新电脑用 WorkBuddy 接手**」。
> 接手前**必读第 2 节（环境）**与**第 4 节（8 个坑）**——踩坑比看代码贵。

---

## 1. 项目现状

**sekai** —— Godot 4.7.2 的第三人称射击原型（TPS）。阶段目标：**「能打完一局」**的可玩闭环。

### 1.1 技术栈与关键约定

| 项 | 值 |
|---|---|
| 引擎 | **Godot 4.7.2-stable（official.ed1daf0bf）**，版本必须精确，见 §2 |
| 语言 | GDScript，`preload` 引用优先于全局 `class_name`（§4-6） |
| 物理 | Jolt（ADR-001） |
| 联机 | **无服务端权威**（ADR-006），权威在房主客户端 |
| 渲染驱动 | **锁定 Vulkan**（本机 AMD RX 6750 GRE 上 D3D12 后端必崩，见 §4-1） |
| 主场景 | `res://scenes/hub/hub.tscn` |
| 自检命令 | `bash tools/verify.sh` |
| 架构文档 | `docs/architecture/`（**9 条 ADR** + `control_checklist.md`） |
| 美术 / GDD | `design/art/`、`design/gdd/` |

### 1.2 仓库拓扑（⚠️ 换机器前必须理解）

本工作区是 **git worktree**，不是独立仓库：

```
D:/sekai/.git                                ← 真实仓库（275 MB，非 bare）
C:/.../Worktrees/sekai/master-230e4f32       ← 你在这里（工作区 403 MB）
    └─ .git 文件内容：gitdir: D:/sekai/.git/worktrees/master-230e4f32
```

- 当前分支：**`workbuddy/master-230e4f32`**
- **领先 `master` 67 个提交，且该分支【尚未推送到 origin】**
  （origin 上只有 `master`、`trae/*`、`branch-*` 等，没有本分支）

### 1.3 2026-10-07 这一轮做了什么

| 领域 | 内容 |
|---|---|
| **资源精简** | 删 9 个模型 + 死资源，**释放 206 MB**（`assets` 269 MB → 63 MB） |
| **枪械 bug** | USP「没有枪管」= 代码把**消音器**当「浮空小圈」裁掉了（`trim` 误裁） |
| **持枪姿势** | 双手 IK 持枪（`weapon_hold_ik.gd`）+ **手指抓握**（`hand_grip.gd`） |
| **受击音效** | 改用 `sfx/hit_female/` 素材池（27 个 wav，**每次受击随机取一条**），玩家+敌人共用 |
| **动画库** | 接入 **Quaternius UAL**（CC0，120+ 动画）：**只补 locomotion，排除一切大幅度动作** |
| **🔴 关键修复** | **T-pose + 轻微抽搐** —— 根因是模型自带的 0.083 s T-pose 定格剪辑被设成循环，每秒重写全身骨骼 12 次 |
| **蹲姿** | 新增（用 UAL 的 `Crouch_Fwd`） |
| **配置** | 变体选择 UI 已删除（每槽只剩 1 个外观）；Vulkan 锁**被编辑器删掉 9 次**（已加测试守护） |

### 1.4 角色动作系统的分层（接手后最容易搞混的部分）

```
Quaternius UAL locomotion   →  腿 + 躯干 + 【空手时的】手臂      （默认开启）
        ↓ 持枪时让出手臂
WeaponHoldIK (TwoBoneIK3D)  →  双臂（武器坐标系由「右手握把 + 左手护木」两点推导）
        ↓
HandGripModifier            →  15 根手指骨（每手 5 指 × 3 节）
```

三个开关（`miku_model.gd`）：

| 开关 | 默认 | 作用 |
|---|---|---|
| `ual_locomotion_enabled` | **true** | UAL 接管腿 + 躯干 |
| `hold_ik_enabled` | false | 双手 IK 持枪 |
| `hand_grip_enabled` | false | 手指抓握 |

⚠️ **必须同时开 `ual_locomotion_enabled` + `hold_ik_enabled`** 才看得到完整持枪效果。

⚠️ `ual_sprint_threshold = 1.1` 是**故意设的**：`speed_ratio` 值域恒为 `[0,1]`，
阈值 1.1 ⇒ **冲刺档永远够不到 `Sprint` 剪辑**（避免双马尾被甩成板子）。**别"顺手修正"成 1.0。**

---

## 2. 环境要求

| 项 | 要求 | 备注 |
|---|---|---|
| **Godot** | **4.7.2-stable 官方版**（`4.7.2.stable.official.ed1daf0bf`） | ⚠️ **不要用 4.6 或 4.7.1/4.7.3**：IK 族（`TwoBoneIK3D` 等）是 4.6 才补齐的，版本错了会一片红 |
| 控制台版 | 需要 `*_console.exe`（Windows） | 无窗口自检靠它 |
| Shell | **Git Bash**（脚本是 bash） | PowerShell 不回显 stdout，调脚本很别扭 |
| 分辨率 | 1920×1080 | 截图工具按包围盒自动取景，改分辨率不影响 |
| 硬件 | — | ⚠️ **Vulkan 锁是针对 AMD RX 6750 GRE 实测的**。换显卡（尤其 NVIDIA）后请**实测** D3D12 是否还崩；不崩就可以去掉锁 |

---

## 3. 在另一台电脑上接手

### 3.0 先决条件

- 本分支**没推到 origin**（§1.2）⇒ **先在旧机器上把代码弄出来**，否则新机器拿不到。
- 旧机器的 Godot 路径是 `C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe`，
  **新机器路径肯定不同** ⇒ 下面命令里的 `GODOT` 换成新机器的实际路径。

### 3.1 方式 A：推到 GitHub（推荐，最干净）

**旧机器**（**你操作**，AI 不代劳 push）：

```bash
cd <工作区>
git push -u origin workbuddy/master-230e4f32
```

**新机器**：

```bash
git clone https://github.com/r41n666/sekai.git
cd sekai
git fetch origin
git checkout workbuddy/master-230e4f32
```

本项目**没用 Git LFS**，直接 clone 即可。

### 3.2 方式 B：离线迁移（无网络 / 不想推 GitHub）

**旧机器**导出单文件（**含全部 67 个提交**）：

```bash
cd <工作区>
git bundle create sekai-handoff.bundle --all    # 连 master 基线一起带走
```

把 `sekai-handoff.bundle` 拷到新机器：

```bash
git clone sekai-handoff.bundle sekai
cd sekai
git checkout workbuddy/master-230e4f32
```

### 3.3 ⚠️ 两种方式都**不会**带走的东西（必须手动补）

| 东西 | 位置 | 会不会丢 |
|---|---|---|
| **WorkBuddy 项目记忆** | `<工作区>/.workbuddy/memory/*.md` | ✅ **在 git 里，跟着代码走**（已提交） |
| **WorkBuddy 用户级记忆** | `C:/Users/Administrator/.workbuddy/user-*/MEMORY.md` | ❌ 在 git 外 |
| **Skill `godot-4x-pitfalls`** | `C:/Users/Administrator/.workbuddy/skills/godot-4x-pitfalls/` | ❌ 在 git 外 |
| Godot 导入缓存 | `.godot/`（gitignored） | 需在新机器重新生成（`verify.sh` 会做） |
| 未跟踪素材 | — | ✅ `sfx/hit_female/*.wav` 本轮**已入库** |

**推荐做法**：把后两项打包带走：

```bash
# 旧机器
cd C:/Users/Administrator/.workbuddy
tar czf ~/workbuddy-personal.tar.gz skills/godot-4x-pitfalls user-*/

# 新机器：解包到 ~/.workbuddy/ 下
# ⚠️ 新机器的 user-<uuid> 目录名会不同 ⇒ 把 MEMORY.md 的内容【合并】进新机器的 MEMORY.md
```

### 3.4 新机器首次验证（按顺序做完再改代码）

```bash
# ① 找到 Godot 并设变量（Git Bash）
export GODOT="/c/Users/<你>/Desktop/Godot_v4.7.2-stable_win64_console.exe"

# ② 一键自检（必要时做一次 --import，然后强制断言 Vulkan 锁还在）
bash tools/verify.sh
#    期望：VERIFY PASS，416 用例 / 6158 断言 / 0 失败

# ③ 项目体检（建议跑一次）
python ~/.workbuddy/skills/godot-4x-pitfalls/scripts/audit_godot_project.py --project .
#    期望：P0 0
```

⚠️ **第 ③ 步若报 `project-godot-modified`（P0）**：说明 `project.godot` 相对 HEAD 有改动。
先 `git diff project.godot` 逐行看清，**多半是 Vulkan 锁被删了**，还原：

```bash
git show HEAD:project.godot > project.godot
grep -c 'rendering_device/driver.windows="vulkan"' project.godot   # 必须是 1
```

⚠️ **换显卡后必做**：实测一次 D3D12 是否还崩。崩 ⇒ 保留锁；不崩 ⇒ 可去掉锁
（并同步改 `tests/suites/test_render_driver.gd` 的断言与 §4-1 的说明）。

### 3.5 让 WorkBuddy 认得这个项目

新机器上开 WorkBuddy 后，**先让它读这两个文件**（项目记忆会自动加载）：

1. `<工作区>/HANDOFF.md`（本文）
2. `<工作区>/docs/architecture/control_checklist.md`（项目铁律与踩坑史）

然后直接说需求即可。若 skill `godot-4x-pitfalls` 已带过去，
让它「**先跑体检脚本再干活**」（§3.4 ③）。

---

## 4. 必须知道的 8 个坑（都实际踩过）

### 4-1 🔴 Vulkan 锁会被 Godot 编辑器删掉（已复发 9 次）
`project.godot` 里的 `rendering_device/driver.windows="vulkan"` 是**保命配置**：
本机 AMD 显卡上 D3D12 后端初始化纹理必失败（`CreateResource failed with error 0x80070057`），
随后引擎拿空 RID 继续走 → **进程崩**。

- **只要开过 Godot 编辑器就要复核**：`grep -c 'rendering_device/driver.windows="vulkan"' project.godot`
- 还原：`git show HEAD:project.godot > project.godot`（**不要用 `git checkout --`，见 4-2**）
- 守护：`tests/suites/test_render_driver.gd` 有断言守着，被删即测试转红
- ⚠️ **会诱导破坏它的过时说明**：若你在旧文档里看到「如遇兼容问题，删掉那一行」——**那是错的**

### 4-2 🔴 `git checkout --` / `git restore` 会「假成功」
退出码 0、无警告，但**内容根本没还原**。本项目已因此丢过一次 C-19 修复。

**永远用**：

```bash
git show HEAD:<path> > <path>          # 从仓库对象直接写
git diff --numstat <path>              # 复核：应为空
grep -c '<关键配置>' <path>            # 复核：应命中
```

### 4-3 🔴 源码副本目录必须放 `.gdignore`
项目里 `.mutation_backup*/`、`tmp_spike/` 等目录存着**源码副本**。
一旦有人开编辑器，Godot 会把它们扫进 `.godot/global_script_class_cache.cfg`
⇒ 同名 `class_name` 撞车 ⇒ `Class "X" hides a global script class`
⇒ 脚本加载失败 ⇒ 节点不挂脚本 ⇒ `@onready` 拿到裸节点 ⇒ **一片测试转红**。

**⚠️ 但资源目录绝对不能放**（会让 Godot 完全跳过导入、`load()` 必然失败）。两条规则**性质相反**：

| 目录类型 | `.gdignore` |
|---|---|
| 存源码副本（备份 / 临时 / 抓取产物） | ✅ **必须加** |
| 存要被 Godot 加载的资源 | ⛔ **绝对不能加** |

### 4-4 🔴 测试断言可能「锁住了 bug 本身」
本项目有 3 条断言曾把「cat 是 T-pose 不动」写成**期望行为**（它断言的是
「模型有 idle 剪辑 ⇒ 不建程序化姿态」，而那个 idle 正是 T-pose 定格）。

⇒ **测试全绿 ≠ 行为正确。** 发现这类「基线即错」要**反转断言方向 + 改名写明原因**，
否则后人会当成漂移改回去。

### 4-5 「截图好看」≠「实机正确」
UAL 集成时截图里步态完全正常，但**实机是 T-pose**——截图工具绕过了出问题的分支
（它验证的是「UAL 开启」路径，而默认配置走另一条）。

⇒ 关键行为必须有**走真实代码路径的端到端断言**：模拟「加载 → 状态机判定 → 连续 N 帧 update」，
量骨骼/位移**是否真的随时间变化**。本项目现有
`tests/suites/test_degenerate_clip.gd::test_legs_actually_move_over_many_frames_after_tpose_fix`
是范例（真跑 60 帧量双脚高度差 + 反向断言排除「乱抖」而非「迈步」）。

### 4-6 优先 `preload`，别依赖全局 `class_name`
未开编辑器时全局类缓存可能未注册 ⇒ headless 找不到类型。
`const X = preload("res://.../x.gd")` 是本项目通行做法。

### 4-7 IK 在 headless 下**不可见**
`skeleton_updated` 在 headless（dummy 渲染）下**不触发** ⇒
**IK 效果无法 headless 验证**，必须开渲染窗口截图。
（对比：`set_bone_global_pose_override` 的结果在 headless 下**可读** ⇒ 程序化姿态能 headless 断言。）

⚠️ 推论：**headless 全绿不代表 IK / 视觉正确**。涉及 IK 的改动**必须开窗口截图**。

### 4-8 几何裁剪（trim）会静默吃掉真实几何
修 USP 时，`"trim": [null,null,[null,11.0]]` 把**消音器**当成「浮空小圈」裁掉了。
被裁段尺寸 8.6×1.7×1.7 单位、位于枪身上部——**从包围盒数字上完全看不出问题**。

⇒ 用 trim 前**必须渲染对照图**。数字不能判定「这是装饰还是零件」。

---

## 5. 常用命令

```bash
export GODOT="/c/Users/<你>/Desktop/Godot_v4.7.2-stable_win64_console.exe"

# 一键自检（导入 + 语法校验 + 全量测试）
bash tools/verify.sh

# 只跑测试
"$GODOT" --headless --path . tests/test_runner.tscn

# 窗口实跑（主场景）
"$GODOT" --path . --rendering-driver vulkan

# 截图（目视验证；工具都自动取景）
"$GODOT" --path . --rendering-driver vulkan --resolution 900x760 res://tools/capture_layered_walk.tscn
#   常用：capture_layered_walk（走路+持枪）/ capture_hand_grip（手指抓握）
#        capture_tpose_verify（T-pose 修复验证）/ capture_crouch（蹲姿）

# 武器外观标定（打印每个变体的武器空间包围盒 + Muzzle 位置）
"$GODOT" --headless --path . res://tools/weapon_variant_check.tscn

# 项目体检（需先装 skill godot-4x-pitfalls）
python ~/.workbuddy/skills/godot-4x-pitfalls/scripts/audit_godot_project.py --project .
```

⚠️ **本项目不要随手用 `--import`**（会走编辑器代码路径 ⇒ 删 Vulkan 锁）。
`tools/verify.sh` 已把它降级为「仅首次执行」+「执行后强制断言锁还在」。

---

## 6. 尚未解决 / 待办

| 项 | 状态 |
|---|---|
| **趴下（Z 键）无动画** | 纯位移实现；蹲姿有动画了，趴姿没有 |
| **`Crouch_Fwd` 蹲姿行走可能偏慢** | 它为更快速度设计，而玩家蹲行上限 1.8 m/s ⇒ 需实机调播放速度倍率 |
| **双马尾在大动作下穿帮** | UAL 骨架无 `ponytail` 骨 ⇒ 只能靠额外写物理/程序化摆动。**已用「排除大幅度动作」规避** |
| **联机未做实机验证** | 断言过「姿态不走 RPC」，但没真跑过联机 |
| **手臂切层** | 已用 influence 渐变（0.18 s）消除跳变，但只有截图证据，没有实机长时间验证 |
| **`miku.glb`（默认模型）仍是乱码 554 骨骼** | 只能用几何启发式猜骨骼；UAL / IK 对它不生效，靠程序化姿态兜底 |

---

## 7. 历史（已完成，不要重做）

- ✅ 9 条 ADR（架构决策）—— `docs/architecture/adr/`
- ✅ 双手 IK 持枪 + 手指抓握（§1.4）
- ✅ Quaternius UAL 动画接入 + 重定向（评估报告：`docs/architecture/ual_retarget_evaluation.md`）
- ✅ USP 消音器修复
- ✅ 资源精简 206 MB
- ✅ 受击音效素材池（27 wav 随机）
- ✅ T-pose / 抽搐根因修复
- ✅ 蹲姿动画
- ✅ 9 次 Vulkan 锁复活 + 测试守护

**别重做的原因**：每一条都对应一个「看起来简单、实际踩过坑」的修复，
坑已写进 §4 与项目记忆。**先读，再动手。**
