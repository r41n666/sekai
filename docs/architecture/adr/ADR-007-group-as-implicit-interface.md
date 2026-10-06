# ADR-007 · 组（group）是隐式接口：`friendly` 的身份/阵营双语义反模式

> **状态（Status）**：Accepted（已采纳 · 回溯 + 待 EP-2 实施迁移）
> **日期**：2026-10-06 ｜ **作者**：程基岩（engineering-lead，E3-01 补录 / E4-01）
> **统一收录**：本议题在三个来源各有一份编号，**是同一条验收要求**：
> - `design/gdd/99_consistency_review.md` **C-16**（原编号，来源设计策略侧）
> - `design/gdd/04_ux_flow.md` §6.4 **AC-F2**（UX 侧回归条款）
> - `design/art/accessibility.md` §7 **AC-A3b**（可访问性侧回归条款）
> 关联条款：**AC-F1 / AC-A3**（显示侧：FFA 无绿色友军）、`00_overview.md §4`（组契约表）、`ADR-006`（无服务器权威）
> **关联**：`player.gd:138`、`weapon.gd:351-362`、`knife.gd:99-109`、`minimap.gd:17-25/116`、`teammate_icons.gd:48`

---

## Context（背景与问题）

本项目的解耦完全依赖**场景组**（`00_overview.md §4`）。**任何组都是隐式接口** —— 组名是一份"口头契约"，
没有类型系统保护，加错组 / 忘加组 / 误用组都不会有编译错误，只会在运行时静默出错。

本次暴露的**具体反模式**：一个 `friendly` 组被同时当作**两种语义**使用：

| 语义 | 消费点 | 用途 |
| --- | --- | --- |
| ① **伤害路由键**（"这是远程玩家 → 伤害只发给他的 authority"） | `weapon.gd:353`（`if collider.is_in_group("friendly")`）、`knife.gd:100` | 决定走 `apply_network_damage.rpc_id(受害者 authority)` 还是走 `apply_damage_to_target` 广播 |
| ② **显示阵营键**（"这是队友 → 画绿点 / 队友图标"） | `minimap.gd:20`（`ally_group` 声明）、`minimap.gd:92`（`_draw` 调用）、`teammate_icons.gd:48` | 决定玩家在小地图 / 屏幕上被画成友军还是敌人 |

在**团队模式**下这两种语义**恰好重合**（队友既是"要特殊路由的远程玩家"，也是"要显示为友军的对象"），
所以历史上"一组两用"没有暴露问题。但在本项目**已定的 FFA 个人死斗**（`01_core_loop.md` ⚑L-1，无队友）下，
两种语义**彻底背离**：

- 按 ①，别的玩家仍需 `friendly` 组做**伤害路由**（否则联机伤害会落到广播分支 → 伤害广播给所有人 → 坏）；
- 按 ②，FFA 里**没有队友**，把远程玩家画成绿色友军是**误导**（玩家会以为对方是队友而不开枪）——
  `04_ux_flow.md §6.2` 已裁定：**FFA 下所有远程玩家按敌对渲染、`friendly` 显示用途为空、`teammate_icons` 不绘制**。

**陷阱**：如果只做 ②（把远程玩家移出 `friendly` 组），①就会坏 ——
`weapon.gd::_deal_damage()` 的 `is_in_group("friendly")` 判断会失败，玩家伤害落到 `else` 广播分支，
**联机伤害逻辑直接损坏**。这正是设计侧在 `accessibility.md:119` 记下的实现陷阱，也是本 ADR 要立此存照的原因。

## Decision（决定）

**把「玩家身份（伤害路由）」与「阵营显示」彻底解耦** —— 路由不再依赖任何**显示语义**的分组。

**推荐做法（本 ADR 立场）：伤害路由改用「能力探测」`collider.has_method("apply_network_damage")`。**

```gdscript
# weapon.gd::_deal_damage() / knife.gd::_slash() —— 修改后（示意）
if NetworkManager.is_online and collider is Node and not collider.is_in_group("bot"):
    if collider.has_method("apply_network_damage"):
        # 远程玩家：伤害只发给被击中者的 authority（受害者端权威）
        collider.apply_network_damage.rpc_id(
            collider.get_multiplayer_authority(), damage, NetworkManager.get_my_name())
    else:
        # 场景物件（训练靶等）：广播到所有端一起结算
        NetworkManager.apply_damage_to_target.rpc(str(collider.get_path()), damage, NetworkManager.get_my_name())
else:
    collider.take_damage(damage)  # 离线 / 人机：纯本地
```

配套（显示侧，与路由**互不影响**）：
- `player.gd::_setup_remote_player()`（`player.gd:137`）：FFA 下远程玩家**加入** `enemy` 组（而非 `friendly`）；
- `teammate_icons.gd`：FFA 下无 `friendly` 成员 → 自然不绘制（无需改代码，或显式早退）；
- `minimap.gd`：远程玩家作为 `enemy` 成员，按敌对**形状/明度**渲染（`04_ux_flow.md §6.1` M1/M2）。

**为什么推荐「能力探测」而不是「新增中性组」**：

1. **声明式 API 优于隐式组**。`apply_network_damage` 是 `PlayerController` **显式声明**的方法（`player.gd:342`）——
   它存在即代表"这是一个可被网络伤害的玩家节点"。这正是本项目 HUD 层已经在用的风格（`hud.gd` 全程
   `has_signal`/`has_method` 鸭子类型，见 `00_overview.md §2.2`）。**用一份显式声明替代一份口头契约**，正好消除本 ADR 的根因。
2. **零组生命周期负担**：不新增组，就没有"忘记加入 / 忘记移除 / 跨场景不一致"的风险 ——
   而"组是隐式接口"恰恰是本 ADR 要防的坑。少一个隐式接口 = 少一类回归。
3. **判别精确**：全项目只有 `PlayerController` 定义 `apply_network_damage`，人机（`bot.gd`）与场景物件都没有。
   因此 `has_method` 恰好把"远程玩家"从"人机 / 靶子"里分出来，与现有 `not is_in_group("bot")` 守卫互补。
4. **改动最小**：`weapon.gd` / `knife.gd` 各改 1 行判据，不碰任何场景 / 组注册。

## Consequences（后果）

**正面**：
- **显示与路由正交**：改可读性（FFA 敌我渲染）**不会再打断联机伤害** —— 这是 AC-F2 / AC-A3b 要守住的回归线。
- **消除 `friendly` 的双重语义**：`friendly` 只剩"显示阵营"一种用途，FFA 下为空、TDM 下才真正填充。
- 与 `ADR-006`（无服务器权威）一致：受害者端权威的伤害路径保持不动。

**负面 / 迁移代价（⚠ 必须一起改，不能只改一半）**：
- 迁移**必须同时**触碰以下文件，任何一处漏改都会静默坏掉：
  | 文件 | 改动 |
  | --- | --- |
  | `player.gd:138` | `_setup_remote_player()` 的组归属：`friendly` → `enemy`（FFA） |
  | `weapon.gd:353` | 路由判据：`is_in_group("friendly")` → `has_method("apply_network_damage")` |
  | `knife.gd:100` | 同上 |
  | `minimap.gd` | 确认远程玩家按 `enemy` 渲染（`enemy_group` 已默认指向 `enemy`，多为免改） |
  | `teammate_icons.gd:48` | 确认 FFA 下无 `friendly` 成员（自然不绘制），或加显式早退 |
- **能力探测的边界**：若未来给某个非玩家节点也加了 `apply_network_damage`（不应发生），会被误判为玩家 ——
  记为**低风险**，用注释在 `player.gd` 方法处标注该方法是"玩家身份契约"。
- **`friendly` 组在 FFA 下为空**（设计侧要求，非缺陷）—— 任何"遍历 `friendly`"的旧逻辑要确认空集安全。

## Alternatives considered（备选方案）

| 方案 | 评价 |
| --- | --- |
| **A · 能力探测 `has_method("apply_network_damage")`（✅ 本 ADR 推荐）** | 声明式、零组维护、判别精确、改动最小。首选 |
| **B · 新增语义明确的中性组 `remote_player`** | 可用且更"显式"，但**仍是一个隐式组接口**（组名无类型保护），需 `player.gd` 负责增删、其他端一致；这是"用另一个隐式接口替换旧的隐式接口"，未根治问题。列为**备选**（若团队更偏好分组风格可采纳） |
| **C · 保持单组 `friendly` + 新增 `team` 字段** | 需要 `player.gd` 维护 `team` 元数据；FFA 下 `team` 全不同 → 路由仍要读 `team`，等于把隐式契约挪到字段上；且 TDM 才真正需要，MVP 过度设计。**否** |
| **D · 用节点元数据（`set_meta("is_remote_player", true)`）** | 元数据更不可发现（连组查找都不如），且无自解释 API；**否** |

## 影响 / 后续

- 本 ADR 的迁移由 **EP-2**（`production/epics/EP-2-ffa-faction-decoupling.md`）承载；回归由 **AC-F2 / AC-A3b** 守（见 `tests/suites/test_damage_routing.gd`，当前为 pending）。
- **流程改进（写入 `control_checklist.md §4` 第 7 条）**：**改任何节点的组归属前，必须先 `grep` 全项目 `is_in_group` / `get_nodes_in_group` 的全部消费点** —— 本次反模式的根因就是"改显示分组时没意识到它同时是路由键"。
- 若未来上 TDM（`01_core_loop.md` 方案 B）：`friendly` 恢复真实语义（队友显示），路由**仍**用能力探测 —— 两者继续正交，无需再改路由。
