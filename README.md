# MikuHighQualityWalk

第三人称射击游戏原型（Godot 4 + Forward+）。角色暂用胶囊体占位，后续替换为初音未来 `.glb` 模型。

- **阶段 1（已完成）**：高画质 3D 小场景自由走动 + 本地 `.ogg` 歌单播放
- **阶段 2（已完成）**：战地 5 风格 HUD + 射击手感（三层后坐力 / 动态准星 / 相机摇晃 / 屏幕震动 / 3D 音效）

---

## 一、阶段划分与当前进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 阶段 1 | 高画质 3D 小场景自由走动 + 本地 `.ogg` 歌单 | ✅ 已完成 |
| 阶段 2 | 战地 5 风格 HUD + 射击手感 | ✅ 已完成（武器模型仍是方块占位） |
| 阶段 3 | 局域网联机（蓝盾 VPN + ENetMultiplayerPeer） | ⬜ 仅预留结构 + TODO |
| 阶段 4 | 初音未来模型导入与动画替换 | ⬜ 仅预留目录 + 文档 |

---

## 二、快速开始

1. 安装 **Godot 4.3 或更高版本**（本项目在 **Godot 4.7.2 stable** 上验证通过；用旧版打开时若提示升级项目版本，按提示继续即可）。
2. 用 Godot 打开本目录下的 `project.godot`。
3. 按 **F5** 运行。

命令行验证（无需打开编辑器）：

```powershell
# 只导入资源并检查是否有解析/导入错误
godot --headless --path . --import

# 无窗口跑 300 帧，检查运行时错误
godot --headless --path . --quit-after 300
```

### 操作说明

| 按键 | 功能 |
| --- | --- |
| `W` `A` `S` `D` | 前后左右移动 |
| 鼠标移动 | 转动视角（第三人称轨道相机） |
| `Shift` | 加速跑 |
| `Space` | 跳跃 |
| **鼠标左键** | **射击（全自动，700 发/分）** |
| **鼠标右键** | **开镜（ADS：FOV 75→55、灵敏度降低、移动变慢、扩散变小）** |
| **`R`** | **换弹（2.1 秒，打空后自动换弹）** |
| `Esc` | 释放鼠标（暂停锁定）；释放后点击画面重新锁定 |
| `N` / `P` | 下一首音乐 / 暂停继续 |

### 场景里有什么

- 50×50 地面 + 10 个柱体方块（看光影反射用）。
- **3 个橙色训练靶**（`Targets/TargetA~C`）：可被击毁、4 发制命（25 伤害 × 100 血）、受击闪白、3 秒后自动复活。
  它们不是敌人 AI，只是阶段 2 用来验证命中反馈 / 击杀日志 / 小地图的占位目标。
- **2 个青色队友占位**（`Allies/SquadmateA/B`）：用来验证屏幕边缘队友图标与队友小地图标记。

---

## 三、项目结构

```text
MikuHighQualityWalk/
├── project.godot                          # 项目设置：项目名 / Forward+ / TAA / 输入映射 / Autoload
├── scenes/
│   ├── main.tscn                          # 主场景：Environment + 平行光 + 地面 + 柱体 + 反射探针 + 训练靶 + 队友 + Player + HUD
│   ├── player.tscn                        # 玩家：移动体 + 占位胶囊 + 武器 + 摄像机链
│   ├── weapons/
│   │   └── rifle.tscn                     # ✅ 占位步枪（方块枪身 + 枪口火光 + 3D 音源 + weapon.gd）
│   ├── hub/                               # 【阶段 3 预留】战术地图 / 小队 / 兵种 / 出生点 Hub
│   └── ui/
│       └── hud.tscn                       # ✅ HUD：准星 / 小地图 / 指南针 / 队友图标 / 血条 / 弹药 / 击杀日志
├── scripts/
│   ├── player.gd                          # ✅ 移动 / 视角 / 跳跃 / 生命值 / 开镜状态 / 驱动后坐力与摇晃
│   ├── music_manager.gd                   # ✅ Autoload：扫描 music/ 下的 .ogg，N/P 控制
│   ├── entities/
│   │   └── training_target.gd             # ✅ 训练靶（阶段 2 数据源，将来换成真正的敌人）
│   ├── shooting/
│   │   ├── weapon.gd                      # ✅ 射击流程：连发 / 弹匣 / 换弹 / ADS / hitscan / 曳光弹 / 命中反馈
│   │   ├── recoil_system.gd               # ✅ 三层后坐力：视觉后坐力 + 弹道偏移模式 + 扩散值
│   │   ├── camera_sway.gd                 # ✅ 相机摇晃：鼠标惯性滞后 + 行走晃动 + 侧倾
│   │   ├── screen_shake.gd                # ✅ 屏幕震动：Trauma / FastNoiseLite 噪声
│   │   └── audio_3d.gd                    # ✅ 3D 枪声：音高/音量 ±5% 随机 + 程序化占位枪声
│   ├── ui/
│   │   ├── hud.gd                         # ✅ HUD 根：信号绑定与数据分发
│   │   ├── crosshair.gd                   # ✅ 动态准星（扩散缩放 / 命中标记 / 换弹环）
│   │   ├── minimap.gd                     # ✅ 小地图（_draw()：障碍物 / 敌我 / 视野扇形 / N 标记）
│   │   ├── compass.gd                     # ✅ 顶部指南针（N/E/S/W + 刻度）
│   │   └── teammate_icons.gd              # ✅ 队友图标（3D 投影 + 贴边）
│   └── network/
│       └── network_manager.gd             # 【阶段 3 预留】ENet 主机/客户端占位
├── assets/
│   ├── environments/
│   │   └── high_quality_environment.tres  # ✅ 高画质 Environment（SDFGI/SSAO/SSR/Glow/ACES/体积雾）
│   └── models/miku/                       # 【阶段 4 预留】把 miku.glb 放这里
├── music/
│   └── README.md                          # ✅ 歌单目录说明（把你的 .ogg 放这里）
└── README.md
```

---

## 四、高画质渲染配置

渲染后端：**Forward+**（`rendering/renderer/rendering_method="forward_plus"`）。

### Environment 参数（[high_quality_environment.tres](assets/environments/high_quality_environment.tres)）

| 类别 | 参数 | 值 |
| --- | --- | --- |
| Background | Background Mode / Material | Sky / `ProceduralSkyMaterial`（无 HDR 素材时的回退） |
| Ambient | Source / Energy | Sky / 1.0 |
| Tonemap | Mode / Exposure / White | **ACES** / 1.0 / 6.0 |
| Glow | Enabled / Bloom / HDR Threshold | ✅ / 0.2 / 0.9 |
| SSAO | Enabled / Radius / Intensity / Light Affect | ✅ / 0.5 / 2.0 / 1.0 |
| SSR | Enabled / Max Steps | ✅ / 64 |
| SDFGI | Enabled / Cascades / Min Cell Size / Bounce Feedback | ✅ / 4 / 0.2 / 0.5 |
| Volumetric Fog | Enabled / Density | ✅ / 0.01 |

### 换成 HDR 天空（推荐）

1. 下载一张 `.hdr` 全景图（例如 [Poly Haven](https://polyhaven.com/hdris) 的 CC0 素材）。
2. 用 Godot 打开 `assets/environments/high_quality_environment.tres`。
3. 把 `Sky` 资源的 `Sky Material` 从 `ProceduralSkyMaterial` 改成 `PanoramaSkyMaterial`，拖入 `.hdr`。
4. （可选）把 `Sky.process_mode` 设为 `Realtime`。

### 抗锯齿 / 性能

- **已开启 TAA**，**已关闭 MSAA**；8x 各向异性过滤；Jolt Physics。
- **FSR 2.2（可选）**：帧率不够时在 `项目设置 → Rendering → Scaling 3D` 里选 `FSR 2.2`、`Scale 0.77`
  （或取消注释 `project.godot` `[rendering]` 段的 `scaling_3d/mode=2` 与 `scaling_3d/scale=0.77`）。
- Windows 默认走 **D3D12** 驱动；如遇兼容问题，删掉 `project.godot` 里的 `rendering_device/driver.windows` 一行即可回退 Vulkan。

---

## 五、音乐系统（本地歌单）

`scripts/music_manager.gd` 作为 **Autoload**（`MusicManager`）随游戏自动加载，启动即播放。

1. 把 `.ogg` 歌曲文件放进 `music/` 目录。
2. 重启游戏（Godot 需要先导入音频资源）。
3. `N` 下一首，`P` 暂停 / 继续。默认音量 **-6 dB**。

细节、格式转换（ffmpeg 命令）、顺序/随机/循环切换见 **[music/README.md](music/README.md)**。

---

## 六、HUD 与射击手感（阶段 2）

### 6.1 HUD 元件

| 屏幕位置 | 元件 | 实现 | 数据来源 |
| --- | --- | --- | --- |
| 中心 | 动态准星 | `crosshair.gd` | `RecoilSystem.get_spread()` → 间距 5→34 px；开镜收缩；命中标记；换弹进度环 |
| 左上 | 小地图 | `minimap.gd`（`_draw()`） | 玩家 `player` 组、摄像机 `camera` 组、`enemy`/`friendly` 组、`minimap_obstacle` 组的 BoxShape3D |
| 顶部 | 指南针 | `compass.gd`（`_draw()`） | 摄像机偏航角（-Z 为北、+X 为东） |
| 屏幕边缘 | 队友图标 | `teammate_icons.gd` | `friendly` 组，3D 投影 + 出屏贴边，显示名字与距离 |
| 底部中央 | 生命值 | `hud.gd` | `PlayerController.health_changed` 信号 |
| 右下 | 弹药 / 装备 | `hud.gd` | `Weapon.ammo_changed` / `reload_*` 信号 |
| 右上 | 击杀日志 | `hud.gd` | `Weapon.hit_confirmed` 信号（击杀时写入，4.5 秒淡出） |

HUD 与游戏逻辑**不做硬引用**，全部通过场景组（`player` / `weapon` / `recoil` / `camera` / `enemy` / `friendly`）
与信号连接，方便后续联机时替换或增加数据源。HUD 已实例化在 `main.tscn` 中。

### 6.2 三层后坐力（[recoil_system.gd](scripts/shooting/recoil_system.gd)）

摄像机链：
`CameraPivot(鼠标 yaw) → RecoilPivot(后坐力) → SwayPivot(摇晃) → SpringArm3D(鼠标 pitch) → Camera3D(屏幕震动)`
各层只写自己的节点变换，互不干扰（叠加关系）。

| 层 | 作用 | 关键参数（默认值） |
| --- | --- | --- |
| 1 · 视觉后坐力 | 每发瞬时上抬 + 随机左右抖动，快速 lerp 归零 | `visual_kick_pitch 0.55°`、`visual_kick_yaw 0.22°`、`visual_recovery 14` |
| 2 · 弹道偏移模式 | 固定可学习的喷射弹道：先垂直爬升再左右漂移，停火后归零 | `pattern_length 30`、`pattern_kick_start 0.22°`、`pattern_kick_end 0.5°`、`pattern_side_kick 0.3°`、`pattern_seed 20260930` |
| 3 · 扩散值 | 连射/移动增大、开镜/静止减小；同时驱动**准星大小**与**实际弹道随机散布** | `base_spread 0.12`、`per_shot_spread 0.16`、`spread_recovery 3`、`ads_spread_scale 0.4`、`move_spread 0.45`、`spread_deg_max 3.6°` |

手感要点：

- 第 3 层用**指数收敛**（`lerpf(_spread, target, 1-exp(-k·dt))`），停火后先快后慢地回正。
- 开镜时**每发增量也乘 `ads_spread_scale`**，所以连射时开镜明显更精准（腰射平衡值约 0.74，开镜约 0.30）。
- 弹道模式用固定种子生成，**同一把枪每一轮喷射弹道一致**，可以像战地/CS 那样背弹道。
- 后坐力直接作用在摄像机旋转上：开枪会真的把镜头顶起来，需要手动压枪。

调参入口：在 Godot 里选中 `scenes/player.tscn → CameraPivot/RecoilPivot`，Inspector 里改 `RecoilSystem` 的导出参数，运行时立刻生效。

### 6.3 相机摇晃 / 屏幕震动 / 3D 音效

| 系统 | 文件 | 说明 |
| --- | --- | --- |
| 相机摇晃 | [camera_sway.gd](scripts/shooting/camera_sway.gd) | 鼠标转动的惯性滞后（转动带拖尾、停下缓慢回正）+ 行走上下晃动 + 横向移动侧倾；接口与 DampedSprings 插件兼容，替换实现即可 |
| 屏幕震动 | [screen_shake.gd](scripts/shooting/screen_shake.gd) | Trauma 系统：`add_trauma()` 累加，幅度 = trauma²，用 `FastNoiseLite` 采样平滑噪声驱动 `h_offset / v_offset / roll`（不是简单随机抖动） |
| 3D 音效 | [audio_3d.gd](scripts/shooting/audio_3d.gd) | `AudioStreamPlayer3D` 播放，每发音高 ±5%、音量 ±5% 随机；**枪声是程序化合成的占位音**（噪声爆音 + 低频冲击 + 余响），换成真实 `.ogg` 采样只需替换 `_build_gunshot()` |

### 6.4 武器（[weapon.gd](scripts/shooting/weapon.gd)）

| 参数 | 默认值 |
| --- | --- |
| 射速 / 模式 | 700 发/分 · 全自动 |
| 伤害 / 射程 | 25 · 200 米 hitscan |
| 弹匣 / 备弹 / 换弹 | 30 / 120 / 2.1 秒（打空自动换弹） |
| 开镜 | FOV 75 → 55，灵敏度 ×0.6，移动 ×0.55 |
| 特效 | 枪口火光 + 曳光弹 + 弹着点火花 + 命中/击杀标记 |

> 武器模型是 `scenes/weapons/rifle.tscn` 里的方块占位。替换真实模型时保留
> `Muzzle` / `MuzzleLight` / `MuzzleFlash` / `GunAudio` 四个节点与 `weapon.gd` 挂载即可。

---

## 七、替换初音未来模型（阶段 4）

1. 准备 `.glb` 模型（Mixamo 自动绑定或自己 K 帧）。
2. 放到 `assets/models/miku/miku.glb`。
3. 打开 `scenes/player.tscn`，选中 **`MikuModel`**，把 `Mesh` 换成 `miku.glb` 生成的
   `MeshInstance3D`（含 `Skeleton3D`）；武器 `Rifle` 保持为 `MikuModel` 的子节点即可继续跟着手部位置。
4. **模型正面请朝 +Z**（`player.gd` 按 +Z 作为正面转向；若模型朝 -Z，给模型节点加 `rotation.y = PI`）。
5. 动画：加 `AnimationPlayer`，在 `player.gd` 里按速度切换 Idle / Walk / Run / Jump。
6. **关闭 MMD 物理**（头发/裙摆刚体、关节），否则容易掉帧。

---

## 八、后续阶段预留结构与 TODO

### 阶段 3：局域网联机（蓝盾 VPN）

- `scripts/network/network_manager.gd` 已预留，计划用 `ENetMultiplayerPeer`：
  - 主机：`peer.create_server(PORT, MAX_CLIENTS)`，端口建议 `7777`。
  - 客户端：`peer.create_client("26.x.x.x", PORT)`。
  - 玩家位置 / 旋转：`MultiplayerSynchronizer`；射击事件：`@rpc("any_peer", "call_local", "reliable")`。
- `scenes/hub/` 预留：战术地图 / 小队 / 兵种 / 出生点 Hub。

**蓝盾 VPN 使用步骤（阶段 3 联机时）**

1. 双方都安装蓝盾 VPN 客户端。
2. 其中一方创建虚拟局域网（网络），把朋友拉进来。
3. 朋友加入该网络，双方获得 `26.x.x.x` 网段的虚拟 IP。
4. **主机**在游戏里点“创建房间”，并把自己的 **26 开头 IP** 复制发给朋友。
5. **客户端**在游戏里输入这个 IP + 端口（默认 `7777`）后连接。
6. 连不上时排查：蓝盾是否显示已连接、Windows 防火墙是否放行 Godot、双方网段是否一致。

### 阶段 2 剩余的 TODO

- **武器模型**：用真实枪械模型替换 `rifle.tscn` 的方块（保留 `Muzzle` 等节点）。
- **枪声素材**：用真实 `.ogg` 枪声替换 `audio_3d.gd::_build_gunshot()` 的程序化占位音。
- **角色持枪姿态**：目前腰射时枪口朝人物移动方向（开镜时才跟随视角），后续可做上半身朝向混合。
- **伤害来源**：`PlayerController.take_damage()` 已实现并会触发屏幕震动与血条更新，但场景里暂时没有会还击的敌人。
- **相机摇晃增强**：可接入 DampedSprings 插件做二阶弹簧版惯性。
- **小地图增强**：地形贴图（SubViewport）、缩放档位、只在被发现时显示敌人。

### 阶段 4：初音未来模型

见上一节。

---

## 九、验证记录

使用本机 Godot **4.7.2 stable** 命令行实测。

### 阶段 1（13 项）

| 项目 | 结果 |
| --- | --- |
| `godot --headless --path . --import` 无错误 | ✅ |
| `--quit-after` 运行无脚本错误 | ✅（仅“music/ 无歌”提示） |
| 12 个输入动作匹配（`InputMap.event_is_action`） | ✅ 全部 |
| Environment 11 项参数（Sky/ACES/Glow/SSAO/SSR/SDFGI/体积雾） | ✅ 全部生效 |
| 主场景结构（阴影 Parallel 4 Splits、ReflectionProbe Once、Props 20 子节点） | ✅ |
| 第三人称相机在玩家身后 `(0, 1.6, 3.5)` | ✅ |
| 音乐：扫描 / 播放 / -6 dB / 暂停 / N 切歌 / 播完自动下一首 | ✅（用真实 .ogg 验证） |
| 音乐：无歌 / 坏文件时只警告不崩溃 | ✅ |

### 阶段 2（34 项）

| 项目 | 结果 |
| --- | --- |
| HUD 接入主场景、7 个元件齐全、信号绑定成功 | ✅ |
| 初始弹匣/血量显示与数据一致 | ✅ |
| 小地图收集 10 个障碍物；坐标换算（正前方在上、东侧在右） | ✅ |
| 敌人（3 训练靶）/ 队友（2 占位）数据源存在 | ✅ |
| 按住左键连发：0.9 秒 11 发（700 RPM ≈ 10 发） | ✅ |
| 开火消耗弹药 + HUD 弹药同步 | ✅ |
| 第 3 层：连射使扩散值升到 0.73，准星同步张开 | ✅ |
| 第 1/2 层：镜头被顶起（pitch ≈ 3.6°、yaw ≈ 5.6°）+ RecoilPivot 旋转生效 | ✅ |
| 屏幕震动 trauma 升到 0.98 | ✅ |
| 枪声音高随机化在 ±5% 内（实测 0.956 / 1.028） | ✅ |
| 开镜：FOV 75 → 55、玩家进入瞄准态、扩散 0.73 → 0.11 | ✅ |
| 换弹：R 触发、进度条显示、完成后弹匣补满（30）、备弹扣减、进度条隐藏 | ✅ |
| 停火后扩散回落至基础值 0.12 | ✅ |
| 命中训练靶：4 发击杀（hp=0、alive=false）、击杀日志 +1 条 | ✅ |
| 指南针随视角转动（朝北 0° → 朝东 90°） | ✅（含 ±2° 容差） |

**未能在 headless 验证的部分**（需要真实窗口）：

- `_draw()` 的实际观感：小地图、指南针、准星、队友图标的视觉效果（headless 无渲染后端时队友图标会主动跳过绘制）。
- 帧率：请在本机 F5 后看 `调试 → 监视器 → FPS`，不够时按第四节开 FSR 2.2 或关 SDFGI。
- 音效听感：程序化枪声的实际音色与 3D 衰减。

> 验证用的临时脚本已在验证完成后删除，仓库里只留项目文件。

---

## 十、当前迭代完成状态

### 阶段 1

- [x] `project.godot`：项目名、Forward+、TAA 开 / MSAA 关、主场景、Autoload、输入映射
- [x] `scenes/main.tscn`：WorldEnvironment + 阴影平行光 + 50×50 地面 + 10 个柱体 + ReflectionProbe(Once) + Player
- [x] `scenes/player.tscn`：CharacterBody3D + 胶囊 + 占位模型 + SpringArm3D(3.5)
- [x] `scripts/player.gd`：WASD / 鼠标视角 / Shift / Space / Esc
- [x] `scripts/music_manager.gd`：Autoload、扫描 `music/*.ogg`、N/P 控制、-6 dB
- [x] `assets/environments/high_quality_environment.tres`
- [x] `README.md`、`music/README.md`、预留目录全部就位

### 阶段 2

- [x] `scenes/ui/hud.tscn` + `scripts/ui/*.gd`：动态准星、小地图、生命值、弹药与装备、击杀日志、指南针、队友图标
- [x] HUD 接入 `main.tscn`，信号与场景组解耦
- [x] `scripts/shooting/recoil_system.gd`：三层后坐力（视觉 / 弹道模式 / 扩散），lerp 平滑恢复
- [x] `scripts/shooting/camera_sway.gd`：惯性平滑 + 行走晃动 + 侧倾
- [x] `scripts/shooting/screen_shake.gd`：Trauma + Noise 屏幕震动
- [x] `scripts/shooting/audio_3d.gd`：3D 枪声 + 音高/音量 ±5% 随机
- [x] `scripts/shooting/weapon.gd` + `scenes/weapons/rifle.tscn`：连发 / 弹匣 / 换弹 / 开镜 / hitscan / 曳光弹 / 命中反馈
- [x] `scripts/entities/training_target.gd`：训练靶（可击毁 + 自动复活，供 HUD / 手感验证）
- [x] 输入映射 `shoot` / `aim` / `reload` 已接入（阶段 1 预留的动作现在生效）

### 验收标准

- [x] 战地 5 风格 HUD：动态准星、小地图、生命值、弹药、击杀日志、指南针、队友图标
- [x] 三层后坐力：视觉后坐力 / 弹道偏移模式 / 扩散值，同时作用于摄像机与准星
- [x] 动态准星随扩散缩放；相机摇晃；Trauma/Noise 屏幕震动；3D 音效（音高音量 ±5% 随机）
- [x] 联机 / Hub / 初音模型位置已预留
- [ ] 1080p 中端 GPU 60 FPS（需在真实 GPU 上确认）
- [ ] 真实观感与手感需在本机 F5 体验后微调参数

---

## 十一、已知限制

- 占位角色是胶囊体，没有动画；武器是方块占位；没有敌人 AI、胜负与关卡设计。
- 腰射时枪口跟随人物朝向（移动方向），只有开镜时才完全跟随视角。
- 训练靶只会挨打不会还击，所以血条暂时不会掉（`take_damage()` 接口已就绪）。
- `music/` 只在启动时扫描一次，运行中加歌需要重启；`reload_playlist()` 已备好接口。
- 反射探针为 `Once` 模式，场景静态物体变化后需要手动重新烘焙。