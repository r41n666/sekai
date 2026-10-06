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
- **测试证据**：截图型断言（`AC-F3`），暂列视觉回归；headless 下断言 `friendly` 组为空。

## ES-2.4 · 启用 `test_damage_routing` 回归 · S · ✅ 已完成

- **目标**：EP-2 落地后把 `tests/suites/test_damage_routing.gd` 的 `EP2_IMPLEMENTED` 置 `true`，使该 suite 从 pending 转为**启用**。
- **验收标准**：runner 输出中该 suite 由 `○ PENDING` 变为 `✓`；退出码仍为 0。
- **依赖**：ES-2.1 / ES-2.2 / ES-2.3 全部完成。
- **涉及文件**：`tests/suites/test_damage_routing.gd`（1 行常量）。
- **测试证据**：`tests/test_runner.tscn` 汇总输出。

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
