--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- bar.luau —— 状态栏上的 EasyTier 组网状态
--
-- 默认显示对等节点数（core 没跑时显示「未运行」），可切换成节点数、直连比、
-- 最优延迟、累计流量或本机虚拟 IP。图标与文字按状态分级变色：
--   正常 → 主题主色    偏高（延迟/丢包/出现中继）→ tertiary    掉线或严重 → error
--
-- 交互（可在设置里的组件手势中改绑）：
--   左键：打开详情面板（plugin.toml 的 [widget.actions] 默认绑定）
--   右键：立刻重新抓一次
--
-- 数据来自 easytier-cli 的子进程调用（见 lib/easytier.luau），只读、不落盘、
-- 不常驻进程。
-- ══════════════════════════════════════════════════════════════════════════

local e = require("./lib/easytier.luau")

-- 最近一次快照与派生指标；nil 表示还没拿到数据
local snap = nil
local derived = nil
local inflight = false
local lastFetchAt = 0
local lastLevel = nil

-- ── 设置 ───────────────────────────────────────────────────────────────────

local function settings()
    return {
        display = e.text("display", "status"),
        glyph = e.text("glyph", "network"),
        showGlyph = e.flag("show_glyph", true),
        glyphColor = e.text("glyph_color", "level"),
        hideWhenStopped = e.flag("hide_when_stopped", false),
    }
end

local function glyphRole(cfg, level)
    local w = settings()
    if w.glyphColor == "level" then
        return e.roleOf(level)
    end
    if w.glyphColor == "theme" then
        return "on_surface"
    end
    return w.glyphColor
end

-- ── 文案 ───────────────────────────────────────────────────────────────────

local function barText(w, snap_, d, info)
    if snap_ == nil or snap_.node == nil then
        return e.tr("bar_off", "未运行")
    end
    if w.display == "peers" then
        return tostring(d.total)
    end
    if w.display == "direct" then
        return string.format("%d/%d", d.direct, d.total)
    end
    if w.display == "latency" then
        return e.ms(d.best)
    end
    if w.display == "traffic" then
        return string.format("↓%s ↑%s", e.bytes(d.rx), e.bytes(d.tx))
    end
    if w.display == "ip" then
        return (info and info.ip) or "--"
    end
    -- status：能看到有几个节点，掉线时才占用文字位置
    return tostring(d.total)
end

local function buildTooltip(cfg, w, snap_, level)
    local rows = {}
    local info = e.nodeInfo(snap_)

    table.insert(rows, { key = e.tr("tt_status", "状态"), value = e.statusText(cfg, snap_) })

    if snap_ ~= nil and snap_.node == nil then
        table.insert(rows, { key = e.tr("tt_portal", "RPC 地址"), value = cfg.portal ~= "" and cfg.portal or "127.0.0.1:15888" })
        table.insert(rows, { key = e.tr("tt_hint_key", "提示"), value = e.tr("tt_hint_off", "确认 easytier-core 正在运行；左键打开面板") })
        return rows
    end

    local d = derived or e.derive(snap_)

    if info ~= nil then
        local where = info.hostname
        if info.ip ~= nil then
            where = string.format("%s · %s", info.hostname, info.ip)
        end
        table.insert(rows, { key = e.tr("tt_network", "网络"), value = (info.network ~= nil) and string.format("%s · %s", info.network, where) or where })
        if info.publicIp ~= nil then
            table.insert(rows, { key = e.tr("tt_public_ip", "公网地址"), value = info.publicIp })
        end
        if info.nat ~= nil then
            table.insert(rows, { key = e.tr("tt_nat", "NAT 类型"), value = info.nat })
        end
    end

    table.insert(rows, {
        key = e.tr("tt_peers", "节点"),
        value = string.format(e.tr("tt_peers_value", "%d 个（直连 %d · 中继 %d）"), d.total, d.direct, d.relay),
    })

    if d.counted > 0 then
        table.insert(rows, {
            key = e.tr("tt_latency", "延迟"),
            value = string.format(
                e.tr("tt_latency_value", "最优 %s · 平均 %s · 最差 %s"),
                e.ms(d.best),
                e.ms(d.avg),
                e.ms(d.worst)
            ),
        })
    end

    if d.lossy > 0 then
        table.insert(rows, {
            key = e.tr("tt_loss", "丢包"),
            value = string.format(e.tr("tt_loss_value", "%d 个节点丢包，最大 %s"), d.lossy, e.percentText(d.lossMax)),
        })
    end

    table.insert(rows, { key = e.tr("tt_traffic", "流量"), value = string.format("↓%s ↑%s", e.bytes(d.rx), e.bytes(d.tx)) })

    if info ~= nil and info.version ~= "" then
        table.insert(rows, { key = e.tr("tt_version", "版本"), value = info.version })
    end

    table.insert(rows, { key = e.tr("tt_hint_key", "提示"), value = e.tr("tt_hint", "左键：详情 · 右键：立刻刷新") })
    return rows
end

-- ── 渲染 ───────────────────────────────────────────────────────────────────

local function render()
    local cfg = e.cfg()
    local w = settings()
    local level = e.level(cfg, snap, derived)

    -- 掉线且设置里要求隐藏时，整块收起来（留出栏位给别的组件）
    if w.hideWhenStopped and level == "off" then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)

    -- 状态变化（运行 ⇄ 掉线）时按设置通知一次
    if cfg.notify and lastLevel ~= nil and level ~= lastLevel then
        if level == "off" and (lastLevel == "ok" or lastLevel == "warn") then
            noctalia.notifyError(e.tr("notify_down_title", "EasyTier 已断开"), e.tr("notify_down_body", "easytier-cli 连不上 core，组网可能已中断"))
        elseif (level == "ok" or level == "warn") and lastLevel == "off" then
            noctalia.notify(e.tr("notify_up_title", "EasyTier 已恢复"), e.tr("notify_up_body", "core 重新可管理"))
        end
    end
    lastLevel = level

    local info = e.nodeInfo(snap)
    local d = derived or e.derive(snap)
    local role = e.roleOf(level)

    if w.showGlyph then
        barWidget.setGlyph(w.glyph)
        barWidget.setGlyphColor(glyphRole(cfg, level))
    else
        barWidget.setGlyph("")
    end

    barWidget.setText(barText(w, snap, d, info))
    -- 正常时回落到组件自己配置的文字颜色，异常/告警时才接管
    if level == "ok" or level == "loading" then
        barWidget.setColor("on_surface")
    else
        barWidget.setColor(role)
    end

    barWidget.setTooltip(buildTooltip(cfg, w, snap, level))
end

-- ── 抓取 ───────────────────────────────────────────────────────────────────

local function request()
    if inflight then
        return
    end
    local cfg = e.cfg()
    inflight = true
    e.fetch(cfg, e.FAST_SUBS, function(result)
        inflight = false
        lastFetchAt = os.time()
        snap = result
        derived = e.derive(result)
        render()
    end)
end

-- ── 指针回调 ───────────────────────────────────────────────────────────────

--- 左键：清单里默认绑成了 panel-toggle；用户改成 none 时这里兜底
function onClick()
    noctalia.togglePanel("ylxc/easytier:panel")
end

--- 右键：立刻重新抓一次（忽略刷新间隔）
function onRightClick()
    if e.cliAvailable(e.cfg()) then
        request()
    end
    noctalia.log("[easytier] 手动刷新")
end

function onIpc(event, _payload)
    if event == "refresh" then
        request()
    elseif event == "panel" then
        noctalia.togglePanel("ylxc/easytier:panel")
    end
end

-- ── 生命周期 ───────────────────────────────────────────────────────────────

function update()
    local cfg = e.cfg()
    noctalia.setUpdateInterval(math.max(1, math.floor(cfg.refresh / 2)) * 1000)
    -- 到期就抓（tick 比刷新间隔密，避免 10 秒的刷新被 12 秒的 tick 拖慢）
    if not inflight and os.time() - lastFetchAt >= cfg.refresh then
        request()
    end
end

update()
