# EP-4 · HUD / UX：比分板 / 结算面板 / 重生倒计时

> **Phase 4 ｜ 优先级 P1 ｜ 负责人**：程基岩（engineering-lead）
> **上游**：`design/gdd/04_ux_flow.md §3/§4/§6`、`design/art/accessibility.md`（Standard 基准线）、`99_consistency_review.md` C-13
> **目标**：把 EP-3 的计分数据变成**玩家可见的 UI**（比分板 / 结算 / 重生倒计时），并把可访问性第二线索落到 HUD。
> **出口判据**：结算面板显示完整比分 + 再开/回大厅；重生 3 s 自动；`AC-F1/F3/F4/F5` 的视觉回归可截图判定。

---

## ES-4.1 · HUD 比分板 Scoreboard（常驻紧凑条）· S · ⏳ 待实施

- **目标**：HUD 顶部中央常驻紧凑条 `[目标] 先到 15 杀　剩余 03:24` + 4 个玩家条目，绑 `ScoreManager.score_changed`。
- **验收标准**（`04_ux §3.1`）：
  - 按击杀降序；领先者**加亮（亮度 + 加粗，不只换色）**；本人条目加 `▶`；
  - 临界：某玩家到 14 杀 → 该条目闪烁 + 「还差 1 杀」；剩余 ≤30 s → 计时器变亮 + 「终局冲刺」；
  - 数字字号 ≥ 16、用**明度对比**而非仅颜色（`§6` Standard）。
- **依赖**：EP-3 ES-3.4（`score_changed` 信号）。
- **涉及文件**：`scripts/ui/hud.gd`（新增 `Scoreboard` 子节点）、`scenes/ui/hud.tscn`。
- **测试证据**：契约锁——断言 `hud.gd` 连接了 `score_changed`；视觉回归留 `tools/capture_acceptance.gd`。

## ES-4.2 · 结算面板 `match_result`（终态）· M · ⏳ 待实施

- **目标**：新增全屏结算面板：标题「对局结束」→ 胜者行 → 完整比分表（排名/名字/击杀/死亡/KD）→ 本局时长 → `[再来一局]`（仅房主）｜`[返回大厅]`。
- **验收标准**（`04_ux §3.2`）：
  - 由 `match_ended(winner_id, final_scores)` 触发；加入 `game_ui` 组、打开时关其它界面（互斥）；
  - **不暂停**游戏（覆盖层，`04_ux §1` 现状约束）；客户端 `[再来一局]` 显示「等待房主…」。
- **依赖**：EP-3 ES-3.4。
- **涉及文件**：**新增** `scripts/ui/match_result.gd` + `scenes/ui/match_result.tscn`；参照 `scenes/ui/death_screen.tscn`；`scripts/ui/game_menu.gd`（`game_ui` 组互斥）。
- **测试证据**：契约锁——断言新面板 `add_to_group(UI_GROUP)` 且实现 `open_ui/close_ui`。

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
- **验收补充**：客户端收到 `sync_match_state(S_COUNTDOWN, r)` → 进入 COUNTDOWN、显示 3-2-1、`set_input_blocked(true)`；收到 `S_LIVE` → 解冻输入；RPC 丢失由 1 s 心跳兜底。
- **涉及文件**：`scripts/network/network_manager.gd::_start_match()`、`scripts/main.gd`、`scripts/game/score_manager.gd`（新增状态广播，**与 ES-4.4 同批实现**）。
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

---

## 依赖拓扑（EP-4 内部）

```
EP-3 ES-3.4（信号）─▶ ES-4.1（比分板）
                   ─▶ ES-4.2（结算面板）
EP-2（FFA 分组）───┐
ES-4.1 ────────────┴─▶ ES-4.5（FFA 显示一致性 + 可访问性）
ES-4.3（重生倒计时）/ ES-4.4（加载倒计时）  ← 相对独立
```

## 跨成员 handoff

- **art-director**：`AC-F4` 的明度差基准、小地图敌对标记形状 M1/M2 的视觉规格。
- **design-strategist**：`⚑F-1`（比分板形态）已定为「常驻紧凑条 + 结算完整榜」，若变更需同步 ES-4.1/ES-4.2。
