#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# tests/run.sh —— 离线测试（不依赖 Noctalia 宿主，也不调用 easytier-cli）
#
# 两个用例：
#   lib   —— lib/easytier.luau 的纯逻辑：设置兜底、argv、单位换算、派生指标、
#            状态分级、排序、本机信息提取、连接器解析
#   panel —— panel.luau 的完整渲染链：假宿主同步回调 easytier-cli 的输出，
#            再检查渲染树的结构与内容（捕获「面板只有一半内容」这类问题）
#
# 拼接（而不是 require）的原因见 tests/env.luau 顶部注释：luau CLI 的 require
# 会把模块放进隔离的全局环境，模块里看不到我们定义的假宿主；而且 CLI 没有
# io 库，模块也没法自己读源码。
#
# 用法：tests/run.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/easytier-tests.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

# ── 用例 1：lib 纯逻辑 ──────────────────────────────────────────────────────
{
    cat "$here/env.luau"
    printf '\nlocal M = (function()\n'
    cat "$root/lib/easytier.luau"
    printf '\nend)()\n\n'
    cat "$here/assertions.luau"
} > "$tmpdir/lib.luau"

echo "── lib（纯逻辑）────────────────────────────────────────────"
luau "$tmpdir/lib.luau"

# ── 用例 2：panel 完整渲染链 ────────────────────────────────────────────────
# panel.luau 顶部的 require 换成直接用上面包好的 M（lib 与面板同处一个环境）
{
    cat "$here/env.luau"
    cat "$here/env_panel.luau"
    printf '\nlocal M = (function()\n'
    cat "$root/lib/easytier.luau"
    printf '\nend)()\n\n'
    sed 's#^local e = require("./lib/easytier.luau")$#local e = M#' "$root/panel.luau"
    printf '\n'
    cat "$here/panel_assert.luau"
} > "$tmpdir/panel.luau"

echo "── panel（完整渲染链）──────────────────────────────────────"
luau "$tmpdir/panel.luau"
