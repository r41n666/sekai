# EP-4 · HUD / UX：比分板 / 结算面板 / 重生倒计时

> **Phase 4 ｜ 优先级 P1 ｜ 负责人**：程基岩（engineering-lead）
> **上游**：`design/gdd/04_ux_flow.md §3/§4/§6`、`design/art/accessibility.md`（Standard 基准线）、`99_consistency_review.md` C-13
> **目标**：把 EP-3 的计分数据变成**玩家可见的 UI**（比分板 / 结算 / 重生倒计时），并把可访问性第二线索落到 HUD。
> **出口判据**：结算面板显示完整比分 + 再开/回大厅；重生 3 s 自动；`AC-F1/F3/F4/F5` 的视觉回归可截图判定。

---

## ES-4.1 · HUD 比分板 Scoreboard（常驻紧凑条）· S · ✅ 已实现

- **目标**：HUD 顶部中央常驻紧凑条 `[目标] 先到 15 杀　剩余 03:24` + 4 个玩家条目，绑 `ScoreManager.score_changed`。
- **验收标准**（`04_ux §3.1`）：
  - 按击杀降序；领先者**加亮（亮度 + 加粗，不只换色）**；本人条目加 `▶`；
  - 临界：某玩家到 14 杀 → 该条目闪烁 + 「还差 1 杀」；剩余 ≤30 s → 计时器变亮 + 「终局冲刺」；
  - 数字字号 ≥ 16、用**明度对比**而非仅颜色（`§6` Standard）。
- **依赖**：EP-3 ES-3.4（`score_changed` 信号）。
- **涉及文件**：`scripts/ui/scoreboard.gd`（新增）+ `scenes/ui/scoreboard.tscn`（新增）、
  `scripts/ui/hud.gd`（`$Scoreboard` 接线 + `_unhandled_input` 处理 Tab）、
  `scenes/ui/hud.tscn`（实例化 `Scoreboard`）、`project.godot`（新增 `scoreboard` 输入动作 = Tab / `4194306`）。
- **实现要点**（与 `ScoreManager` 同一取舍）：
  - **纯逻辑 / 渲染分离**：`build_rows` / `display_name_for` / `format_clock` / `kd_text` /
    `is_near_target` / `compact_row_text` / `full_row_text` 全为**静态纯函数**，headless 可直接断言；
    节点树只负责把输出贴到 Label。→ 排序口径、KD 零分母、倒计时格式都能被单测钉死。
  - **排序与胜负同口径**：击杀降序 → 死亡升序 → peer_id 升序。末位`peer_id` 是为了
    **各端排出完全相同的顺序**（否则榜会在两端抖动）。
  - **领先者标记取「击杀数并列最高」的全部行**，而非只标排序后第 0 行；
    且**开局 0:0 时无人领先**（全高亮等于没高亮）。
  - **不自行判定胜负**：胜负唯一口径是 `ScoreManager._evaluate_winner()`，
    本文件只读 `scores`（配`test_does_not_reimplement_winner_evaluation` 纪律锁）。
  - **Tab 完整榜为非模态覆盖层**：不进 `game_ui` 组，可边看边打；
    但被其它 `game_ui` 界面（死亡界面 / 结算面板）打开时屏蔽（`_blocked_by_other_ui`）。
- **测试证据**：`test_scoreboard.gd` **20 用例** —— 排序口径 / 跨端顺序稳定 / 并列领先 /
  0:0 无领先 / KD 零分母 / 倒计时格式与负数夹取 / 临界边界 / 标记与文案非空 /
  接线契约锁 / 输入动作注册 / 场景节点路径 / 字号下限 / 禁止自行判定胜负。
  窗口实测（Vulkan，300 帧）确认：`▶ 玩家1  0`、`1　玩家1　0　0　—`、Tab 切换正常、0 脚本错误。

## ES-4.2 · 结算面板 `match_result`（终态）· M · ✅ 已实现

- **目标**：新增全屏结算面板：标题「对局结束」→ 胜者行 → 完整比分表（排名/名字/击杀/死亡/KD）→ 本局时长 → `[再来一局]`（仅房主）｜`[返回大厅]`。
- **验收标准**（`04_ux §3.2`）：
  - 由 `match_ended(winner_id, final_scores)` 触发；加入 `game_ui` 组、打开时关其它界面（互斥）；
  - **不暂停**游戏（覆盖层，`04_ux §1` 现状约束）；客户端 `[再来一局]` 显示「等待房主…」。
- **依赖**：EP-3 ES-3.4。
- **涉及文件**：**新增** `scripts/ui/match_result.gd` + `scenes/ui/match_result.tscn`；参照 `scenes/ui/death_screen.tscn`；`scripts/ui/game_menu.gd`（`game_ui` 组互斥）。
- **测试证据**：契约锁——断言新面板 `add_to_group(UI_GROUP)` 且实现 `open_ui/close_ui`。

### 实现要点（工程侧补记）

- **纯逻辑 / 渲染分离**（沿用 ES-4.1 取舍）：「数据 → 显示什么」的推导全部抽成**静态纯函数**
  ——`title_for` / `winner_text` / `format_duration` / `elapsed_seconds` / `build_standings` /
  `row_text` / `button_caption` / `can_request_reset`，headless 可直接断言、零副作用；
  节点树只负责把输出贴到 Label。
- **排序与文案口径一律复用 `Scoreboard`，不另写一套**：`build_standings` → `Scoreboard.build_rows`、
  `row_text` → `Scoreboard.full_row_text`、`winner_text` → `Scoreboard.display_name_for`、
  `format_duration` → `Scoreboard.format_clock`。理由：结算面板与比分板若各排一次，
  会出现「比分板显示 A 第一、结算面板显示 B 第一」的自相矛盾（本项目已登记过的风险）。
- **时长**：`elapsed_seconds = match_duration - time_remaining`（**不是**直接用上限——
  赢在 15 杀时提前结束，直接显示上限会谎报时长）；格式**不显示小时**：
  §3.2 只写「本局时长」未要求 `HH:MM:SS`，而单局上限 300 s→ 小时位永不可达（死代码），
  且与 ES-4.1 剩余计时同为 `MM:SS` 可免掉同屏两套单位。边界 `3600s → "60:00"` 已钉进测试。
- **⚠ 「不暂停」≠「不屏蔽输入」（两者独立，已分别加锁）**：
  - **不暂停**：`get_tree().paused` 全程不动。理由：面板是覆盖层（§1 现状约束），
    且 `ScoreManager` 靠 `_process` 驱动倒计时/计时，暂停树会让它停摆。
  - **要屏蔽输入**：面板属于「打开即屏蔽输入」类别 —— ① 鼠标必须**可见**才能点按钮，
    而释放鼠标的唯一入口就是 `player.set_input_blocked(true)`；② 对局已 ENDED、
    武器触发器应随之关闭（§4-1「双闸门」，不要只调 `release_mouse` 一半）。
    `close_ui()` 对称恢复 `set_input_blocked(false)` + `capture_mouse()`，与 `game_menu` 同口径。
- **客户端按钮**：`button_caption(false) == "等待房主…"` 且 `disabled = true`。
  文案与可点性由 `can_request_reset()` **同源**派生，避免「写着等待房主却能点」的矛盾态
  （客户端点了也什么都不会发生 —— `request_reset()` 开头就是 `if not is_authority(): return`）。
- **不碰 RPC**（架构铁律）：只连`ScoreManager.match_ended` 本地信号；
  复位只调既有 `ScoreManager.request_reset()`，不自造 `net_match_reset`。
- **胜负不由 UI 判定**：本面板只**消费** `match_ended` 传来的 `winner_id`，
  代码中不存在任何`kills`/`deaths` 的比较运算（语义级纪律锁，见下）。

### 测试证据

- `tests/suites/test_match_result.gd` **36 用例 / 148 断言**（已登记进 `test_runner.gd::SUITE_SCRIPTS`，§4-9）——
  胜者行四态（本人 / 他人 / 平局 / 未定，且平局**不得**出现玩家名）/ 时长边界 0·59·60·3599·3600 /
  时长格式与比分板一致 / **排序逐行序列与 `Scoreboard.build_rows` 完全相等（QA AC-A4，
  5 组数据 × 2 视角，含并列/同分/0:0/单人）** / KD 零分母 / **面板打开时 `paused` 仍为 false** /
  `game_ui` 组与`open_ui·close_ui·is_open` 契约 / **互斥实测**（打开时关闭同组其它界面）/
  **Tab 完整榜在结算面板打开时不响应（QA B2/AC-B7 阻塞项，用真实 `scoreboard.tscn` 端到端实测）** /
  客户端文案与 `disabled` / 纪律锁（不得重算胜负、不得发 RPC、复位只走 `request_reset`）/
  接线契约锁 / 字号下限 / 领先者加粗双通道。
- **与 QA 审计对齐**（`production/qa/ES-4.1-audit-and-ES-4.2-acceptance.md`）：
  Q1「`paused` 恒 false + `set_input_blocked(true)`」与 Q2「复用 `ScoreManager.is_authority()`、
  UI 层做纯函数 `can_request_reset()`」两条**均已按此实现**；B2 阻塞项已补自动化守护。
  遗留：AC-B2（emoji 在所选字体下是否 tofu）、AC-B4（`返回大厅` 两条路径实机）、
  AC-B8（双端联机）等B 栏项目**仍需窗口/双端手动实测**，未纳入自动化。
- **变异测试 7/7 全杀**（`tools/mutation_es42.py`）：M1 面板暂停 / M2 客户端谎报可点 /
  M3 面板自行按 kills 重算胜负 / M4 caption 对但 disabled 放行 / M5 平局显示玩家名 /
  M6 不关同组界面 / M7 时长改自带小时格式 —— **0 存活**。
  M3 首轮曾**存活**，原因是纪律锁只搜`"kills >"` 单条字面量，被`get("kills", 0) > 0`
  换了写法绕过 → 已改为「代码中不得出现 `kills`/`deaths` 的任意比较运算」语义级锁。
- **窗口实测（Vulkan · RX 6750 GRE ·非 headless）**：面板文本逐行确认为
  `对局结束` / `🏆 你 获胜` / `本局时长 03:24` / 表 `1　玩家1　15　3　5.0`、`2　玩家2　9　7　1.3`、
  `3　玩家3　4　11　0.4`，`[再来一局]` 房主可点、`[返回大厅]` 正常，**13/13 断言通过、渲染 0 错误**；
  另跑 `res://scenes/main.tscn` 180 帧启动检查，**0 error**（面板挂在 HUD 下不影响主场景）。
- 回归基线：**98 用例 / 287 断言 / 0 失败 → 134 用例 / 435 断言 / 0 失败**。

## ES-4.3 · 死亡界面 + 重生倒计时（3 s 自动）· S · ⏳ 待实施

- **目标**：死亡界面「你已阵亡」+ 按钮上方 3/2/1 倒计时；归 0 **自动** `player.respawn()`；`[立即重生]` 保留可提前。
- **验收标准**（`04_ux §3.3` / ⚑L-4 / C-13）：3 s 后自动重生；重生点 = **离最近敌人最远的出生点**（`01_core_loop §6`）。
- **依赖**：无（复用 `player.died` / `player.respawn()`）。
- **涉及文件**：`scripts/ui/death_screen.gd`（现「重生」按钮逻辑）、`scripts/player.gd::respawn()`、`scripts/main.gd::_spawn_point_for()`。
- **测试证据**：契约锁——断言 `respawn()` 的选点走「最远出生点」逻辑。

## ES-4.4 · 加载 3-2-1 倒计时（冻结输入）· S · ⏳ 待实施

- **目标**：LOADING 阶段 3-2-1 倒计时，**冻结输入**，避免「谁先加载完谁先开枪」。
- **验收标准**（`01_core_loop §5` / `04_ux §4` 规则 3）：倒计时期间 `set_input_blocked(true)`，结束 `LIVE` 才 `false`。
- **依赖**：EP-3 ES-3.1（`match_state` COUNTDOWN）+ **EP-3 补 `sync_match_state` RPC（✅ 设计侧已定稿）**。
- **✅ 前置已确认**：`01_core_loop.md` 附录 **A.4 `sync_match_state`**（房主 → 全端，`authority`/`reliable`，载荷 `state: int, countdown_remaining: float`）**已由 design-strategist 裁定定稿**（非再「待确认」）。
  理由：原 A.4 消息清单无状态迁移消息 → 客户端不知道 COUNTDOWN 何时开始 → 无法冻结输入、无法显示 3-2-1。`sync_match_state` 是**唯一**触发信息来源（设计裁定：客户端不得本地推断）。
  A.9.1 的客户端临时近似解（收 `sync_scores` 推断 `LIVE`）**已作废**；UI 规格见 `04_ux_flow.md §3.4`。
  → **本 Story 与 `sync_match_state` 同批实现**（工程实施随 ES-4.4，见 `EP-3` 变更记录 `8b0e479`）。
- **验收补充**：客户端收到 `sync_match_state(S_COUNTDOWN, r)` → 进入 COUNTDOWN、显示 3-2-1、`set_input_blocked(true)`；收到 `S_LIVE` → 解冻输入；RPC 丢失由 1 s 心跳兜底。**倒计时 UI 绑本端信号 `countdown_updated(remaining)`（`01_core_loop.md` 附录 A.5），不直接绑 RPC**。
- **涉及文件**：`scripts/network/network_manager.gd::_start_match()`、`scripts/main.gd`、`scripts/game/score_manager.gd`（新增状态广播 + **新增信号 `countdown_updated`**，**与 ES-4.4 同批实现**）。
- **测试证据**：契约锁——断言 COUNTDOWN 态调用 `set_input_blocked(true)`；断言客户端收到 `sync_match_state` 后进入 COUNTDOWN 并冻结输入；断言 `LIVE` 后解冻。

## ES-4.5 · FFA 显示一致性 + 可访问性第二线索 · M · ⏳ 待实施

- **目标**：落地 `04_ux §6` 的 M1/M2/M4/M6：小地图敌对**方点**、明度次之；击杀标记加环；低血斜纹 / 空弹下划线。
- **验收标准**（可测，指向 `04_ux §6.4`）：
  - **AC-F1 / AC-A3**：FFA 下 `friendly` 组为空、远程玩家在敌对渲染集合；
  - **AC-F3 / AC-A1**：小地图敌对标记为**方形**且与背景明度差达标；
  - **AC-F4 / AC-A2**：正对近白天空时准星/指南针/比分板与背景**明度差 ≥ 0.3**；
  - **AC-F5 / AC-A4**：低血/空弹存在第二线索（形状/图标/音效）。
- **依赖**：EP-2（FFA 分组）；ES-4.1（比分板）。
- **涉及文件**：`scripts/ui/minimap.gd:108-127`（`_draw_group` 形状/明度）、`scripts/ui/crosshair.gd::_draw()`、`scripts/ui/hud.gd`。
- **测试证据**：截图型断言（灰度截图，需渲染后端）→ 归入视觉回归；headless 下先断言 `friendly` 组为空。

## ES-4.6 · 超半径敌人的定位辅助（小地图边缘方向箭头）· S · ✅ 已实现（R2 `b370974`）（**G4 前置**）

- **目标**：`minimap.gd` 对 `distance > world_radius`（60 m）的敌对目标，在**圆周边缘**画**三角方向箭头**（只给方位，不给精确点）。
- **验收标准**（`03_map §6 AC-3` / `04_ux §3.5` / C-17）：
  - `70 m` 处敌人（`> 60`）→ 该方向上**出现三角箭头**、**不出现在半径内**；
  - `50 m` 处敌人（`< 60`）→ 为**范围内核敌方方点 □**、无箭头；
  - 箭头为**三角形**（区别于范围内**方形** □，对齐 M1 形状编码）。
- **依赖**：ES-4.5（M1 形状编码）；`world_radius 60` 保持不变（**不扩到 95**）。
- **涉及文件**：`scripts/ui/minimap.gd::_draw_group()`（新增超距分支）。
- **测试证据**：契约锁——对超距节点断言箭头绘制路径被触发；截图型归视觉回归。
- **⚠ 归属说明**：C-17 的**另一半**（出生点按人数自适应）归 **EP-1 ES-1.1**。**G4 前至少本 Story 落地**（否则 2 人 FFA 找不到对方）。

---

## 依赖拓扑（EP-4 内部）

```
EP-3 ES-3.4（信号）─▶ ES-4.1（比分板）
                   ─▶ ES-4.2（结算面板）
EP-2（FFA 分组）───┐
ES-4.1 ────────────┴─▶ ES-4.5（FFA 显示一致性 + 可访问性）─▶ ES-4.6（边缘方向箭头）
ES-4.3（重生倒计时）/ ES-4.4（加载倒计时）  ← 相对独立
```

## 跨成员 handoff

- **art-director**：`AC-F4` 的明度差基准、小地图敌对标记形状 M1/M2 的视觉规格。
- **design-strategist**：`⚑F-1`（比分板形态）已定为「常驻紧凑条 + 结算完整榜」，若变更需同步 ES-4.1/ES-4.2。
