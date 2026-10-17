--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- tests/env.luau —— 测试用的假宿主与断言辅助
--
-- 由 tests/run.sh 把它、lib/easytier.luau、tests/assertions.luau 拼成
-- 一个文件后交给 luau 执行。原因：luau CLI 的 require 会把模块放进隔离的
-- 全局环境（模块里看不到这里定义的 noctalia），而且 CLI 没有 io 库，
-- 所以只能靠「拼接 + 同一环境执行」。
--
-- 假宿主只实现 lib 在纯解析路径上用到的 API；runAsync 故意返回 false
-- （启动失败分支），任何真实抓取都不会发生。
-- ══════════════════════════════════════════════════════════════════════════

local cfgTable = {
    cli_path = "/usr/bin/easytier-cli",
    rpc_portal = "127.0.0.1:15888",
    instance_name = "default",
    instance_id = "",
    refresh_seconds = 10,
    warn_latency_ms = 150,
    crit_latency_ms = 400,
    relay_warn = true,
    loss_warn_percent = 2,
    loss_crit_percent = 10,
    fetch_extras = true,
    max_peers = 64,
    server_prefix = "PublicServer",
    notify_state_change = false,
    display = "status",
    glyph = "network",
    show_glyph = true,
    glyph_color = "level",
    hide_when_stopped = false,
}

noctalia = {
    getConfig = function(key)
        return cfgTable[key]
    end,
    -- 返回键名本身，于是 lib 的 M.tr 会回落到内置的中文兜底文案
    tr = function(key)
        return key
    end,
    fileExists = function()
        return true
    end,
    commandExists = function()
        return true
    end,
    json = {
        decode = function()
            return nil
        end,
        encode = function()
            return "{}"
        end,
    },
    runAsync = function()
        return false
    end,
    log = function() end,
}

local checks = 0

local function eq(actual, expected, what)
    checks += 1
    if actual ~= expected then
        error(string.format("[FAIL] %s：期望 %s，实际 %s", what, tostring(expected), tostring(actual)), 2)
    end
end
