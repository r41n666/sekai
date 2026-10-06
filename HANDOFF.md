# 交接说明（本地接手用）

> 背景：云端同步出过事故（一次分支冲突 + 一次工作区被重置），**以本地这份仓库为准**。
> 阅读顺序：本文 → `README.md`（权威文档：阶段进度 / 结构 / 已知限制）→ 直接跑起来。

---

## 一、现在的状态（先看这个）

- 工程：Godot **4.7.2**，用 Godot 打开 `project.godot` 即可；主场景 `scenes/hub/hub.tscn`（大厅）→ 开始对战进 `scenes/main.tscn`。
- 代码状态：所有脚本都能通过 headless 解析（`--check-only` 全绿）。最新提交见 `git log`（本文件所在提交之上还有一次「清理 autoload」的小提交）。
- **仓库里缺 7 个新模型的文件**：云端同步时工作区被重置，`assets/models/` 下只剩老模型（M4A4 / 粉色 USP / hudidao 蝴蝶刀 / 青花瓷手雷 / miku / miku_maid / miku_navy）。新模型只在你的本机，按下面第二节放回去、导入就行。
- 已经写好并且好用的部分：
  - **武器外观变体系统**：每个武器槽可挂多个模型，Esc 菜单里点「外观」立即换；3D 检视同步；皮肤叠加在外观之上；`anim` 字段支持掏出时播模型自带动画（FPS 蝴蝶刀翻刃）。
  - 菜单右栏改成两列：**外观（模型）** / **皮肤**；武器槽按钮上直接显示「步枪·AK-47」这样的当前外观名。
  - 已校准正确：**AK-47**（第一/第三人称都验过，枪口朝前、大小合适）、M67 手雷、青花瓷手雷、M4A4、粉色 USP、hudidao 蝴蝶刀。
  - 待校准：**USP-S 赛睿**（疑似前后反 + 偏小）、**FPS 蝴蝶刀**（偏小）。

### 待办（接手 AI 的三件事）

#### 1) 把 7 个模型放回项目并导入

| 你本机的文件 | 放到项目里的路径 | 备注 |
| --- | --- | --- |
| `ak-47.glb` | `assets/models/weapons/ak47.glb` | 已校准，照抄 VARIANTS 里的值 |
| `usp-s__cyrex.glb` | `assets/models/weapons/usp_cyrex.glb` | **待校准**（见下） |
| `fps_butterfly_knife.glb` | `assets/models/weapons/knife_fps.glb` | **待校准**（见下） |
| `pubg_mobile_grenade.glb` | `assets/models/weapons/grenade_pubg.glb` | 基本 OK（已校准过缩放/对中） |
| `mikunightcord_a_las_2500_escenario_colorido.glb` | `assets/models/miku_nightcord/miku_nightcord.glb` | 角色：2 网格 / 有骨架 / 高约 1.9 单位 / 2 张贴图 |
| `miku.glb` | `assets/models/miku_ps/miku_ps.glb` **或** `miku_statue/miku_statue.glb` | 用特征对号，见下 |
| `hatsune_miku.glb` | 剩下的那个 | 同上 |

>`miku_ps` 与 `miku_statue` 的名字是我按模型特征起的，导入时用这两组特征判断谁是谁：
> - **miku_ps**：60 个网格、有骨架、**531 根骨骼**、尺寸约 17×25×24 单位、5 张贴图；
> - **miku_statue**：18 个网格、**没有骨架**（摆件/雕像类，只能用静态姿势）、尺寸约 14×19.5×7.2 单位、8 张贴图。

导入方法：把文件放好后**用 Godot 编辑器打开项目**（会自动导入，生成 `*.glb.import` 和抽取出来的贴图）。如果哪天在无头机上导入不出来，用「临时 autoload + `preload()`」触发按需导入（本次会话用过：加 `_tmp_force_import.gd` 到 project.godot 的 `[autoload]`，跑 `--headless --editor --quit`，然后删掉）。

#### 2) 校准 USP-S 与 FPS 蝴蝶刀

两个都是同一个病：**模型里疑似有离群杂物几何把 AABB 撑大**，而摆放矩阵的缩放 / 对中都是按 AABB 算的 → 模型会偏小、位置偏。USP 还疑似**前后反**。

校准流程（每一步都有现成工具）：
1. 跑 `godot --headless --path . res://tools/weapon_variant_check.tscn`；
2. 把工具里的 `RAW_ONLY` 改成 `true`、往 `RAW_MODELS` 里加要看的模型 → 输出「三个投影面的 ASCII 剪影 + 每个 surface 的包围盒 + 顶点数」；
3. 对比每个 surface 的包围盒，**找出那个离群的 surface**（离群的那个往往顶点很少、位置在整段 AABB 的角落/另一头）。正常做法：要么在 `hide` 字段里按名字删掉它，要么按主体 geometry 的包围盒重算 scale / 对中 / muzzle；
4. 改 `scripts/shooting/weapon_variant.gd` 的 `VARIANTS` 表（`transform` / `muzzle` / `view_offset`），再把 `RAW_ONLY` 改回 `false` 核对**武器空间剪影**：`+Z` 端应是枪口方向、`M`（Muzzle 标记）要落在包围盒 `+z` 端内侧、整个模型尽量对中在原点；
5. 跑 `tools/capture_acceptance.tscn` 拍「第三人称 + 第一人称」核对（手枪在手前应指向远方，看不到枪口内孔 = 没装反）。

已校准的参考值（AK-47，照抄即可）：

```gdscript
"transform": Transform3D(Vector3(0.0, 0.0, 0.4591), Vector3(0.0, 0.4591, 0.0),
        Vector3(-0.4591, 0.0, 0.0), Vector3(0.1813, -0.028, -2.148)),
"muzzle": Vector3(0.0, 0.078, 0.45),
"view_offset": Vector3(0.18, -0.17, -0.6),
```

手头测过的数据（帮你省时间）：
- `usp_cyrex`：文件空间 AABB x −1021~761（长 1782，X 是枪管轴）、y −188~496、z −143~28。**+X 端是又大又密的块（握把/套筒），−X 端是稀疏细长结构（疑似消音器）→ 枪口很可能朝 −X**；如果确认，就得把 x 轴反向（`x_axis` 取 (0,0,−s)，z 轴顺右手法则变 (s,0,0)），origin 相应取 ‑(B·center) 重算。按 1782 全长算的 scale=0.0001346（手枪实际约 0.24 m）→ 若真被杂物撑大，这个 scale 会让枪偏小。
- `knife_fps`：文件空间 AABB 1.67×0.14×0.39（X 是长轴），**6 根骨骼、动画名 "Scene"（翻刃）**；按 1.67 算 scale=0.15 → 0.25 m，但实测在手里明显偏小 → 怀疑 AABB 里含杂物/展开后的外扩，用主体 surface 重算缩放。
- `hudidao` 蝴蝶刀：1.12 长、scale 0.25、transform y 从 0.09~1.20 → 已验正确，别动。
- `grenade_pubg`：文件空间 6.5×8.7×6.2（Y 是上下），scale 0.0132 → 约 0.115 m 高，已校准。

#### 3) 重拍验收截图 + 更新文档

```
# Windows 本机（有窗口）：直接跑，图在 /tmp/accept（或改成项目里的目录）
godot --path . res://tools/capture_acceptance.tscn
# 无头机：
xvfb-run -a godot --path . res://tools/capture_acceptance.tscn --rendering-driver opengl3 --resolution 1280x720
```

它会把 `main.tscn` 拉起来：四个武器槽各拍「第三人称 + 第一人称」→ 换回旧外观回归 → 打开 Esc 菜单拍外观/皮肤/3D 检视 → 逐个切角色模型。
挑好的图放进 `docs/acceptance/`，并按 README 的约定更新**阶段进度表 / 已知限制**（README 是权威文档，改完功能必须同步）。

---

## 二、必须知道的三个坑（都踩过，别再踩）

1. **Transform3D 两种写法互为转置**：
   - GDScript `Transform3D(Vector3 x轴, Vector3 y轴, Vector3 z轴, Vector3 原点)` 传的是**轴向量**；
   - `.tscn` 里 `Transform3D(9 个浮点, 3 个原点)` 的 9 个浮点按**矩阵行**读（第一行 = 三根轴的 X 分量）。
   - 手改 `.tscn` 的 transform 必须转置，否则模型前后/左右反；改 GDScript 用 4 个 Vector3 最直观。
   - 另外：GDScript 里**没有** 9/12 个浮点的 Transform3D 构造（会报 "No constructor matches"），别写。
2. **武器摆放约定**：武器空间 **+Z = 枪口方向、+Y = 上方、模型对中到原点**；`VARIANTS` 里的 `transform` 就是把 glb 文件空间转成这个约定的矩阵；`muzzle` 会带着 Muzzle / MuzzleLight / MuzzleFlash / GunAudio 一起挪。
3. **headless 导入产物**：`--import` 有时不给 glb 生成导入产物（`.godot/imported/*.scn`），此时 `load()` 返回 null、模型不显示。本机用编辑器打开就正常；无头机用「临时 autoload + preload」触发（文件删掉记得同时撤 autoload 项）。

---

## 三、两个现成工具（都在 `tools/`）

| 工具 | 用途 | 怎么跑 |
| --- | --- | --- |
| `weapon_variant_check.gd/.tscn` | 校准 / 自检：RAW 阶段画原始文件三视图 + 列每个 surface 的 AABB（找离群几何）；变体阶段打印武器空间包围盒 / 轴映射 / Muzzle / 零件位置 + 侧视剪影 | `godot --headless --path . res://tools/weapon_variant_check.tscn`（`RAW_ONLY` 开关） |
| `capture_acceptance.gd/.tscn` | 一键验收截图（四槽 × 两人称 + 菜单 + 角色） | 见上面「重拍验收截图」 |

> 这两个是**长期工具**，不是一次性脚本，别删；一次性脚本用完照惯例删（`_tmp_` 前缀）。

---

## 四、后续 AI 提示词（整段复制给本地 TraeWork 的 AI）

```
我在做 Godot 4.7.2 的第三人称射击原型（仓库 sekai，分支 master，用 Godot 打开 project.godot）。
动手前先完整读 README.md 和 HANDOFF.md，README 是权威文档，改完功能必须同步更新它。

现状：
- 「武器外观变体」系统已经写好：scripts/shooting/weapon_variant.gd 定义每个武器槽可挂的模型（transform / muzzle /
  第一人称摆放 / 掏出动画），Esc 菜单右栏有「外观（模型）」列表（scripts/ui/game_menu.gd + game_menu.tscn），
  3D 检视（scripts/ui/weapon_preview.gd）会先套外观再套皮肤；皮肤系统是 scripts/shooting/weapon_skin.gd。
  代码能过 headless 解析，但新模型的资源文件不在仓库里（云端同步丢过工作区）。
- 原始 glb 在我本机，按 HANDOFF.md 第一节的对照表放回 assets/models/ 对应目录，然后用 Godot 编辑器打开项目导入。

请按顺序做三件事：
1. 放回并导入 7 个新模型（对照表 + 特征对号在 HANDOFF.md；导入后确认有 *.glb.import 和抽取贴图）。
2. 校准两个外观：USP-S 赛睿（疑似前后反 + 偏小）、FPS 蝴蝶刀（偏小）。用 tools/weapon_variant_check.tscn：
   先把 RAW_ONLY 改 true 看原始文件三视图 / 每个 surface 的 AABB 找离群杂物几何，改
   scripts/shooting/weapon_variant.gd 的 VARIANTS 表，再改回 RAW_ONLY=false 核对武器空间剪影（+Z 端是枪口、
   Muzzle 落在 +z 端内侧、对中到原点）。AK-47 的已校准值在 HANDOFF.md 里，照抄。
3. 跑 tools/capture_acceptance.tscn 拍验收截图，挑图进 docs/acceptance/，更新 README 的进度表与已知限制。

硬约定：武器空间 +Z=枪口、+Y=上、对中到原点；GDScript 的 Transform3D(4 个 Vector3) 与 .tscn 的 Transform3D(12 个
浮点) 互为转置（手改 tscn 要转置）；皮肤叠加在外观之上、换模型后要重套；临时脚本用完删；完成后用中文提交信息提交。
```

---

## 五、历史（已完成，不要重做）

- 阶段 1~5：高画质场景 / 战地风 HUD + 射击手感 / 局域网联机 / 初音模型接入 + 程序化步态 / Esc 菜单 + 死亡重生 + H 人机。
- 模型管线：`tools/pmx2glb.py`（PMX→glb，含镜像修正）、`tools/obj2glb.py`、`tools/blend2glb.py`；面部贴图 / 朝向 / 尺寸自动适配在 `scripts/entities/miku_model.gd`。
- 武器：真实模型（M4A4 / 粉色 USP / 青花瓷手雷 / hudidao 蝴蝶刀）+ 武器皮肤（程序化贴图）+ 3D 检视 + 第一人称武器视图 + 第三人称跟手挂点。
- 细节、验证记录、已知限制全在 `README.md`。