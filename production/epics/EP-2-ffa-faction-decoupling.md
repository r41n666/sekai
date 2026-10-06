# EP-2 · FFA 阵营与伤害路由解耦

> **Phase 4 ｜ 优先级 P0（关键回归）｜ 负责人**：程基岩（engineering-lead）
> **上游**：`design/gdd/99_consistency_review.md` **C-16**、`design/gdd/04_ux_flow.md §6.2/§6.4` **AC-F2**、`design/art/accessibility.md §7` **AC-A3b**、`docs/architecture/adr/ADR-007-group-as-implicit-interface.md`
> **目标**：消除 `friendly` 组的「身份（伤害路由）+ 阵营（显示）」双语义——**显示改敌对渲染不会打断联机伤害**。
> **出口判据**：把 `tests/suites/test_damage_routing.gd` 的 `EP2_IMPLEMENTED` 置 `true` 后，该 suite 4 个用例全绿。
> **⚠ 本 Epic 的迁移必须「四文件同改」**——任何一处漏改都会**静默**弄坏联机伤害（详见 ADR-007 Consequences）。

---

## ES-2.1 · 伤害路由改「能力探测」· S · ✅ 已完成

- **目标**：`weapon.gd::_deal_damage()` / `knife.gd::_slash()` 的 `is_in_group("friendly")` 判据替换为
  `collider.has_method("apply_network_damage")`（受害者端权威路由保持不变）。
- **验收标准**（ADR-007 Decision / AC-F2）：全项目只有 `PlayerController` 定义 `apply_network_damage`
  （`player.gd:342`）；命中玩家走 `apply_network_damage.rpc_id(victim authority)`，命中场景物件走 `apply_damage_to_target.rpc` 广播。
- **依赖**：ES-2.2（同批改，不能只改一半——见 ADR-007）。
- **涉及文件**：`scripts/shooting/weapon.gd:351-362`、`scripts/shooting/knife.gd:99-109`。
- **测试证据**：`tests/suites/test_damage_routing.gd::test_weapon_routing_uses_capability_probe` / `::test_knife_routing_uses_capability_probe`。

## ES-2.2 · 远程玩家组归属（FFA：`friendly` → `enemy`）· S · ✅ 已完成

- **目标**：FFA 下 `_setup_remote_player()` 把远程玩家加入 `enemy` 组（`friendly` 组留空）；TDM 未来再恢复。
- **验收标准**（`04_ux §6.2` / AC-F1）：FFA 对局中 `friendly` 组为空；远程玩家出现在 `enemy` 渲染集合。
- **依赖**：ES-2.1（同批）。
- **涉及文件**：`scripts/player.gd:138`（`_setup_remote_player` 的 `add_to_group(...)`）。
- **测试证据**：`tests/suites/test_damage_routing.gd::test_remote_player_joins_enemy_group_in_ffa`。

## ES-2.3 · 显示侧：FFA 敌对渲染 + 队友图标停用 · S · ✅ 已完成

- **目标**：`minimap.gd` 远程玩家按 `enemy` 形状/明度渲染（M1 方点 / M2 明度）；`teammate_icons.gd` 在无 `friendly` 成员时自然不绘制（或显式早退）。
- **验收标准**（`04_ux §6.1/§6.2`）：FFA 下 `teammate_icons` 不绘制任何图标；小地图敌对标记为**方形**。
- **依赖**：ES-2.2。
- **涉及文件**：`scripts/ui/minimap.gd:92`（`_draw_group(ally_group,...)`）、`scripts/ui/teammate_icons.gd:48`（`get_nodes_in_group("friendly")`）。
- **实现**（2026-10-06）：`minimap.gd::_draw_group()` 新增 `hostile: bool` 参数——敌对组走 `_draw_square()`（实心方点 □，M1），友方组保留 `draw_circle()`（圆点 ○，TDM 未来用）。
- **测试证据**：截图型断言（`AC-F3`），暂列视觉回归；headless 下运行时断言 `friendly` 组为空（见 ES-2.4 第 4 用例）。

## ES-2.4 · 启用 `test_damage_routing` 回归 · S · ✅ 已完成

- **目标**：EP-2 落地后把 `tests/suites/test_damage_routing.gd` 的 `EP2_IMPLEMENTED` 置 `true`，使该 suite 从 pending 转为**启用**；并补齐 **AC-F1 运行时断言**（第 4 用例）。
- **验收标准**：runner 输出中该 suite 由 `○ PENDING` 变为 `✓`，**4 用例**全绿；退出码仍为 0。
- **依赖**：ES-2.1 / ES-2.2 / ES-2.3 全部完成。
- **涉及文件**：`tests/suites/test_damage_routing.gd`（`EP2_IMPLEMENTED` 常量 + 第 4 用例 `test_friendly_group_empty_in_ffa`）。
- **第 4 用例说明**（AC-F1 = AC-A3，`04_ux §6.4` 原文「断言 FFA 对局中 `friendly` 组为空」）：**唯一运行时断言**——实例化真实 `player.tscn`，把 authority 设为非本端 id（2）→ `_ready()` 走 `_setup_remote_player()`，入树后断言 ①`is_in_group("enemy")` ②`not is_in_group("friendly")` ③`get_nodes_in_group("friendly").is_empty()`，用完 `queue_free()` 清理。前 3 个用例全是 `_read_source()` 字符串匹配，只证明「源码文本含 `has_method(...)`」，**不证明运行时 `friendly` 组为空**——本用例补上该缺口（否则有人把组归属改回 `friendly` 时前 3 用例仍全绿）。
- **测试证据**：`tests/test_runner.tscn` 汇总输出（`test_damage_routing` 4 用例 / 8 断言）。

---

## 依赖拓扑（EP-2 内部）

```
ES-2.1（路由判据）─┐
ES-2.2（组归属）───┼─▶ ES-2.3（显示侧）─▶ ES-2.4（启用回归）
ES-2.1 ◀── 必须与 ES-2.2 同批提交（ADR-007：不能只改一半）
```

## 风险

- **只改一半**（如把 `player.gd` 改到 `enemy` 却留 `weapon.gd` 读 `friendly`）→ 玩家伤害落到广播分支 → **联机伤害损坏**。AC-F2 就是为此立的回归线。
- 能力探测的**边界**：若未来给非玩家节点也加 `apply_network_damage` 会被误判——低风险，用注释标注该方法为「玩家身份契约」（ADR-007）。

---

## 变更记录

- **2026-10-06**｜程基岩｜EP-2 落地（ES-2.1 ~ ES-2.4 全部完成），四文件同改 + 回归启用：
  - `scripts/shooting/weapon.gd:353`：`if collider.is_in_group("friendly")` → `if collider.has_method("apply_network_damage")`。
  - `scripts/shooting/knife.gd:100`：同上，保持枪/刀同一路由判据。
  - `scripts/player.gd:138`（`_setup_remote_player`）：`add_to_group("friendly")` → `add_to_group("enemy")`；同步改写上方注释（FFA = 敌对渲染）。
  - `scripts/player.gd`（`apply_network_damage`）：加「玩家身份契约」注释，警示勿给非玩家节点加同名方法。
  - `scripts/ui/minimap.gd`：**确认免改**（`enemy_group` 默认即 `"enemy"`，`:93` 已有 `_draw_group(enemy_group, ...)`）；仅更新头部注释澄清 FFA 语义。
  - `scripts/ui/teammate_icons.gd`：新增 `ally_group` 导出并**显式早退**（`allies.is_empty()` → return），使「FFA 无队友图标」成为明确意图。
  - `tests/suites/test_damage_routing.gd:16`：`EP2_IMPLEMENTED` `false` → `true`，suite 启用。
  - 验证：全量回归 **31 用例 / 89 断言 / 0 失败 / exit 0**；负向验证（判据改回 `friendly`）确认 `test_weapon_routing_uses_capability_probe` **确实失败**（exit 1 / 2 断言失败），证明测试非空跑。

- **2026-10-06**｜程基岩｜EP-2 补完（规格纠正后，`minimap` M1 方形 + AC-F1 运行时断言）：
  - **纠正**：上一轮把 ES-2.3 的小地图「方形」误判为免改，实为 ES-2.3 正文要求（`04_ux §6.1` M1 明确点名 `minimap.gd::_draw_group()`）。
  - `scripts/ui/minimap.gd::_draw_group()`：新增 `hostile: bool` 参数——敌对组 `_draw_square()`（实心方点 □），友方组保留 `draw_circle()`（○）；`_draw()` 调用处 enemy 传 `true`、ally 传 `false`。
  - `scripts/ui/minimap.gd` 头部注释 + `scripts/player.gd` 头部注释：同步 FFA 敌对方点语义。
  - `tests/suites/test_damage_routing.gd`：新增第 4 用例 **`test_friendly_group_empty_in_ffa`**（AC-F1 运行时断言：实例化 `player.tscn` → authority=2 → 远端分支 → 断言 enemy∈ / friendly∉ / friendly 组为空）。**补上此前 3 个纯字符串用例的运行时缺口。**
  - 验证：全量回归 **32 用例 / 92 断言 / 0 失败 / exit 0**；对新用例做负向验证（`player.gd:139` 改回 `add_to_group("friendly")`）确认 `test_friendly_group_empty_in_ffa` **三条断言全部失败**（exit 1 / 4 失败），改回 `enemy` 后复绿。
