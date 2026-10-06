# 05 · 规则配置化与玩家属性规格（Rule Config Spec）

> **Task ID**：D2-04｜ **作者**：文策渊（Vince Coyer）· 设计策略师 ｜ **状态**：draft（待工程侧实现）
> **上游依赖**：`design/gdd/01_core_loop.md` §4 / §5 / **附录 A.3/A.4/A.5/A.6**、`design/gdd/04_ux_flow.md` §3.1/§3.2、`design/gdd/99_consistency_review.md`（C-1 / C-3 / C-12）、`docs/architecture/control_checklist.md` §4、`docs/architecture/adr/ADR-006` / `ADR-007` / `ADR-008`、`scripts/game/score_manager.gd`、`scripts/player.gd`、`scripts/shooting/weapon.gd`、`scripts/ui/scoreboard.gd`、`scripts/main.gd`
> **本规格的读者**：`engineering-lead`（程基岩）。本文**只定义结构与流程，不含实现代码**；所有字段名/ 类型 / 方法签名均可直接落到 GDScript 语法。
> **基线**：S2 ·185 用例 / 716 断言 / 0 失败。本规格的实现**不得回退**任何一条既有关闭判据（见 §7）。

---

## 0. 一句话结论（先读这段）

| 项 | 结论 |
| --- | --- |
| **配置形态** | **混合式**：`Dictionary` 作**配置真值与传输格式** + `RefCounted` **规则对象**作求值器 + **注册表**作扩展点。**不用 `Resource`**（理由见 §1.3）。 |
| **胜负判定归属** | **不变**。仍在 `ScoreManager`（A.6 铁律），规则引擎是它内部的**纯逻辑子模块**，不新增第二个判定口径。 |
| **本期落地** | 条件类型**2 个真实现**（`kill_target` / `time_limit`）+ **3 个注册表占位**（`score_target` / `collect_items` / `defeat_boss`，注册但判定返回"不可用"）。属性**7 项**接入。 |
| **本期不做** | 回合 / 波次 / 道具 / Boss / 队伍 —— **项目均无对应系统**，强行实现即空壳（详见 §8）。 |
| **契约冲突** | **发现 2 处必须标红的冲突**（`max_health` 与 ADR-008 对撞、`score` 第三字段与结算冻结冲突），均已给替代方案，见 §6.3。 |

> **⚠️ 本文与用户原始需求的一处诚实修正**：用户列的5 种条件里，有 **3 种在本项目当前没有任何支撑系统**（回合 / 道具 / Boss）。把它们写成"可配置的条件类型"很容易，做成"能跑的条件"需要先有对应玩法系统。本规格的处理是：**注册表留位 + 显式不可用态**，而不是写一个永远返回 `false` 的假条件。理由见 §3。

---

## 1. 配置结构设计

### 1.1 为什么是「混合式」——三种形态的取舍

用户要求"可配置、可自由组合、与核心战斗逻辑解耦、方便后续扩展"。这四点同时成立时，三种候选形态的取舍如下。

#### 形态 A：纯字典配置（`Dictionary` + JSON / `.tres`）

| 维度 | 评价 |
| --- | --- |
| 灵活性 | ✅ 最高。任意键值、任意嵌套，无需改类。 |
| 类型安全 | ❌ **无**。`cfg["targt_kills"]`（拼错）与 `cfg["target_kills"]` 在GDScript 里**都是合法读取**，只是都返回 `null` → 静默退化成"阈值为 null"，条件永远不成立。**这类错误编译期不报、运行期不炸、表现为"规则没生效"**。 |
| 传输（RPC） | ✅ **决定性优势**。`Dictionary` 可直接作 `@rpc` 载荷跨端传输。 |
| 可测试性 | ✅ 优秀。纯数据结构，headless 直接构造断言，无需引擎特性。 |
| 扩展成本 | ✅ 新增条件 = 加一个键。**但判定逻辑总得有地方写** → 逻辑若写在 `if/elif` 链里，加第6 种条件就要改判定函数本体，扩展性收益归零。 |

#### 形态 B：`Resource` 子类（自定义 `.tres`）

| 维度 | 评价 |
| --- | --- |
| 编辑器友好 | ✅ 最好。Inspector 面板、类型下拉、内置校验。 |
| 类型安全 | ⚠️ **部分**。字段名由 `@export` 固定（比裸字典好），但 `params: Dictionary` 那层仍是裸字典，**类型安全在真正需要它的地方（每个条件的阈值）依然是空的**。 |
| 传输（RPC） | ❌ **决定性劣势**。`Resource` 是**引用型资源对象**，跨端不能按值传输。要同步只能传 `resource_path` 字符串 → 于是"配置"退化成"两端必须装同一个 `.tres` 文件且版本一致"，联机版本错配即静默行为不一致。 |
| 项目现状 | ⚠️ **全项目 0 个 `Resource` 子类**（已核对 `grep -rn "extends Resource" scripts/` 无结果）。这是**引入全新范式**，不是延续既有取舍。 |
| headless 测试 | ⚠️ 可测，但要`load()` 资源文件，测试与磁盘文件耦合（改配置即改测试环境）。 |
| 扩展成本 | ⚠️ 新增字段**必须改类**；新增条件类型要新增子类 + 改主类的`@export` 列表 → **用户明确反对的正是这一点**（"新增字段需改类"是形态 B 的固有成本）。 |

#### 形态 C：规则对象 + 注册表

| 维度 | 评价 |
| --- | --- |
| 扩展性 | ✅ 最好。加新条件 = **新增一个文件 + 一行注册**，判定函数本体**不动**（开闭原则）。 |
| 样板代码 | ❌ 最多。每种条件一个类 + 一个工厂 + 一次注册。 |
| 传输 |⚠️ 规则对象**不可跨端传输**（同 B）。**但规则对象不需要传输** —— 传输的是配置，规则对象是**每端各自从配置编译出来的本地产物**。这一点是本方案成立的关键。 |
| 纯度 | ✅ 规则对象是纯计算体（无 Node、不碰场景树）→ **天然适配本项目既定的"静态纯函数 + headless 断言"取舍**。 |

#### ✅ 裁定：混合式（A 的传输层 + C 的求值层）

```
   配置真值 / 传输          编译（每端各编一次）              求值
  ─────────────────  ──────────────────────────────  ─────────────────────
  Dictionary          ConditionRegistry.compile()      RuleSet.evaluate()
  （可 JSON 化、      （Dictionary → 规则对象树）        （纯函数、只读快照、
   可 rpc 传输、       （本地产物、不传输）                无副作用、可 headless 断言）
   headless 可构造）
```

三句话理由：

1. **传输层必须是字典** —— 联机下配置要跨端送达，`Resource`做不到按值传输，`Resource` 方案等于把"配置一致"变成"文件版本一致"，这是**把运行时问题推给打包流程**。
2. **求值层必须是对象** —— 否则"新增条件类型"就要改判定函数本体，`if/elif` 链会长到不可维护，违背用户"方便后续扩展"的诉求。
3. **两者都不污染判定口径** —— 规则对象是纯计算体，不碰 `multiplayer`、不碰场景树，符合 `control_checklist §4` 与 A.6「唯一口径在 `ScoreManager`」。

**明确不选 `Resource` 的代价**（诚实记录）：放弃 Inspector 的可视化编辑。补偿手段是 §2.6 的**配置校验器** + §9 建议的 `tools/` 预览页；若后续确实需要可视化编辑，**增量加一层 `Resource` 只作为"编辑入口"**（编辑器里编辑 → 导出为 JSON），**不改变运行时格式**。这是可后补的，不锁死。

### 1.2 完整结构定义

#### 1.2.1 `MatchRuleset` —— 规则集（配置真值，唯一权威来源）

以 `Dictionary` 表达（键名全为`String`，值类型固定）：

| 字段 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `schema_version` | int | 是 | `1` | 结构版本。解析器按此分派；不匹配即拒绝加载并回落内置默认（§3.3）。 |
| `ruleset_id` | String | 是 | `"ffa_kill15"` | 稳定标识。用于日志、保存、以及客户端确认"我拿到的是同一份配置"。 |
| `label` | String | 否 | `""` | 面向玩家的规则名（如"个人死斗 · 先到 15 杀"）。**空则 UI 不显示规则名**，不影响判定。 |
| `combine` | String | 是 | `"ANY_OF"` | 顶层组合算子。枚举：`"ALL_OF"` / `"ANY_OF"`。§5.1 定义精确语义。 |
| `conditions` | Array | 是 | `[]` | 条件列表。**声明顺序 = 求值顺序 = `decisive_condition` 的判定顺序**（§5.2）。空数组 → 永不自动结束（合法，用于"只靠显式失败条件结束"的规则）。 |
| `winner_policy` | String | 是 | `"MAX_KILLS"` | 结束瞬间**谁**算胜者。枚举见 §1.2.3。 |
| `fail_conditions` | Array | 否 | `[]` | 显式失败条件。语义恒为"任一成立即该 peer 失败"，详见 §5.4。 |
| `duration_limit` | float | 是 | `300.0` | 对局时长上限（秒）。喂给 `time_remaining` / `match_duration`。**必须 > 0**。 |
| `player_defaults` | Dictionary | 否 | `{}` | 本局玩家属性**覆盖集**（§6）。键为属性 id，仅列出与 `@export` 默认值不同的项。 |

**完整示例（当前 FFA「先到 15 杀」，与现有行为逐位等价）**：

```gdscript
# ⚠ 这是配置数据（Dictionary 字面量），不是伪代码：可直接作为
#   MatchRuleset.new({...}) 的实参，或存成 .json 后由 loader 读入。
{
	"schema_version": 1,
	"ruleset_id": "ffa_kill15",
	"label": "个人死斗 · 先到 15 杀",
	"combine": "ANY_OF",
	"winner_policy": "MAX_KILLS",
	"duration_limit": 300.0,
	"conditions": [
		{"type": "kill_target", "enabled": true, "params": {"target_kills": 15}},
		{"type": "time_limit", "enabled": true, "params": {}},
	],
	"fail_conditions": [],
	"player_defaults": {},
}
```

> **向后兼容论证**：该配置的判定结果 ≡ 现有 `_check_end_condition()`（`time_remaining <= 0` **或** `_max_kills() >= kill_target`）。逐条对照见 §7.2。

#### 1.2.2 条件条目（`conditions[]` / `fail_conditions[]` 的元素）

| 字段 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `type` | String | 是 | — | 条件类型 id，须已在 `ConditionRegistry` 注册。未注册 → 解析失败（§3.3）。 |
| `enabled` | bool | 否 | `true` | 关闭时**跳过求值**，等价于从列表移除，但**保留在配置里**（便于"临时关掉某条"而不删配置）。 |
| `params` | Dictionary | 否 | `{}` | 该类型的阈值字段。**键名由类型自己定义**，注册表会校验必填键（§2.6）。 |

#### 1.2.3 `winner_policy` 枚举

| 值 | 语义 | 现状 |
| --- | --- | --- |
| `MAX_KILLS` | `kills` 最高者胜；平局比 `deaths` 少者；仍平 → `WINNER_TIE(-2)`。 | ✅ **= 现有 `_evaluate_winner()`**，本期默认。 |
| `DECISIVE_OWNER` | 触发结束的那条条件的**归属 peer** 获胜。用于"谁先拿N 杀 / 谁先打掉 Boss"这类竞速规则。 | ⚠️ 本期**注册但不用**（`kill_target` 可支持，但 MVP 走 `MAX_KILLS` 以保行为不变）。 |
| `LAST_SURVIVOR` | 结束时仍存活者胜；全灭 → `WINNER_UNSET(-1)`。 | ❌ 需「存活状态」字段，项目当前 `scores` 不记存活（死亡即重生，⚑L-4）→ **本期不实现**。 |

### 1.3 判定结果结构 `RuleEvaluation`

规则集求值产出**一个纯数据结果**，`ScoreManager` 依它结算（**该结构是新的，不改 A.5 任何既有信号签名**）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `should_end` | bool | 是否触发对局结束。 |
| `decisive_type` | String | 触发的条件类型 id（`""` = 未结束）。 |
| `decisive_peer` | int | 归属 peer（`WINNER_UNSET = -1` = 无归属，如超时）。 |
| `failed_peers` | Array[int] | 本局失败的 peer 列表（§5.4）。 |

---

## 2. 条件类型清单

### 2.1 用户点名的 5 种 —— 逐条诚实标注支撑度

>图例：🟢 **本期可实现**｜ 🟡 **需先有支撑系统**（本期只留注册表占位）｜ ⛔ **与既有设计决策冲突**

| # | 条件 | type id | 需要的输入 | 阈值字段 | 需不需要新信号 | 支撑度 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 击杀 N 个目标 | `kill_target` | `scores[peer_id].kills`（**已有**，`score_manager.gd:107`） | `target_kills: int`（>0） | ❌ 不需要。已有 `score_changed`（A.5）驱动 | 🟢 **本期实现** |
| 2 | 存活到第 N 回合 | `survive_rounds` | 回合计数 | `target_rounds: int`（>0） | ⚠️ 需要"回合推进"事件 | ⛔ **本期不实现**，理由见 §2.2 |
| 2′ | **替代**：存活到指定时刻 | `time_limit` | `time_remaining`（**已有**，`score_manager.gd:105`） | 无（用 `duration_limit`） | ❌ 不需要 | 🟢 **本期实现**（承接现有超时逻辑） |
| 3 | 达到 N 分 | `score_target` | 独立 `score` 计数 —— **不存在** | `target_score: int` | ⚠️ 需要新增计分事件 | 🟡 **本期留占位**，理由见 §2.3 |
| 4 | 收集 N 个道具 | `collect_items` | 道具计数 —— **无道具系统** | `target_items: int`、`item_id: String`（可空 = 任意道具） | ⚠️ 需要 `item_collected(peer, item_id)` | 🟡 **本期留占位**，理由见 §2.4 |
| 5 | 击败指定 Boss | `defeat_boss` | Boss 死亡事件 —— **无 Boss 系统** | `boss_id: String` | ⚠️ 需要 `boss_defeated(boss_id, killer_peer)` | 🟡 **本期留占位**，理由见 §2.5 |

**核对依据（已 grep 全项目确认，非转述）**：

- `grep -rin "boss" scripts/` → **0 结果**（除`bomb` 误配，无Boss）。
- `grep -rin "pickup|collect|道具" scripts/` → 仅命中 `miku_model.gd` 的"舞台展示道具"（**美术含义，与玩法道具无关**）、`bot.gd::_collect_meshes()`（收集网格）。**无玩法道具系统**。
- `grep -rin "round|回合" scripts/` → 仅命中 `roundi()`（四舍五入）与 `ground_gap`。**无回合概念**。
- `grep -rin "wave|波次" scripts/` → 仅命中 `grenade_projectile.gd` 的曳光弹网格变量。**无波次系统**。
- `grep -rn "\"score\"|add_score" scripts/` → **0 结果**。项目只有 `kills` / `deaths`，**无独立 score 字段**。

### 2.2⛔ `survive_rounds`（存活到第 N 回合）—— 为什么本期不做

**用户点名的「回合」在本项目有三种可能定义，每一种都需要尚不存在的系统**：

|候选定义 | 需要什么 | 现状 |
| --- | --- | --- |
| (a) 时长换算的"回合"（`duration / rounds`） | 无新系统 | ⛔ **不采用**：这是把时间切片伪装成回合。`04_ux_flow` 全程没有回合概念，HUD 无回合显示位，玩家会看到"第 3 回合"却不知道它意味着什么 → **认知过载**（设计红线）。 |
| (b) 波次制（wave） | 波次生成器、刷怪表、波次间结算 | 🟡 `99_consistency_review` 无 wave 条目，项目无任何支撑。 |
| (c) 真回合制（objective rounds） | 回合状态机、回合间冻结/不重生、**队伍系统** | ⛔ `01_core_loop §4` 已把方案 C（回合制占点）**明确定为"愿景层"**，且**依赖尚不存在的队伍系统**。现在实现 = 提前推翻已判决策。 |

**裁定**：本期**以 `time_limit` 承接用户「存活到某个时点」的真实意图**（这是当前项目唯一诚实、且已存在的"存活到"语义 —— `time_remaining` 归零），`survive_rounds` **在注册表中保留位置但标注不可用**（§8.2）。回合制留给 `01_core_loop §4 方案 C` 的轮次，不在本轮。

### 2.3 🟡 `score_target`（达到 N 分）—— 一个真实的字段级障碍

不是"缺个计数器"那么简单。**加第三个计分字段会与结算冻结机制对撞**：

- `score_manager.gd:530 _freeze_scores()` 结算时**显式重建**条目，只保留 `{"kills":…, "deaths":…}` → **任何第三键在结算瞬间被丢弃**。
- `score_manager.gd:514_ensure_entry()` 初始化也只写两个键。
- `Scoreboard.build_rows()` / `kd_text()` 只消费 `kills` / `deaths`。

所以「独立 score」的真实成本是**改动结算冻结 + 计分条目 schema + 比分板三处**，且这三处都被既有测试覆盖（`test_score_manager.gd:118` 断言冻结语义、`test_scoreboard.gd` 52 条断言）。

**裁定**：本期 `score_target` **注册但不可用**。若用户强烈需要"达到 N 分"，**零 schema 改动的过渡方案**是：`score_target` 的求值**复用 `kills`**（配置里显式写 `"score_source": "kills"`），即"N 分 = N 击杀"，与现状同义、零风险；真正独立的分数计分（含道具/占领点加分）留到有玩法支撑时再做，且届时必须同步改`_freeze_scores`（§8.3）。

### 2.4 🟡 `collect_items`（收集 N 个道具）

需先有：道具实体（可拾取 `Area3D`）、拾取判定、道具 id 体系、**以及最关键的：跨端一致性**。当前项目是 P2P 无服务器权威（ADR-006），道具被谁捡了必须由**权威端裁定**并广播，否则两端会各自判定"我捡到了"。

### 2.5 🟡 `defeat_boss`（击败指定 Boss）

需先有完整 Boss 概念：血量权威（跨端，参照ADR-008 受害者权威模式）、AI、阶段、结算归属。**这是独立 Epic 的量级**，不是配置化能解决的。

### 2.6 参数校验（`ConditionRegistry.validate`）

每种条件类型在注册时同时登记**参数规格**，供静态校验（防§1.1 里"键名拼错静默失效"）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `required: Array[String]` | Array | 必填键。缺失 → **加载失败并回落默认**（不静默）。 |
| `optional: Dictionary` | Dictionary | 可选键 → 默认值。 |
| `numeric_positive: Array[String]` | Array | 必须为正数的键（如 `target_kills`）。`0` / 负数 → 加载失败。 |

校验失败的处理见 §3.3。**这条直接消除形态 A 的最大风险（拼错键名静默失效）**。

---

## 3. 规则注册与加载

### 3.1 注册表（静态，进程内一次性）

```
ConditionRegistry
├── register(type: String, factory: Callable, spec: Dictionary) -> void
├── compile(params: Dictionary) -> Rule            # 工厂 + 参数校验，产出规则对象
├── registered_types() -> Array[String]# 自省用，供校验/工具页
└── has_type(type: String) -> bool
```

- **注册时机**：`ConditionRegistry` 用`static var` 存表，进程启动时由一个 `register_all()` 集中注册全部内置类型。**不使用 Autoload**（与 A.1 同理：规则注册是纯数据/纯逻辑，不需要跨场景生命周期，也避免多出一个全局单例）。
- **工厂用lambda 表达式**（GDScript 原生支持）：`func(cfg: Dictionary) -> Rule: return KillTargetRule.new(cfg)`。
- **重复注册**：`register()` 遇到同名 type → 覆盖并打印警告（便于测试用替身条件做白盒验证）。

### 3.2 规则对象契约

所有条件类型继承同一基类`Rule`（`extends RefCounted`）：

| 成员 | 签名 | 语义 |
| --- | --- | --- |
| `type_id` | `String`（只读） | 条件类型 id。 |
| `evaluate(snapshot: Dictionary, peer_id: int) -> bool` | 实例方法 | **纯函数**：只看 `snapshot`，不写任何状态、不碰场景树 / `multiplayer` / 时间。 |
| `owner_of(snapshot: Dictionary) -> int` | 实例方法 | 返回"归属peer"，无归属返回 `WINNER_UNSET(-1)`。默认实现 = "第一个满足者"。 |
| `poll_mode` | `String`（只读） | `"TICK"`（每 tick 轮询）或 `"EVENT"`（可事件驱动）。见 §6.3 性能。 |

`snapshot` 字段（**求值所需的全部输入，纯数据**）：

| 键 | 类型 | 来源 | 现状 |
| --- | --- | --- | --- |
| `scores` | Dictionary | `ScoreManager.scores` | ✅ 已有 |
| `time_remaining` | float | `ScoreManager.time_remaining` | ✅ 已有 |
| `match_state` | int | `ScoreManager.match_state` | ✅ 已有 |
| `elapsed` | float | 由 `duration_limit - time_remaining` 导出 | ✅ 可导出 |
| `alive_peers` | Array[int] | **无**（§1.2.3 `LAST_SURVIVOR` 需） | 🟡 未来 |
| `collected_items` | Dictionary | **无**（需道具系统） | 🟡 未来 |
| `defeated_bosses` | Dictionary | **无**（需 Boss 系统） | 🟡 未来 |

> **设计要点**：快照**只含数据、不含节点引用**。这让条件求值天然可在headless 下用字面量 `Dictionary` 断言——延续 `Scoreboard` / `MatchResult` 的静态纯函数取舍（`control_checklist §4` 第9 条的血泪教训同源：**判定绝不能依赖"本端那份会变/不会变的副本"**）。

### 3.3 加载与失败回落（**不允许静默失败**）

```
load_ruleset(cfg: Dictionary) -> MatchRuleset
```

1. `schema_version` 不识别 → **拒绝**，回落内置默认（`ffa_kill15`），并 `push_warning`。
2. 某条件 `type` 未注册 → **拒绝整份配置**，回落默认，**跳过该条其余条件而不是当作 `false`**。
   > ⚠️ 区别很重要：把未注册条件当 `false` 会让"规则没生效"表现得像"条件没达成"，是典型的静默故障。
3. `params` 缺必填键 / 数值键非正 → 同上，回落默认。
4. 全部通过 → 编译成 `MatchRuleset`，**记下 `ruleset_id` 供跨端核对**。

> **回落而非崩溃的理由**：联机 P2P 下，一端配置坏了就崩= 房间直接炸；回落默认 = 至少 everyone 还能打完这局。但**必须 `push_warning` 且可观测**，不能默默换掉。

### 3.4 执行流程（判定链路）

```
 [配置来源]  内置默认 / .json 文件 / 权威端 RPC 下发
      │
      ▼  load_ruleset(cfg)  ← §3.3 校验 + 回落
 MatchRuleset（配置真值）
      │
      ▼  ConditionRegistry.compile()   每端各编译一次（不传输规则对象，只传配置）
 RuleSet（规则对象树 · 本地产物）
      │
      ▼  每次判定：RuleSet.evaluate(snapshot)  纯函数、无副作用
 RuleEvaluation{should_end, decisive_type, decisive_peer, failed_peers}
      │
      ▼  ScoreManager 消费（唯一口径 · A.6）
 _end_match() → 固化 winner_id → 冻结 scores → ENDED → match_ended(winner_id, final_scores)
```

**关键约束**：规则对象**只在权威端参与判定**（§6.4）；客户端拿配置只为了①显示目标文案②本地不判定。

---

## 4. 组合语义（精确规定）

### 4.1 `ALL_OF` / `ANY_OF`

| 算子 | 结果 |
| --- | --- |
| `ANY_OF` | **任一**启用条件成立 → `should_end = true`。 |
| `ALL_OF` | **全部**启用条件成立 → `should_end = true`。 |

- **空列表语义**：`ANY_OF` +空 →恒 `false`（永不自动结束）；`ALL_OF` + 空 → 恒 `true`（**危险**：开局即结束）。
  > ⚠ **必须在加载时拒绝 `ALL_OF` + 空条件**（属配置错误），回落默认。这是唯一一条"空列表不等于直觉"的组合，交给作者踩不如拦掉。
- **禁用项**：`enabled = false` 的条目先被剔除，再判空。
- **短短路**：成立即停（`ANY_OF` 首个成立即返回；`ALL_OF` 首个不成立即返回）。
- **嵌套**：`params` 内**不支持嵌套组合子**（本期单层）。理由：嵌套需要子规则集参与 AND/OR 混合求值，其短路语义与"归属 peer"归属会相互纠缠（`ANY_OF` 里嵌套 `ALL_OF` 时 `decisive_owner` 无定义）。**本期明确不支持，需要时再设计**——这是**有意的范围裁剪**，不是遗漏。

### 4.2 顺序依赖与副作用（回答"条件间是否有副作用/顺序依赖"）

**无副作用**：条件是纯函数（§3.2），只读同一份 `snapshot`。因此：

- **布尔结果与求值顺序无关** —— `(A and B)` 无论先算A 还是 B，结果相同。
- **短路是纯粹的优化**，不改变结果，只是省掉一次求值。
- **⚠️ 但 `decisive_type` / `decisive_peer` 与顺序有关** —— 报告的是**声明顺序里第一个成立的条件**。所以 `conditions[]` 的顺序是**语义的一部分**：想要"15 杀优先于超时作为对外播报的理由"，就把 `kill_target` 写在 `time_limit` 前。**顺序在配置里固定，因此跨端可复现**（这点对联机一致性至关重要，见 §6.4）。

### 4.3 平局判定（`WINNER_TIE = -2` 语义必须保留）

`winner_policy = MAX_KILLS` 时，**完全沿用现有 `_evaluate_winner()` 逻辑，一个字节都不改**：

```
空 scores                → WINNER_UNSET(-1)
kills 最高者              → 该 peer
kills 相同 → deaths 少者  → 该 peer
kills/deaths 全同且≥2 人   → WINNER_TIE(-2)
```

- `WINNER_TIE = -2` / `WINNER_UNSET = -1` 是 `score_manager.gd:48/50` 的既有常量，**语义与数值均不变**（A.3）。`MatchResult.winner_text()` 已按此渲染（`scripts/ui/match_result.gd:111`），**结算面板零改动**。
- **`decisive_peer` 与 `winner_id` 是两件事**：`decisive_peer` = "谁触发了结束条件"，`winner_id` = "按 `winner_policy` 判出的胜者"。当前 `MAX_KILLS` 下二者可能不同（如超时结束时 `decisive_peer = -1` 但 `winner_id = 击杀最多者`）。**不要混用**。

### 4.4 失败条件（用户明确要求"胜利/失败条件"）

**建议：显式失败条件 + "胜者之外皆负"的默认规则**，两者并存：

| 机制 | 语义 | 本期 |
| --- | --- | --- |
| **默认规则**（无`fail_conditions` 时） | 对局结束时**只有 `winner_id` 一个平反**，其余 peer 一律视为失败（UI 显示"第 2/ 3 / 4 名"）。 | ✅ **默认生效**，与现状一致（现状也没有"失败"概念，只有排名） |
| **显式失败条件**（`fail_conditions[]`） | 列表内条件语义**恒为 `ANY_OF`**（任一成立 → 该 peer 失败），**不支持 `ALL_OF`**（"必须同时死两次才算失败"无意义）。 | 🟡 **接口本期留空**，见下 |

**为什么本期不实现显式失败条件的类型**：`fail_conditions` 复用条件类型，而现有 4 个可用类型里没有一个语义上适合当失败条件（`kill_target` 当失败条件毫无意义）。真正有用的失败条件是「死亡即失败」「被 N 次击杀即失败」，而**死亡即失败与已决决策 ⚑L-4 冲突**：

>⚑L-4 已判「阵亡后 **3 秒倒计时自动重生**」（`01_core_loop §4.2`，用户已拍板）。「死亡即失败」会**直接推翻**这条已决决策（阵亡从"可重生事件"变成"终局事件"）。

**因此本期**：`fail_conditions` **字段存在、加载器校验、语义（恒 `ANY_OF`）定义完毕**，但**不内置任何失败条件类型**，配置里写了会因"无匹配类型"被§3.3 拦下回落默认。**这是有意的**：与其写一个会推翻已决决策的条件类型，不如把决策留回给用户（§9待决项 Q1）。

---

## 5. 判定时机与挂接

### 5.1 挂在哪（保持现状，只换实现）

**判定仍由 `_tick_live(delta)` 驱动，只把内部两个写死调用换成规则引擎**：

| 现状（`score_manager.gd`） | 本期改为 |
| --- | --- |
| `_tick_live()` :310 调 `_check_end_condition()` | `_tick_live()` 调 `_check_end_condition()` → 内部改为 `RuleSet.evaluate(snapshot)` |
| `_check_end_condition()` :197 写死两条件 | **保留同签名** `-> bool`，改为求值规则集（§7.1 兼容性关键） |
| `_evaluate_winner()` :163 写死排序 | **保留同签名** `-> int`，逻辑一字不改 |

**判定频率 = 每帧（LIVE 期间、仅权威端）** —— 与现状一致，不引入新调度器。

### 5.2 每帧轮询的性能考量

**结论：本期保持每帧轮询，不引入脏标记 / 事件驱动。**理由（成本收益）：

- 单帧成本量级：≤5 个条件 × 每人 1 次整数比较 + N 个 peer 迭代（N ≤ 4）。**约 20 次整数比较/帧**，相对本项目已有的每帧物理与动画开销**可忽略**。
- 事件驱动（脏标记）会引入"事件漏发导致规则永不触发"的失效模式，而收益仅省下20 次整数比较 → **典型的过度工程**。
- `poll_mode` 字段已在规则对象上预留（§3.2）：若将来条件数增至数十个或引入昂贵条件（如需遍历全场实体），再按 `poll_mode = "EVENT"` 逐个升级，**接口不需要变**。

### 5.3 时序（与 `_tick_live` 内部顺序的关系）

现状 `_tick_live` 顺序为：递减 `time_remaining` → 心跳广播 → `_check_end_condition()`。**保持不变**。即：

- 判定发生在**本帧计时递减之后** → `time_limit` 读到的是本帧最新值（与现状 `time_remaining <= 0` 口径一致）。
- 击杀导致的达标，在**下一帧**的判定中生效（现状亦然：`_apply_kill` 不触发判定，只改`scores`）。**不引入"击杀即刻结算"**——那会改变同一帧多人的胜负归属（现状"A.9 同一帧多人达成 → 以先到达该帧者为准"的规则依赖"判定在固定时点发生"）。

---

## 6. 玩家属性配置化

### 6.1 属性模型：`PlayerStats`

以`Dictionary` 表达：`{属性 id: float}`。属性 id 为`String`，由**属性规格表**统一定义元数据：

| 元数据 | 类型 | 说明 |
| --- | --- | --- |
| `default` | float | 默认值。**必须与对应 `@export var` 的当前值逐字一致**（§6.4）。 |
| `min` / `max` | float | 合法区间，超出即**夹取**（clamp），不报错。 |
| `step` | float | UI 步进（供未来配置面板用）。 |
| `affects_combat` | bool | `true` = 战斗属性（受公平性约束，见 §6.2）。 |
| `apply` | String | 落地目标：`"player"` 或 `"weapon:<slot>"`。 |

**本期接入的属性（7 项，全部对齐现有 `@export`）**：

| 属性 id | 现状字段 | 默认值 | 区间 | affects_combat | apply |
| --- | --- | --- | --- | --- | --- |
| `max_health` | `player.gd:62` | `100.0` | `[1, 1000]` | ✅ | player |
| `walk_speed` | `player.gd:37` | `3.6` | `[0.1, 20]` | ✅ | player |
| `sprint_speed` | `player.gd:39` | `6.5` | `[0.1, 30]` | ✅ | player |
| `jump_velocity` | `player.gd:45` | `5.0` | `[0.1, 30]` | ✅ | player |
| `weapon_damage` | `weapon.gd:37` | `25.0` | `[1, 500]` | ✅ | weapon:Rifle |
| `weapon_magazine_size` | `weapon.gd:26` | `30` | `[1, 999]` | ✅ | weapon:Rifle |
| `weapon_reload_time` | `weapon.gd:29` | `2.1` | `[0.1, 30]` | ✅ | weapon:Rifle |

> **只接7 项、且都是纯数值**：视角灵敏度（`mouse_sensitivity`）、姿态高度（`STANCE_HEIGHTS`，`const` **不可运行时改**）、特效时长（`tracer_lifetime` 等）**本期不接** —— 前者属个人偏好（应留在本地），后者是表现参数（配置它会让"规则配置"背上"美术配置"的锅）。

### 6.2 ⛔ 公平性：客户端能否自定义本地属性（外挂面）

**结论：不允许客户端自行决定战斗属性。** 分档如下：

| 场景 | `affects_combat = true` | `affects_combat = false` |
| --- | --- | --- |
| **离线 / 训练模式**（`is_authority()` 为真且离线） | ✅ **本地自由配置** —— 这正是用户要的"开局前自由配置"，单人或本地练习场景无作弊面 |✅ 自由 |
| **联机 · 本地是权威（房主）** | ✅ 房主可配（房主即规则制定者） | ✅ 自由 |
| **联机 · 本地是客户端** | ⛔ **只读**。属性由权威端在开局时下发并应用。**客户端提交的任何修改请求一律拒绝**（本期连"请求"通道都不做，见下） | ✅ 本地自由（纯表现） |

**为什么客户端不能改血量/攻击力**：项目是 P2P 无服务器权威（ADR-006），`max_health` 与`damage` **没有任何一端做二次校验**（现状 `report_kill` 就是"信任客户端"，A.11.1 已记录该作弊面）。若再开"客户端自选属性"，等于在**既有的信任模型上再叠一个免费的作弊面** —— 而本作是"局域网熟人局"（ADR-006 明确 P2 支柱放弃服务器权威），**开这个口子的收益（多人自定义房间）远小于成本（PvP 公平性归零）**。

**本期不做"客户端请求 → 房主批准"通道**：那需要新增 RPC + 房主 UI + 超时/拒绝态，是独立 Epic。**本期客户端对战斗属性只读**，配置权完全在权威端。

### 6.3 ⛔ 与 `@export var` 的关系：谁覆盖谁

**裁定：保留 `@export` 作为"默认值 / 场景层覆盖"，配置层是"运行期覆盖"，两者都要 —— 但有一个执行顺序陷阱必须按下面方式处理。**

优先级（低→高）：

```
① 属性规格表 default（代码常量）
      ↑ 被覆盖
② player.tscn / weapon.tscn 里的 @export 值（场景/编辑器层）← 现状的「逐节点手改」能力保留
      ↑ 被覆盖
③ MatchRuleset.player_defaults（配置层 · 本局）
```

**⚠️ 关键陷阱（否则玩家血量配置会静默失效）**：`player.gd:120` 的 `_ready()` 里执行 `health = max_health`。若在 `add_child()` **之后**才写 `max_health`，则 `health` 仍是旧的 100 → 表现为"改了血量上限但血条还是 100"。

**因此规格强制要求**：属性应用必须发生在 **`add_child()` 之前**（即 `main.gd:60_make_player()` 里`instantiate()` 之后、`_players.add_child()` 之前），由`main.gd` 在此处调用统一入口：

```
MatchRuleset.apply_player_stats(player: Node, peer_id: int, stats: Dictionary) -> void
```

该入口负责：查 `player_defaults` → 合并到属性规格默认值 → 按 `apply` 字段写入 `player` 与其武器子节点 → **在入树前完成**。若将来无法在入树前应用，则该入口**必须同时重置 `health`**（`_ready` 已跑过的情况下）—— 建议直接采纳"入树前"方案，避免两套时序。

> **设计理由**：把配置能力做在 `@export` **之上**（而非替换掉）→ 保住编辑器逐节点调参的现有能力（策划/美术仍能用），同时获得集中配置、按局保存、按玩家区分的能力。三者共存，靠明确的优先级与唯一的应用入口。

### 6.4🟥 冲突 1：`max_health` 可配 ⨯ `ADR-008` 血量显示守卫（**必须标红**）

**冲突事实**（已核对原文）：

- `player.gd:371 get_display_max_health()` **故意使用本端 `max_health`**，注释原文写着「双方 `max_health` 来自**同一份 `player.tscn` 的 export 默认值**（场景未覆盖它）→ 跨端一致」—— **"跨端一致"这个前提，正是建立在 `max_health` 两端相同之上。**
- `player.gd:355 _is_valid_display_health()` 把 **`value > max_health` 判为非法**（协议污染），**整个丢弃并保持上一有效值**（ADR-008 铁律，`test_health_sync.gd:350/351` 用 `10000.0` / `100.5` 钉死）。

**冲突场景**：房主把 peer B 配成 `max_health = 200`。若配置未同步到 B 端，B 的本地 `max_health` 仍是 100，而 B 端会收到 A 端广播的血量值（> 100）→ **被判"超 max_health" → 整个丢弃 → B 端永远看不到 A 的血条**（静默失效，形态与 C-18「比分永远 0」完全同源：日志正常、扣血正常、只有显示死了）。

**替代方案（本期必须采纳）**：

1. **`max_health` 视为"必须跨端一致的全局规则"，不按玩家区分** —— 即 `max_health` 从 `player_defaults` 里**移出**，只能由规则集统一设定，且**开局前随配置下发到所有端**（§7.2 的 `sync_ruleset` 同步）。
2. **`get_display_max_health()` 改为读"本端已应用的本局配置值"**，而非裸 `@export` —— 即属性应用后，两端 `max_health` 相同，守卫的既有语义（超上限 = 协议污染）**保持不变**。
3. **在配置下发完成前不开始对局** —— COUNTDOWN 的 3 秒正好用于"应用属性 → 再冻结输入"，与A.2 `COUNTDOWN` 冻结输入的既有语义天然契合。

> **若坚持要"每玩家不同血量"**（部分玩法需要，如"巨人模式"），则**必须先给血量广播带上发送方的上限**（载荷扩为 `apply_network_state(pos, yaw, health, max_health)`），并按 §6.3 的入树前顺序两端一致地应用。⚠ **但 `test_health_sync.gd:459` 有用例按源码文本断言 `apply_network_state` 内部调用 `_is_valid_display_health`，且 `player.gd:322` 注释明写"签名必须与 `network_manager.gd::net_player_state` 的调用端逐字一致"** —— 改载荷会同时波及 `network_manager.gd` 与既有测试。**因此本期明确不做每玩家差异化血量**，列为 §9 待决项 Q2。

---

## 7. 迁移路径（保证 G4 既有关闭判据不回退）

### 7.1 必须保留的现有 API 面（工程侧的硬约束）

| 符号 | 位置 | 要求 |
| --- | --- | --- |
| `kill_target: int = 15` | `score_manager.gd:101` | **字段必须保留**。既有测试**直接写** `mgr.kill_target = 3`（`test_score_manager.gd:348`）。 |
| `match_duration: float = 300.0` | `score_manager.gd:103` | 同上，测试直接写 `mgr.match_duration = 10.0`（`:329`）。 |
| `_check_end_condition() -> bool` | `:197` | **签名与语义均保留**（30 条计分测试多处直接调用）。 |
| `_evaluate_winner() -> int` | `:163` | **签名与实现一字不改**（5 条测试直接断言其返回）。 |
| `_end_match() -> void` | `:206` | 签名、幂等语义、冻结顺序均保留。 |
| `WINNER_TIE=-2` / `WINNER_UNSET=-1` | `:48/:50` | 常量与语义保留（A.3）。 |
| 信号 `score_changed` / `match_state_changed` / `match_ended` / `countdown_updated` / `match_reset` | `:54~95` | **签名一律不动**（A.5 是对 EP-4 的承诺，团队已有"不扩签名、只增新信号"的先例裁定）。 |

> **⚠️ 最容易踩的坑**：如果工程侧把 `kill_target` 换成"从配置读"，`test_live_tick_ends_on_kill_target`（写 `mgr.kill_target = 3` 后期望 3 杀结束）会**当场转红**。
> **规格要求**：`kill_target` 与 `match_duration` 保留为**权威字段**，且**内置默认规则集的两个阈值必须从这两个字段读取**（而非在配置里再写一份 15 / 300.0）。即：
>
> ```
> 内置默认规则集（ffa_kill15）的 time_limit.duration  ← 读 match_duration
> 内置默认规则集（ffa_kill15）的 kill_target.target_kills ← 读 kill_target
> ```
>
> 这样"`kill_target` 是唯一真值来源"得以保持，配置化只提供**换一个真值来源**的能力。

### 7.2 迁移步骤（建议顺序，每步可独立验证）

| 步 | 动作 | 验证点 |
| --- | --- | --- |
| **M1** | 加 `ConditionRegistry` + `Rule` 基类 + 内置 `kill_target` / `time_limit` 两个条件类型。**不改 `score_manager.gd`。** | 新增 suite 断言注册表可编译默认配置、参数校验能拦住缺键/非正值。 |
| **M2** | 加 `MatchRuleset`（配置结构 + 校验 + 回落），内置默认规则集 `ffa_kill15`，其阈值**读 `kill_target` / `match_duration`**。 | 断言"默认规则集求值 ≡ 旧写死逻辑"（§7.3 逐例表）。 |
| **M3** | `score_manager.gd` **内部**换实现：`_check_end_condition()` 改为求值规则集，**签名不变**；`_evaluate_winner()` / `_end_match()` 不动。 | **185/716 全绿**，`test_score_manager.gd` 30 条零改动通过。 |
| **M4** | 加 `sync_ruleset`（A.4 新增RPC）+ 客户端应用配置；`scoreboard.gd` 的 `KILL_TARGET` 硬编码改为读配置。 | 新增用例：客户端收到配置后目标文案与房主一致。 |
| **M5** | 加 `PlayerStats` 规格表 + `apply_player_stats`，在 `main.gd:60_make_player()` **入树前**调用。 | 断言 `max_health` 配置生效且 `health` 同步为新值；断言 ADR-008 守卫行为不变。 |

> **M4 的 `scoreboard.gd` 改动说明**：`scoreboard.gd:29 const KILL_TARGET := 15` 与 `:200 "先到 %d 杀" % KILL_TARGET` 是**第二处硬编码耦合**（主理人勘察未提及）。既有测试 `test_scoreboard.gd:157test_is_near_target_boundary` 依赖 `is_near_target(kills)` 的**默认参数**为 15。
> **规格要求**：`is_near_target(kills, target = KILL_TARGET)` 的**默认参数保留 15**（向后兼容既有测试），但 `_refresh_objective()` 的文案改为读**实际生效的目标值**。即"默认参数是兜底，不是真值"。

### 7.3 既有测试的通过保证（逐条论证）

| 既有测试 | 依赖的行为 | 迁移后保证机制 |
| --- | --- | --- |
| `test_field_defaults` | `kill_target=15` / `match_duration=300.0` | 默认规则集阈值读这两个字段（§7.1） |
| `test_kill_target_triggers_end` | 15 杀 → `_check_end_condition()` 真 | 默认规则集含 `kill_target(读 kill_target)`，`ANY_OF` |
| `test_timeout_triggers_end_and_picks_max_kills` | `time_remaining=0` → 真 | 默认规则集含 `time_limit(读 time_remaining)` |
| `test_live_tick_ends_on_kill_target` | 写 `kill_target = 3` 后 3 杀结束 |阈值**读字段**而非配置（§7.1 关键） |
| `test_live_tick_ends_on_timeout` | 写 `match_duration = 10.0` | 同上 |
| `test_tie_break_by_fewer_deaths` / `test_still_tied_returns_tie` / `test_still_tied_returns_tie` | `_evaluate_winner` 排序与 `WINNER_TIE` | **函数一字不改**（§7.1） |
| `test_match_ended_signal_fires_once_with_frozen_state` | `match_ended` 1 次、冻结、`_apply_kill` 不改写终态 | `_end_match()` 不动 |
| `test_apply_kill_records_kill_and_death`（G4 判据：击杀计数全端一致） | A.8 死亡计分 | `_apply_kill` / `_freeze_scores` **不动** |
| `test_scoreboard.is_near_target_boundary` | 默认参数 15 | 保留默认参数（§7.2 M4） |
| `test_health_sync`（G4 判据：伤害只结算受害端 / ADR-008） | `apply_network_state` 三参签名、越界丢弃 | **不改 `player.gd` 伤害路径**；属性应用在入树前完成（§6.3） |
| `test_kill_attribution`（8 条，G4 判据：归因） | 射手端不结算远端血量 | **完全不受本次改动影响**（不碰 `weapon.gd` / 伤害路径） |
| `test_invariants`（24 条） | 项目级不变量 | 逐条复核；新增文件须登记 `test_runner.gd:SUITE_SCRIPTS`（`control_checklist §4` 第 9 条元纪律） |

**新增必过用例（工程侧须补）**：

1. 默认规则集求值结果 ≡ 旧写死逻辑（覆盖上表前4 条各1 例）。
2. 未注册 `type` → 回落默认 + `push_warning`（不静默当 `false`）。
3. `ALL_OF` + 空条件 → 拒绝加载。
4. 参数缺必填键 / 负值 → 拒绝加载。
5. `kill_target` 改字段后判定随之改变（M3 的核心回归护栏）。
6. `decisive_type` 遵循 `conditions[]` 声明顺序（§4.2）。
7. `PlayerStats` 夹取越界值到 `min/max`，不报错。
8. 客户端模式下战斗属性写入被拒绝（§6.2）。
9. 两条端到端：`max_health = 200` 时两端 `get_display_max_health()` 相等（§6.4 冲突 1 的护栏）。

### 7.4 联机一致性（谁判定、谁显示）

| 角色 | 判定 | 显示 |
| --- | --- | --- |
| **权威端**（房主 / 离线本端，`is_authority()`） | ✅ **唯一判定者**。构造 `snapshot` → `RuleSet.evaluate()` → 决定是否 `_end_match()`。 | 本地 emit `match_ended` |
| **客户端** | ⛔ **不判定**。即使本地持有同一份配置（为显示文案）也**不求值、不触发 `_end_match()`** | 收 A.4 `match_ended` → `_apply_ended()` → 本地 emit `match_ended` → 结算面板 |

**会不会分叉？**不会，只要守住三条：

1. **只有权威端求值**（客户端路径里根本没有 `RuleSet.evaluate` 调用点）。
2. **配置本身跨端一致** —— 房主在 COUNTDOWN 前用 `sync_ruleset`（A.4 新增）下发**同一份Dictionary**；客户端按 `ruleset_id` 校验一致性，不一致则 `push_warning` 并**以本地收到的为准但不参与判定**（反正不判定）。
3. **`snapshot` 只含权威端数据** —— 客户端连求值所需的输入都没有（`scores` 是同步来的副本），从物理上杜绝客户端误判。

> **⚠️ 契约变更声明**：新增 A.4 RPC `sync_ruleset(ruleset: Dictionary)` 属**纯增量**（新增条目，不改任何既有 RPC 的方向/模式/载荷），与 A.5 已有裁定先例一致（「新增独立信号则纯增量、零外溢」）。**已在 `01_core_loop.md` 附录 A.4 / A.6 同步标注**（见该文档变更记录）。

---

## 8. 本期 MVP 边界（**本节是本规格最重要的一节**）

> 目的：**防止工程侧写出无法运行的空壳**。凡"注册了但判不出结果"的条件类型，必须**显式不可用**，而不是返回 `false` 假装可用。

### 8.1 做什么

| 项 | 内容 |
| --- | --- |
| 规则机制 | `ConditionRegistry` + `Rule` 基类+ `MatchRuleset` 配置结构 + 加载校验回落 + `RuleSet.evaluate()` |
| 条件类型（**可跑**） | ① `kill_target`（`target_kills`）② `time_limit`（读 `time_remaining`） |
| 组合 | 顶层 `ALL_OF` / `ANY_OF`，**单层**、短路、顺序敏感仅限 `decisive_type` |
| 胜者策略 | `MAX_KILLS`（= 现有 `_evaluate_winner()`，逻辑不改） |
| 失败条件 | **仅"非胜者即负"的默认语义**（已有）；`fail_conditions` 字段存在但**不内置类型** |
| 属性 | `PlayerStats` 7 项（§6.1）+ 入树前应用入口 + 夹取 + 战斗属性客户端只读 |
| 联机 | `sync_ruleset` 下发配置；客户端只显示不判定 |
| 配置形态 | Dictionary（内置默认 + 可选 `.json` 文件加载） |

### 8.2 只留接口、不实现判定（**注册表里有，但显式不可用**）

| 项 | 状态 | 判定时的行为 |
| --- | --- | --- |
| `survive_rounds` | 注册占位 | 求值返回 `UNAVAILABLE`（§8.4） |
| `score_target` | 注册占位 | 同上。**零 schema 过渡方案见 §2.3**（若用户坚持要"达到 N 分 = N 击杀"，可在配置里显式写 `"score_source": "kills"`，此时**不读独立 score 字段**，零改动可用） |
| `collect_items` | 注册占位 | 同上 |
| `defeat_boss` | 注册占位 | 同上 |
| `LAST_SURVIVOR` 胜者策略 | 注册占位 | 同上 |
| `DECISIVE_OWNER` 胜者策略 | **可跑**（`kill_target` 已能给出归属）但默认不用 | — |
| 嵌套组合子 | **不实现**（§4.1） | 配置里出现嵌套结构 → 加载失败回落 |
| 客户端属性「请求-批准」通道 | **不做**（§6.2） | — |
| 每玩家差异化 `max_health` | **不做**（§6.4冲突 1） | — |
| `.json` 文件热重载 / 编辑器可视化编辑面板 | **不做** | — |

### 8.3 不做什么（需要独立系统的玩法）

回合制（`01_core_loop §4 方案 C`，依赖队伍系统）、波次、道具系统、Boss、队伍/积分榜、经济系统（C-12 / ⚑E-4 已判 MVP 不做）、排位/匹配（ADR-006 明确放弃）。

### 8.4 「不可用」的表达方式（**工程侧必须照做**）

不可用条件**不得**返回 `false`。规格要求：

```
Rule.evaluate() 返回三态：
  OK      → true / false        （真的判了）
  UNAVAILABLE → 该条件无法判定（缺支撑系统）
```

- `MatchRuleset` 在 `evaluate` 后统计：若**任一启用条件**返回 `UNAVAILABLE`，则**整个规则集不可信** → **不结束对局**，并 `push_warning`（一次/局，不刷屏）。
- **理由**：静默返回 `false` 会让"配了 5 个条件只跑通 1 个"看起来像"另外 4 个没达成"，排查成本极高（形态同 C-18）。**显式不可用 = 配置错误可见**。

---

## 9. 待用户拍板项（**不定稿会导致工程侧返工**）

| 编号 | 待决| 选项 | 我的建议 |
| --- | --- | --- | --- |
| **Q1** | 「失败条件」要不要推翻 ⚑L-4（阵亡 3 秒自动重生）？ | (甲) 保留重生、失败只用于"结算时排名"； (乙) 允许「死亡即失败」 | **建议 (甲)**（本期实现）。若要 (乙)，则⚑L-4 需用户重新拍板，且死亡 UI 与重生流程都要改。 |
| **Q2** | 是否需要**每玩家差异化血量**（巨人/速攻模式）？ | (甲) 不需要，`max_health` 全局统一（本期实现）； (乙) 需要 → 须扩 `apply_network_state` 载荷 + 改 `network_manager.gd` + 迁移 `test_health_sync.gd` | **建议 (甲)**。(乙) 会碰 ADR-008 的签名铁律与既有测试，成本远大于本期收益。 |
| **Q3** | 「达到 N 分」是否接受**零 schema 的过渡语义**（分数 = 击杀）？ | (甲) 接受，加条件时再演进为真独立分数； (乙) 本期就做真独立 score（须改 `_freeze_scores` + 计分条目 schema + 比分板） | **建议 (甲)**。(乙) 触碰结算冻结机制，风险与收益不成比例。 |
| **Q4** | 联机时**房主是否需要可视化配置面板**（本期只做配置下发，不做 UI）？ | (甲) 本期只落配置机制，UI 后续； (乙) 本期一并做 | **建议 (甲)**。用户要的是"机制"，UI 属 `04_ux_flow` 范畴。 |

---

## 10. 设计理论红线自检

| 红线 | 自检结论 |
| --- | --- |
| **主导策略** | ✅ 无。`MAX_KILLS` 下三种配置（15 杀 / 超时 / 自定义）产生相同策略空间；条件类型不引入新的最优玩法选择。 |
| **经济失衡** | ⚪ 不适用（⚑E-4 已判 MVP 不做经济）。但已记一条：`max_health` / `damage` 可配**存在平衡风险** → 故限定为**权威端配置**，不给客户端自由度（§6.2）。 |
| **认知过载** | ✅ 已规避。(a) 拒绝 `ALL_OF` + 空列表（§4.1）；(b) 拒绝静默失败（§3.3/§8.4）；(c) **不做假回合**（§2.2）；(d) 属性只接 7 项纯数值，不把表现参数塞进规则配置（§6.1）。 |
| **支柱漂移** | ✅ 无。P2「4 人 FFA、即开即战、无服务器权威」未被动摇：客户端不可配战斗属性（保公平）、回合制/Boss/队伍（会拉长单局、破坏核心循环的方案 C）明确推迟。 |
| **契约一致性** | ⚠️ 1 处**增量**变更（A.4 新增 `sync_ruleset`）+ 1 处**文档**更新（A.6 表述）。**A.5 全部信号签名零改动。** |

---

## 11. 变更记录

| 日期 | 作者 | 变更 |
| --- | --- | --- |
| 2026-10-06 | 文策渊 | 初版。裁定：混合式配置（Dictionary 传输 + 规则对象求值 + 注册表扩展），不用 `Resource`；本期真实现 2 个条件类型，3 个条件类型仅留显式不可用占位；保留 `kill_target` / `match_duration` 为阈值唯一真值来源以保证 30 条计分测试零改动通过；标红 `max_health` 与 ADR-008 的对撞冲突并给出替代方案。 |