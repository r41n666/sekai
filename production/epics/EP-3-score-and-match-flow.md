# EP-3 · 计分与对局流程（ScoreManager）

> **Phase 4 ｜ 优先级 P0 ｜ 负责人**：程基岩（engineering-lead）
> **上游**：`design/gdd/01_core_loop.md §4/§5/§6 + 附录 A（数据契约）`、`99_consistency_review.md` **C-1**、`04_ux_flow.md §3.1/§3.2`
> **目标**：补上本项目最大的设计空洞（无胜负条件）——FFA「15 杀 / 5 分钟」的**权威计分 + 胜负判定 + 同步**。
> **出口判据**：headless 可测——模拟 15 次击杀 → `ScoreManager` 触发 `match_ended(winner_id)`（`01_core_loop §4`）；新增 `test_score_manager.gd` 全绿。

---

## ES-3.1 · `ScoreManager` 节点 + 数据契约 · M · ⏳ 待实施

- **目标**：新增 `ScoreManager`，挂在 `main.tscn` 下（**每局随场景创建/销毁 → 天然复位，不用 Autoload**，`附录 A.1`）。
- **验收标准**（`01_core_loop 附录 A.3`）：
  - 字段齐备：`match_state`(enum)、`kill_target=15`、`match_duration=300.0`、`time_remaining=300.0`、`scores:Dictionary`、`winner_id=-1`（`-2`=并列）；
  - 权威归属：`peer_id==1`（`is_server`）唯一权威；离线 `NetworkManager.is_online==false` 时本端即权威（A.1）。
- **依赖**：无。
- **涉及文件**：**新增** `scripts/game/score_manager.gd`；`scenes/main.tscn`（挂节点）。
- **测试证据**：新增 `tests/suites/test_score_manager.gd`（断言默认字段值）。

## ES-3.2 · 击杀上报与死亡计分 RPC · M · ⏳ 待实施

- **目标**：击杀者本端解析 `victim_id` 并 `report_kill.rpc_id(1, victim_id)`；房主记击杀 +1 并给受害者 `deaths+1`（一条消息同时记击杀与死亡，`附录 A.8`）。
- **验收标准**（`附录 A.4/A.7/A.8`）：
  - 节点名 = peer id（`main.gd::_make_player()` 设 `player.name = str(id)`）→ 由此解出 `victim_id`；
  - 离线 / bot：`killed && collider.is_in_group("bot")` → **本地 +1**，不走联机 RPC；
  - ⚠ 现状缺口：`hit_confirmed` 只给名字不给 id，需在 `_deal_damage` 额外解析 `collider.name`。
- **依赖**：ES-3.1。
- **涉及文件**：`scripts/shooting/weapon.gd:335/346-365`、`scripts/shooting/knife.gd:98-111`、`scripts/main.gd::_make_player()`、`scripts/entities/bot.gd:191`。
- **测试证据**：`test_score_manager.gd` 模拟 `report_kill` 断言 `scores` 结构。

## ES-3.3 · 对局状态机 + 计时 + 胜负判定 · M · ⏳ 待实施

- **目标**：`IDLE→COUNTDOWN(3s)→LIVE→ENDED`；`LIVE` 每帧检查 `max(kills) ≥ 15` 或 `time_remaining ≤ 0` → `_end_match()`。
- **验收标准**（`附录 A.2/A.6`）：胜者 = 击杀最高；平局 → 死亡少者；仍平 → `winner_id=-2`；结算终态 `winner_id` 固化、`scores` 冻结。
- **依赖**：ES-3.1。
- **涉及文件**：`scripts/game/score_manager.gd`。
- **测试证据**：`test_score_manager.gd`——注入 15 杀 / 超时 / 平分三种场景断言 `winner_id`。

## ES-3.4 · 同步 RPC + 信号总线 · S · ⏳ 待实施

- **目标**：实现 `sync_scores`（房主→全端，变更时 + 每 1 s 心跳）、`match_ended`、`match_reset`；暴露信号供 HUD 绑定。
- **验收标准**（`附录 A.4/A.5`）：
  - 信号：`score_changed(scores, time_remaining)`、`match_state_changed(state)`、`match_ended(winner_id, final_scores)`；
  - `match_reset` 复位比分 / 位置 / 倒计时（`04_ux §7` 待评估项②）。
- **依赖**：ES-3.1 / ES-3.3。
- **涉及文件**：`scripts/game/score_manager.gd`；`scripts/network/network_manager.gd`（复用 `is_server` / `get_players()`）。
- **测试证据**：`test_score_manager.gd` 断言信号触发（`match_ended` 连接回调计数）。

## ES-3.5 · `test_score_manager.gd` 回归 · S · ⏳ 待实施（随 ES-3.1~3.4）

- **目标**：为 EP-3 建回归基线。
- **验收标准**：15 杀触发、5 分钟超时、平分判定、字段默认值——全部可断言。
- **依赖**：ES-3.1~3.4。
- **涉及文件**：**新增** `tests/suites/test_score_manager.gd`；登记进 `tests/framework/test_runner.gd::SUITE_SCRIPTS`。
- **测试证据**：runner 汇总输出。

---

## 依赖拓扑（EP-3 内部）

```
ES-3.1（ScoreManager + 契约）
   ├─▶ ES-3.2（击杀上报 RPC）
   ├─▶ ES-3.3（状态机 + 胜负）
   │       └─▶ ES-3.4（同步 RPC + 信号）─▶ ES-3.5（回归）
```
**EP-3 → EP-4**：EP-4 的比分板 / 结算面板消费 EP-3 的信号（ES-3.4）。
