# EP-1 · 竞技场几何与出生点

> **Phase 4 ｜ 优先级 P1 ｜ 负责人**：程基岩（engineering-lead）
> **上游**：`design/gdd/03_map_encounter.md`、`design/art/asset_spec_arena.md`、`99_consistency_review.md §3`（C-5/C-8/C-9/C-10）
> **目标**：把「400×400 水面 + 空场景」补成**一张可打的 80×80 竞技图**——四角出生、12 处掩体、小地图覆盖全图、人机刷新合规。
> **出口判据**：`tests/suites/test_spawn_points.gd` + `test_minimap_radius.gd` 全绿；掩体可被小地图采集（`minimap_obstacle` 组非空）。

---

## ES-1.1 · 出生点四角分散（AC-1）· S · ✅ 已完成（E3-01）

- **目标**：4 个 `Marker3D` 从中心 16×16 m 移到四角 `(±32, 0.5, ±32)`。
- **验收标准**（可测，指向 `03_map §6 AC-1` / C-8）：
  - AC-1①：每点 `|x|,|z| ≥ 24`；
  - AC-1②：任意两点距离 `≥ 45 m`；
  - AC-1③：在边界内 `|x|,|z| ≤ 40`；目标幅值 `= 32`。
- **依赖**：无。
- **涉及文件**：`scenes/main.tscn:52-62`（Spawn1~4 的 `Transform3D`）；`scripts/main.gd::_spawn_point_for(id)`（逻辑无需改）。
- **测试证据**：`tests/suites/test_spawn_points.gd`（5 用例 / 23 断言，通过）。

## ES-1.2 · 小地图显示半径 ≥ 60（AC-2）· S · ✅ 已完成（E3-01）

- **目标**：`world_radius` 覆盖 80×80 对角半长 `√(40²+40²) ≈ 56.57 m`。
- **验收标准**（`03_map §6 AC-2` / C-5 / ⚑M-5）：`world_radius ≥ 56.5686`（现值 `60`）。
- **依赖**：无。
- **涉及文件**：`scripts/ui/minimap.gd:15`（`@export var world_radius := 60.0`）。
- **测试证据**：`tests/suites/test_minimap_radius.gd`（4 用例 / 4 断言，通过）。

## ES-1.3 · 12 处掩体手摆 + `minimap_obstacle` 组 · L · ⏳ 待实施

- **目标**：按 `asset_spec_arena.md §3` 清单手摆 12 处掩体（C1×4 + C2×4 + C3×2 + C4×1 + C5×1）+ 4 m 立柱 C6，全部 `CollisionShape3D`（`BoxShape3D`）节点加入 `minimap_obstacle` 组。
- **验收标准**：
  - 掩体总数 = 12（`03_map §2`）；垂直台阶 `1.0→2.0→3.0 m` + `4.0 m` 立柱（⚑M-3）；
  - 每个掩体在 `minimap_obstacle` 组 → `minimap.gd::_collect_obstacles()` 采集数 == 12（`asset_spec_arena §8.2 AA-2`）；
  - 避开四角出生点 `(±32,±32)`（⚑M-2）；
  - 材质非金属（`metallic 0.0`，`asset_spec_arena §5`）。
- **依赖**：ES-1.4（碰撞层规划先定，避免返工）。
- **涉及文件**：`scenes/main.tscn`（**新增 `Obstacles` 节点**，`03_map §4`）；`scripts/ui/minimap.gd:45`（`_collect_obstacles` 读组）；美术权威 `design/art/asset_spec_arena.md §3~§5`。
- **测试证据**：新增 `tests/suites/test_arena_obstacles.gd`——实例化场景后断言 `minimap_obstacle` 组采集数 == 12、台阶高度序列。**（待补）**

## ES-1.4 · 掩体碰撞层规划（C-9）· M · ⏳ 待实施

- **目标**：确定掩体的碰撞层，避免 `SpringArm3D`（相机）撞掩体时错误收缩。
- **验收标准**：第三人称下相机不被掩体挡；`player.tscn` 的 `SpringArm3D.collision_mask` 与掩体层不冲突（`99_consistency_review §3` C-9）。
- **依赖**：无（但**阻塞 ES-1.3**）。
- **涉及文件**：`scenes/main.tscn`（`Ground` 现 `collision_layer=2`）、`scenes/player.tscn`（`SpringArm3D.collision_mask=2`）。
- **测试证据**：契约锁——断言掩体层与 `SpringArm3D.collision_mask` 的位不重叠。

## ES-1.5 · 人机刷新「边界内 + 非掩体」校验（C-10）· S · ⏳ 待实施

- **目标**：人机刷新点必须落在地图内（`|x|,|z| ≤ 40`）且不与掩体碰撞。
- **验收标准**（`03_map §3.1` / C-10）：重复采样刷新点，`100%` 满足 `|x|,|z| ≤ 40` 且不在掩体内。
- **依赖**：ES-1.3（需要掩体存在才能做碰撞校验）。
- **涉及文件**：`scripts/entities/bot_manager.gd::_random_spawn_position()`（`spawn_min_distance 8.0` / `spawn_max_distance 18.0`）。
- **测试证据**：新增 `tests/suites/test_bot_spawn_bounds.gd`——多次调用采样断言边界与碰撞。

---

## 依赖拓扑（EP-1 内部）

```
ES-1.4（碰撞层）
   └─▶ ES-1.3（12 掩体）──▶ ES-1.5（人机刷新校验）
ES-1.1 ✅   ES-1.2 ✅            （相互独立、已完成）
```
