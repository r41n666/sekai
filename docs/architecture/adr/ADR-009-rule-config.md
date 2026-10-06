# ADR-009 · 规则配置化：混合式形态（Dictionary 传输 + 规则对象求值）与「不可用必须显式」

> **状态（Status）**：Accepted（已采纳）
> **日期**：2026-10-06 ｜ **作者**：程基岩（engineering-lead，D2-04 · 规则配置化与玩家属性）
> **关联**：`scripts/game/rules/`（`match_rule.gd` / `condition_registry.gd` / `rule_set.gd` /
> `match_ruleset.gd` / `player_stats.gd` / `kill_target_rule.gd` / `time_limit_rule.gd` /
> `unavailable_rule.gd`）、`scripts/game/score_manager.gd`、`scripts/main.gd`、
> `scripts/ui/scoreboard.gd`、`scripts/player.gd`、`design/gdd/05_rule_config_spec.md`、
> `design/gdd/01_core_loop.md` 附录 A.4/A.5/A.6、`ADR-006-no-server-authority.md`、
> `ADR-008-remote-health-display.md`、`control_checklist.md §4-9/§4-13/§4-16`
> **守护**：`tests/suites/test_rule_config.gd`（66 用例 / 373 断言）、
> `tools/mutation_rule_config.py`（8 杀 + 4 守恒对照）

---

## Context（背景与问题）

用户提出三条需求：**①胜利/失败条件支持多种可选类型并可组合；②玩家属性可由用户开局前配置；
③规则配置化、与核心战斗逻辑解耦、便于扩展。**

三条都指向同一件事：**把「硬编码在代码里的玩法参数」变成「数据」**。而这三条里，
第①条最危险 —— 它要动的是**胜负判定链路本身**。

动手前的现场勘察有四个发现，每一个都改变了做法：

| # | 发现 | 若无视会怎样 |
| --- | --- | --- |
| 1 | 现有条件**只有两条**（`_check_end_condition()` 里 `time_remaining <= 0` **或** `_max_kills() >= kill_target`） | — |
| 2 | 用户点名的 5 种条件里，**3 种在本项目无任何支撑系统**（无回合、无道具、无 Boss） | 写成"能跑的条件"= 写出一批**永远返回 false 的假条件** |
| 3 | `kill_target` / `match_duration` 是**公开可写字段**，既有测试直接写它们（`test_score_manager.gd:348` 写 `= 3`、`:329` 写 `= 10.0`） | 把阈值改成"从配置读"→ 既有测试**当场转红** |
| 4 | `player.gd::get_display_max_health()` 的注释写着「两端`max_health` 来自同一份 tscn 默认值 → 跨端一致」，而 ADR-008 的守卫把 `value > max_health` 判为协议污染**整条丢弃** | 房主配 200 血而配置未同步 → 对端**永久丢弃**血量广播 → **血条永远不动且不报错** |

第 2 条与第 4 条是**同一种病**：**静默失效**。本项目已经为它栽过两次
（C-18「比分永远 0」躲了两轮 G4；ES-4.3 的 `pending()` 空壳让删除的用例伪装成绿灯）。
**本ADR 的核心价值不在"怎么把规则配置化"，而在"怎么让配错/跑不了这件事可见"。**

---

## Decision（决定）

### 1. 形态：**混合式**（配置真值是 `Dictionary`，求值器是规则对象，扩展点是注册表）

```
配置真值 / 传输          编译（每端各编一次）              求值
─────────────────  ─────────────────────────────  ─────────────────────
Dictionary          ConditionRegistry.compile()      RuleSet.evaluate()
（可 JSON 化、可rpc 传输、headless 可构造）  （本地产物、不传输）  （纯函数、无副作用）
```

三条理由：

1. **传输层必须是字典。** 联机下配置要跨端送达。`Resource` 是**引用型**对象，跨端不能按值传输，
   要同步只能传 `resource_path` → 于是「配置一致」退化成「两端必须装同一个文件且版本一致」，
   **把运行时问题推给打包流程**（联机版本错配即静默行为不一致）。
2. **求值层必须是对象。** 否则「新增条件类型」就要改判定函数本体，`if/elif` 链会长到不可维护
   —— 直接违背用户「方便后续扩展」的诉求。
3. **两者都不污染判定口径。** 规则对象是纯计算体（无 Node、不碰 `multiplayer`、不碰场景树）
   → 天然适配本项目既定的「静态纯函数 + headless 断言」取舍。

**明确不选 `Resource` 的代价（诚实记录）**：放弃 Inspector 可视化编辑。补偿手段是加载期校验器
+ 未来的 `tools/` 预览页。若日后确需可视化编辑，**增量加一层 `Resource` 只作为"编辑入口"**
（编辑器里编辑 → 导出 JSON），**不改变运行时格式**。这是可后补的，不锁死。

### 2. ⛔ **不可用条件必须返回三态，`UNAVAILABLE` 禁止降级为 `false`**

`Rule.evaluate()` 返回三态而非 `bool`：

```
OK_TRUE / OK_FALSE  →  真判了
UNAVAILABLE         →  判不了（项目缺支撑系统）
```

任一**启用**条件返回 `UNAVAILABLE` → **整个规则集不可信 → 不结束对局** + 一次 `push_warning`（每局一次）。

**理由**：静默 `false` 会让「配了 5 个条件、只跑通 1 个」看起来像「另外 4 个没达成」。
日志全正常、只有规则没生效 —— 与 C-18 同源，排查成本极高。
**显式不可用 = 配置错误可见**（规格 §8.4）。

⚠ 这条纪律被推到了**三个层次**，因为每一层都能独立失效：

| 层 | 防护 |
| --- | --- |
| **加载期** | `ConditionRegistry.validate` 对占位类型直接报错 → `load_ruleset` **整份回落默认**（不静默接受半份配置） |
| **运行期· 普查** | `RuleSet.evaluate` 在组合求值**之前**先普查全部不可用条件 —— 否则 `ANY_OF` 下首个条件成立就短路返回，后面的不可用条件**永远没被看见**（变异体⑥就是这一条） |
| **运行期 · 求值** | 纵深防御：普查说可判定、`evaluate` 却返回 `UNAVAILABLE`（有人只翻了 `judgeable` 没翻 `evaluate`）→ 同样按不可用处理 |

**不可用条件在注册表里留位**（而非不注册）：不注册会在加载期被拦下回落，
用户配了 5 个只有 1 个生效却**看不到是哪个类型不认识**；注册 + `UNAVAILABLE` 才能在告警里点名。

### 3. 组合语义与**顺序即语义**

`ALL_OF` / `ANY_OF`，单层、短路。
⚠ **不支持嵌套组合子**（本期单层）：嵌套会让 `ANY_OF` 里的子 `ALL_OF` 的「归属 peer」无定义。
这是**有意的范围裁剪**，不是遗漏。

`decisive_type` / `decisive_peer` 报**声明顺序里第一个成立**的条件
→ `conditions[]` 的顺序**是语义的一部分**，也因此**跨端可复现**。
⚠ 明确**不做**「改成哪个条件最紧急」—— 那会让两端报出不同的 `decisive_type`。

### 4. `kill_target` / `match_duration` 保留为**阈值唯一真值来源**

内置默认规则集 `ffa_kill15` 的两个阈值**从 `ScoreManager` 字段读**，
**不在配置里另写一份 15 / 300.0**：

```
MatchRuleset.builtin_default(kill_target, match_duration)
  → kill_target.target_kills ← 入参 kill_target
  → duration_limit← 入参 match_duration
```

`ScoreManager._active_ruleset()` 按需重建（而非缓存），因为那两个字段是公开可写的既有契约。

> **为什么这条必须写进 ADR**：字段可写性是**既有测试的契约**，不是实现细节。
> 缓存规则集只在初始化编译一次是最"优雅"的写法，但会让 `mgr.kill_target = 3` 失效
> ——`test_live_tick_ends_on_kill_target` 当场转红。
> **配置化提供的是"换一个真值来源"的能力，不是"把真值来源搬进配置"。**

### 5. `max_health` ⛔ 降为**全局规则**（解 ADR-008 对撞，见发现 4）

| 步 | 做法 |
| --- | --- |
| ① | `max_health` 随 `sync_ruleset` **开局前下发两端**，两端保证相同 |
| ② | `get_display_max_health()` 读「本端已应用的本局配置值」 |
| ③ | **守卫语义一字不改**：`value > max_health` 仍判协议污染、仍整条丢弃（ADR-008 铁律，`test_health_sync.gd:350/351` 用 `10000.0` / `100.5` 钉死） |

⚠ 明确**不做**「每玩家差异化血量」：那需要扩 `apply_network_state` 载荷
（带上发送方上限），会同时波及 `network_manager.gd` 与既有测试 —— 收益远小于本期成本。

### 6. 判定仍**每帧轮询**（不引入脏标记/事件驱动）

≤5 条件 × ≤4 peer ≈ **20 次整数比较/帧**，相对本项目已有的每帧物理与动画开销可忽略。
事件驱动会引入「事件漏发 → 规则永不触发」的失效模式，而收益仅省下20 次整数比较
→ **典型的过度工程**。`poll_mode` 字段按规格预留（将来条件数增至数十个再逐个升级，接口不变）。

### 7. 属性应用必须在 `add_child()` **之前**

`player.gd::_ready()` 执行 `health = max_health`。入树后再写 `max_health`
→ 表现为「改了血量上限但血条还是 100」，**且不报任何错**。
故唯一应用入口 `PlayerStats.apply_player_stats()` 由 `main.gd::_make_player()` 在
`instantiate()` 之后、`add_child()` 之前调用（变异体⑤就是这一条）。

⚠ **补一条入树后的路径**：客户端的玩家节点在场景 `_ready()` 阶段就建好了，
而 `sync_ruleset` 是 COUNTDOWN 之前才到的 —— 客户端**根本没机会**在入树前应用。
故 `ScoreManager` 增一条 `ruleset_applied` 信号（**A.5 纯增量**，既有5 条信号签名未动），
`main.gd` 据此对**已存在**的玩家节点补应用一次。

### 8. 客户端对战斗属性**只读**（公平性）

P2P 无服务器权威（ADR-006）下，`max_health` / `damage` **没有任何一端做二次校验**。
再开「客户端自选属性」等于在既有信任模型上**再叠一个免费作弊面**。
本期客户端对战斗属性只读，配置权完全在权威端；**连「请求-批准」通道都不做**（独立 Epic）。

---

## Consequences（后果）

### 正面

- **判定链路可扩展**：新增条件 = 新增一个文件 + 一次注册，判定函数本体不动（用例
  `test_new_condition_needs_only_registration` 用一个注册即插即用的替身证明这一点）。
- **配置跨端一致有据可查**：`ruleset_id` 供两端核对，不一致会 `push_warning`。
- **既有契约零改动**：`test_score_manager`(30) / `test_kill_attribution`(8) /
  `test_health_sync`(27) / `test_match_result`(58) / `test_scoreboard`(22) **全部零改动通过**。
- **「规则没生效」从此可见**：占位条件在加载期就报错，运行期还有一次性告警。

### 负面 / 代价（明写，不藏）

- **每帧重建规则集**（`_active_ruleset()`）：约 2 次字典字面量 + 2 次对象构造。
  为的是保住「字段可写」这条既有契约。将来若引入不可写配置对象，可改缓存 + 显式失效。
- **A.4 / A.5 各增一条**（`sync_ruleset` RPC、`ruleset_applied` 信号）。
  两条都是**纯增量**（既有 5 条 RPC 与 5 条信号的方向/模式/签名一律未改），
  与 A.5 已有裁定先例一致（`countdown_updated` / `match_reset` 都是这样加的）。
- **放弃 Inspector 可视化编辑**（见 Decision 1 的诚实记录）。
- **本期只真实现 2 种条件**。用户点名的 5 种里 3 种（回合 / 道具 / Boss）
  在本项目**无任何支撑系统**，强行实现即空壳 —— 这是**有意的范围裁剪**，不是遗漏。

### 遗留风险

1. ~~**客户端属性补应用依赖 `ruleset_applied` 连线**~~ → **已关闭（2026-10-06 补测）**。
   原风险：若有人改 `main.gd::_ready()` 删掉那两行，客户端 `max_health` 会停在场景默认值 →
   房主配高血时客户端**永久丢弃**血量广播（ADR-008 守卫）。
   **关闭方式**：新增两条 headless 纪律锁 + 两个变异体（详见下方「补测记录」）。
2. ~~**本期无双端自动化守护**~~ → **部分关闭**。「配置下发后两端求值结果相同」这条**性质**
   已抽成 headless 纯逻辑用例常态化；但**跨端传输本身**（RPC 真跑一趟）仍只有人工探针。
   主理人裁定探针**不纳入常设回归**（多进程要占端口、拉两个 Godot 进程，当前无 CI 环境不可靠）。
3. **`fail_conditions` 字段存在但不可用**（会推翻已决 ⚑L-4「阵亡 3 s 自动重生」）。
   加载器会拦下并报错 —— 这是有意的，让决策留回给用户。

---

## 补测记录（2026-10-06 · 主理人复核后追加）

首轮实现自评「遗留风险 1」（`ruleset_applied` 连线零自动化覆盖）为**真**，且严重度评估为
「与 C-18 同构」：该连线是**客户端应用属性的唯一通道**，断掉后客户端 `max_health` 停在 100 →
ADR-008 守卫把房主广播的 200 血判为协议污染**整条丢弃** → 血条**永远不动且不报错**。

⚠ **`test_health_sync.gd` 测不到这条**：它测的是「血量广播的 clamp / 越界守卫」，
与「配置有没有到达客户端应用层」是两件事，长得像但无关。

### 新增用例（7 条，`test_rule_config.gd` 59 → 66 用例 / 308 → 373 断言）

| 用例 | 性质 | 杀死的变异体 |
| --- | --- | --- |
| `test_main_ready_connects_ruleset_applied_signal` | 源码纪律锁：`_ready` 体内有 `ruleset_applied.connect(`，实参确实是 `_on_ruleset_applied`，且该方法真实存在 | **杀⑦**（删 connect） |
| `test_ruleset_applied_handler_really_applies_player_stats` | 这条处理链**可达** `PlayerStats.apply_player_stats(`（含负向对照：可达性分析不得恒真） | **杀⑧**（handler 体清空） |
| `test_ruleset_applied_handler_iterates_existing_player_nodes` | 补应用必须作用于 `_players` **已入树**节点 + 走 `_can_configure_stats()` 公平性闸门 | **杀⑧** |
| `test_two_independent_rulesets_agree_on_every_snapshot` | 两端独立编译的 `RuleSet` 对 6 组快照求值结果相同（附「至少 3 例真结束」反向护栏，防「两端都没判」的假绿） | — |
| `test_two_ends_render_identical_objective_text` | 两块真实 `Scoreboard` 节点的目标文案逐字相同，且真的显示配置值 | — |
| `test_both_ends_freeze_identical_scores_at_end` | 两端走各自真实记分/判定/结算路径后，`scores` 与 `winner_id` 逐字一致 | — |
| `test_snapshot_is_pure_data_so_cross_end_equality_is_meaningful` | 快照只含纯数据（否则上面两条的「两端相同」前提会悄悄失效而它们仍绿） | — |

### 关键取舍：断言按**可达性**而非 token 存在性写

守恒对照 g4（「handler 改为转发到助手」的语义等价重构）要求断言**不得**退化成
「`_on_ruleset_applied` 体内必须出现 `PlayerStats.apply_player_stats(`」——
否则一次**正确**的重构就会假红（§4-16 的「误杀」方向）。
故测试侧用 `_main_reaches()`（本文件内局部函数调用的有限深度可达性分析）判定。
它同时满足两个变异体验证：handler 体清空 → 不可达 → 转红；改为转发 → 仍可达 → 仍全绿。

### 变异测试

`tools/mutation_rule_config.py`：**6 杀 3 守恒 → 8 杀 4 守恒**，0 存活 / 0 误杀 / 0 注入失败。
新增 **杀⑦**（删 connect）、**杀⑧**（handler 体清空，留 `pass`）、**守恒D**（转发到助手的等价重构）。
两条杀组**杀不同的用例**——只有 ⑦ 时无法证明handler 那条断言不是 ⑦ 的附属品。


---

## Alternatives Considered（备选方案与否决理由）

| 备选 | 否决理由 |
| --- | --- |
| **纯字典配置**（`if/elif` 链判定） | 新增第6 种条件要改判定函数本体 → 扩展性收益归零，违背用户明确诉求 |
| **`Resource` 子类 + `.tres`** | 引用型对象跨端不能按值传输 → 「配置一致」退化成「文件版本一致」，把运行时问题推给打包流程 |
| **不可用条件直接不注册** | 加载期被拦下回落，但告警**说不出是哪个类型不认识** → 配置错误不可定位 |
| **不可用条件返回 `false`** | 「配了 5 个只跑通 1 个」看起来像「另外 4 个没达成」→ **静默失效**（C-18 同源） |
| **阈值搬进配置、删掉 `kill_target` 字段** | 既有测试直接写该字段（`:348` / `:329`）→ **当场转红**；字段可写性是既有契约 |
| **脏标记 / 事件驱动判定** | 「事件漏发 → 规则永不触发」的失效模式，换20 次整数比较不划算（过度工程） |
| **缓存规则集 + 字段变更时失效** | 字段可写是既有契约，但缓存会让「只写字段不调失效钩子」静默失效 → 本期选择按需重建 |
| **每玩家差异化 `max_health`** | 须扩 `apply_network_state` 载荷 + 改 `network_manager.gd` + 迁移 `test_health_sync` → 成本远大于收益 |
| **直接实现「回合 / 道具 / Boss」三种条件** | 项目无对应系统，做出来必然是永不成立的空壳（认知过载 + 支柱漂移，`05_rule_config_spec` §8.3） |

---

## 验证（How this ADR is enforced）

| 层 | 手段 |
| --- | --- |
| 回归基线 | `bash tools/verify.sh` → **251 用例 / 1089 断言 / 0 失败**（改造前 185 / 716） |
| 等价性 | `test_default_ruleset_matches_legacy_end_condition`（11 组用例逐位对照旧写死逻辑） |
| 防空壳 | `test_unavailable_conditions_never_report_false` + `test_unavailable_warning_actually_emits_a_warning` |
| 客户端应用通道 | `test_main_ready_connects_ruleset_applied_signal` + `test_ruleset_applied_handler_really_applies_player_stats` + `test_ruleset_applied_handler_iterates_existing_player_nodes` |
| 跨端一致性（性质） | `test_two_independent_rulesets_agree_on_every_snapshot` + `test_two_ends_render_identical_objective_text` + `test_both_ends_freeze_identical_scores_at_end` |
| 变异测试 | `tools/mutation_rule_config.py` → **8 杀伤组全灭 + 4 守恒组零误杀** |
| 双端实测（人工） | `tests/manual_rule_config_probe.tscn`（房主配 3 杀→ 两端文案「先到 3 杀」+ 两端结算） |

> **变异测试抓到过一条真实弱断言**（诚实记录）：`test_unavailable_condition_warns_exactly_once_per_match`
> 原本只断言 `_ruleset_warned` 标志，而该标志在 `push_warning` **之前**置位
> → 把 `push_warning(...)` 整行删掉仍全绿。补了
> `test_unavailable_warning_actually_emits_a_warning`（源码纪律锁，剥注释后判函数体内有告警调用）
> 才杀死该变异体，并配**守恒对照组 g3**（告警文案换一种拼接写法仍须全绿）防止误杀。

> **补测轮再次抓到一条「断言了状态 ≠ 断言了行为」**（同类形态，诚实记录）：
> 首轮 `test_main_ready_connects_ruleset_applied_signal` 只证明「线接了」，
> 而把 `_on_ruleset_applied` 函数体换成 `pass`（保留 connect）照样全绿。
> 主理人手工注入确认当时 **244 用例 / 1024 断言 / 0 失败**。
> → 补 `test_ruleset_applied_handler_really_applies_player_stats`（判**可达性**，
>   而非体内有无该 token）才杀死该变异体，并配**守恒对照组 g4**
>   （handler 改为转发到助手的语义等价重构仍须全绿）防止把断言写成字面量锁。