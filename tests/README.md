# 测试框架（tests/）

> **Task ID**：E4-01 ｜ **作者**：程基岩（Cheng Jiyan）· 工程负责人 ｜ **状态**：draft
> **定位**：本项目的**回归基线**——把 GDD 的验收条款（AC-*）与「改代码时必须保持的不变量」变成可 `headless` 重跑的断言。
> **关联**：`design/gdd/03_map_encounter.md §6`（AC-1/AC-2）、`04_ux_flow.md §6.4`（AC-F1~F5）、
> `docs/architecture/control_checklist.md §4`（关键不变量）、`docs/architecture/adr/ADR-007`、`production/epics/`。

---

## 1. 怎么跑

**必须用「测试场景 + Runner 节点」运行**（不是 `-s`），因为 Autoload 只有在普通场景运行时才注册：

```bash
# ⚠️ --import 只在「类缓存不存在」时才需要（首次 / 清过 .godot 后）。
#    它会走编辑器代码路径、可能删掉 project.godot 的 Vulkan 锁（已复发 6 次，见 control_checklist §4-17）。
#    缓存已在时**直接跑第二步**；若确实跑了 --import，用后必须 grep 复核该锁还在。
"C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe" --headless --path . --import

# 跑测试场景（日常只需这一步）
"C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe" --headless --path . res://tests/test_runner.tscn
```

**出口码**（统一约定，供 CI / 脚本判定）：

| 出口码 | 含义 |
| --- | --- |
| `0` | 全部通过（**含 pending 跳过**——跳过不算失败） |
| `1` | 存在失败用例 |

**输出样例**（E4-01 实测）：

```
=================== sekai 测试汇总 ===================
  ✓ test_spawn_points（5 用例 / 23 断言）
  ✓ test_minimap_radius（4 用例 / 4 断言）
  ○ PENDING  test_damage_routing（依赖未就绪，本次跳过）
  ✓ test_invariants（7 用例 / 25 断言）
-----------------------------------------------------
用例 16 ｜ 断言 52 ｜ 失败 0 ｜ pending suite 1
=================== PASS ===================
```

> **⚠ 已知无害噪音**：退出时会打印 `WARNING: 4 ObjectDB instances were leaked at exit` / `ERROR: 2 resources still in use at exit`。
> 这是 **Godot 4.7.2 引擎关机期的既有告警**，与本框架无关——用未经改动的 `res://scenes/hub/hub.tscn` 跑 `--quit-after 10` 会**一模一样**地复现。
> 判定优先级：**先看 `=================== PASS/FAIL ===` 与出口码**，不要被这条噪音误导。
>
> **⚠ 为什么不用 `-s`（`--script` 直接跑 SceneTree 脚本）**：`-s` 模式下 **Autoload 不注册** →
> 引用 `NetworkManager` / `MusicManager` 的脚本会编译失败。用普通场景运行本 `.tscn` 才会正常注册 Autoload（本项目踩过的坑）。

---

## 2. 目录结构

```
tests/
├── test_runner.tscn          # 入口场景（根节点挂了 test_runner.gd）
├── framework/
│   ├── test_suite.gd         # 基类 TestSuite：断言 + 生命周期钩子
│   └── test_runner.gd        # Runner：反射收集用例、汇总、置出口码
├── suites/
│   ├── test_spawn_points.gd      # AC-1  出生点四角分散
│   ├── test_minimap_radius.gd    # AC-2  小地图半径 ≥ 56.6
│   ├── test_damage_routing.gd    # AC-F2/AC-A3b  FFA 伤害路由（pending）
│   └── test_invariants.gd        # 关键不变量回归（换弹/双闸门/后坐力/皮肤）
└── README.md                 # 本文件
```

---

## 3. 怎么写新用例

### 3.1 一个 suite = 一个 `extends TestSuite` 的脚本

- **用例** = 方法名以 `test_` 开头、**无参数、返回 void** 的普通方法；Runner 用 `get_method_list()` 反射收集并**按名排序**（顺序稳定）。
- **断言失败只记录、不中断**：一个 suite 会跑完全部用例再汇总（对齐「回归基线」用法）。
- 需要**异步 / 多帧**的用例？本框架的用例是**同步调用**的——不要 `await`。需要多帧的先 `add_child()` 再手动调 `_process(dt)`。

```gdscript
extends TestSuite

const WEAPON_SRC := "res://scripts/shooting/weapon.gd"

func test_something() -> void:
	# 断言 API：check_true / check_false / check_eq / check_ge / check_le / check_near
	check_ge(60.0, 56.6, "半径应覆盖对角半长")
	check_eq(4, 4, "数量应为 4")
```

### 3.2 可用的断言与钩子（`framework/test_suite.gd`）

| 成员 | 作用 |
| --- | --- |
| `check_true/check_false(cond, msg)` | 布尔断言 |
| `check_eq(actual, expected, msg)` | 相等（Variant） |
| `check_ge/check_le(actual, bound, msg)` | 大小比较（float） |
| `check_near(actual, expected, tol, msg)` | 近似相等（float） |
| `fail(msg)` | 直接记一次失败 |
| `pending(reason)` | 记一条「跳过说明」（**不算失败**） |
| `before_each()/after_each()` | 每用例前 / 后钩子（重写） |
| `is_pending() -> bool` | 重写为 `true` → **整个 suite 跳过**、不计失败（用于「依赖尚未实现」） |

### 3.3 两类断言的取舍（**重要**）

| 类型 | 何时用 | 例子 |
| --- | --- | --- |
| **行为断言** | 依赖少、能独立实例化的节点 | `RecoilSystem.new()` → `fire_shot()` → 验 `rotation`；`WeaponSkin.apply_to()` 验 `material_override` |
| **契约锁（源码结构断言）** | 耦合过重（需完整场景/相机/音频/网格） | 读 `weapon.gd` 文本，断言「屏蔽分支里仍有 `_update_reload(delta)`」 |

**为什么要有契约锁**：像「换弹计时在输入屏蔽期间继续走」这种不变量，其载体 `weapon.tscn` 的 `_process` 会访问 camera/audio/muzzle，headless 独立实例化会空引用崩。
契约锁用**源码文本断言**锁住「守卫调用仍在」，防止被误删；它**只防误删、不验运行时行为**——因此每条契约锁都在注释里写明「为什么不用行为断言」。新增契约锁时**请沿用这个注释约定**。

### 3.4 读源码 / 读场景的姿势（避免踩坑）

```gdscript
# 读源文本（FileAccess 出作用域自动关闭）
func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()

# 读场景结构：instantiate **但不要入树**（不触发任何 _ready → headless 零副作用）
var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
var root: Node = scene.instantiate()
var v: Vector3 = (root.get_node("SpawnPoints/Spawn1") as Marker3D).position
root.free()
```

### 3.5 新增 suite 的登记

在 `framework/test_runner.gd` 的 `SUITE_SCRIPTS` 数组里**追加路径**即可：

```gdscript
const SUITE_SCRIPTS: Array[String] = [
	"res://tests/suites/test_spawn_points.gd",
	// 新增：
	"res://tests/suites/test_score_manager.gd",
]
```

---

## 4. 当前覆盖（E4-01）

| suite | 覆盖 | 出处 | 状态 |
| --- | --- | --- | --- |
| `test_spawn_points` | AC-1：4 点 `|x|,|z|=32`、任意两点 ≥45、边界内 ≤40 | `03_map §6 AC-1` / C-8 | ✅ 通过（5 用例 / 23 断言） |
| `test_minimap_radius` | AC-2：`world_radius ≥ 56.5686`（当前 60） | `03_map §6 AC-2` / C-5 / ⚑M-5 | ✅ 通过（4 / 4） |
| `test_damage_routing` | AC-F2 / AC-A3b：FFA 伤害路由与显示分组解耦 | `04_ux §6.4` / `accessibility §7` / C-16 | ⏳ **pending**（待 EP-2） |
| `test_invariants` | 换弹计时续走 / `input_blocked` 双闸门 / 三层后坐力写入范围 / `apply_to` 重套皮肤 | `control_checklist §4` / `README §8.1` / ADR-003 | ✅ 通过（7 / 25） |

**当前合计**：16 用例 / 52 断言 / 0 失败 / 1 pending suite。

### 4.1 尚未覆盖（记入待办，随 EP 推进补齐）

- **AC-F1 / AC-F3~F5**（FFA 无绿色友军 / 色盲形状 / 明度差 / 第二线索）——多为**截图型断言**，需要渲染后端，headless 下先不做，留待视觉回归（`tools/capture_acceptance.gd` 方向）。
- **ScoreManager 计分 / 胜负判定**（15 杀 / 5 分钟 / 平分）——待 EP-3 落地后新增 `test_score_manager.gd`（`01_core_loop 附录 A` 已给出可测契约）。
- **手雷伤害路由**（C-3，local-only 不一致）——待 EP-5 修复后新增。
- **GPU 相关路径**（皮肤贴图生成 ≥256²）——依赖渲染后端，暂不纳入 headless 基线。

---

## 5. 技术选型：为什么自研轻量 harness，而不用 GUT / gdUnit4

| 维度 | 自研 harness（✅ 本方案） | GUT / gdUnit4 |
| --- | --- | --- |
| **依赖** | 零第三方依赖，纯源码运行 | 需引入插件（`addons/`），plugin 需在 `project.godot` 启用 |
| **与 `--import` 的兼容** | 无插件注册，导入零风险 | 插件脚本会被 `--import` 全量解析，配置不当会拖垮导入 |
| **本仓库现实** | 单人、源码运行、无 CI、`--headless` 直跑 | 面向有 CI/多项目复用的团队 |
| **warnings-as-errors** | 框架代码极小、可全量静态类型化 | 第三方代码可能触发本仓的严格告警 |
| **能力** | 覆盖本项目所需（断言 + pending + 反射收集 + 统一出口码） | 能力更强（mock/参数化/报告），但本项目暂不需要 |

**结论**：在「单人 + 源码运行 + 无 CI + 严格告警」的约束下，自研 harness 以**零依赖、零导入风险、全静态类型**胜出；
若未来接入 CI 或需要 mock/覆盖率，再评估迁移 gdUnit4（suite 结构可平移）。

---

## 6. 变更记录

| 日期 | 变更 | 作者 |
| --- | --- | --- |
| 2026-10-06 | 初版：框架 + 首批 4 个 suite（16 用例 / 52 断言）；确立「测试场景 + Runner」与统一出口码 | 程基岩（E4-01） |
