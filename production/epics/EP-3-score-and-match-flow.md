# EP-3 · 计分与对局流程（ScoreManager）

> **Phase 4 ｜ 优先级 P0 ｜ 负责人**：程基岩（engineering-lead）
> **上游**：`design/gdd/01_core_loop.md §4/§5/§6 + 附录 A（数据契约）`、`99_consistency_review.md` **C-1**、`04_ux_flow.md §3.1/§3.2`
> **目标**：补上本项目最大的设计空洞（无胜负条件）——FFA「15 杀 / 5 分钟」的**权威计分 + 胜负判定 + 同步**。
> **出口判据**：headless 可测——模拟 15 次击杀 → `ScoreManager` 触发 `match_ended(winner_id)`（`01_core_loop §4`）；新增 `test_score_manager.gd` 全绿。

---

## ES-3.1 · `ScoreManager` 节点 + 数据契约 · M · ✅ 已完成

- **目标**：新增 `ScoreManager`，挂在 `main.tscn` 下（**每局随场景创建/销毁 → 天然复位，不用 Autoload**，`附录 A.1`）。
- **验收标准**（`01_core_loop 附录 A.3`）：
  - 字段齐备：`match_state`(enum)、`kill_target=15`、`match_duration=300.0`、`time_remaining=300.0`、`scores:Dictionary`、`winner_id=-1`（`-2`=并列）；
  - 权威归属：`peer_id==1`（`is_server`）唯一权威；离线 `NetworkManager.is_online==false` 时本端即权威（A.1）。
- **依赖**：无。
- **涉及文件**：**新增** `scripts/game/score_manager.gd`；`scenes/main.tscn`（挂节点）。
- **测试证据**：新增 `tests/suites/test_score_manager.gd`（断言默认字段值）。

## ES-3.2 · 击杀上报与死亡计分 RPC · M · ✅ 已完成

- **目标**：击杀者本端解析 `victim_id` 并 `report_kill.rpc_id(1, victim_id)`；房主记击杀 +1 并给受害者 `deaths+1`（一条消息同时记击杀与死亡，`附录 A.8`）。
- **验收标准**（`附录 A.4/A.7/A.8`）：
  - 节点名 = peer id（`main.gd::_make_player()` 设 `player.name = str(id)`）→ 由此解出 `victim_id`；
  - 离线 / bot：`killed && collider.is_in_group("bot")` → **本地 +1**，不走联机 RPC；
  - ⚠ 现状缺口：`hit_confirmed` 只给名字不给 id，需在 `_deal_damage` 额外解析 `collider.name`。
- **依赖**：ES-3.1。
- **涉及文件**：`scripts/game/score_manager.gd`（`report_kill` RPC + `_report_local_kill` + `_apply_kill` + `_apply_bot_kill` + `resolve_victim_id`）、`scripts/shooting/weapon.gd:335-338 + _report_kill_if_player`、`scripts/shooting/knife.gd:113 + _report_kill_if_player`。
- **测试证据**：`test_score_manager.gd` 用例 13~16（上报核心逻辑 / 归因安全解析 / 非法 id 拒绝 / 人机本地计分）。
- **实现说明**：`resolve_victim_id()` 为 **static 纯函数**，用 `String.is_valid_int()` 严格判定节点名；非数字名（bot/靶子/自动命名）与 `id<=0`（ENet 保留值 0）一律返回 -1 → 双保险（调用方 + `_apply_kill` 各自拒绝）。**未改动 `hit_confirmed` 现有签名**（HUD 命中原样可用），击杀上报走**独立路径**。

## ES-3.3 · 对局状态机 + 计时 + 胜负判定 · M · ✅ 已完成

- **目标**：`IDLE→COUNTDOWN(3s)→LIVE→ENDED`；`LIVE` 每帧检查 `max(kills) ≥ 15` 或 `time_remaining ≤ 0` → `_end_match()`。
- **验收标准**（`附录 A.2/A.6`）：胜者 = 击杀最高；平局 → 死亡少者；仍平 → `winner_id=-2`；结算终态 `winner_id` 固化、`scores` 冻结。
- **依赖**：ES-3.1。
- **涉及文件**：`scripts/game/score_manager.gd`（`_process` / `start_match` / `_drive_countdown` / `_tick_live` / `_set_players_input_blocked`）；`scripts/main.gd::_ready()`（触发 `start_match()`）。
- **测试证据**：`test_score_manager.gd` 用例 17~21（状态迁移 / 开局幂等 / 超时结算 / 达标结算 / 输入冻结防御）。
- **实现说明**：IDLE→COUNTDOWN 触发点 = `main.gd::_ready()` 玩家节点创建完成后（A.2「对局加载完成」）；COUNTDOWN 冻结输入复用 `player.gd::set_input_blocked()`（已存在）；新增 `auto_drive` 开关供测试手工喂 `delta`（**不改契约默认值 3.0 / 300.0**）。

## ES-3.4 · 同步 RPC + 信号总线 · S · ✅ 已完成

- **目标**：实现 `sync_scores`（房主→全端，变更时 + 每 1 s 心跳）、`match_ended`、`match_reset`；暴露信号供 HUD 绑定。
- **验收标准**（`附录 A.4/A.5`）：
  - 信号：`score_changed(scores, time_remaining)`、`match_state_changed(state)`、`match_ended(winner_id, final_scores)`；
  - `match_reset` 复位比分 / 位置 / 倒计时（`04_ux §7` 待评估项②）。
- **依赖**：ES-3.1 / ES-3.3。
- **涉及文件**：`scripts/game/score_manager.gd`（`sync_scores` / `net_match_ended` / `net_match_reset` RPC + `_apply_sync` / `_apply_ended` / `_apply_reset` / `request_reset`）；`scripts/main.gd::sync_scoreboard()`。
- **测试证据**：`test_score_manager.gd` 用例 22~30（sync 本地应用 / 结算应用幂等 / 复位 / 信号双路径 / 房间增删 / 默认值 / 客户端状态推断）。
- **实现说明**：**命名冲突解决** —— 附录 A.4 的 `match_ended` / `match_reset` **RPC 加 `net_` 前缀**（→ `net_match_ended` / `net_match_reset`），**signal 保持契约原名**（HUD 绑定面是 signal，改名会波及 EP-4）；`sync_scores` / `report_kill` 无同名 signal → 保持原名。`match_reset` 复位回 **IDLE**（而非直接重开 COUNTDOWN）：与 A.2 状态图一致，且让「再来一局」复用 `main.tscn` 的加载完成 → `start_match()` 路径。

## ES-3.5 · `test_score_manager.gd` 回归 · S · ✅ 已完成（随 ES-3.1~3.4）

- **目标**：为 EP-3 建回归基线。
- **验收标准**：15 杀触发、5 分钟超时、平分判定、字段默认值——全部可断言。
- **依赖**：ES-3.1~3.4。
- **涉及文件**：`tests/suites/test_score_manager.gd`（ES-3.1 建基线 12 用例；本批扩至 **30 用例 / 115 断言**）；已登记进 `tests/framework/test_runner.gd::SUITE_SCRIPTS`。
- **测试证据**：runner 汇总 —— `✓ test_score_manager（30 用例 / 115 断言）`，全量 `用例 50 ｜ 断言 175 ｜ 失败 0 ｜ exit 0`。
- **完成判定说明**：ES-3.5 的出口判据是「15 杀 / 超时 / 平分 / 字段默认值全部可断言」，本批扩测已**超出**该范围（新增击杀上报 / 状态机 / 同步应用 / 归因解析 / 信号双路径等 18 个用例），故判定为 ✅ 完成。

---

## 依赖拓扑（EP-3 内部）

```
ES-3.1（ScoreManager + 契约）
   ├─▶ ES-3.2（击杀上报 RPC）
   ├─▶ ES-3.3（状态机 + 胜负）
   │       └─▶ ES-3.4（同步 RPC + 信号）─▶ ES-3.5（回归）
```
**EP-3 → EP-4**：EP-4 的比分板 / 结算面板消费 EP-3 的信号（ES-3.4）。

---

## 变更记录

| 日期 | 条目 | 变更 | 说明 |
| --- | --- | --- | --- |
| 2026-10-06 | ES-3.1 | ⏳→✅ | `ScoreManager` 骨架 + 数据契约落地：新增 `scripts/game/score_manager.gd`（`class_name ScoreManager`，字段/信号/权威口径/状态机枚举 + 胜负判定纯逻辑）；挂 `scenes/main.tscn::ScoreManager` 节点；新增 `tests/suites/test_score_manager.gd`（12 用例 / 32 断言）并登记 runner。RPC 收发（ES-3.2/3.4）与对局驱动接线（ES-3.3）保持 ⏳。 |
| 2026-10-06 | ES-3.2 / ES-3.3 / ES-3.4 / ES-3.5 | ⏳→✅ | 击杀上报 RPC + 对局状态机驱动 + 同步信号总线落地：`score_manager.gd` 扩至约 430 行（`report_kill` RPC + `_report_local_kill` / `_apply_kill` / `_apply_bot_kill` / `resolve_victim_id`；`_process` / `start_match` / `_drive_countdown` / `_tick_live`；`sync_scores` / `net_match_ended` / `net_match_reset` RPC + `_apply_sync` / `_apply_ended` / `_apply_reset` / `request_reset`）；`weapon.gd` / `knife.gd` 加 `_report_kill_if_player()`（致命时归因上报，不改 `hit_confirmed` 签名）；`main.gd` 接线 `sync_scoreboard()` + `_ready()` 触发 `start_match()`。测试扩至 **30 用例 / 115 断言**；全量回归 **50 用例 / 175 断言 / 0 失败 / exit 0**。**关键设计取舍**：RPC 加 `net_` 前缀避免与 signal 同名；IDLE→COUNTDOWN 触发点 = `main.gd::_ready()`；房主自身击杀走直调（不用 `call_local`）；COUNTDOWN 冻结输入复用 `player.gd::set_input_blocked()`。**未验证项**：真实 RPC 收发与 `multiplayer.get_remote_sender_id()` 仅 headless 单机自测（见提交说明）。 |
