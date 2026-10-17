--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- panel.luau —— EasyTier 详情面板
--
-- 自上而下：
--   本机卡片  虚拟 IP、网络名、版本、NAT 类型、公网地址、实例 ID、监听器
--   概览      节点数 / 直连 / 中继 / 最优与平均延迟 / 累计收发
--   节点列表  每个对等节点：cost、延迟、丢包、隧道协议、NAT 类型、收发字节
--   路由表    ipv4、下一跳、路径跳数、路径延迟（next_hop_lat / path_latency）
--   连接器    每个 --peer 地址的连通状态
--   代理      子网代理 CIDR（node.proxy_cidrs）
--   端口转发  已配置的转发条目
--
-- 打开方式：栏组件左键，或
--   noctalia msg panel-toggle ylxc/easytier:panel
-- ══════════════════════════════════════════════════════════════════════════

local e = require("./lib/easytier.luau")

local snap = nil
local derived = nil
local inflight = false
local lastFetchAt = 0
local open = false
local expanded = false
local serversOpen = false -- 服务器节点（公共共享节点）默认折叠
local routesOpen = false -- 路由表默认折叠
local connectorsOpen = false -- 连接器列表默认折叠

local draw, request -- 前向声明（draw 供卡片回调，request 供 offlineCard 引用）

local function tr(key, fallback)
    return e.tr(key, fallback)
end

-- ── 配色与图标 ─────────────────────────────────────────────────────────────

local function costGlyph(cost)
    if cost == "p2p" then
        return "plug"
    end
    if cost == "relay" then
        return "route"
    end
    return "server"
end

local function lossRole(cfg, loss)
    if loss == nil or loss <= 0 then
        return "on_surface_variant"
    end
    if loss >= cfg.lossCrit then
        return "error"
    end
    return "tertiary"
end

-- ── 小组件 ─────────────────────────────────────────────────────────────────

--- 概览里的一块：小标题 + 大字数值
local function tile(label, value, glyph, role)
    return ui.column({ gap = 2, padding = 8, radius = 8, fill = "surface_variant/0.35" }, {
        ui.row({ gap = 5, align = "center" }, {
            ui.glyph({ name = glyph, size = 12, color = role or "on_surface_variant" }),
            ui.label({ text = label, color = "on_surface_variant", fontSize = 10, maxLines = 1 }),
        }),
        ui.label({ text = value, fontWeight = "bold", fontSize = 13, color = role or "on_surface" }),
    })
end

--- 一行「键 值 键 值 …」，用于本机卡的元信息
local function pairsRow(items)
    local children = {}
    for index, item in ipairs(items) do
        if index > 1 then
            table.insert(children, ui.spacer({ flexGrow = 1 }))
        end
        table.insert(children, ui.label({ text = item[1], color = "on_surface_variant", fontSize = 10 }))
        table.insert(children, ui.label({ text = item[2], fontSize = 11, maxLines = 1 }))
    end
    return ui.row({ gap = 6, align = "center" }, children)
end

local function sectionHead(glyph, text, count, extra)
    local head = {
        ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = text, fontWeight = "semibold" }),
    }
    if count then
        table.insert(head, ui.label({ text = tostring(count), color = "on_surface_variant", fontSize = 11 }))
    end
    table.insert(head, ui.spacer({ flexGrow = 1 }))
    if extra then
        table.insert(head, extra)
    end
    return ui.row({ gap = 8, align = "center" }, head)
end

-- ── 可折叠分区的标题行 ──────────────────────────────────────────────────────

--- 可折叠分区的标题行：整行可点，右侧给「展开／收起」。
--- 不用 ui.button 是故意的：按钮必须待在容器末尾，而这里后面还要接卡片。
local function toggleHead(glyph, text, count, isOpen, toggle, tooltipText, extra)
    local head = {
        ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = text, fontWeight = "semibold" }),
        ui.label({ text = tostring(count), color = "on_surface_variant", fontSize = 11 }),
        ui.spacer({ flexGrow = 1 }),
    }
    if extra ~= nil then
        table.insert(head, extra)
    end
    table.insert(head, ui.label({
        text = isOpen and tr("panel_collapse", "收起") or tr("panel_show", "展开"),
        color = "on_surface_variant",
        fontSize = 10,
    }))
    return ui.row({ gap = 8, align = "center", onClick = toggle, tooltip = tooltipText }, head)
end

-- ── 本机卡片 ───────────────────────────────────────────────────────────────

local function selfCard(cfg, info)
    local role = e.roleOf(e.level(cfg, snap, derived))
    local lines = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "server", size = 14, color = role }),
            ui.label({ text = info.hostname, fontWeight = "semibold", maxLines = 1 }),
            info.ip and ui.label({ text = info.ip, color = "on_surface_variant", fontSize = 11 })
                or ui.label({ text = "", fontSize = 11 }),
            ui.spacer({ flexGrow = 1 }),
            info.network and ui.label({ text = info.network, color = "on_surface_variant", fontSize = 11 })
                or ui.label({ text = "", fontSize = 11 }),
        }),
    }

    local meta = {}
    if info.version ~= "" then
        table.insert(meta, { tr("panel_version", "版本"), info.version })
    end
    if info.nat ~= nil then
        table.insert(meta, { tr("panel_nat", "NAT"), info.nat })
    end
    if info.publicIp ~= nil then
        table.insert(meta, { tr("panel_public", "公网"), info.publicIp })
    end
    if #meta > 0 then
        table.insert(lines, pairsRow(meta))
    end

    local ids = {}
    local short = e.shortId(info.instId)
    if short then
        table.insert(ids, { tr("panel_inst", "实例"), short })
    end
    if info.peerId ~= "" then
        table.insert(ids, { tr("panel_peer_id", "Peer ID"), info.peerId })
    end
    if info.publicPortRange then
        table.insert(ids, { tr("panel_port_range", "公网端口"), info.publicPortRange })
    end
    if #ids > 0 then
        table.insert(lines, pairsRow(ids))
    end

    if #info.listeners > 0 then
        table.insert(lines, ui.label({
            text = string.format("%s %s", tr("panel_listen", "监听"), table.concat(info.listeners, "  ")),
            color = "on_surface_variant",
            fontSize = 10,
            maxLines = 2,
        }))
    end

    if #info.proxyCidrs > 0 then
        table.insert(lines, ui.label({
            text = string.format("%s %s", tr("panel_proxy", "子网代理"), table.concat(info.proxyCidrs, ", ")),
            color = "on_surface_variant",
            fontSize = 10,
            maxLines = 2,
        }))
    end

    return ui.column({ gap = 6, padding = 10, radius = 10, fill = "surface_variant/0.45" }, lines)
end

-- ── 概览 ───────────────────────────────────────────────────────────────────

local function overview(cfg, d)
    local tiles = {
        tile(tr("panel_peers", "节点"), tostring(d.total), "server", "primary"),
        tile(tr("panel_direct", "直连"), tostring(d.direct), "plug", d.direct > 0 and "primary" or "on_surface_variant"),
        tile(tr("panel_relay", "中继"), tostring(d.relay), "route", d.relay > 0 and "tertiary" or "on_surface_variant"),
        tile(tr("panel_best", "最优延迟"), e.ms(d.best), "bolt", d.best ~= nil and e.roleOf(e.level(cfg, snap, d)) or "on_surface_variant"),
    }
    local lines = { ui.row({ gap = 6, align = "stretch" }, tiles) }

    local second = {
        tile(tr("panel_avg", "平均延迟"), e.ms(d.avg), "activity", "on_surface"),
        tile(tr("panel_worst", "最差延迟"), e.ms(d.worst), "activity", "on_surface_variant"),
        tile(tr("panel_loss", "丢包节点"), tostring(d.lossy), "alert-triangle", d.lossy > 0 and "tertiary" or "on_surface_variant"),
        tile(tr("panel_traffic", "累计流量"), string.format("↓%s ↑%s", e.bytes(d.rx), e.bytes(d.tx)), "cloud", "on_surface"),
    }
    table.insert(lines, ui.row({ gap = 6, align = "stretch" }, second))
    return ui.column({ gap = 6 }, lines)
end

-- ── 节点卡片 ───────────────────────────────────────────────────────────────

local function peerCard(cfg, row)
    local role = e.roleOf(row.level)
    local tooltip = string.format("%s\n%s %s\nID %s", row.hostname, tr("panel_cost", "cost"), row.costText, row.id)

    local head = {
        ui.glyph({ name = costGlyph(row.cost), size = 13, color = role }),
        ui.label({ text = row.hostname, fontWeight = "semibold", maxLines = 1 }),
    }
    if row.ip then
        table.insert(head, ui.label({ text = row.ip, color = "on_surface_variant", fontSize = 10 }))
    end
    table.insert(head, ui.spacer({ flexGrow = 1 }))
    table.insert(head, ui.label({ text = row.costText, color = "on_surface_variant", fontSize = 10 }))
    table.insert(head, ui.label({ text = e.ms(row.latency), fontWeight = "bold", color = role, fontSize = 12 }))

    local meta = {
        ui.label({
            text = string.format("%s %s", tr("panel_loss_rate", "丢包"), e.percentText(row.loss)),
            color = lossRole(cfg, row.loss),
            fontSize = 10,
        }),
        ui.label({ text = row.proto, color = "on_surface_variant", fontSize = 10 }),
    }
    if row.nat then
        table.insert(meta, ui.label({ text = row.nat, color = "on_surface_variant", fontSize = 10 }))
    end
    if row.version ~= "" and tooltip ~= nil then
        table.insert(meta, ui.label({ text = row.version, color = "on_surface_variant", fontSize = 10 }))
    end
    table.insert(meta, ui.spacer({ flexGrow = 1 }))
    table.insert(meta, ui.label({
        text = string.format("↓%s ↑%s", e.bytes(row.rx or 0), e.bytes(row.tx or 0)),
        color = "on_surface_variant",
        fontSize = 10,
    }))

    local lines = {
        ui.row({ gap = 8, align = "center" }, head),
        ui.row({ gap = 10, align = "center" }, meta),
    }

    if row.loss ~= nil and row.loss > 0 then
        table.insert(lines, ui.progress({
            progress = math.min(1, row.loss / 100),
            height = 3,
            radius = 2,
            fill = lossRole(cfg, row.loss),
            track = "surface_variant",
        }))
    end

    return ui.column({
        gap = 5,
        padding = 9,
        radius = 9,
        fill = "surface_variant/0.35",
        tooltip = tooltip,
    }, lines)
end

local function peerSection(cfg, rows)
    local lines = {}
    local limit = cfg.maxPeers
    local shown = #rows

    if not expanded and #rows > limit then
        shown = limit
    end

    if #rows == 0 then
        table.insert(lines, ui.label({
            text = tr("panel_no_peer", "当前没有其他节点。"),
            color = "on_surface_variant",
            fontSize = 11,
        }))
    else
        for index = 1, shown do
            table.insert(lines, peerCard(cfg, rows[index]))
        end
    end

    -- 按钮必须是该容器的最后一个子节点，否则同级节点会整片不渲染
    if #rows > limit then
        table.insert(lines, ui.button({
            text = expanded and tr("panel_collapse", "收起") or string.format(tr("panel_expand", "展开其余 %d 个"), #rows - limit),
            glyph = expanded and "chevron-up" or "chevron-down",
            glyphSize = 13,
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                expanded = not expanded
                draw()
            end,
        }))
    end

    return ui.column({ gap = 6 }, lines)
end

--- 服务器节点分区的标题行：默认折叠（serversOpen = false），右侧附带可用性文案。
local function serverHead(count, d)
    return toggleHead("cloud", tr("panel_servers", "服务器"), count, serversOpen, function()
        serversOpen = not serversOpen
        draw()
    end, tr("panel_servers_toggle", "点击展开或收起服务器节点"), ui.label({
        -- 服务器可用性：只要有一台不可用就用告警色标出（全挂时栏图标会变红）
        text = e.serversText(d),
        color = ((d and (d.serversDown or 0) > 0) and "error") or "on_surface_variant",
        fontSize = 10,
    }))
end

-- ── 路由 / 连接器 / 代理 / 转发 ────────────────────────────────────────────

local function routeSection(cfg, routes)
    local lines = {}
    local shown = math.min(#routes, 12)
    for index = 1, shown do
        local r = routes[index]
        local latency = e.num(r.path_latency)
        local role = "on_surface_variant"
        if latency ~= nil and latency >= cfg.critLatency then
            role = "error"
        elseif latency ~= nil and latency >= cfg.warnLatency then
            role = "tertiary"
        end
        local hostname = tostring(r.hostname or "?")
        local hop = tostring(r.next_hop_hostname or "-")
        table.insert(lines, ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = hostname, fontSize = 11, fontWeight = "semibold", maxLines = 1 }),
            ui.label({
                text = (type(r.ipv4) == "string" and r.ipv4 ~= "") and r.ipv4 or "-",
                color = "on_surface_variant",
                fontSize = 10,
            }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({
                text = string.format(tr("panel_hop", "经 %s"), hop),
                color = "on_surface_variant",
                fontSize = 10,
                maxLines = 1,
            }),
            ui.label({
                text = string.format(tr("panel_hops", "%d 跳"), tonumber(r.path_len) or 0),
                color = "on_surface_variant",
                fontSize = 10,
            }),
            ui.label({ text = e.ms(latency), fontSize = 11, fontWeight = "bold", color = role }),
        }))
    end
    if #routes > shown then
        table.insert(lines, ui.label({
            text = string.format(tr("panel_more", "还有 %d 条…"), #routes - shown),
            color = "on_surface_variant",
            fontSize = 10,
        }))
    end
    return ui.column({ gap = 5 }, lines)
end

local function connectorSection(connectors)
    local lines = {}
    for _, entry in ipairs(connectors) do
        local ok = entry.status == 0
        table.insert(lines, ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = ok and "plug" or "alert-triangle", size = 12, color = ok and "primary" or "error" }),
            ui.label({ text = entry.url, fontSize = 11, maxLines = 1 }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({
                text = ok and tr("panel_connected", "已连接") or string.format(tr("panel_status_code", "状态 %d"), entry.status),
                color = ok and "on_surface_variant" or "error",
                fontSize = 10,
            }),
        }))
    end
    return ui.column({ gap = 5 }, lines)
end

--- 代理与端口转发：字段随版本变化，取不到就跳过，保证不炸
local function genericSection(entries, keys)
    local lines = {}
    for _, entry in ipairs(entries) do
        local parts = {}
        if type(entry) == "table" then
            for _, key in ipairs(keys) do
                local value = entry[key]
                if type(value) == "string" and value ~= "" then
                    table.insert(parts, value)
                elseif type(value) == "number" then
                    table.insert(parts, tostring(value))
                end
            end
            if #parts == 0 then
                local encoded = noctalia.json.encode(entry, false)
                if type(encoded) == "string" and encoded ~= "" then
                    table.insert(parts, encoded)
                end
            end
        else
            table.insert(parts, tostring(entry))
        end
        if #parts > 0 then
            table.insert(lines, ui.label({
                text = table.concat(parts, " · "),
                fontSize = 11,
                maxLines = 1,
            }))
        end
    end
    return ui.column({ gap = 5 }, lines)
end

-- ── 未运行时的诊断 ─────────────────────────────────────────────────────────

local function offlineCard(cfg)
    local found = e.cliAvailable(cfg)
    local lines = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
            ui.label({ text = tr("panel_offline", "EasyTier core 未运行或 RPC 连不上"), fontWeight = "semibold" }),
        }),
        ui.label({
            text = string.format(
                tr("panel_cli_line", "easytier-cli：%s"),
                found and e.cliPath(cfg) or tr("panel_cli_missing", "未找到（请在插件设置里指定绝对路径）")
            ),
            color = found and "on_surface_variant" or "error",
            fontSize = 11,
            maxLines = 2,
        }),
        ui.label({
            text = string.format(
                tr("panel_rpc_line", "RPC 地址：%s"),
                cfg.portal ~= "" and cfg.portal or "127.0.0.1:15888"
            ),
            color = "on_surface_variant",
            fontSize = 11,
        }),
        ui.label({
            text = tr("panel_offline_hint", "确认 easytier-core 正在运行，且它的 --rpc-portal 与本插件设置一致。"),
            color = "on_surface_variant",
            fontSize = 10,
            opacity = 0.8,
        }),
    }
    if snap ~= nil and snap.failed.node ~= nil then
        table.insert(lines, ui.label({
            text = string.format(tr("panel_fail_reason", "上次失败原因：%s"), tostring(snap.failed.node)),
            color = "on_surface_variant",
            fontSize = 10,
        }))
    end
    -- 按钮放最后
    table.insert(lines, ui.button({
        text = tr("panel_retry", "重试"),
        glyph = "refresh",
        glyphSize = 13,
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
            request()
        end,
    }))
    return ui.column({ gap = 6, padding = 10, radius = 10, fill = "surface_variant/0.45" }, lines)
end

-- ── 主体 ───────────────────────────────────────────────────────────────────

local function body(cfg)
    local nodes = {}

    if snap ~= nil and snap.node == nil then
        table.insert(nodes, offlineCard(cfg))
        return nodes
    end
    if snap == nil then
        table.insert(nodes, ui.label({
            text = tr("panel_loading", "正在读取 easytier-cli…"),
            color = "on_surface_variant",
        }))
        return nodes
    end

    local info = e.nodeInfo(snap)
    local d = derived or e.derive(snap, cfg)

    if info ~= nil then
        table.insert(nodes, selfCard(cfg, info))
    end
    table.insert(nodes, overview(cfg, d))

    table.insert(nodes, ui.spacer({ height = 4 }))
    -- 普通设备与服务器节点分两段：公共共享服务器单独成段且默认折叠
    local normalRows, serverRows = e.splitRows(e.rows(snap, cfg), cfg)

    table.insert(nodes, sectionHead("server", tr("panel_peers", "节点"), #normalRows))
    table.insert(nodes, peerSection(cfg, normalRows))

    if #serverRows > 0 then
        table.insert(nodes, serverHead(#serverRows, d))
        if serversOpen then
            table.insert(nodes, peerSection(cfg, serverRows))
        end
    end

    if snap.routes ~= nil and #snap.routes > 0 then
        table.insert(nodes, ui.spacer({ height = 4 }))
        table.insert(nodes, toggleHead("route", tr("panel_routes", "路由"), #snap.routes, routesOpen, function()
            routesOpen = not routesOpen
            draw()
        end, tr("panel_routes_toggle", "点击展开或收起路由表")))
        if routesOpen then
            table.insert(nodes, routeSection(cfg, snap.routes))
        end
    end

    if snap.connectors ~= nil and #snap.connectors > 0 then
        table.insert(nodes, ui.spacer({ height = 4 }))
        table.insert(nodes, toggleHead("plug", tr("panel_connectors", "连接器"), #snap.connectors, connectorsOpen, function()
            connectorsOpen = not connectorsOpen
            draw()
        end, tr("panel_connectors_toggle", "点击展开或收起连接器列表")))
        if connectorsOpen then
            table.insert(nodes, connectorSection(e.connectorRows(snap)))
        end
    end

    if snap.proxies ~= nil and #snap.proxies > 0 then
        table.insert(nodes, ui.spacer({ height = 4 }))
        table.insert(nodes, sectionHead("cloud", tr("panel_proxy_title", "子网代理"), #snap.proxies))
        table.insert(nodes, genericSection(snap.proxies, { "cidr", "proxy_cidrs", "bind_addr", "dst_addr" }))
    end

    if snap.forwards ~= nil and #snap.forwards > 0 then
        table.insert(nodes, ui.spacer({ height = 4 }))
        table.insert(nodes, sectionHead("plug", tr("panel_forward", "端口转发"), #snap.forwards))
        table.insert(nodes, genericSection(snap.forwards, { "proto", "bind_addr", "dst_addr", "bind_addr_display" }))
    end

    if cfg.extras and snap.routes == nil and snap.failed.route ~= nil then
        table.insert(nodes, ui.label({
            text = string.format(tr("panel_route_failed", "路由表读取失败：%s"), tostring(snap.failed.route)),
            color = "tertiary",
            fontSize = 10,
        }))
    end

    return nodes
end

-- ── 抓取 ───────────────────────────────────────────────────────────────────

local function subs(cfg)
    if cfg.extras then
        return e.FULL_SUBS
    end
    return e.FAST_SUBS
end

request = function()
    if inflight then
        return
    end
    local cfg = e.cfg()
    inflight = true
    e.fetch(cfg, subs(cfg), function(result)
        inflight = false
        lastFetchAt = os.time()
        snap = result
        derived = e.derive(result, cfg)
        draw()
    end)
end

-- ── 渲染 ───────────────────────────────────────────────────────────────────

draw = function()
    local cfg = e.cfg()
    local level = e.level(cfg, snap, derived)
    local role = e.roleOf(level)

    local head = {
        ui.glyph({ name = "network", size = 15, color = role }),
        ui.label({ text = "EasyTier", fontWeight = "bold", fontSize = 15 }),
        ui.label({ text = e.statusText(cfg, snap), color = role, fontSize = 11, maxLines = 1 }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({
            text = string.format(tr("panel_updated", "更新于 %s"), os.date("%H:%M:%S")),
            color = "on_surface_variant",
            fontSize = 11,
        }),
        ui.button({
            glyph = inflight and "loader" or "refresh",
            glyphSize = 14,
            variant = "ghost",
            controlSize = "sm",
            tooltip = tr("panel_refresh", "重新读取"),
            onClick = function()
                request()
            end,
        }),
    }

    local footer = {
        ui.label({
            text = string.format(
                tr("panel_source", "数据源：%s（只读，不修改 EasyTier 配置）"),
                e.cliPath(cfg)
            ),
            color = "on_surface_variant",
            fontSize = 10,
            opacity = 0.7,
            maxLines = 1,
        }),
    }
    -- 标题行 + 主体 + 页脚全部交给滚动区，并把滚动区当作根节点渲染。
    -- ylxc-qweather 用的就是这个结构（根 = ui.scroll + padding/gap）；
    -- 若改成在 column 里放 flexGrow 的 scroll，宿主的弹性布局会把滚动区
    -- 压成一条缝、面板只剩本机卡片可见（实测踩到过）。
    local content = body(cfg)
    table.insert(content, ui.column({ gap = 2 }, footer))
    table.insert(content, 1, ui.row({ gap = 8, align = "center" }, head))

    panel.render(ui.scroll({ flexGrow = 1, gap = 10, padding = 14 }, content))
end

-- ── 生命周期 ───────────────────────────────────────────────────────────────

function onOpen(_context)
    open = true
    noctalia.setUpdateInterval(1000)
    request()
    draw()
end

function onClose()
    open = false
end

function update()
    if not open then
        return
    end
    local cfg = e.cfg()
    if os.time() - lastFetchAt >= cfg.refresh then
        request()
    end
end

function onIpc(event, _payload)
    if event == "refresh" then
        request()
    end
end

draw()
