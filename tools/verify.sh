#!/usr/bin/env bash
#
# tools/verify.sh —— sekai 一键自检（headless 静默验证）
#
# 用途：把「导入 → 脚本可解析性校验 → 测试」固化成一条可重复命令，
#       供每次改动后自检。任一必需环节失败 → 非零退出。
#
# ⚠ 一句话纪律：**在本项目不要用 `--import`，用纯 `--headless`。**
#   `--import` 会走编辑器代码路径并重写 project.godot、删掉 Vulkan 锁（§4-17）。
#   本脚本已把它降级为「仅首次（类缓存不存在时）执行」+「执行后强制断言锁还在」。
#   详见文件头「为什么 --import 必须条件执行」。

# 用法：
#   bash tools/verify.sh            # 静默模式：只打印每环节结论 + 最终退出码
#   bash tools/verify.sh -v         # 详细模式：追加 --import / 测试的完整原始输出
#   GODOT_BIN=/path/to/godot bash tools/verify.sh
#
# 环境变量：
#   GODOT_BIN       Godot 可执行文件路径（可选）。未设置时按顺序探测常见安装位置，最后退回 `godot`。
#   VERIFY_TIMEOUT  单步超时秒数（默认 180）。
#
# 退出码：
#   0   全部环节通过
#   1   有环节失败（--import 失败 / 测试失败 / 步骤超时 / import 破坏 Vulkan 锁）
#   2   前置条件不满足（找不到 Godot 可执行文件 / 参数错误）
#
# ---------------------------------------------------------------------------
# 为什么本脚本「不」用裸 `--check-only`（ES-5.5 字面要求的第二步）
# ---------------------------------------------------------------------------
# ES-5.5 原文要求 `--import` → `--check-only` → `test_runner.tscn`。但在本项目实测，
# 裸 `--check-only` 有两种致命用法，都不可用作门禁（2026-10-06 实测）：
#
#   ① `godot --headless --path . --check-only <file>`
#      → 会挂起不退出（本机 4.7.2 实测 timeout 15s 后仍被 kill，exit 124）。
#
#   ② `godot --headless --path . --script <file> --check-only`
#      → 能退出，但该模式**不注册 Autoload**。本项目几乎每个关键脚本都引用
#        `NetworkManager` / `MusicManager`，于是本应「通过」的脚本被误报为：
#            SCRIPT ERROR: Compile Error: Identifier not found: NetworkManager
#        exit code = 1。即：干净的 HEAD 上裸跑这个门禁也会「失败」。
#
# 结论：裸 `--check-only` 在本项目**必然误报**，不适合当门禁。ES-5.5 的**实质意图**
# 是「改动后一键确认脚本可解析 + 测试通过」——而本项目里有更可靠的等价物：
#
#   `test_runner.tscn` 以**普通场景**运行 → Autoload 正常注册 → 会 load+compile 被测脚本。
#   实测：注入语法错误时 runner 会明确报 `Failed to load script ... Parse error`。
#   因此它同时充当「可解析性门禁」+「行为门禁」，正是 ES-5.5 想要的那一步。
#
# 本脚本采用方案 A：`--import`（建类缓存）→ `test_runner.tscn`（解析 + 行为门禁）。
# 另有一个关键运行事实：**runner 在遇到解析错误时不会走到 quit()，会挂起**
# （实测 exit 124）。所以本脚本对 runner 强制加 timeout，并把「超时」判为失败，
# 同时尝试从输出里抓出 `Parse error` 作为失败原因。详见下方 run_runner()。
# ---------------------------------------------------------------------------
#
# ---------------------------------------------------------------------------
# ⚠⚠⚠ 为什么 `--import` 必须「条件执行」（control_checklist §4-17 第 5 次复发的机制）
# ---------------------------------------------------------------------------
# 2026-10-06 实测事故：**跑一次本脚本就会删掉 project.godot 的 Vulkan 锁。**
#
#   机制：`--import` 走的是 Godot 的**编辑器代码路径**（输出里可见
#         `loading_editor_layout` / 「正在加载中央编辑器布局」），而编辑器在加载
#         布局时会**重写 project.godot**，把
#             rendering_device/driver.windows="vulkan"
#         这一整块删掉（Godot 4.7 对「当前非默认渲染后端」的容错写法）。
#
#   为什么这条链特别恶心：删锁的**不是**那次运行，而是**下一次**。
#         verify.sh 跑完 → 锁没了 → verify.sh 自己这轮全绿（它没检查）
#         → 下一轮测试因 D3D12 崩溃而转红 → 失败现象指向「测试坏了」
#         → 真因（「脚本破坏了配置」）被完全掩盖。
#         这正是 C-19 复发 5 次、前 4 次都查不到根因的机制。
#
#   判据（结论，写进纪律）：
#         **在这个项目里不要用 `--import`，用纯 `--headless`。**
#         class_name 注册在**首次**导入后就已写入
#         `.godot/global_script_class_cache.cfg`，后续纯 `--headless` 运行即可。
#
#   因此本脚本的两条硬规则：
#     ① `--import` **只在类缓存不存在时**才跑（缓存已存在 → 打印 SKIP 直接跳过）。
#     ② 万一还是跑了，`--import` 之后**立刻**断言 Vulkan 锁还在；不在就
#        **自动还原 + 非零退出**，绝不允许流程「继续往下跑测试然后莫名转红」。
#   还原一律用 `git show HEAD:project.godot > project.godot`（写字节），
#   **禁止** `git checkout --` / `git restore`（§4-11 实测会「退出码 0 但文件没还原」）。
# ---------------------------------------------------------------------------

set -u

# --- 0. 定位项目根（对当前工作目录不敏感）-----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || { echo "FAIL 无法进入项目根: $PROJECT_ROOT"; exit 2; }

# --- 1. 解析参数 -------------------------------------------------------------
VERBOSE=0
for arg in "$@"; do
	case "$arg" in
		-v|--verbose) VERBOSE=1 ;;
		-h|--help)
			sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "FAIL 未知参数: $arg（用 --help 查看用法）"
			exit 2
			;;
	esac
done

# --- 2. 探测 Godot 可执行文件 ------------------------------------------------
resolve_godot() {
	if [ -n "${GODOT_BIN:-}" ]; then
		if [ -x "$GODOT_BIN" ] || command -v "$GODOT_BIN" >/dev/null 2>&1; then
			printf '%s' "$GODOT_BIN"
			return 0
		fi
		echo "FAIL GODOT_BIN 指向的文件不可执行: $GODOT_BIN" >&2
		return 1
	fi
	# 常见安装位置（按顺序探测）
	local candidates=(
		"$HOME/Desktop/Godot_v4.7.2-stable_win64_console.exe"
		"$HOME/Desktop/Godot_v4.7.2-stable_win64.exe"
		"/c/Program Files/Godot/godot.exe"
		"/usr/local/bin/godot"
		"/usr/bin/godot"
	)
	local c
	for c in "${candidates[@]}"; do
		if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
	done
	# 最后退回 PATH 上的 godot
	if command -v godot >/dev/null 2>&1; then printf '%s' "godot"; return 0; fi
	return 1
}

GODOT="$(resolve_godot)"
if [ -z "$GODOT" ]; then
	echo "FAIL 找不到 Godot 可执行文件。请设置环境变量 GODOT_BIN 指向它，例如："
	echo "     GODOT_BIN=/c/path/to/Godot_v4.7.2-stable_win64_console.exe bash tools/verify.sh"
	exit 2
fi

TIMEOUT_SECS="${VERIFY_TIMEOUT:-180}"

# 日志放到项目内的临时目录，避免 Windows 路径下 rm 的安全删除拦截
LOG_DIR="$PROJECT_ROOT/.verify_tmp"
mkdir -p "$LOG_DIR"

# --- 3. 输出辅助 -------------------------------------------------------------
# 详细模式才回显原始输出
dump() {
	if [ "$VERBOSE" -eq 1 ]; then
		echo "----- 原始输出开始 -----"
		cat "$1"
		echo "----- 原始输出结束 -----"
	fi
}

# --- 4. 步骤 1：--import（建资源 / 类缓存）----------------------------------
# ⚠ 条件执行 + 后置断言，理由见文件头「为什么 --import 必须条件执行」。
IMPORT_LOG=""
RUNNER_LOG=""
CLASS_CACHE="$PROJECT_ROOT/.godot/global_script_class_cache.cfg"

# 用 git show HEAD:<path> 读字节并写回（禁用 git checkout --/git restore：§4-11 假成功）
restore_project_godot() {
	if git show HEAD:project.godot > "$PROJECT_ROOT/project.godot" 2>/dev/null \
	   && grep -q 'rendering_device/driver.windows="vulkan"' "$PROJECT_ROOT/project.godot"; then
		printf '      已自动还原 project.godot（git show HEAD:project.godot），Vulkan 锁已恢复 o\n'
		return 0
	fi
	printf '      x 自动还原失败！请手工执行：git show HEAD:project.godot > project.godot\n'
	return 1
}

# Vulkan 锁守门：无论 --import 跑没跑，都必须断言锁还在。
# ⚠ 为什么不放在「--import 之后」这一处：实测发现**锁可能在本脚本跑之前就已经没了**
#   （上一次误用 --import、或用 Godot 编辑器打开过项目）。若断言只在 import 之后做，
#   类缓存已存在时的 SKIP 路径就会**完全绕过检查** → 在坏配置上跑测试 → 转红 →
#   失败现象指向「测试坏了」，真因（配置被破坏）再次被掩盖（§4-17 前 4 次的机制）。
#   所以这里做成**无条件前置断言**：进门先验锁，坏在源头就不往下走。
assert_vulkan_lock() {
	if grep -q 'rendering_device/driver.windows="vulkan"' "$PROJECT_ROOT/project.godot"; then
		return 0
	fi
	printf 'FAIL  %s\n' "Vulkan 锁缺失（control_checklist §4-17 第 5 次复发）。还原命令：git show HEAD:project.godot > project.godot"
	if [ "${1:-}" = "import" ]; then
		printf '      %s\n' "⚠ 就在刚才的 --import 之后检测到：--import 走编辑器代码路径（loading_editor_layout）会重写 project.godot 并删掉该行。"
	fi
	restore_project_godot || true
	echo "  已中止：绝不在被破坏的配置上继续跑测试（否则失败现象会指向「测试坏了」，掩盖真因）。"
	IMPORT_VULKAN_BROKEN=1
	return 1
}

run_import() {
	local log="$LOG_DIR/import.log"

	# ① 条件执行：类缓存已存在 → 跳过 --import（--import 会污染 project.godot）
	if [ -f "$CLASS_CACHE" ]; then
		# 即便跳过 import，也**必须**验锁（锁可能是上一次误用 --import 时已被删）
		if ! assert_vulkan_lock ""; then return 1; fi
		printf 'SKIP  %s\n' "import（类缓存已存在）"
		printf '      %s\n' "$CLASS_CACHE"
		return 0
	fi

	printf 'INFO  %s\n' "类缓存不存在，执行首次 --import（此后本步骤将一直 SKIP）"
	timeout "$TIMEOUT_SECS" "$GODOT" --headless --path "$PROJECT_ROOT" --import >"$log" 2>&1
	local rc=$?
	dump "$log"
	if [ "$rc" -ne 0 ]; then
		if [ "$rc" -eq 124 ]; then
			printf 'FAIL  %s\n' "import（步骤超时 ${TIMEOUT_SECS}s）"
		else
			printf 'FAIL  %s\n' "import（退出码 $rc；GLB/贴图等资源导入失败）"
		fi
		grep -iE "error|failed|could not" "$log" | head -5 | sed 's/^/      /'
		echo "  详见：$log（保留供排查）"
		IMPORT_LOG="$log"
		return 1
	fi

	# ② 后置断言：--import 之后 Vulkan 锁必须还在（§4-17 第 5 次复发的守门）
	if ! assert_vulkan_lock "import"; then
		rm -f "$log"
		return 1
	fi

	printf 'PASS  %s\n' "import（资源/类缓存就绪，Vulkan 锁完好）"
	rm -f "$log"
	return 0
}

# --- 5. 步骤 2：脚本可解析性 + 行为门禁（test_runner.tscn）------------------
# 关键：runner 遇到解析错误时**不会走到 quit()，会挂起** → 必须用 timeout，
#       并把超时判为失败，同时抓取输出里的 Parse error 作为原因。
run_runner() {
	local log="$LOG_DIR/runner.log"
	timeout "$TIMEOUT_SECS" "$GODOT" --headless --path "$PROJECT_ROOT" res://tests/test_runner.tscn >"$log" 2>&1
	local rc=$?
	dump "$log"

	# 无论哪种结局，先抓解析错误（作为可读原因）
	local parse_err
	parse_err="$(grep -iE "Parse Error|Failed to load script" "$log" | head -3)"

	if [ "$rc" -eq 124 ]; then
		printf 'FAIL  %s\n' "测试 + 解析（步骤超时 ${TIMEOUT_SECS}s——runner 未走到退出，通常是脚本解析错误导致）"
		[ -n "$parse_err" ] && echo "$parse_err" | sed 's/^/      /'
		echo "  详见：$log（保留供排查）"
		RUNNER_LOG="$log"
		return 1
	fi

	if [ "$rc" -eq 0 ]; then
		# 绿色通道：正常退出 0；但若输出里意外夹带解析错误，也算失败（防御）
		if [ -n "$parse_err" ]; then
			printf 'FAIL  %s\n' "测试 + 解析（退出码 0 但输出含解析错误）"
			echo "$parse_err" | sed 's/^/      /'
			RUNNER_LOG="$log"
			return 1
		fi
		# 抓一行汇总作为结论附注（可选）
		local pass_line
		pass_line="$(grep -E "用例 [0-9]+ ｜" "$log" | tail -1)"
		printf 'PASS  %s\n' "测试 + 解析（$pass_line）"
		rm -f "$log"
		return 0
	fi

	# rc != 0 且非超时：测试失败（runner 正常置了非零退出码）或其它异常
	local summary
	summary="$(grep -E "用例 [0-9]+ ｜|=================== (PASS|FAIL)" "$log" | tail -2)"
	printf 'FAIL  %s\n' "测试 + 解析（退出码 $rc）"
	[ -n "$summary" ] && echo "$summary" | sed 's/^/      /'
	[ -n "$parse_err" ] && echo "$parse_err" | sed 's/^/      /'
	echo "  详见：$log（保留供排查）"
	RUNNER_LOG="$log"
	return 1
}

# --- 6. 主流程 ---------------------------------------------------------------
echo "sekai verify ｜ Godot: $GODOT"
echo "-----------------------------------------------------"

FAILED=0
IMPORT_VULKAN_BROKEN=0

if ! run_import; then
	FAILED=1
	# Vulkan 锁被破坏时**立刻中止**：在坏配置上跑测试得到的红结论全是噪声
	# （真因是「脚本破坏了配置」，现象却指向「测试坏了」）。这正是 §4-17 查不到根因的机制。
	if [ "$IMPORT_VULKAN_BROKEN" -eq 1 ]; then
		echo "-----------------------------------------------------"
		echo "VERIFY FAIL（退出码 1）｜ import 污染 project.godot，已中止（未跑测试）"
		exit 1
	fi
fi

# import 失败时仍尝试跑 runner（可能给更多线索），但整体已判失败
if ! run_runner; then FAILED=1; fi

echo "-----------------------------------------------------"

# 失败时**不删**日志，否则用户看到"详见 xxx"却找不到文件。
if [ "$FAILED" -eq 0 ]; then
	rmdir "$LOG_DIR" 2>/dev/null || true
	echo "VERIFY PASS（退出码 0）"
	exit 0
else
	echo "VERIFY FAIL（退出码 1）｜ 排查日志：$LOG_DIR"
	exit 1
fi
