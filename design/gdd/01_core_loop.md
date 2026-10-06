# 01 · 核心循环与对局流程

> **Task ID**：D2-01 ｜ **作者**：文策渊（Vince Coyer）· 设计策略师 ｜ **状态**：draft（终局决策已全部回填 · 无待决项）
> **上游依赖**：`design/pillars.md`、`design/gdd/00_concept_mda.md`、`README.md`（§9 联机、§12 已知限制）、`scripts/network/network_manager.gd`、`scripts/main.gd`、`scripts/ui/hub.gd`、`scripts/ui/death_screen.gd`、`scripts/ui/hud.gd`
> **状态说明**：本项目**原本没有胜负设计**（README §12 原文：「场景里没有道具 / 靶子 / 队友，也没有胜负设计」）。本文是补齐这一最大空洞的核心文档。
> **✅ 用户已决**：MVP 模式 = **个人死斗（FFA）**；单局 = **5 分钟 / 15 杀**；重生 = **3 秒倒计时自动**（⚑L-4）；人机 = **不进正式对局**（⚑L-5）。（见 §4.2 / §8）

---

## 1. 三层循环总览

```
┌─────────────────────────── 宏循环（局与局之间，分钟级）───────────────────────────┐
│  大厅(Hub) → 建房/加入 → 开打 → 结算面板 → 再来一局 / 回大厅 → (循环)               │
│                                                                                  │
│   ┌──────────────────────── 中循环（一局对战，5 分钟）─────────────────────────┐  │
│   │  出生 → 接敌 → 交火 → 击杀或阵亡 → 重生 → 接敌 … → 达成胜利条件 → 结算       │  │
│   │                                                                          │  │
│   │      ┌──────────── 微循环（一次交火，3~8 秒）────────────┐                │  │
│   │      │  发现敌人 → 瞄准/开镜 → 压枪开火 → 命中/被命中     │                │  │
│   │      │  → 击杀确认 或 阵亡 → (回到中循环)                 │                │  │
│   │      └──────────────────────────────────────────────────┘                │  │
│   └──────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 微循环（Micro Loop · 一次交火，3~8 秒）

**动词序列**：`观察 → 定位 → 对准 → 开火 → 压枪/走位 → 确认`

| 阶段 | 玩家动作 | 系统反馈（现有代码） | 目标时长 |
| --- | --- | --- | --- |
| 观察 | 扫视准星周围、看小地图 | `minimap.gd` 敌方红点（`world_radius 60 m`）、`compass.gd` 指南针 | 0.5~2 s |
| 定位 | 转视角找敌人 | `camera_sway.gd` 惯性、`teammate_icons.gd` 队友贴边 | 0.3~1 s |
| 对准 | 选择开镜或腰射 | `weapon.gd::_update_aiming()`，FOV `75→55`(步枪)/`60`(手枪)，灵敏度 ×0.6 | 0.2~0.6 s |
| 开火 | 扣左键 | 枪口火光 / 曳光弹 / 3D 枪声 / `screen_shake` `add_trauma(0.28)` | 0.1 s |
| 压枪/走位 | 下拉镜头、蹲/趴降扩散 | 三层后坐力顶镜头；`move_spread 0.45` | 0.5~3 s |
| 确认 | 看到命中/击杀标记 | `crosshair.show_hitmarker()`、`hud.gd::push_kill()`（保留 `4.5 s`） | 0.2 s |

**微循环的设计红线**：单次交火理想时长 **3~8 秒**。经验值：步枪（`700 RPM` / `25 伤害`）在 100 血无护甲下需 **4 发命中**；手枪（`34 伤害`／`400 RPM` 半自动）需 **3 发**。这保证「一次交火 ≈ 一次有意义的技巧对决」，而不是「互相对射 30 秒谁也打不死」。

**关键数值进/退场时间**（可直接填入测试用例）：
- 步枪 TTK（理论，全命中）：`4 × (60/700) ≈ 0.34 s`。
- 手枪 TTK（理论，全命中）：`3 × (60/400) ≈ 0.45 s`。
- 蝴蝶刀 TTK：`65 伤害` → 两刀；`swing_time 0.22 + 0.08 = 0.30 s/刀` → **0.60 s**。
- 手雷：`fuse 1.6 s` + 6 m 内最高 `70 伤害`（不满血一雷不死，需补枪）。

---

## 3. 中循环（Meso Loop · 一局对战，5 分钟）

### 3.1 一局的节奏骨架

```
出生(0~2s) → 热身/接敌(30~60s) → 滚雪球/追分(60~240s) → 终局冲刺(剩余30s) → 结算
   低谷          爬升                持续张力              峰值               释放
```

### 3.2 心流曲线（张力 Tension over Time）

| 时间轴 | 张力 | 事件 | 设计手段 |
| --- | --- | --- | --- |
| t=0 出生 | 低 | 4 人分散出生 | 出生点分散在四角，避免开局即死 |
| t=0~20s | 中 | 首次接敌 | 视线长度 25~35 m（中距），给瞄准反应时间 |
| t=20s~60s | 高 | 前几轮交火 | 击杀数领先者制造追逐感 |
| t=60s~70% 时长 | **峰谷交替** | 交错击杀 / 被反杀 | 死亡后 3 秒倒计时重生，快速回到张力 |
| 最后 30s | **峰值** | 比分接近时的终局冲刺 | 比分板高亮 + 播报「领先/落后」 |
| 达成条件 | 释放 | 结算面板 | 比分板 + 击杀/死亡统计 + 「再来一局」 |

**防止张力塌陷的两个机制**：
1. **追分补偿（rubber-band）**：领先者无任何增益，落后者无惩罚——靠「先到 15 杀」的短目标让比分自然咬合（见 §4.1）。**不引入**「落后方加血 / 加伤害」这类会破坏竞技公平的机制。
2. **重生即时性**：`death_screen.gd` 的「重生」按钮 + `player.gd::respawn()` 已是「手动秒重生」。**MVP 采用「阵亡后 3 秒倒计时自动重生」**（⚑L-4 ✅ 已决（用户判）；见 §4.2），减少挂机、让节奏不断档；按钮保留可提前重生。

---

## 4. 胜负条件（✅ 已采纳：方案 A · 个人死斗 FFA）

> **这是本项目最大的设计空洞，已由用户拍板解决。** 用户已采纳 **方案 A（个人死斗 FFA）**；下方 B / C 保留为「备选 / 愿景层」，供后续扩展参考。

### ✅ 方案 A · 个人死斗（FFA Deathmatch）— 已采纳（用户决策 ⚑L-1）

| 项 | 规则 |
| --- | --- |
| 队伍 | 无队伍，4 人各自为战（**与现状完全一致**：`network_manager.gd` 无队伍概念，`main.gd` 按 peer 生成平级玩家） |
| 胜利条件 | **先达 15 次击杀** 或 **5 分钟到时击杀数最高者胜**（平局比较死亡数少者胜，仍平则并列入胜） |
| 重生 | 阵亡后 **3 秒倒计时自动重生**（⚑L-4 ✅ 已决（用户判）；`death_screen.gd` 的按钮保留可提前重生），回到距离敌人最远的出生点 |
| 计分 | 击杀 +1；自杀（手雷炸自己）不扣分（MVP 简化）；可加「击杀 - 被击杀」净值展示 |
| 可验证 | headless 可测：模拟 15 次击杀调用 → 断言 `ScoreManager` 触发 `match_won(player_id)` |

**为什么采纳**：改动最小（`network_manager.gd` 加 `score_changed` RPC + `hud.gd` 加比分板），复用 `SPAWNPOINTS`（4 个）、`push_kill` 击杀日志、`death_screen` 重生。**完美贴合「小游戏 + 4 人 + 即开即战」，且不引入队伍系统。**

### 备选 · 方案 B · 团队死斗（TDM 2v2）— 目标层待议

| 项 | 规则 |
| --- | --- |
| 队伍 | 分 2 队，每队 2 人（4 人满员时 2v2；不足 4 人时 1v1 或人机补位） |
| 胜利条件 | **先达 30 次团队击杀** 或 **8 分钟到时团队击杀数高者胜** |
| 额外需求 | 队伍分配 UI（Hub）、队伍颜色（`friendly` 组需再分敌我友）、友军免伤判定、阵营专属出生点 |
| 可验证 | 需新增 `team` 字段贯穿 player / bot / 伤害判定 |

**代价**：现状**完全没有队伍系统**——`player.gd` 把所有其他玩家放进 `friendly` 组当队友，`weapon.gd::_deal_damage()` 对 `friendly` 组发伤害。做 TDM 要引入队伍，属**中等工作量改动**（见 `99_consistency_review.md` 的 C-2）。**用户已明确 MVP 不引入队伍系统**，故降为目标层待议。

### 愿景 · 方案 C · 回合制占点（Objective Rounds）— 愿景层

| 项 | 规则 |
| --- | --- |
| 队伍 | 2 队，回合制 |
| 胜利条件 | 中央目标点 / 控制区，读条占领；先赢 5 回合的队伍胜（一局约 5 回合 × 45 秒） |
| 额外需求 | 目标点触发器（`Area3D`）、回合状态机、回合间不重生 / 冻结、服务器权威判定 |
| 可验证 | 需要新的 `GameMode` 节点与回合逻辑 |

**代价**：改动最大（新系统多），且与「5 分钟一局、死即重生」的 P2 支柱**张力最大**（回合制会拉长单局）。**建议放到愿景层**。

### 4.1 ✅ 采纳结论（用户已判）

> **MVP = 方案 A（个人死斗、15 杀 / 5 分钟）** ✅；目标层 = 方案 B（团队死斗）；愿景层 = 方案 C（回合制占点）。
> 理由：A 与现有代码现实的**接缝最小**，同时立刻补上「无胜负」这个致命空洞；B/C 都依赖尚不存在的「队伍系统」，应先由 A 验证核心循环再扩展。

### 4.2 决策状态

| 编号 | 决策点 | 状态 | 结论 / 推荐 |
| --- | --- | --- | --- |
| ⚑L-1 | MVP 模式 | ✅ 已决（用户判） | **方案 A · 个人死斗 FFA**（不引入队伍系统） |
| ⚑L-2 | 击杀目标数 | ✅ 已决（用户判） | **15 杀** |
| ⚑L-3 | 时长上限 | ✅ 已决（用户判） | **5 分钟** |
| ⚑L-4 | 重生方式 | ✅ 已决（用户判） | **3 秒倒计时自动重生**（减少挂机；`death_screen.gd` 按钮保留可提前） |

---

## 5. 完整对局流程状态机

```
                    ┌─────────────────────────────────────────────┐
                    │              [BOOT / 启动]                    │
                    │   project.godot 主场景 = scenes/hub/hub.tscn  │
                    └───────────────────────┬─────────────────────┘
                                            ↓
┌───────────────────────────────[LOBBY · 大厅 hub.tscn]───────────────────────────────┐
│  输入昵称（NameEdit）                                                                 │
│   ├─ [创建房间] → NetworkManager.host_game(7777) → HOST_ROOM                          │
│   ├─ [加入房间] → NetworkManager.join_game(ip,7777) → CONNECTING → CLIENT_ROOM        │
│   └─ [单人试玩] → change_scene(main.tscn) → LOCAL_MATCH                               │
└───────────────────────────────────────────────────────────────────────────────────────┘
        ↓ HOST_ROOM / CLIENT_ROOM（房间内，玩家列表 ≤ 4）
        │   房主：[开始对战] → NetworkManager.host_start_match()
        ↓
┌────────────────────────────[LOADING · 加载对局]────────────────────────────┐
│  广播 _start_match.rpc() → 所有端 change_scene_to_file(main.tscn)           │
│  main.gd::_sync_players() 按玩家列表创建玩家节点（节点名 = peer id）          │
│  ⚑ 新增：3-2-1 倒计时（冻结输入，避免有人先加载完先开枪）                     │
└────────────────────────────────────────┬───────────────────────────────────┘
        ↓
┌────────────────────────────[LIVE · 对局进行中]────────────────────────────┐
│  微循环 ×N + 中循环骨架                                                      │
│  ⚑ 新增 ScoreManager：击杀 +1 → score_changed.rpc() → HUD 比分板             │
│  ⚑ 新增 每帧检查胜利条件（击杀数 ≥ 15 或 剩余时间 ≤ 0）                      │
└────────────────────────────────────────┬───────────────────────────────────┘
        ↓ 达成胜利条件
┌────────────────────────────[MATCH_END · 结算]────────────────────────────┐
│  ⚑ 新增 结算面板：最终比分板（击杀/死亡/KD）+ 胜者高亮 + 本局时长            │
│  [再来一局] → 房主回 LOADING（复位比分/位置）                                │
│  [返回大厅] → NetworkManager.leave_game() 或 change_scene(hub.tscn)         │
└───────────────────────────────────────────────────────────────────────────┘
```

**边界情况处理**：
- **房主离开** → 现状即「解散房间，客户端自动回大厅」（`network_manager.gd::_on_server_disconnected`）——MVP 保留。
- **对局中迟到加入** → 现状「立刻看到所有人」（`main.gd::_sync_players` 幂等补齐）——MVP 保留；其击杀数从 0 起算。
- **人数不足 4** → 允许 1~4 人开打。人机补位仅用于**离线单人练习**（⚑L-5 ✅ 已决（用户判）：**人机不进正式对局**）——故正式局**不依赖**人机联机同步，现状「人机仅本端、不同步」不再是阻塞项。
- **全员死亡同时达成** → 以「达成条件的那一刻」先生效者胜（服务器 `is_server` 裁决）。
- **时间到 + 平分** → 死亡数少者胜；仍平 → 并列入胜（MVP 简化）。

### 5.1 加载倒计时 UI（对接 §4 规则 3 / `04_ux_flow.md §4` / EP-4 ES-4.4）

| 项 | 规格 |
| --- | --- |
| 触发 | `ScoreManager.match_state → COUNTDOWN`；**客户端由 `sync_match_state`（附录 A.4）获知** |
| 显示 | 屏幕**中央**大号数字「3 / 2 / 1」（覆盖层，不进 `game_ui` 互斥组）；数据源 = **本端信号 `countdown_updated(remaining)`（附录 A.5）**，由本地按帧递减平滑，`sync_match_state` 心跳校正 |
| 输入 | COUNTDOWN 全程 `set_input_blocked(true)`；→ `LIVE` 时 `false` 并 `capture_mouse()`（对齐 `04_ux_flow.md §4` 输入屏蔽矩阵「加载 / 3-2-1 倒计时」行） |
| 目的 | 避免「谁先加载完谁先开枪」（`04_ux_flow.md §4` 规则 3） |
| 离线 | 本端即权威，直接本地倒计时，无 RPC |
| 依赖 | **`sync_match_state` RPC（A.4）——同批实现** |

---

## 6. 与现有代码的接缝（工程可执行清单）

| 环节 | 需要改动的现有脚本 | 改动性质 | 复用 | 风险 |
| --- | --- | --- | --- | --- |
| 开局协调 | `network_manager.gd::host_start_match()` / `_start_match()` | 加 `match_state` 字段 + 倒计时广播 | 切场景逻辑已就绪 | 低 |
| 玩家创建 | `main.gd::_sync_players()` / `_make_player()` | 加 `score` 元数据初始化 | 幂等补齐逻辑已就绪 | 低 |
| 出生点 | `main.tscn` 的 `SpawnPoints`（现有 4 个 `Marker3D`） | 改为**四角分散**（每角 1~2 个），对齐 `03_map_encounter.md` | 现有 4 个可直接改坐标 | 低 |
| 比分与胜负 | **新增** `scripts/game/score_manager.gd`（或并入 `network_manager.gd`） | 新系统 | `push_kill` 已有击杀钩子 | 中（需 RPC 时序正确） |
| 比分板 UI | `hud.gd`（新增 `Scoreboard` 子节点） | 加 UI 元件 | 信号绑定框架已有 | 低 |
| 结算面板 | **新增** `scripts/ui/match_result.gd` + `scenes/ui/match_result.tscn` | 新界面 | 参考 `death_screen.tscn` 结构 | 低 |
| 重生 | `death_screen.gd::_on_respawn_pressed()` / `player.gd::respawn()` | 加 3 秒倒计时（⚑L-4 ✅ 已决） | 重生逻辑已完整 | 低 |
| 大厅选装 | `hub.gd` + `game_menu.tscn` | 把 Esc 菜单的「外观/皮肤/角色」前置到大堂（可选） | `game_menu.gd` 已有全部逻辑 | 低 |
| 受伤音效 | `player.gd::take_damage()` | 加 `hit_player` 占位音效 | `bot.gd::_setup_hit_audio()` 可复用合成方式 | 低 |
| 复活选点 | `player.gd::respawn()` | 改为「回到离敌人最远的出生点」 | `main.gd::_spawn_point_for()` 已有选点 | 低 |

> **待 engineering-lead 评估**：
> 1. 比分 RPC 的**权威归属**（建议房主 `peer_id=1` 为权威，客户端只上报「我击杀了我 X」意图）。
> 2. 对局中迟到加入者的**比分初始化**与「当局已进行时间」的对齐。
> 3. 是否需要 `GameMode` 抽象层以支持未来多模式（建议用枚举 + 策略，而非硬编码）。

---

## 7. 宏循环（Macro Loop · 局与局之间）

```
结算 → [再来一局]（复位状态，回 LOADING）→ 新一局
结算 → [返回大厅]（leave_game / change_scene）→ Hub → 换人/换装/换外观 → 再开
```

- **MVP**：宏循环 = 结算面板的「再来一局 / 返回大厅」两个按钮。
- **目标层**：加入**轻量进度**——累计胜场 / KD / 最长连胜展示（满足 Achiever），以及「本局最佳击杀」回放式提示。
- **反目标**：**不做**需要长期投入的赛季/通行证/数值成长（违背 P2「小游戏」定位）。

---

## 8. 决策状态汇总（本文档）

| 编号 | 决策点 | 状态 | 结论 / 推荐 | 影响面 |
| --- | --- | --- | --- | --- |
| ⚑L-1 | MVP 胜负模式 | ✅ 已决（用户判） | **A 个人死斗 FFA** | 决定后续所有结构性工作 |
| ⚑L-2 | 击杀目标数 | ✅ 已决（用户判） | **15** | 决定单局时长手感 |
| ⚑L-3 | 时长上限 | ✅ 已决（用户判） | **5 分钟** | 决定心流曲线长度 |
| ⚑L-4 | 重生方式 | ✅ 已决（用户判） | **3 秒倒计时自动** | 对局节奏与挂机行为 |
| ⚑L-5 | 人机是否进入正式对局 | ✅ 已决（用户判） | **否**（仅离线练习） | 已消除人机联机同步的工程依赖 |

---

# 附录 A · ScoreManager 数据契约

> **Task ID**：D2-02 ｜ **作者**：文策渊 · 设计策略师 ｜ **状态**：draft
> **配套**：`design/gdd/04_ux_flow.md`（UX 规格）、本文 §4/§5/§6（胜负条件 / 流程状态机 / 接缝）
> **说明**：本附录是 `04_ux_flow.md` §3.1（比分板）/ §3.2（结算面板）的数据层契约，供 engineering-lead 直接实现。

## A.1 定位与部署
- **系统名**：`ScoreManager`（**新增**）。
- **部署**：在 `scenes/main.tscn` 下挂一个 `ScoreManager` 节点（每局随场景创建/销毁 → **天然复位**）。**不用 Autoload**（Autoload 跨场景、需手动复位，且 Hub 不需要它）。
- **权威**：**房主 `peer_id == 1`（`is_server`）为唯一权威**；客户端只上报意图、接收同步。
- **离线**：`NetworkManager.is_online == false` 时本端即权威（用于「单人 vs 人机」练习结算）。

## A.2 状态机
```
IDLE ──(对局加载完成)──▶ COUNTDOWN(3s) ──▶ LIVE ──(胜利条件)──▶ ENDED
  ▲                                                             │
  └──────────────────── match_reset()（再来一局）────────────────┘
```
| 状态 | 行为 |
| --- | --- |
| `IDLE` | 场景就绪、等待玩家节点创建完成 |
| `COUNTDOWN` | **冻结输入**、显示 3-2-1；结束 → `LIVE`、启动计时器 |
| `LIVE` | `time_remaining` 递减；处理击杀上报；每帧检查胜利条件 |
| `ENDED` | 冻结计分；广播 `match_ended`；等待 `reset` 或回大厅 |

## A.3 字段
| 字段 | 类型 | 说明 | 默认 |
| --- | --- | --- | --- |
| `match_state` | enum | 见 A.2 | `IDLE` |
| `kill_target` | int | 击杀目标 | `15` |
| `match_duration` | float | 时长上限（秒） | `300.0` |
| `time_remaining` | float | 剩余秒 | `300.0` |
| `scores` | Dictionary | `peer_id → {kills:int, deaths:int}` | `{}` |
| `winner_id` | int | 胜者 peer id；`-1`=未定；`-2`=并列 | `-1` |

`scores` 结构示例：
```
{ 1: {"kills": 7, "deaths": 3}, 12345: {"kills": 5, "deaths": 6} }
```

## A.4 RPC 消息清单
| 消息 | 方向 | 模式 | 载荷 | 说明 |
| --- | --- | --- | --- | --- |
| `report_kill` | 客户端 → 房主 | `any_peer` / `reliable` | `victim_id: int` | 击杀者上报「我杀了他」；房主记录 +1（并给受害者 deaths+1，见 A.8） |
| `sync_scores` | 房主 → 全端 | `authority` / `reliable` | `scores: Dictionary, time_remaining: float` | 变更时 + 每 1 s 心跳 |
| `match_ended` | 房主 → 全端 | `authority` / `reliable` | `winner_id: int, final_scores: Dictionary` | 触发结算面板 |
| `match_reset` | 房主 → 全端 | `authority` / `reliable` | — | 「再来一局」复位 |
| `sync_match_state` ✅**已定稿（设计裁定）** | 房主 → 全端 | `authority` / `reliable` | `state: int, countdown_remaining: float` | **来源**：工程实现反馈（EP-3 / ES-3.3~3.4，commit `8b0e479`），设计侧于本轮回填裁定。**用途**：客户端精确跟随房主 `match_state`（含 `countdown_remaining`），用于 ① COUNTDOWN 期间显示 3-2-1；② 在 COUNTDOWN 期间冻结输入（`set_input_blocked(true)`）。**触发时机**：状态迁移时（`IDLE→COUNTDOWN`、`COUNTDOWN→LIVE`、`LIVE→ENDED`）+ COUNTDOWN 期间每 1 s 心跳（与 `sync_scores` 心跳同频）。**必要性**：本条是 `04_ux_flow.md §4 规则 3` / `EP-4 ES-4.4`「加载倒计时 + 冻结输入」的**唯一触发信息来源**——缺它则客户端无法得知 COUNTDOWN 何时开始，ES-4.4 不可实现。**权威**：房主状态机是唯一真源，客户端**不得**本地推断（见 A.9.1 已作废的临时近似解）。 |

## A.5 信号（供 HUD / UI 绑定）

> **信号是「本地通知总线」，不是「跨端传输」**——房主与客户端**都**在本端 emit，**本地消费**（HUD / 倒计时 UI）。跨端传输走 A.4 的 RPC；RPC 到达后再由 `_apply_*()` 在本端 emit 对应信号。两条通道**不混用**：UI **只绑信号**，**不直接绑 RPC**。

- `score_changed(scores: Dictionary, time_remaining: float)` —— **保持不变**
- `match_state_changed(state: int)` —— **保持不变**：回答「状态变了没」（稀疏事件，最多 4 次/局）。**不扩签名**。
- **`countdown_updated(remaining: float)`** ✅**已定稿**（新增）——`remaining` = COUNTDOWN 剩余秒数（3.0 → 0.0），供倒计时 UI（`04_ux_flow.md §3.4`）平滑取值。
  - **发出点**：`_drive_countdown()` 递减后 emit（权威端逐帧）；**客户端**在 `sync_match_state` 到达后于 `_apply_*()` 中 emit。离开 `COUNTDOWN`（进 `LIVE` / `ENDED` / `IDLE`）后**停止 emit**。
  - **载荷语义**与 A.4 `sync_match_state` 的 `countdown_remaining` **一致**（同为「剩余秒数」），避免两处口径相反。
- `match_ended(winner_id: int, final_scores: Dictionary)` —— **保持不变**

> **⚠ 信号形态的裁定记录（team-lead · 游承峰 · 2026-10-06）**
> 本项曾出现两种方案分歧：**(甲) 扩 `match_state_changed` 签名** vs **(乙) 新增独立 `countdown_updated`**。
> **最终裁定 = (乙)**，理由：
> 1. **不破坏既有契约**。A.5 明写「供 HUD 绑定」，签名是**对下游的承诺**；扩签名是破坏性变更（波及 EP-4 全部绑定面 + 既有测试迁移），新增独立信号则**纯增量、零外溢**。
> 2. **语义与频率分离**。状态迁移是**稀疏**事件（≤4 次/局），倒计时是**高频**事件（逐帧）。塞进同一条信号，会让「状态变了」被高频刷新污染——订阅者每次 tick 都收到一次「状态变化」，与字面语义冲突，且调用方只能靠比对 `state` 值去区分「真迁移」与「倒计时 tick」，等于把语义推给调用方猜。
> 3. 方案 (甲) 的合理内核（**UI 必须能平滑取值、不能只靠 1 s 心跳的 RPC**）**已被 (乙) 完整满足**——(乙) 同样让 UI 绑本端高频信号。
> **本段由 team-lead 裁定并落盘；design-strategist 所提「信号是本地通知总线、UI 只绑信号不绑 RPC」的洞察已保留为上节引言。**

## A.6 结算触发与判定
- `LIVE` 每帧检查：`max(kills) >= kill_target` **或** `time_remaining <= 0` → 房主 `_end_match()`。
- **胜者**：`kills` 最高者；平局 → `deaths` 少者；仍平 → `winner_id = -2`（并列，UI 显示「平局」）。
- 结算终态：`winner_id` 固化、`scores` 冻结。

## A.7 击杀归因路径（接缝关键）
- 击杀发生在本端：`weapon.gd::_deal_damage()` / `knife.gd::_slash()` **已在致命时算出 `killed: bool`**。
- 该处的 `collider` 即被击中的玩家节点，**节点名 = peer id**（`main.gd::_make_player()` 设 `player.name = str(id)`）→ 由此解出 `victim_id`。
- 击杀者本端（武器 `is_multiplayer_authority`）→ 调 `ScoreManager.report_kill.rpc_id(1, victim_id)`。
- 离线 / bot：`killed && collider.is_in_group("bot")` → **本地直接 +1**（不进联机 RPC，对齐现有 `weapon.gd` 对 bot 的本地结算）。
- ⚠ **现状缺口**：`hit_confirmed` 目前只给「名字」不给 id；需在 `_deal_damage` 里额外解析 `collider.name`（**属工程改动**）。

## A.8 死亡计分
- **推荐**：房主收到 `report_kill(victim_id)` 时**同时给 `victim_id` 的 `deaths +1`**——**一条消息同时记击杀与死亡**，避免额外的死亡上报 RPC。
- 备选：被击中者本端在 `player.died` 时上报 `report_death`（多一条 RPC，不推荐）。

## A.9 边界情况
| 情况 | 处理 |
| --- | --- |
| 对局中迟到加入 | `scores` 初始化 `{kills:0, deaths:0}`；`time_remaining` 用房主当前值同步 |
| 中途离开 | 房主移除其条目（MVP 简化）；「保留并标『已离开』」列为**后续备选实现**（非阻塞） |
| 自杀（手雷炸自己） | **不记击杀、不扣分**（MVP 简化，对齐 §4 方案 A）；是否计入 `deaths` 仅影响 tie-break，不影响胜负 |
| 同一帧多人达成 | 房主以「先到达该帧者」为准 |
| 人机击杀 | **离线计分；联机局不计入**（对齐 `04_ux_flow.md` ⚑F-2 / `01_core_loop.md` ⚑L-5） |
| 时间到 + 平分 | `deaths` 少者胜；仍平 → `winner_id = -2`（平局） |

### A.9.1 客户端状态跟随规则 ✅**已定稿（设计裁定 · 方向 A）**
> **来源**：EP-3 / ES-3.3~3.4 工程实现（commit `8b0e479`）；**设计侧裁定**：认可并定稿 `sync_match_state`（A.4），本近似解**作废**。

**裁定**：客户端**唯一**通过 A.4 的 `sync_match_state` 得知 `match_state` 迁移；**禁止**用「收 `sync_scores` 推断 LIVE」近似（该近似无法得知 COUNTDOWN，会导致倒计时不显示 + 输入不冻结）。

| 客户端收到 | `match_state` | 精度 |
| --- | --- | --- |
| 本地初始（尚未收到任何 `sync_match_state`） | `IDLE` | 本地默认；收到首条 `sync_match_state` 即以房主为准 |
| `sync_match_state(state=S_COUNTDOWN, countdown_remaining=r)` | `COUNTDOWN` | **精确**（房主真源）；据此显示 3-2-1 + `set_input_blocked(true)` |
| `sync_match_state(state=S_LIVE, …)` | `LIVE` | 精确；解冻输入、启动本地计时显示（以 `sync_scores.time_remaining` 校准） |
| `match_ended` | `ENDED` | 精确（保留） |
| `match_reset` | `IDLE` | 精确（保留） |

- **RPC 容错**：`sync_match_state` 丢失由**每 1 s 心跳**兜底（见 A.4）；客户端在 `IDLE` 下若收到 `sync_scores`（说明已进 `LIVE`）→ **不推断状态、但记录分数**，并等待下一条 `sync_match_state` 校正（心跳 ≤1 s）。
- **离线**：`is_online == false` 时本端即权威，直接驱动本地状态机，无需 RPC。
- → 本规则是 `EP-4 ES-4.4` 的**直接前置**；`sync_match_state` 与 ES-4.4 **同批实现**。

## A.10 与现有脚本的接缝
| 脚本 | 改动 | 复用 |
| --- | --- | --- |
| `network_manager.gd` | 复用 `is_server` / `get_players()`；比赛生命周期可挂 `match_started` | ✅ 已有 |
| `main.gd` | 场景内实例化 `ScoreManager`；把玩家列表喂给它 | ✅ `_sync_players()` |
| `weapon.gd` / `knife.gd` | `_deal_damage()` / `_slash()` 解析 `victim_id` 并上报 | 复用现有 `killed` 判定 |
| `player.gd` | 若采用 A.8 备选，`died` 时通知 ScoreManager | ✅ `died` 信号 |
| `hud.gd` | 新增 `Scoreboard` 绑定 `score_changed`（见 `04_ux_flow.md` §3.1） | ✅ 信号框架 |
| `match_result.gd` | 新界面，监听 `match_ended`（见 `04_ux_flow.md` §3.2） | 参照 `death_screen` |

## A.11 待 engineering-lead 评估
1. **RPC 权威与作弊面**：客户端上报击杀，房主是否需二次校验（例如房主本地也观察到该击杀）。局域网熟人局 MVP 可接受「信任客户端」，但**记风险**。
2. **时序**：`report_kill` 与现有 `net_fire_effects` / `apply_network_damage` 在同一帧的调用顺序。
3. 是否用 `call_local` 让房主自己的击杀也走同一路径（保持幂等）。
