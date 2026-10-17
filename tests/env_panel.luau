--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- tests/env_panel.luau —— 面板离线渲染测试的假宿主（在 env.luau 之后拼接）
--
-- 在 env.luau 的基础上追加三件事：
--   * 假 easytier-cli：runAsync 同步回调一行哨兵文本 "::node" / "::peer" …，
--     json.decode 按哨兵返回预置的 Lua 表。这样既跑完了「抓取 → 组装 →
--     渲染」的完整链路，又不必真去调 easytier-cli，也不用在这儿写 JSON 解析器。
--   * 假 ui.*：每个构造器原样记录 props 与 children，供断言遍历。
--   * 假 panel.render：把渲染树存进全局 rendered。
--
-- 于是 panel.luau 里的任何 lua 错误都会在测试里直接抛出，而不是变成
-- 「面板只有一半内容」这种只能靠截图发现的现象。
-- ══════════════════════════════════════════════════════════════════════════

-- ── 假 CLI 数据（取自真实 easytier-cli 2.6.4 的输出结构）─────────────────

local cli = {
    node = {
        peer_id = 1062248666,
        ipv4_addr = "172.24.1.1/16",
        proxy_cidrs = { "192.168.122.0/24" },
        hostname = "ylxc-t480s",
        inst_id = "2c7e53fe-47f4-46c3-9db6-58f29e39dc49",
        listeners = { "ring://abc", "tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", "wg://0.0.0.0:11011" },
        version = "2.6.4",
        stun_info = { udp_nat_type = 6, tcp_nat_type = 6, public_ip = { "183.219.160.42" }, min_port = 11450, max_port = 52819 },
        ip_list = { public_ipv4 = { addr = 3084623914 } },
        config = 'network_name = "ylxc"\ninstance_name = "default"\n',
    },
    peer = {
        { hostname = "ylxc-t480s", ipv4 = "172.24.1.1", cost = "Local", lat_ms = "0.00", loss_rate = "1.0%", rx_bytes = "1.00 kB", tx_bytes = "2.00 kB", tunnel_proto = "tcp", nat_type = "Symmetric", version = "2.6.4", id = 1062248666 },
        { hostname = "ylxc-r9000p", ipv4 = "172.24.1.2", cost = "p2p", lat_ms = "29.40", loss_rate = "1.0%", rx_bytes = "100.47 kB", tx_bytes = "117.73 kB", tunnel_proto = "tcp", nat_type = "PortRestricted", version = "2.6.4", id = 11 },
        { hostname = "ylxc-phone", ipv4 = "172.24.1.3", cost = "relay", lat_ms = "-", loss_rate = "0.0%", rx_bytes = "5.87 MB", tx_bytes = "1.03 MB", tunnel_proto = "udp", nat_type = "Symmetric", version = "2.6.4", id = 12 },
        { hostname = "PublicServer_debian", ipv4 = "", cost = "p2p", lat_ms = "30.60", loss_rate = "0.0%", rx_bytes = "67.00 kB", tx_bytes = "83.00 kB", tunnel_proto = "tcp", nat_type = "Symmetric", version = "2.4.5-4c4d172e", id = 13 },
    },
    route = {
        { hostname = "ylxc-r9000p", ipv4 = "172.24.1.2", proxy_cidrs = {}, next_hop_ipv4 = "172.24.1.2", next_hop_hostname = "ylxc-r9000p", next_hop_lat = "0", path_len = 1, path_latency = "29.40" },
        { hostname = "ylxc-phone", ipv4 = "172.24.1.3", proxy_cidrs = {}, next_hop_ipv4 = "172.24.1.2", next_hop_hostname = "ylxc-r9000p", next_hop_lat = "29.40", path_len = 2, path_latency = "58.80" },
    },
    connector = {
        { url = { url = "tcp://public.easytier.cn:11010" }, status = 0 },
        { url = { url = "wss://et.chinokou.cn/" }, status = 1 },
    },
    proxy = {},
    ["port-forward"] = { cfgs = {} },
}

noctalia.json.decode = function(text)
    local key = text:match("^::(%S+)$")
    if key ~= nil then
        return cli[key]
    end
    return nil
end

noctalia.runAsync = function(argv, callback, _timeout)
    local sub = argv[#argv]
    if cli[sub] == nil then
        return true
    end
    if callback ~= nil then
        callback({ exitCode = 0, stdout = "::" .. sub, stderr = "", timedOut = false, stdoutTruncated = false, stderrTruncated = false })
    end
    return true
end

noctalia.setUpdateInterval = function() end
noctalia.notify = function() end
noctalia.notifyError = function() end
noctalia.togglePanel = function() end

-- ── 假 ui：原样记录，便于断言遍历 ─────────────────────────────────────────

local function makeKind(name)
    return function(props, children)
        return { kind = name, props = props or {}, children = children or {} }
    end
end

ui = {
    column = makeKind("column"),
    row = makeKind("row"),
    scroll = makeKind("scroll"),
    box = makeKind("box"),
    dragSource = makeKind("dragSource"),
    dropZone = makeKind("dropZone"),
    label = makeKind("label"),
    markdown = makeKind("markdown"),
    glyph = makeKind("glyph"),
    image = makeKind("image"),
    separator = makeKind("separator"),
    spacer = makeKind("spacer"),
    progress = makeKind("progress"),
    button = makeKind("button"),
    graph = makeKind("graph"),
    input = makeKind("input"),
    select = makeKind("select"),
    slider = makeKind("slider"),
    toggle = makeKind("toggle"),
}

-- ── 假 panel：存下渲染树 ───────────────────────────────────────────────────

rendered = nil
local renderedTimes = 0

panel = {
    render = function(tree)
        rendered = tree
        renderedTimes += 1
    end,
    close = function() end,
    setWantsSecondTicks = function() end,
    setNeedsFrameTick = function() end,
    openContextMenu = function() end,
}

-- 调试用：可以从断言里读渲染次数
function renderCount()
    return renderedTimes
end
