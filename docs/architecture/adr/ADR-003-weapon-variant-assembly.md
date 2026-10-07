# ADR-003 · 武器外观装配管线：网格重建 + 皮肤重套

> **状态（Status）**：Accepted（已采纳 · 回溯记录）
> **日期**：2026-10-06 ｜ **作者**：程基岩（engineering-lead，E3-01）
> **关联**：`shooting/weapon_variant.gd`、`shooting/weapon_skin.gd`、`player.gd:412-452`、
> `scenes/weapons/*.tscn`、`README §6.4`、`HANDOFF.md §2`

---

## Context（背景与问题）

一个武器槽要支持**多个外观模型**（`VARIANTS` 表，`weapon_variant.gd:26-122`），且**皮肤**（程序化贴图）
必须叠加在外观之上（`weapon_skin.gd`）。难点：

1. **模型来源杂乱**（Sketchfab / Source 2 / OBJ 转换），文件空间的轴、缩放、离群几何各不相同 ——
   需要在应用到武器时统一到「**+Z = 枪口、+Y = 上、对中到原点**」的武器空间约定。
2. **模型里有杂项几何**：离群小圈 / 混进来的手臂 / 展示台，会撑大 AABB（`README §6.4`、`weapon_variant.gd:76-84`）。
3. **皮肤是 `material_override`**：一旦**重建网格**（换外观），旧的材质覆盖会丢失 —— 必须重新套。

## Decision（决定）

**采用「`apply_to()` 单入口 + 有序装配 + 皮肤最后重套」的管线**（`weapon_variant.gd::apply_to()`，`weapon_variant.gd:169`）：

装配顺序（**顺序是不变量**）：
1. `load()` 变体的 glb，`instantiate()`，命名 `Model`；
2. 应用 `transform`（武器空间摆放 / 缩放 / 对中）；
3. 应用 `hide`（按节点名删除杂项，`weapon_variant.gd:190-192`）；
4. 应用 `trim`（按**网格本地坐标** AABB 裁掉离群三角形，重建 surface，`weapon_variant.gd:196-198`）；
5. 替换旧的 `Model`（先改名 `ModelOld` 再 `queue_free`，保证新节点能叫 `Model`）；
6. 搬移 `Muzzle` / `MuzzleLight` / `MuzzleFlash` / `GunAudio` 到新 `muzzle` 位置；
7. 写第一人称 `view_offset` / `view_yaw_deg`、HUD `display_name`；
8. **最后** `apply_skin(WeaponSkin.get_selected(slot))` —— **重套皮肤**（`weapon_variant.gd:227-229`）。

`player.gd::_equip_slot()` 的装备顺序同样是契约（`player.gd:424-433`）：
`apply_variant()` → `set_active(true)`（此时才播掏出动画）→ `apply_skin()`（再保一次）。

同时约定：**皮肤与外观的 id 存在「本端静态字典」**（`WeaponVariant.selected` / `WeaponSkin.selected`），
`player.gd` 装备时按字典查表套用 —— 与联机无关（不同步，见 ADR-006）。

## Consequences（后果）

**正面**：
- **一个入口解决所有外观差异**：加新外观只需往 `VARIANTS` 表加一条（path / transform / muzzle / view_offset / 可选 hide+trim），
  不改框架 —— 符合「不堆内容量也能低成本扩外观」。
- **`hide` + `trim` 双层过滤**：`hide` 处理「能按名字删的杂项」（如 FPS 蝴蝶刀混入的手臂 `Object_65`），
  `trim` 处理「和枪身同 surface、按名字删不掉的离群几何」（如 USP-S 赛睿的 4 组浮空小圈）——
  覆盖了两类 Sketchfab 导出瑕疵。
- **皮肤与外观正交**：皮肤只写 `material_override`、不动几何；外观只换几何、最后重套皮肤 → 两者可自由组合。

**负面 / 需注意的不变量**：
- ⚠ **换外观后必须重套皮肤**（第 8 步）。若有人把 `apply_skin` 提前或删除，皮肤会**静默丢失** —— 这是本 ADR 的核心保护点。
- ⚠ **`trim` 用的是「导入后的网格本地坐标」**，不是 glb 文件原始数字（glTF 导入器把 Sketchfab 的 ×100 缩放 / 换轴烘进顶点）。
  量错会导致裁错或裁不动（`weapon_variant.gd:255-261` 注释、`README §6.4`）。
- ⚠ **`ArrayMesh.get_aabb()` 重建后不刷新**：核对包围盒必须用 `get_faces()` 自算（`weapon_variant.gd:261` 注释）。
- ⚠ **`Transform3D` 两种写法互为转置**：GDScript 传 4 个轴向量；`.tscn` 传 9 个浮点按**矩阵行**读。手改 `.tscn` 必须转置，
  否则模型「前后/左右反」（`HANDOFF.md §2`、`weapon_variant.gd:10-13`）。
- **`trim` / `view_offset` 是逐模型手调的**：换模型 / 重导需重新量（`README §12` 已列为遗留）。

## Alternatives considered（备选方案）

| 方案 | 为何未选 |
| --- | --- |
| **每个外观一个独立 `weapon.tscn`** | 武器逻辑（射击 / 弹匣 / 后坐力接线）会复制 N 份，改一处要改 N 处；且皮肤/第一人称摆放无法统一管理 |
| **把皮肤烘进模型顶点 / 换材质槽** | 侵入性大，且程序化皮肤（`weapon_skin.gd` 的 FastNoiseLite 贴图）本就是「覆盖式」设计；`material_override` 最简单 |
| **在导入阶段预处理 glb（去离群几何、统一轴）** | 已在 `tools/*.py` 做过一部分（PMX/OBJ→glb），但 Sketchfab 导出的内层节点链差异太大；运行期 `hide`/`trim` 更灵活、可维护 |
| **不重套皮肤，改为事件通知皮肤系统刷新** | 增加耦合与竞态；「装配末尾重套」是确定性最强的做法 |

## 影响 / 后续

- 新增武器外观时：先跑 `tools/weapon_variant_check.tscn` 量 RAW 空间找离群几何，再填 `VARIANTS`，
  再核对武器空间剪影（`HANDOFF.md §1` 流程）。
- 若未来做「皮肤联机同步」（C-6）：需要把「当前外观 id / 皮肤 id」纳入玩家状态广播，
  并在**装配末尾重套**不改变的前提下扩展。

---

> **2026-10-07 更新**（**追加说明，正文原样保留**）：
>
> 1. **本 ADR 的装配管线（`VARIANTS` 表 → 摆 transform → 重套皮肤）今天完全有效，未改架构**，无需修订。
>
> 2. **⚠️ 但 `VARIANTS` 的内容已大幅收缩：现在是「每槽 1 个变体」**。
>    资源精简后只剩 4 个武器模型：
>    `Rifle → ak47.glb` / `USP → usp_cyrex.glb` / `Knife → knife_fps.glb` / `Grenade → grenade_pubg.glb`。
>    已删除：`m4a4.glb` / `pink_pistol.glb` / `butterfly_knife.glb`（hudidao）/ `porcelain_grenade.glb`。
>    ⇒ **"一个槽挂多个模型"的能力仍在（`VARIANTS` 是数组、结构没变），但当前每槽只有一条**，
>    所以 **Esc 菜单右栏的「外观（模型）」变体选择列表已删除**（选择冗余）。
>    **皮肤（`WeaponSkin`）选择保留**；`WeaponVariant` 仍在装备时按 `get_selected()`（默认变体）自动套用。
>    ⇒ 恢复多外观需同时改三处：`weapon_variant.gd::VARIANTS` 补条目 + `game_menu.gd` 恢复列表 + 本文。
>
> 3. **⚠️ 正文「影响 / 后续」里"新增武器外观"的流程仍有效，但其中一项判断已被实测证伪**：
>    曾用 `trim`（按网格本地坐标裁剪离群三角形）裁掉 USP 枪口侧"4 组浮空小圈"，
>    注释称那是浮空瑕疵。**渲染对比 + 探针实测推翻了该判断**：那 4 组其实是**消音器上的环形分段**，
>    裁掉等于把消音器与枪管前端齐刷刷切掉（看着就像"没有枪管"）。
>    ⇒ **`trim` 已从 USP 删除**，整枪（含消音器）完整保留，长度 0.4135 m 正是 USP-S 的真实长度。
>    **教训（写给未来的自己）**：「看起来是瑕疵的几何」在裁之前必须先确认它是什么 ——
>    `hide`（按节点名删整个杂项网格，如 `Object_65` 那条手臂）比 `trim` 安全得多，
>    因为 `hide` 有语义（按名字）、`trim` 只有坐标。
