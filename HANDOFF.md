# 交接提示词（给接手本项目的 AI / 开发者）

> 用法：在另一台电脑用 Trae Work（云端 GitHub）打开本仓库后，把本文档内容作为提示词发给 AI 即可继续开发。

---

## 一、项目背景

这是一个 **Godot 4 的第三人称射击原型**（主角：初音未来，复刻 sky.jpeg 的白云蓝天 + 水面场景）。
- 仓库：https://github.com/r41n666/sekai ，工作分支 **master**（= 最新提交）
- 本地准备：`git clone https://github.com/r41n666/sekai.git && cd sekai && git checkout master && git pull`
- 另一条分支 `feat-add-new-model-vm4GuF` 是更早的真实武器模型改版，其内容（M4A4 / 粉色 USP / 青花瓷手雷 + `tools/obj2glb.py`）已移植进 master；master 上还多了菜单 / 重生 / 人机系统，**以 master 为准**
- 用 **Godot 4.7.2**（≥4.3 均可）打开 `project.godot`
- **先完整读 `README.md`**：它是权威文档（阶段进度表、项目结构、操作说明、验证记录、已知限制）。每次改完功能必须同步更新它。

## 二、已完成的部分（不要重做）

| 模块 | 说明 |
| --- | --- |
| 阶段 1 | 高画质场景（程序化云层天空 + ACES/Glow/SSAO/SSR/体积雾）+ 本地 `.ogg` 歌单（MusicManager） |
| 阶段 2 | 战地风格 HUD（准星/小地图/指南针/队友图标/血条/弹药/击杀日志）+ 三层后坐力 / 相机摇晃 / Trauma 屏幕震动 / 3D 程序化枪声 |
| 阶段 3 | 局域网联机：`scenes/hub/hub.tscn` 大厅（创建/加入房间、玩家列表、开始对战）、ENetMultiplayerPeer、位置同步（普通 RPC，**不要换成 MultiplayerSynchronizer/Spawner**，迟到加入会失效）、伤害/开火特效 RPC、房主离开自动回大厅 |
| 阶段 4 | 初音模型接入（见下）+ 无动画模型的**程序化步态** |
| 操作 | `1/2/3/4` 武器槽（步枪 / USP / 蝴蝶刀 / 手雷，**同键再按 = 空手**）、`Ctrl` 蹲、`Z` 趴、`V` 第一/三人称、`Alt` 自由视角、`R` 换弹（**长按 3 秒补满备弹/手雷**）、`Esc` 释放鼠标 |

模型管线要点（`scripts/entities/miku_model.gd`、`miku_procedural_pose.gd`）：
- 自动加载 `assets/models/miku/miku.glb`；按骨骼范围自动缩放到 1.75 m、脚底对齐胶囊底；
- 自动清理 mmd_tools 导出混进来的物理刚体/关节占位网格（否则是白盒子）；
- 模型正面约定为 **+Z**（不对就用 `yaw_offset_deg` 修正）；
- 模型没有动画剪辑时自动启用**程序化步态**：屈膝抬脚、摆臂、身体起伏、步频按速度自适应（防滑步）；
  实现用 `set_bone_global_pose_override` + **逐级枢轴累积**（多个绝对覆写会打断父子链，必须按关节枢轴逐级叠加）；
  骨骼识别是启发式的（脚→大腿→膝→踝、手→上臂→肘沿父链定位，骨骼名乱码也能用）。

## 三、任务（A / B 均已完成 ✅；实现细节与验证记录见 README.md）

> 本轮已完成：**任务 A**（PMX→glb 转换器修复 + 3 个 MMD 模型接入）与 **任务 B**（Esc 菜单 / 死亡重生 / H 人机）。
> 下面保留原始需求作为记录。
>
> 追加：**真实武器模型**（M4A4 / 粉色 USP / 青花瓷手雷）已从 `feat-add-new-model-vm4GuF` 移植进 master（含 `tools/obj2glb.py`）；
> 蝴蝶刀仍是方块占位——模型在开发机 `D:\sekai\assets\models\hudidao`（尚未进仓库），接入方式与其它武器一致（见 README「武器与装备槽」）。

### 任务 A：修复 `tools/pmx2glb.py`（已完成）

**目标**：把 `assets/models/` 下两个 MMD 模型转成 glb 并加进游戏（供角色选择用）：
- `YYB式改 小海军初音 Mku/YYB式改变miku.pmx`
- `YYB式改变初音未来-伯爵女仆/YYB 猫猫女仆.pmx`、`YYB 猫猫女仆2.pmx`

**已确认正确的部分**（不要推翻）：
- PMX 头 / 顶点 / 面 / 贴图 / 材质解析正确：41168 顶点、189417 索引、23 材质、21 贴图，
  `材质 face_count 总和 == 索引总数`（一致性校验通过）；
- 骨骼 flag 用**高位编码**：`0x0001` 尾骨骼索引、`0x0100/0x0200` 旋转/移动付与、`0x0400` 轴固定、
  `0x0800` 局部轴、`0x2000` 外部亲；
- 前 7 根骨骼（操作中心 / 全ての親 / センター / グルーブ / 腰 / 右足IK親 / 右足ＩＫ）**逐字节手算核对一致**。

**现存 bug**：解析到第 8 根骨骼开始偏移错位（把"文本长度"读成 2621544 之类的垃圾值 → 最终越界）。
即尾部字段的消耗规则在某个 flag 组合下与我的假设不符。

调试线索（`YYB式改变miku.pmx`）：
- 第 8 根骨骼起始偏移 = `2532327`（第 7 根结束处），原始字节：

```
68 00 28 00 00 00 00 00 00 40 02 00 00 00 67 00 01 db 0f 49 c0 00 00 00 00
00 00 00 00 35 fa 0e bc 00 00 00 00 00 00 00 00 66 00 00 0c 00 00 00 f3 53
64 30 7e 30 48 51 29 ff 2b ff 00 00 00 00 59 9a 21 bf 00 20 a0 3e bc c2 ad bf
06 00 02 00 00 00 3e 00 00 00 00 00 d8 99 3a bf 00 c8 4d 3b 6d 00 03 00 00
00 00 00 80 40 01 00 00 00 68 00 00 0a 00 00 00 e6 5d b3
```

**建议的解决路径（最快）**：
1. 对照 mmd_tools 官方 PMX 读取实现：`https://github.com/powroupi/blender_mmd_tools`
   里的 `src/mmd_tools/core/pmx/__init__.py`（Bone.read 及尾部字段顺序），照着改即可；
2. 或写"逐根消耗字节数 vs 手工 hex 解码"的对比脚本定位（本次修复前 7 根就是这么验出来的，够用）；
3. 解析通过后：`python tools/pmx2glb.py <pmx路径> assets/models/<英文目录名>`，产物 glb 需能被 Godot 导入、
   外观/骨骼正常（尺寸与落地交给项目侧自动适配；正面朝向约定 +Z，不对就用 `yaw_offset_deg`）。

### 任务 B：菜单 / 重生 / 人机（已完成）

1. **`Esc` 呼出菜单**：
   - 角色选择：扫描 `assets/models/*/*.glb` 生成列表，点击切换本地玩家的 `MikuModel.model_path` 并重载模型；
   - 退出游戏：`get_tree().quit()`（联机时先走 `NetworkManager` 退出房间）；
   - 菜单打开时释放鼠标 + 屏蔽玩家输入（移动/开火），关闭后恢复并重新锁定鼠标。
2. **死亡与重生**：
   - 玩家生命到 0 → 显示死亡界面（"你已阵亡" + 重生按钮）；`player.gd` 已有 `died` 信号；
   - 重生 = 回满血 + 在出生点重生 + 恢复输入。
3. **`H` 键人机管理**：
   - 面板增减人机数量；人机**随机刷新在玩家周围 8~18 m**（出生点/地面是 y=0 的水面，注意不要生成在玩家身上）；
   - 主动靠近并攻击玩家：追踪 + 周期射击（带散布、命中扣玩家血）；
   - **受击动画**（受击后仰/闪白特效）+ **受击音效**（可程序化合成，参考 `scripts/shooting/audio_3d.gd` 的 WAV 合成方式）；
   - 建议实现：新建 `scenes/bot.tscn`（CharacterBody3D + 复用 `MikuModel` + 占位胶囊）、`scripts/entities/bot.gd` 写简单 AI；
     用 `MikuModel.update_animation(delta, speed, ratio, moving, on_floor)` 驱动行走步态，人机拿枪可实例化 `scenes/weapons/rifle.tscn` 做外观；
     武器 hitscan 会对任何带 `take_damage()` 的碰撞体生效（`training_target.gd` 是接口范例），人机实现同名方法即可被玩家打死；
   - 人机**仅本端生成、不同步**（联机时每端各自刷），在 README 已知限制里写明。

## 四、必须遵守的工程约定

1. **README.md 是权威文档**：每次改完同步更新（进度表 / 结构树 / 验证记录 / 已知限制）。
2. 新增脚本/场景由 Godot 生成 `.uid` 文件，一并提交；**临时验证脚本用完删除**（不要留在仓库）。
3. **验证方式**（headless）：
   `godot --headless --path . --import` 后运行
   `godot --headless --path . --quit-after 2400 -s tools/_tmp_xxx.gd`
   （SceneTree 脚本，用 `print` 断言关键数值；验证通过后删除临时脚本）。
4. 联机：位置同步用普通 RPC；伤害走 `network_manager.gd` 现有 RPC 路由；
   空手/武器槽/蹲趴/第一人称等**只在本端表现**（不同步），已知限制里要如实写。
5. 提交：中文提交信息；完成后提交并推送到 `branch-7TXhiN`。

## 五、环境与常用操作

- Godot：4.7.2（Windows 控制台版，原开发机路径 `C:\Users\13569\Desktop\Godot_v4.7.2-stable_win64_console.exe`，新机器自行替换；当前机器在桌面上）
- 本机其它工具：Blender 5.2（`D:\Program Files\Blender Foundation\Blender 5.2`，可作为 PMX 转换的备选路径）、
  Git（`C:\Program Files\Git`）、itch（`D:\develop\itch`，后续发布用）
- 联机自测：开两个客户端实例，一个「创建房间」，另一个用 `127.0.0.1` 加入（局域网/VPN 用内网 IP）
- 当前仓库规模：模型 54 MB + 音乐 9 MB（已包含在仓库里），另有 3 个转换好的 glb（含 Godot 抽取的贴图，约 52 MB）