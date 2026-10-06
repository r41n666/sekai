# ADR-001 · 物理引擎选型：Jolt Physics

> **状态（Status）**：Accepted（已采纳 · 回溯记录）
> **日期**：2026-10-06 ｜ **作者**：程基岩（engineering-lead，E3-01）
> **关联**：`project.godot:145`、`design/gdd/03_map_encounter.md`、`99_consistency_review.md` C-9

---

## Context（背景与问题）

Godot 4 默认提供两套 3D 物理后端：**Godot Physics**（内置）与 **Jolt Physics**（Godot 4.4 起官方集成）。
本项目是 TPS 联机原型，物理负载集中在：

1. **玩家 / 人机的角色移动**（`CharacterBody3D::move_and_slide()`，`player.gd:219`、`bot.gd:114`）——
   每帧对地形与掩体做胶囊体扫掠。
2. **hitscan 射线**（`weapon.gd:329`、`knife.gd:89`、`bot.gd:158`）—— 每发子弹 / 每周期一次 `intersect_ray`。
3. **手雷刚体**（`grenade_projectile.gd` 继承 `RigidBody3D`）—— 抛体 + 落点弹跳。
4. **相机弹簧臂遮挡**（`SpringArm3D`，`player.tscn:59-61`）。

关键约束（`design/gdd/03_map_encounter.md §1`）：竞技场 80×80 m，**掩体 8~12 处**（箱体 / 墙 / 高台）、
垂直空间 0~4 m，且 `03_map §4` 明确「掩体用 `collision_layer=2`（与地面同层），细节待 engineering-lead」。

## Decision（决定）

**采用 Jolt Physics 作为 3D 物理引擎**（`project.godot` 的 `[physics] 3d/physics_engine="Jolt Physics"`）。

理由（基于本项目真实负载，而非泛泛而谈）：

1. **角色移动（`move_and_slide` + 胶囊）更稳**：Jolt 在「胶囊贴墙滑行 / 台阶 / 斜坡」上的抖动与穿透明显少于
   Godot Physics。本项目出生点四角化后玩家会频繁贴掩体与地图边缘跑动，角色稳定性直接影响「射击手感」（P1）。
2. **Jolt 支持多线程 / SIMD**，在 4 人 + 8 人机（`bot_manager.gd::max_bots = 8`）同场时余量更大。
3. **`RigidBody3D`（手雷）行为更可预测**：Jolt 的接触求解更符合直觉，抛体落点更稳定，便于设计侧调「6 m 爆炸半径」。
4. **官方集成、零外部依赖**：Godot 4.4+ 原生内置，不引入 GDExtension 构建负担。

## Consequences（后果）

**正面**：
- 角色 / 相机 / 手雷三类物理表现更稳，为「帧级可读的开火反馈」提供基座。
- 掩体（P1 工程项）加入后，`move_and_slide` 与 `SpringArm3D` 的交互更可控。

**负面 / 需注意**：
- **Jolt 的角色控制器与 Godot Physics 参数不完全等价**：`physics/3d/*` 下的部分调参（摩擦、弹跳、接触偏差）
  在 Jolt 下语义不同。**新增掩体 / 高台时必须实测**「能否跳上 1.0~1.2 m 箱体」（`03_map §4`：跳高约 1.27 m）。
- **Jolt 与 `SpringArm3D` 的碰撞层交互仍受 C-9 影响**（掩体若放 layer 2，相机会收缩）—— 这是**碰撞层规划问题，不是 Jolt 问题**，
  见 `00_overview.md §8.4`。
- Jolt 对**异常几何**（巨大 / NaN 尺寸的碰撞体）更敏感；本项目掩体需手摆且尺寸合理（不加超大地板重复）。

## Alternatives considered（备选方案）

| 方案 | 为何未选 |
| --- | --- |
| **Godot Physics（默认）** | 角色贴墙滑行抖动更多；多线程支持弱；与 Jolt 相比没有优势，只省「无迁移成本」这一项，而项目本就没在 Godot Physics 上投产 |
| **第三方 GDExtension 物理（如 Rapier / PhysX 绑定）** | 引入构建与跨平台维护成本，违反「小游戏 + 低摩擦」（P2）；官方 Jolt 已覆盖需求 |
| **自定义角色运动学（不用 `CharacterBody3D`）** | 改动面过大，且放弃引擎的 `move_and_slide` / 台阶处理；不划算 |

## 影响 / 后续

- 掩体加入时回归：`03_map §4` 要求的「半高箱 1.2 m 可跳 / 高台 1.0 m 可跳 / 全高墙 2.5 m 不可跳」需在 Jolt 下逐项实测。
- 若未来出现 Jolt 特有的穿透 / 抖动问题，先查碰撞体尺寸与层，再考虑回退（回退仅需改 `project.godot` 一行）。
