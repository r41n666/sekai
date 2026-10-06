#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""变异测试 · 对局复位闭环（EP-3 增补match_reset）—— 验证新增断言**真的有牙齿**。

## 为什么需要这个文件
本轮修的是**用户双端实测报出的真实缺陷**：房主点「再来一局」后，**客户端**结算面板永不关闭。
根因是`ScoreManager._apply_reset()` 只 emit `score_changed`（比分板的绑定面），
结算面板没有任何复位信号可听。
这类缺陷的测试最容易写成**弱断言**：
  · 只断言「信号存在」→ 变异掉emit 仍全绿（正是本轮要防的「信号加了但没发」）；
  · 只断言「面板关了」→ 变异掉 `_has_result` 复位仍全绿（下次结算被陈旧态污染）；
  · 只断言房主路径 → 变异掉客户端 emit 仍全绿（缺陷恰恰在客户端那条唯一路径上）。
→ 故每个关键不变量配一个变异体，确认对应用例**如期转红**。

## 纪律（本脚本自身踩过的坑，务必保持）
1. **注入必须校验**：注入后源码要与备份不同，否则报 `NOT_APPLIED`。
2. **注入失败 ≠ 存活**：两者分开计数，且**注入失败也要让本脚本非零退出**
   （早期版本注入全失败却打印 "MUTATION PASS" —— 全绿结论比红结论危险得多）。
3. **锚点必须唯一命中**：多处命中视为注入失败（改到哪一处是未定义的，
   「变异体存活」的结论会失去意义）。
4. **只改一份文件时不碰其它文件**（避免误伤工作区）；收尾 `finally` 里还原 + 逐字节自检。
5. **守恒对照组（§4-16）**：弱断言有「漏杀」与「误杀」两个方向，只测漏杀不够。
   语义等价的正确改写**必须仍然全绿**；守恒组转红即判「误杀」并非零退出。

用法：
    python tools/mutation_match_reset.py
退出码：0 = 全部杀伤组变异体被杀死、且守恒对照组全绿；1 = 有存活 / 误杀 / 注入失败
"""

import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCORE_MANAGER = os.path.join(ROOT, "scripts", "game", "score_manager.gd")
MATCH_RESULT = os.path.join(ROOT, "scripts", "ui", "match_result.gd")
BAK_DIR = os.path.join(ROOT, ".tmpdbg", "mutation_match_reset")
GODOT = os.environ.get(
    "GODOT_BIN", "C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe"
)

SUITE = "test_match_result"

TAB = "\t"


def read(path):
    with io.open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def snapshot():
    """备份全部可能被改动的文件，返回 {路径: 原文}。"""
    return {p: read(p) for p in (SCORE_MANAGER, MATCH_RESULT)}


def restore_all(snap):
    for path, text in snap.items():
        write(path, text)


def run_failures():
    """跑一次 headless runner，返回 (失败数, 失败用例名列表, 解析错误列表)。"""
    proc = subprocess.run(
        [GODOT, "--headless", "--path", ROOT, "res://tests/test_runner.tscn"],
        capture_output=True, text=True, timeout=300, errors="replace",
    )
    out = proc.stdout + proc.stderr
    m = re.search(r"用例\s+(\d+)\s+｜\s+断言\s+(\d+)\s+｜\s+失败\s+(\d+)", out)
    if not m:
        return None, [], ["runner 无输出/超时（多半是变异体语法错）"]
    failed = sorted(set(re.findall(re.escape(SUITE) + r"\.([A-Za-z0-9_]+)", out)))
    parse_err = re.findall(r"Parse Error|Failed to load script", out)
    return int(m.group(3)), failed, parse_err


# ══════════════════════════════════════════════════════════════════════
#  变异体定义
#  (名称, 期望转红的用例, 变异函数, 分组)
#  分组 "kill" = 期望转红；"conserve" = 语义等价改写，期望**仍全绿**（守恒对照）
#  变异函数签名：base(= 全部基线源码 dict) -> mutated dict；锚点未命中/多处命中 raise
# ══════════════════════════════════════════════════════════════════════


def _patch(base, key, old, new):
    """在base[key] 里替换 old→new；锚点必须**恰好命中一次**（0 次或多���都算注入失败）。"""
    src = base[key]
    n = src.count(old)
    assert n == 1, "锚点命中 %d 次（要求恰好 1 次）：%s / %r" % (n, key, old[:70])
    return dict(base, **{key: src.replace(old, new, 1)})


# ── 杀伤组：真缺陷改了必须转红 ──

def m1_drop_emit(base):
    """M1 去掉 `_apply_reset()` 末尾的 `match_reset.emit()` —— **本轮缺陷的原始形态**。"""
    return _patch(
        base, SCORE_MANAGER,
        TAB + "_set_state(MatchState.IDLE)\n"
        + TAB + "score_changed.emit(scores, time_remaining)\n"
        + TAB + "match_reset.emit()\n",
        TAB + "_set_state(MatchState.IDLE)\n"
        + TAB + "score_changed.emit(scores, time_remaining)\n",
    )


def m2_keep_has_result(base):
    """M2 `close_ui()` 不复位 `_has_result` —— 复位后残留 true → 下次结算被陈旧态污染。"""
    return _patch(
        base, MATCH_RESULT,
        TAB + "_has_result = false\n"
        + TAB + "_winner_id = ScoreManager.WINNER_UNSET\n",
        TAB + "_winner_id = ScoreManager.WINNER_UNSET\n",
    )


def m3_no_input_restore(base):
    """M3 复位时不恢复 `input_blocked` —— 面板关了但玩家仍不能动。"""
    return _patch(
        base, MATCH_RESULT,
        TAB + "visible = false\n"
        + TAB + "_set_input_blocked(false)\n"
        + TAB + "_capture_mouse()\n",
        TAB + "visible = false\n"
        + TAB + "_capture_mouse()\n",
    )


def m4_no_connect(base):
    """M4 `bind()` 不连 `match_reset` —— **「信号加了但 UI 没接」的半吊子实现**。"""
    return _patch(
        base, MATCH_RESULT,
        TAB + "if score_manager.has_signal(\"match_reset\") \\\n"
        + TAB * 3 + "and not score_manager.match_reset.is_connected(_on_match_reset):\n"
        + TAB * 2 + "score_manager.match_reset.connect(_on_match_reset)\n",
        "",
    )


def m5_handler_noop(base):
    """M5 `_on_match_reset()` 什么都不做（空实现）—— 复位信号收到了但面板不关。"""
    return _patch(
        base, MATCH_RESULT,
        "func _on_match_reset() -> void:\n" + TAB + "close_ui()\n",
        "func _on_match_reset() -> void:\n" + TAB + "pass\n",
    )


def m6_leave_final_scores(base):
    """M6 复位时不清 `_final_scores` —— 下次 `open_ui()` 会渲染上一局的比分表。"""
    return _patch(
        base, MATCH_RESULT,
        TAB + "_final_scores = {}\n" + TAB + "_duration_seconds = 0.0\n",
        TAB + "_duration_seconds = 0.0\n",
    )


def m7_no_authority_guard(base):
    """M7 `net_match_reset` 去掉权威守卫 —— 房主会复位两次（且未来非幂等副作用会出事）。"""
    return _patch(
        base, SCORE_MANAGER,
        "func net_match_reset() -> void:\n"
        + TAB + "if is_authority():\n"
        + TAB * 2 + "return\n"
        + TAB + "_apply_reset()\n",
        "func net_match_reset() -> void:\n"
        + TAB + "_apply_reset()\n",
    )


def m8_again_closes_directly(base):
    """M8 `[再来一局]` 绕过统一入口直接 `close_ui()` —— 未绑定 ScoreManager 时陈旧态残留。"""
    return _patch(
        base, MATCH_RESULT,
        TAB * 2 + "_score_manager.call(\"request_reset\")\n" + TAB + "_on_match_reset()\n",
        TAB * 2 + "_score_manager.call(\"request_reset\")\n" + TAB + "close_ui()\n",
    )


# ── 守恒对照组：语义等价的正确改写**必须仍然全绿**（§4-16 anti-误杀）──

def c1_emit_before_score(base):
    """C1【守恒】把 `match_reset.emit()` 挪到 `score_changed` 之前 —— 两条信号都发、语义等价。

    ⚠ 唯一的差别是同一帧内的**先后顺序**，而本项目对这两条信号的相对顺序**没有**契约
    （面板关闭与比分板清空都是纯 UI 操作，互不依赖）→ 断言不应误杀这种改写。
    """
    return _patch(
        base, SCORE_MANAGER,
        TAB + "_set_state(MatchState.IDLE)\n"
        + TAB + "score_changed.emit(scores, time_remaining)\n"
        + TAB + "match_reset.emit()\n",
        TAB + "_set_state(MatchState.IDLE)\n"
        + TAB + "match_reset.emit()\n"
        + TAB + "score_changed.emit(scores, time_remaining)\n",
    )


def c2_clear_before_close(base):
    """C2【守恒】`_on_match_reset` 里先清态再 `close_ui()`（与现写法顺序相反）—— 语义等价。

    `close_ui()` 只看 `visible`、不读 `_has_result`，故两条语句换个先后不改变可观测行为。
    """
    return _patch(
        base, MATCH_RESULT,
        TAB + "close_ui()\n",
        TAB + "_has_result = false\n" + TAB + "close_ui()\n",
    )


def c3_connect_with_and_not(base):
    """C3【守恒】`bind()` 改用 `is_connected(...)` 的否定前置判断（另一种等价写法）。

    现写法 `has_signal(x) and not is_connected(c)` ↔ 改写后 `has_signal(x) and is_connected(c) == false`。
    断言必须按**语义**（连上了没有）而非字面量，否则会把正确改写判成失败（§4-16 误杀）。
    """
    return _patch(
        base, MATCH_RESULT,
        TAB * 3 + "and not score_manager.match_reset.is_connected(_on_match_reset):\n",
        TAB * 3 + "and score_manager.match_reset.is_connected(_on_match_reset) == false:\n",
    )


MUTANTS = [
    # ── 杀伤组 ──
    ("M1 去掉 match_reset 的 emit", "test_apply_reset_emits_match_reset", m1_drop_emit, "kill"),
    ("M2 复位不复位 _has_result", "test_again_button_closes_panel_and_clears_state", m2_keep_has_result, "kill"),
    ("M3 复位不恢复 input_blocked", "test_input_blocked_is_symmetric_across_reset", m3_no_input_restore, "kill"),
    ("M4 bind 不连 match_reset", "test_panel_actually_connects_match_reset", m4_no_connect, "kill"),
    ("M5 _on_match_reset 空实现", "test_reset_closes_panel_on_client_path", m5_handler_noop, "kill"),
    ("M6 复位不清 _final_scores", "test_reset_clears_all_stale_result_fields", m6_leave_final_scores, "kill"),
    ("M7 net_match_reset 去权威守卫", "test_net_match_reset_ignored_by_authority", m7_no_authority_guard, "kill"),
    ("M8 再来一局绕过统一入口", "test_again_button_uses_unified_reset_entry", m8_again_closes_directly, "kill"),
    # ── 守恒对照组（期望仍全绿）──
    ("C1【守恒】emit 顺序对调", None, c1_emit_before_score, "conserve"),
    ("C2【守恒】先清态再close_ui", None, c2_clear_before_close, "conserve"),
    ("C3【守恒】is_connected 否定前置", None, c3_connect_with_and_not, "conserve"),
]


def main():
    os.makedirs(BAK_DIR, exist_ok=True)
    base = snapshot()
    for path, text in base.items():
        write(os.path.join(BAK_DIR, os.path.basename(path) + ".bak"), text)

    print("变异测试 · 对局复位闭环（ScoreManager.match_reset）")
    bf, _, _ = run_failures()
    if bf is None:
        print("  !! 基线 runner 无输出/超时，终止")
        return 1
    print("基线（未变异）：%d 失败" % bf)
    if bf != 0:
        print("  !! 基线本就不绿，先修基线再谈变异")
        return 1
    print("-" * 68)

    total = killed = 0
    survived, false_kill, inject_fail = [], [], []

    try:
        for name, expect_test, fn, group in MUTANTS:
            total += 1
            restore_all(base)
            try:
                mutated = fn(base)
            except AssertionError as e:
                inject_fail.append("%s（%s）" % (name, e))
                print("  !! 注入失败  %s —— %s" % (name, e))
                continue
            # 注入生效校验：至少一个文件必须真的变了（否则「什么都没注入」会被当成存活）
            if all(mutated[p] == base[p] for p in base):
                inject_fail.append("%s（变异未改变任何源码）" % name)
                print("  !! 注入失败  %s —— 变异后源码与基线相同" % name)
                continue
            restore_all(mutated)

            fails, failed_tests, parse_err = run_failures()
            if fails is None:
                inject_fail.append("%s（runner 超时/无输出：%s）" % (name, "; ".join(parse_err[:2])))
                print("  !! runner异常 %s —— %s" % (name, "; ".join(parse_err[:2])))
                continue

            if group == "kill":
                if fails > 0:
                    killed += 1
                    hit = "OK" if any(expect_test in t for t in failed_tests) else "!!"
                    print("  %s 变异体被杀  %-28s → 失败 %d  %s"
                          % (hit, name, fails,
                             " ".join(t.replace(SUITE + ".", "") for t in failed_tests)))
                    if hit == "!!":
                        print("       !! 转红用例与预期 %s 不符，请核对" % expect_test)
                        inject_fail.append("%s（转红用例与预期不符）" % name)
                else:
                    survived.append(name)
                    print("  ✗ 变异体存活  %-28s → 仍全绿（弱断言！）" % name)
            else:  # conserve
                if fails == 0:
                    print("  OK 守恒对照组  %-26s → 仍全绿（无误杀）" % name)
                else:
                    false_kill.append(name)
                    print("  ✗ 守恒组转红  %-28s → 失败 %d（误杀！%s）"
                          % (name, fails, " ".join(failed_tests)))
    finally:
        restore_all(base)

    print("-" * 68)
    dirty = [p for p in base if read(p) != base[p]]
    if dirty:
        print("  !! 源码未还原干净！%s" % dirty)
        return 1
    print("工作区已还原干净")

    kills = sum(1 for m in MUTANTS if m[3] == "kill")
    cons = sum(1 for m in MUTANTS if m[3] == "conserve")
    print("变异体 %d 个（杀伤 %d + 守恒 %d）｜ 被杀 %d ｜ 存活 %d ｜ 误杀 %d ｜ 注入失败 %d"
          % (total, kills, cons, killed, len(survived), len(false_kill), len(inject_fail)))
    if survived:
        print("存活明细：")
        for s in survived:
            print("  ✗ %s → 断言太弱，必须重写" % s)
    if false_kill:
        print("误杀明细：")
        for s in false_kill:
            print("  ✗ %s → 断言按字面量写死了，挡住了语义等价的正确改写（§4-16）" % s)
    if inject_fail:
        print("注入失败明细：")
        for s in inject_fail:
            print("  !! %s" % s)
    if survived or false_kill or inject_fail:
        print("MUTATION FAIL")
        return 1
    print("MUTATION PASS（杀伤组全灭 + 守恒组全绿 → 断言有牙齿且不误杀）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
