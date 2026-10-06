# ADR-002 · 网络位置同步模型：~30 Hz 普通 RPC + 本端平滑

> **状态（Status）**：Accepted（已采纳 · 回溯记录）
> **日期**：2026-10-06 ｜ **作者**：程基岩（engineering-lead，E3-01）
> **关联**：`player.gd:88-93/231-235/283-298`、`network/network_manager.gd:212-220`、`main.gd:2-8`、
> `design/pillars.md` P2、`99_consistency_review.md` C-1/C-3

---

## Context（背景与问题）

TPS 联机小游戏（P2「三秒进场，三分钟一局」，4 人局域网 / 蓝盾 VPN）需要同步其他玩家的**位置与朝向**。
可选的 Godot 同步手段有三类：

1. **`MultiplayerSynchronizer`**（引擎内置的场景属性复制）。
2. **普通 `@rpc` 广播**（自己写「发送状态 → 远端插值」）。
3. **服务器权威 + 回滚 / 延迟补偿**（完整预测-回滚模型）。

约束：
- 打法需要**即时**看到别人（对枪手感，P1）。
- 「对局进行中迟到加入」必须**立刻**看到所有人（`README §9`）。
- 该项目刻意保持**简单**（`pillars.md` P2 明确「放弃匹配/排位/断线重连/服务器权威」）。

## Decision（决定）

**采用「节点名 = peer id 的本地确定性重建 + ~30 Hz 普通 RPC 广播 + 本端指数平滑」**：

1. **各端本地创建同批玩家节点**（不用 `MultiplayerSpawner`）：`main.gd::_sync_players()` 按
   `NetworkManager.get_players()` 的名单，在本地 `Players/` 下创建 `str(peer_id)` 命名的节点，
   `player.set_multiplayer_authority(peer_id)`（`main.gd:25-45`）。
2. **位置/朝向**由本端 `player.gd::_physics_process` 每 `NET_SYNC_INTERVAL = 0.033 s`（≈30 Hz）
   经 `NetworkManager.net_player_state.rpc(pos, yaw)` 广播（`player.gd:231-235`，`network_manager.gd:213`，
   注解 `any_peer, call_remote, unreliable_ordered`）。
3. **远端平滑**：收到后存为「目标」，每帧 `global_position.lerp(target, 1-exp(-14·dt))`、
   `lerp_angle` 追 yaw（`player.gd:283-291`）。
4. **其他表现**（开火特效 / 手雷 / 伤害）走**独立 RPC**，与位置解耦（见 `00_overview.md §7.2`）。

## Consequences（后果）

**正面**：
- **迟到加入天然可用**：新玩家的节点由**名单**决定（各端跑同一段 `_sync_players`），不依赖「增量复制缓存」，
  因此「对局中才加入」也能立刻看到所有人（`main.gd:5-6` 注释；`README §10` 阶段 3 实测通过）。
- **广播与表现解耦**：`net_player_state` 用 `unreliable_ordered`（丢包无所谓，下一帧覆盖）；
  开火 / 伤害用 `unreliable` / `reliable` 各自合适的通道。
- **实现简单、可调试**：同步逻辑全在 `player.gd` + `network_manager.gd` 两处，无隐藏的复制缓存。

**负面 / 已接受的取舍**：
- **无权威、无回滚**：远端位置是「广播值 + 平滑」，高延迟 / 丢包下会**抖动**（`README §12` 已记录）。
  这是**有意保留的简单化**，不是缺陷（P2 明确放弃）。
- **无客户端预测**：本端自己的移动是本地即时（权威），因此**手感不受延迟影响**（对 P1 是关键）。
- **带宽随频率线性**：30 Hz × (Vector3 + float) × N 端。4 人规模下可忽略；若扩到更多人需重新评估。
- **确定性重建的隐含契约**：`_sync_players` 必须幂等且各端一致（`main.gd:24` 注释「幂等」）。
  新增玩家相关状态（如比分）时，必须同时改这段，否则各端会分叉。

## Alternatives considered（备选方案）

| 方案 | 为何未选 |
| --- | --- |
| **`MultiplayerSynchronizer`（属性复制）** | 依赖「场景复制缓存」；迟到加入 / 中途重建节点的行为更隐晦；本项目已用「名单本地重建」解决迟到加入，再叠 Synchronizer 会造成两套生成机制竞争。可复现性 / 可读性都不如显式 RPC（`network_manager.gd:8` 旧注释曾提同步器，实际实现已改为普通 RPC） |
| **服务器权威 + 回滚 / 延迟补偿** | 工作量与复杂度远超 MVP；与 P2「小游戏、局域网友好、放弃服务器权威」直接冲突。列为**愿景层**（若未来做匹配/排位再评估） |
| **`MultiplayerSpawner` + 服务器生成** | 迟到加入需要额外的「全量状态补发」，本项目用名单重建更直接 |

## 影响 / 后续

- **比分 / 胜负**（C-1）落地时：应沿用「名单 + 广播」范式，建议房主（`peer_id=1`）为比分权威，
  客户端只上报意图（`01_core_loop.md §6` 待 engineering-lead 评估项）。
- 若未来要缓解远端抖动：可插入「快照缓冲 + 插值延迟」或引入 `MultiplayerSynchronizer` 做插值，
  但**不改权威模型**（仍是本端权威）。
