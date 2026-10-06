#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""变异测试 · D2-04 规则配置化 —— 验证 `test_rule_config.gd` 的断言**真的有牙齿**。

## 为什么需要这个文件
本项目因「弱断言（变异后仍全绿）」吃过**五次**亏（ES-4.1 的 `ceil→floor`、ES-4.2 的
`kills >` 绕过、C-18 的 token 版 `was_alive`、ES-4.2 的「锚点不匹配却被当成存活」、
ES-4.3 的「`pending()` 空壳」）。本次改动**触碰了胜负判定链路本身**
（`_check_end_condition` 从写死判断换成规则集求值），是最需要钉死的一类改动。

## 纪律（本脚本自身踩过的坑，务必保持）
1. **注入必须校验**：注入后源码要与备份不同，否则报 `NOT_APPLIED`。
2. **注入失败 ≠ 存活**：两者分开计数，且**注入失败也要让本脚本非零退出**
   （早期版本注入全失败却打印 "MUTATION PASS" —— 全绿结论比红结论危险得多）。
3. **只改一份文件时不碰其它文件**（避免误伤工作区）；收尾 `finally` 里还原 + 自检。
4. **守恒对照组**（§4-16）：弱断言有「漏杀」与「误杀」两个方向。
   本脚本显式区分 `kill`（期望转红）与 `guard`（期望仍绿），`guard` 转红即判误杀并非零退出。

## 变异体一览（8 杀 + 4 守恒对照）
  杀 ① 不可用条件改成返回 false        ← 本任务最重要的设计约束（防空壳）
  杀 ② 去掉 push_warning（静默不可用）
  杀 ③ ALL_OF 改成 ANY_OF
  杀 ④ 默认规则集阈值写死不读 kill_target 字段
  杀 ⑤ 属性在 add_child 之后应用
  杀 ⑥ 不可用条件被短路掩盖（先组合后普查）
  杀 ⑦ 删掉 ruleset_applied.connect（**客户端属性应用通道断**，C-18 同构失效）
  杀 ⑧ handler 函数体清空（线还在，但线那头不干活）
  守恒A `time_remaining <= 0` 改写成 `not (time_remaining > 0)`（语义等价）
  守恒B `ALL_OF` 短路方向改写（`if not satisfied` → `if satisfied == false`）
  守恒C 告警文案换一种拼接写法
#  守恒D handler 改为「空转发壳」（转发到助手，语义等价）
# ⚠ 杀⑦ 与杀⑧ 都在 `main.gd`，但**杀不同的用例**：
#   ⑦ 由 `test_main_ready_connects_ruleset_applied_signal` 抓（线没接）；
#   ⑧ 由 `test_ruleset_applied_handler_really_applies_player_stats` 抓（线接了但不干活）。
#   两条缺一不可：只有 ⑦ 时，无法证明「handler 那条断言不是 ⑦ 的附属品」。
用法：
    python tools/mutation_rule_config.py
退出码：0 = 全部变异体被杀死且守恒组未误杀；1 = 有存活（弱断言）/ 守恒组误杀 / 注入失败
"""

import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULES = os.path.join(ROOT, "scripts", "game", "rules")
SCORE_MANAGER = os.path.join(ROOT, "scripts", "game", "score_manager.gd")
MAIN = os.path.join(ROOT, "scripts", "main.gd")
SCOREBOARD = os.path.join(ROOT, "scripts", "ui", "scoreboard.gd")

BAK_DIR = os.path.join(ROOT, ".tmpdbg", "mutation_rule_config")
GODOT = os.environ.get(
    "GODOT_BIN", "C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe"
)

SUITE = "test_rule_config"

# 参与快照的全部文件（还原时逐字节校验）
TRACKED = [
    os.path.join(RULES, "match_rule.gd"),
    os.path.join(RULES, "kill_target_rule.gd"),
    os.path.join(RULES, "time_limit_rule.gd"),
    os.path.join(RULES, "unavailable_rule.gd"),
    os.path.join(RULES, "rule_set.gd"),
    os.path.join(RULES, "condition_registry.gd"),
    os.path.join(RULES, "match_ruleset.gd"),
    os.path.join(RULES, "player_stats.gd"),
    SCORE_MANAGER,
    MAIN,
    SCOREBOARD,
]


def read(path):
    with io.open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def snapshot():
    """备份全部可能被改动的文件，返回 {路径: 原文}。"""
    return {p: read(p) for p in TRACKED}


def restore_all(snap):
    for path, text in snap.items():
        write(path, text)


def run_failures():
    """跑一次 headless runner，返回 (失败数, 失败用例名列表, 汇总行)。"""
    proc = subprocess.run(
        [GODOT, "--headless", "--path", ROOT, "res://tests/test_runner.tscn"],
        capture_output=True, text=True, timeout=300, errors="replace",
    )
    out = proc.stdout + proc.stderr
    m = re.search(r"用例\s+(\d+)\s+｜\s+断言\s+(\d+)\s+｜\s+失败\s+(\d+)", out)
    if not m:
        return None, [], ""
    failed = sorted(set(re.findall(re.escape(SUITE) + r"\.([A-Za-z0-9_]+)", out)))
    return int(m.group(3)), failed, m.group(0)


# ══════════════════════════════════════════════════════════════════════
#  变异体定义
#  变异函数签名：base(=全部基线源码 dict) -> mutated dict；锚点未命中 raise AssertionError
# ══════════════════════════════════════════════════════════════════════


def _patch(base, path, old, new, count=1):
    """在 base[path] 里替换 old→new；锚点未命中直接 raise（绝不静默跳过）。"""
    src = base[path]
    assert old in src, "锚点未命中：%s / %r" % (os.path.basename(path), old[:70])
    assert src.count(old) == count, (
        "锚点出现 %d 次（期望 %d 次）——锚点不唯一，注入会误伤" % (src.count(old), count)
    )
    return dict(base, **{path: src.replace(old, new, count)})


def m1_unavailable_returns_false(base):
    """M1（★核心）不可用条件改成返回 false —— 静默失效的经典形态。

    这正是本任务最重要的设计约束要防的：配了 5 个条件只跑通 1 个时，
    另外 4 个「看起来像没达成」而不是「配置错误」。
    """
    return _patch(
        base, os.path.join(RULES, "unavailable_rule.gd"),
        "func evaluate(_snapshot: Dictionary) -> int:\n\treturn EVAL_UNAVAILABLE",
        "func evaluate(_snapshot: Dictionary) -> int:\n\treturn EVAL_OK_FALSE",
    )


def m2_drop_push_warning(base):
    """M2 去掉「不可用条件」的一次性 push_warning —— 规则不生效但全程静默。"""
    return _patch(
        base, SCORE_MANAGER,
        "\tpush_warning(\"ScoreManager: 本局规则集含**不可用**条件（%s）→ 判定不可信，\"\n"
        "\t\t% str(ruleset.rule_set.last_unavailable_types())\n"
        "\t\t+ \"按规格 §8.4 **不结束对局**。请改用 kill_target / time_limit，\"\n"
        "\t\t+ \"或先在项目里实现该条件类型的支撑系统。\")",
        "\t# 变异体：删掉告警（静默失效）",
    )


def m3_all_of_becomes_any_of(base):
    """M3 把 ALL_OF 的短路方向反过来（语义塌陷成 ANY_OF）。"""
    return _patch(
        base, os.path.join(RULES, "rule_set.gd"),
        "\t\tif combine == COMBINE_ALL and not satisfied:\n"
        "\t\t\treturn result # ALL_OF 短路：首个不成立即返回（should_end 保持 false）",
        "\t\tif combine == COMBINE_ALL and satisfied:\n"
        "\t\t\treturn result # 变异体：ALL_OF 的短路方向反了（语义变成 ANY_OF）",
    )


def m4_hardcode_threshold(base):
    """M4 内置默认规则集把 kill_target 阈值写死 15，不再从 ScoreManager 字段读。

    这是规格 §7.1 点名的最易踩坑：既有测试 `mgr.kill_target = 3` 会当场失效。
    """
    return _patch(
        base, os.path.join(RULES, "match_ruleset.gd"),
        '"params": {"target_kills": int(kill_target)}},',
        '"params": {"target_kills": 15}}, # 变异体：写死 15，不读字段',
    )


def m5_apply_stats_after_add_child(base):
    """M5 属性在 `add_child()` **之后**才应用（违反规格 §6.3 时机铁律）。

    后果：`player.gd::_ready()` 已执行 `health = max_health` 定死血量
    → 表现为「改了血量上限但血条还是 100」，且不报任何错。
    """
    return _patch(
        base, MAIN,
        "\tPlayerStats.apply_player_stats(player, _player_stat_overrides(), _can_configure_stats())\n"
        "\treturn player",
        "\treturn player # 变异体：入树前不应用属性",
    )


def m6_unavailable_masked_by_short_circuit(base):
    """M6 把「先普查不可用条件」挪到组合求值之后 —— 不可用条件被短路掩盖。

    `ANY_OF` 下 `kill_target` 先成立就短路返回，后面的不可用条件永远没被看见
    → 「配了 5 个只跑通 1 个」又变回静默失效。
    """
    return _patch(
        base, os.path.join(RULES, "rule_set.gd"),
        "\t# ── 先普查不可用条件（不受短路影响，规格 §8.4）──\n"
        "\t#   ⚠ 必须在组合求值**之前**普查：否则 `ANY_OF` 下第一个条件成立就短路返回了，\n"
        "\t#   后面的不可用条件永远没被看见 → 「配了 5 个只跑通 1 个」又变成静默失效。\n"
        "\tfor rule in rules:\n"
        "\t\tif not rule.judgeable:\n"
        "\t\t\t_last_blocked_by_unavailable = true\n"
        "\t\t\t_last_unavailable_types.append(rule.type_id)\n"
        "\n"
        "\tif _last_blocked_by_unavailable:\n"
        "\t\t# 规则集不可信 → **不结束对局**（`should_end` 保持 false），由调用方push_warning。\n"
        "\t\tresult.should_end = false\n"
        "\t\tresult.decisive_type = \"\"\n"
        "\t\tresult.decisive_peer = MatchRule.NO_PEER\n"
        "\t\treturn result\n",
        "\t# 变异体：删掉「先普查不可用条件」这一步",
    )


def m7_drop_ruleset_applied_connect(base):
    """M7（★本轮核心）删掉 `main.gd::_ready` 里的 `ruleset_applied.connect(...)`。

    这一行是**客户端把规则配置变成实际玩家属性的唯一通道**。删掉后的失效形态
    与 C-18「比分永远 0」同构（形态同构、严重度更高）：

      ① 客户端 `max_health` 停在 `player.tscn` 的场景默认值 100（房主配 200 时）；
      ② ADR-008 守卫（`player.gd:355`）把房主广播来的 200 血判为「协议污染」；
      ③ 该条广播被**整条丢弃** → 客户端血条**永远不动，且不报任何错**。

    ⚠ `test_health_sync.gd` 测的是「血量广播的 clamp / 越界守卫」，
      **测不到「配置有没有到达客户端应用层」** —— 两件事长得像，极易混淆。
    """
    return _patch(
        base, MAIN,
        "\tif _score.has_signal(\"ruleset_applied\"):\n"
        "\t\t_score.ruleset_applied.connect(_on_ruleset_applied)\n",
        "\t# 变异体：删掉 ruleset_applied.connect —— 客户端属性应用通道断开\n",
    )


def m8_empty_ruleset_applied_handler(base):
    """M8 把 `_on_ruleset_applied` 的**函数体清空**（保留 connect，保留空实现）。

    与 M7 的区别：M7 是「线没接」，本条是「线接了但那头不干活」。
    两者都会让客户端属性不生效，但**必须由不同的用例抓住**——
    若只有 M7 入库，就无法证明「`test_ruleset_applied_handler_really_applies_player_stats`
    这条断言真的有牙齿」（它可能只是 M7 的附属品）。
    """
    return _patch(
        base, MAIN,
        "\tvar overrides := _player_stat_overrides()\n"
        "\tif overrides.is_empty():\n"
        "\t\treturn\n"
        "\tvar can_configure := _can_configure_stats()\n"
        "\tfor child in _players.get_children():\n"
        "\t\tPlayerStats.apply_player_stats(child, overrides, can_configure)\n",
        "\tpass # 变异体：handler 函数体清空（线还在，但线那头不干活）\n",
    )


# ── 守恒对照组（§4-16：必须仍然全绿，否则判「误杀」）──


def g1_equivalent_time_comparison(base):
    """守恒A `time_remaining <= 0` 改写成语义等价的 `not (time_remaining > 0)`。

    这是**正确**的等价改写。若断言转红 → 说明断言是字面量锁而非语义锁（误杀）。
    """
    return _patch(
        base, os.path.join(RULES, "time_limit_rule.gd"),
        "\treturn EVAL_OK_TRUE if float(snapshot[REQUIRED_KEY]) <= 0.0 else EVAL_OK_FALSE",
        "\treturn EVAL_OK_TRUE if not (float(snapshot[REQUIRED_KEY]) > 0.0) else EVAL_OK_FALSE",
    )


def g2_equivalent_short_circuit(base):
    """守恒B `ALL_OF` 短路条件 `not satisfied` 改写成等价的 `satisfied == false`。"""
    return _patch(
        base, os.path.join(RULES, "rule_set.gd"),
        "\t\tif combine == COMBINE_ALL and not satisfied:",
        "\t\tif combine == COMBINE_ALL and satisfied == false:",
    )


def g3_equivalent_warning_text(base):
    """守恒C 告警文案换一种拼接写法（语义等价，仍是 `push_warning(...)`）。

    验证纪律锁是「这个函数有没有发出告警」的**语义**判断，
    而不是比对某一句文案 —— 后者会把正确改写误判为失败（§4-16 的「误杀」方向）。
    """
    return _patch(
        base, SCORE_MANAGER,
        "\tpush_warning(\"ScoreManager: 本局规则集含**不可用**条件（%s）→ 判定不可信，\"\n"
        "\t\t% str(ruleset.rule_set.last_unavailable_types())\n"
        "\t\t+ \"按规格 §8.4 **不结束对局**。请改用 kill_target / time_limit，\"\n"
        "\t\t+ \"或先在项目里实现该条件类型的支撑系统。\")",
        "\tvar unavailable := str(ruleset.rule_set.last_unavailable_types())\n"
        "\tpush_warning(\"ScoreManager: 本局规则集含不可用条件 %s → 判定不可信，"
        "按规格 §8.4 不结束对局。\" % unavailable)",
    )


def g4_equivalent_handler_forwarding(base):
    """守恒D 把 handler 改成「**空转发壳**」：`_on_ruleset_applied` 只转发到助手函数。

    这是**语义完全等价**的重构（信号照收、属性照样应用），所以必须**仍全绿**。

    它防的是「纪律锁退化成token 存在性检查」：若断言写成
    「`_on_ruleset_applied` 体内必须出现 `PlayerStats.apply_player_stats(`」，
    那么这次正确重构就会假红（误杀）。
    → 故测试侧用**调用链可达性**（`_main_reaches`）判定：
      handler 体清空 → 不可达 → 转红（杀）；
      handler 改为转发 → 仍可达 → 仍全绿（本条守恒）。
    """
    return _patch(
        base, MAIN,
        "func _on_ruleset_applied(_ruleset_id: String) -> void:\n"
        "\tvar overrides := _player_stat_overrides()\n"
        "\tif overrides.is_empty():\n"
        "\t\treturn\n"
        "\tvar can_configure := _can_configure_stats()\n"
        "\tfor child in _players.get_children():\n"
        "\t\tPlayerStats.apply_player_stats(child, overrides, can_configure)\n",
        "func _on_ruleset_applied(_ruleset_id: String) -> void:\n"
        "\t_apply_stats_to_existing_players() # 变异体（守恒）：转发到助手\n"
        "\n"
        "\n"
        "func _apply_stats_to_existing_players() -> void:\n"
        "\tvar overrides := _player_stat_overrides()\n"
        "\tif overrides.is_empty():\n"
        "\t\treturn\n"
        "\tvar can_configure := _can_configure_stats()\n"
        "\tfor child in _players.get_children():\n"
        "\t\tPlayerStats.apply_player_stats(child, overrides, can_configure)\n",
    )


MUTANTS = [
    ("杀① 不可用条件改成返回 false", "kill", "test_unavailable_conditions_never_report_false", m1_unavailable_returns_false),
    ("杀② 去掉 push_warning（静默不可用）", "kill", "test_unavailable_warning_actually_emits_a_warning", m2_drop_push_warning),
    ("杀③ ALL_OF 改成 ANY_OF", "kill", "test_all_of_semantics", m3_all_of_becomes_any_of),
    ("杀④ 阈值写死不读字段", "kill", "test_default_ruleset_thresholds_track_manager_fields", m4_hardcode_threshold),
    ("杀⑤ 属性在 add_child 之后应用", "kill", "test_main_applies_stats_before_adding_child", m5_apply_stats_after_add_child),
    ("杀⑥ 不可用条件被短路掩盖", "kill", "test_unavailable_condition_is_not_masked_by_short_circuit", m6_unavailable_masked_by_short_circuit),
    ("杀⑦ 删掉 ruleset_applied.connect", "kill", "test_main_ready_connects_ruleset_applied_signal", m7_drop_ruleset_applied_connect),
    ("杀⑧ handler 函数体清空", "kill", "test_ruleset_applied_handler_really_applies_player_stats", m8_empty_ruleset_applied_handler),
    ("守恒A time_limit 比较式等价改写", "guard", "*", g1_equivalent_time_comparison),
    ("守恒B ALL_OF 短路条件等价改写", "guard", "*", g2_equivalent_short_circuit),
    ("守恒C 告警文案换一种拼接写法", "guard", "*", g3_equivalent_warning_text),
    ("守恒D handler 改为转发到助手", "guard", "*", g4_equivalent_handler_forwarding),
]


def main():
    os.makedirs(BAK_DIR, exist_ok=True)
    base = snapshot()
    for path, text in base.items():
        write(os.path.join(BAK_DIR, os.path.basename(path) + ".bak"), text)

    print("变异测试 · D2-04 规则配置化")
    bf, _, summary = run_failures()
    if bf is None:
        print("  !! 基线 runner 无输出/超时，终止")
        return 1
    print("基线（未变异）：%s" % summary)
    if bf != 0:
        print("  !! 基线本就不绿，先修基线再谈变异")
        return 1
    print("-" * 68)

    total = killed = 0
    guards_ok = 0
    survived, false_positive, inject_fail = [], [], []

    try:
        for name, kind, expect_test, fn in MUTANTS:
            total += 1
            restore_all(base)
            try:
                mutated = fn(base)
            except AssertionError as e:
                inject_fail.append("%s（%s）" % (name, e))
                print("  !! 注入失败  %s —— %s" % (name, e))
                continue
            # 注入生效校验：至少一个文件必须真的变了
            if all(mutated[p] == base[p] for p in base):
                inject_fail.append("%s（变异未改变任何源码）" % name)
                print("  !! 注入失败  %s —— 变异后源码与基线相同" % name)
                continue
            restore_all(mutated)

            fails, failed_tests, _ = run_failures()
            if fails is None:
                inject_fail.append("%s（runner 超时/无输出，多半是变异体语法错）" % name)
                print("  !! runner异常 %s" % name)
                continue

            label = name.split(" ", 1)[1] if " " in name else name
            if kind == "kill":
                if fails > 0:
                    killed += 1
                    hit = "✓" if any(expect_test in t for t in failed_tests) else "!"
                    print("  %s %-28s → 失败 %d  %s"
                          % (hit, label, fails,
                             " ".join(t.replace(SUITE + ".", "") for t in failed_tests)))
                    if hit == "!":
                        print("       ⚠ 转红用例与预期 %s 不符，请核对" % expect_test)
                else:
                    survived.append(name)
                    print("  ✗ %-28s → 仍全绿（弱断言！）" % label)
            else:  # guard：期望**仍全绿**
                if fails == 0:
                    guards_ok += 1
                    print("  ✓ %-28s → 仍全绿（无误杀，断言按语义写）" % label)
                else:
                    false_positive.append(name)
                    print("  ✗ %-28s → 转红 %d（误杀！断言是字面量锁）"
                          % (label, fails))
    finally:
        restore_all(base)

    print("-" * 68)
    dirty = [os.path.basename(p) for p in base if read(p) != base[p]]
    if dirty:
        print("  !! 源码未还原干净！%s" % dirty)
        return 1
    print("工作区已还原干净")

    print("变异体 %d 个 ｜ 杀伤组被杀 %d ｜ 守恒组无误杀 %d ｜ 存活 %d ｜ 误杀 %d ｜ 注入失败 %d"
          % (total, killed, guards_ok, len(survived), len(false_positive), len(inject_fail)))
    if survived:
        print("存活明细（断言太弱，必须重写）：")
        for s in survived:
            print("  ✗ %s" % s)
    if false_positive:
        print("误杀明细（断言是字面量锁，必须改成按语义写）：")
        for s in false_positive:
            print("  ✗ %s" % s)
    if inject_fail:
        print("注入失败明细：")
        for s in inject_fail:
            print("  !! %s" % s)
    if survived or false_positive or inject_fail:
        print("MUTATION FAIL")
        return 1
    print("MUTATION PASS（全部杀伤组被杀死、守恒组无误杀 → 断言有牙齿且按语义写）")
    return 0


if __name__ == "__main__":
    sys.exit(main())