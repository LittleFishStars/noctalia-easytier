--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- lib/easytier.luau —— EasyTier 运行时数据的抓取、整理与格式化
--
-- 数据全部来自 easytier-cli 的 JSON 输出（-o json），以子进程方式调用
-- （noctalia.runAsync，argv 数组形式，不经过 shell）：
--   node          本机节点：虚拟 IP、hostname、peer_id、STUN 公网地址、监听器、配置文本
--   peer          对等节点：cost（Local / p2p / relay）、延迟、丢包、收发字节、隧道协议、NAT 类型
--   route         路由表：下一跳、路径跳数、路径延迟
--   connector     连接器：每个 --peer 地址的连通状态
--   proxy         TCP / KCP 代理
--   port-forward  端口转发
--
-- bar.luau（栏组件）与 panel.luau（详情面板）共用这一份逻辑：
--   * 设置读取：noctalia.getConfig 只收一个参数、没有默认值，统一在这里兜底
--   * 并发抓取：多个子命令同时发起，全部回来后组装成一份快照
--   * 派生指标：直连 / 中继计数、最优 / 平均 / 最差延迟、丢包面、收发流量
--   * 格式化：字节、百分比、NAT 类型、虚拟 IP、实例 ID
--
-- 只读：不写 EasyTier 的配置文件、不改运行状态、不常驻进程。
-- ══════════════════════════════════════════════════════════════════════════

local M = {}

M.VERSION = "1.0.0"

-- 单条 easytier-cli 的超时（宿主会把 timeoutMs 夹到 [50, 60000]）
M.TIMEOUT_MS = 8000

-- 栏组件只需要这几个（最省），全量抓取留给面板开启时
M.FAST_SUBS = { "node", "peer" }
M.FULL_SUBS = { "node", "peer", "route", "connector", "proxy", "port-forward" }

-- 子命令 → 快照字段名（port-forward 取 .cfgs）
local SUB_FIELDS = {
    ["node"] = "node",
    ["peer"] = "peers",
    ["route"] = "routes",
    ["connector"] = "connectors",
    ["proxy"] = "proxies",
    ["port-forward"] = "forwards",
}

-- ── 设置读取 ───────────────────────────────────────────────────────────────

local function raw(key)
    local ok, value = pcall(noctalia.getConfig, key)
    if not ok then
        return nil
    end
    return value
end

--- 字符串设置；空串按「未设置」处理，回落到 default
function M.text(key, default)
    local value = raw(key)
    if type(value) ~= "string" or value == "" then
        return default
    end
    return value
end

--- 布尔设置；兼容字符串/数字形式
function M.flag(key, default)
    local value = raw(key)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        if value == "true" or value == "1" then
            return true
        end
        if value == "false" or value == "0" then
            return false
        end
    end
    return default
end

--- 数字设置；兼容字符串形式的数字
function M.number(key, default)
    local value = raw(key)
    if type(value) == "number" then
        return value
    end
    local parsed = tonumber(value)
    if parsed ~= nil then
        return parsed
    end
    return default
end

function M.clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

--- 翻译；键缺失时回落到中文兜底
function M.tr(key, fallback)
    local ok, value = pcall(noctalia.tr, key)
    if ok and type(value) == "string" and value ~= "" and value ~= key then
        return value
    end
    return fallback or key
end

--- 当前设置（每轮重读，改设置后不用重载插件；plugin.toml 的 default 只兜首次）
function M.cfg()
    local warn = M.number("warn_latency_ms", 150)
    local crit = M.number("crit_latency_ms", 400)
    if crit <= warn then
        crit = warn + 1
    end
    return {
        cli = M.text("cli_path", ""),
        portal = M.text("rpc_portal", ""),
        instanceName = M.text("instance_name", ""),
        instanceId = M.text("instance_id", ""),
        refresh = M.clamp(M.number("refresh_seconds", 10), 2, 600),
        warnLatency = warn,
        critLatency = crit,
        relayWarn = M.flag("relay_warn", true),
        lossCrit = M.clamp(M.number("loss_crit_percent", 10), 1, 100),
        lossWarn = M.clamp(M.number("loss_warn_percent", 2), 1, 100),
        extras = M.flag("fetch_extras", true),
        maxPeers = M.clamp(M.number("max_peers", 64), 4, 512),
        serverPrefix = M.text("server_prefix", "PublicServer"),
        notify = M.flag("notify_state_change", false),
    }
end

-- ── 数值与单位 ─────────────────────────────────────────────────────────────

--- 从 EasyTier 的字段里取数字："29.40" → 29.4；"-" → nil
function M.num(value)
    if type(value) == "number" then
        return value
    end
    if type(value) ~= "string" then
        return nil
    end
    local head = value:match("^%s*([%-%+]?[%d%.]+)")
    if head == nil then
        return nil
    end
    return tonumber(head)
end

local BYTE_MULT = {
    B = 1,
    b = 1,
    K = 1024,
    kB = 1024,
    KB = 1024,
    kb = 1024,
    KiB = 1024,
    M = 1024 * 1024,
    MB = 1024 * 1024,
    MiB = 1024 * 1024,
    G = 1024 * 1024 * 1024,
    GB = 1024 * 1024 * 1024,
    GiB = 1024 * 1024 * 1024,
    T = 1024 * 1024 * 1024 * 1024,
    TB = 1024 * 1024 * 1024 * 1024,
    TiB = 1024 * 1024 * 1024 * 1024,
}

--- "100.47 kB" → 102881；无法解析返回 nil
function M.parseBytes(value)
    if type(value) == "number" then
        return value
    end
    if type(value) ~= "string" then
        return nil
    end
    local number_, unit = value:match("^%s*([%d%.]+)%s*(%a*)%s*$")
    if number_ == nil then
        return nil
    end
    local n = tonumber(number_)
    if n == nil then
        return nil
    end
    if unit == "" then
        return n
    end
    local mult = BYTE_MULT[unit] or BYTE_MULT[unit:upper()]
    if mult == nil then
        -- 认不出的单位（例如 "B/s"）就当字节数，至少不丢信息
        return n
    end
    return n * mult
end

local BYTE_UNITS = { "B", "K", "M", "G", "T", "P" }

--- 字节数 → 人类可读（1024 进制，栏上要短：9.8K / 100K / 5.9M）
function M.bytes(value)
    if type(value) ~= "number" or value < 0 then
        return "--"
    end
    local scaled = value
    local index = 1
    while scaled >= 1024 and index < #BYTE_UNITS do
        scaled = scaled / 1024
        index += 1
    end
    if index == 1 then
        return string.format("%d%s", scaled, BYTE_UNITS[index])
    end
    if scaled < 10 then
        return string.format("%.1f%s", scaled, BYTE_UNITS[index])
    end
    return string.format("%d%s", scaled, BYTE_UNITS[index])
end

--- 延迟文本：29ms（无数据时 "-"）
function M.ms(value)
    if type(value) ~= "number" then
        return "-"
    end
    if value >= 1000 then
        return string.format("%.2fs", value / 1000)
    end
    if value >= 100 then
        return string.format("%dms", math.floor(value + 0.5))
    end
    return string.format("%.1fms", value)
end

--- 丢包率文本：保留一位小数
function M.percentText(value)
    if type(value) ~= "number" then
        return "-"
    end
    if value == 0 then
        return "0%"
    end
    if value < 1 then
        return string.format("%.1f%%", value)
    end
    return string.format("%.1f%%", value)
end

--- 32 位整数 → 点分十进制（node.ip_list.public_ipv4.addr 是整数形式）
function M.ipFromInt(value)
    if type(value) ~= "number" or value < 0 or value > 4294967295 then
        return nil
    end
    local n = math.floor(value)
    return string.format("%d.%d.%d.%d", math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

--- "172.24.1.1/16" → "172.24.1.1"
function M.stripCidr(value)
    if type(value) ~= "string" then
        return nil
    end
    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end
    return (trimmed:match("^([^/]+)") or trimmed)
end

--- 磁盘风格的时间片：now / 12s / 3min / 2h
function M.ago(seconds)
    if type(seconds) ~= "number" or seconds < 0 then
        return nil
    end
    if seconds < 3 then
        return M.tr("ago_now", "刚刚")
    end
    if seconds < 60 then
        return string.format(M.tr("ago_sec", "%d 秒前"), math.floor(seconds))
    end
    if seconds < 3600 then
        return string.format(M.tr("ago_min", "%d 分钟前"), math.floor(seconds / 60))
    end
    return string.format(M.tr("ago_hour", "%d 小时前"), math.floor(seconds / 3600))
end

-- ── NAT 类型 ───────────────────────────────────────────────────────────────
-- node.stun_info.udp_nat_type 是枚举数字，peer 表里的 nat_type 是同一个枚举的
-- 字符串形式（实测 6 ↔ "Symmetric"），两张表可以对上。

local NAT_NAMES = {
    [0] = "Unknown",
    [1] = "OpenInternet",
    [2] = "NoPAT",
    [3] = "FullCone",
    [4] = "Restricted",
    [5] = "PortRestricted",
    [6] = "Symmetric",
    [7] = "SymUdpFirewall",
    [8] = "SymmetricEasyInc",
    [9] = "SymmetricEasyDec",
}

function M.natName(value)
    if type(value) == "string" then
        if value == "" or value == "-" then
            return nil
        end
        return value
    end
    if type(value) == "number" then
        return NAT_NAMES[value] or ("#" .. tostring(value))
    end
    return nil
end

-- ── 命令组装与抓取 ─────────────────────────────────────────────────────────

--- easytier-cli 的可执行文件：设置里填了就用它，否则交给 PATH
function M.cliPath(cfg)
    if cfg and cfg.cli ~= "" then
        return cfg.cli
    end
    return "easytier-cli"
end

--- cli 是否可用（填了绝对路径就查文件，否则查 PATH）
function M.cliAvailable(cfg)
    local path = M.cliPath(cfg)
    local ok, result
    if path:find("/", 1, true) then
        ok, result = pcall(noctalia.fileExists, path)
    else
        ok, result = pcall(noctalia.commandExists, path)
    end
    return ok and result == true
end

--- 组装一条子命令的 argv（argv 形式不经过 shell，实例名里的空格也安全）
function M.argv(cfg, sub)
    local argv = { M.cliPath(cfg) }
    if cfg.portal ~= "" then
        table.insert(argv, "-p")
        table.insert(argv, cfg.portal)
    end
    if cfg.instanceName ~= "" then
        table.insert(argv, "-n")
        table.insert(argv, cfg.instanceName)
    end
    if cfg.instanceId ~= "" then
        table.insert(argv, "-i")
        table.insert(argv, cfg.instanceId)
    end
    table.insert(argv, "-o")
    table.insert(argv, "json")
    table.insert(argv, sub)
    return argv
end

local function once(fn)
    local done = false
    return function(...)
        if done then
            return
        end
        done = true
        return fn(...)
    end
end

--- 单条命令的结果 → 已解码的值；失败返回 (nil, 原因)
local function decodeResult(res)
    if type(res) ~= "table" then
        return nil, "nofork"
    end
    if res.timedOut then
        return nil, "timeout"
    end
    if res.exitCode ~= 0 then
        local why = tostring(res.stderr or ""):gsub("%s+$", "")
        if why == "" then
            return nil, "exit"
        end
        return nil, "rpc"
    end
    local out = tostring(res.stdout or "")
    if out:match("^%s*$") then
        return nil, "empty"
    end
    local value = noctalia.json.decode(out)
    if value == nil then
        return nil, "json"
    end
    return value
end

--- 并发抓取若干子命令，全部返回后回调快照。
---   snap = { at, failed = { [sub] = 原因 }, node, peers, routes, connectors, proxies, forwards }
--- 单个子命令失败不影响整体：`node` 缺失即代表 core 没在跑 / RPC 连不上。
function M.fetch(cfg, subs, cb)
    subs = subs or M.FAST_SUBS
    local snap = { at = os.time(), failed = {}, started = os.time() }
    local pending = #subs
    if pending == 0 then
        cb(snap)
        return
    end

    local function done()
        pending -= 1
        if pending == 0 then
            cb(snap)
        end
    end

    for _, sub in ipairs(subs) do
        local handle = once(function(res)
            local value, why = decodeResult(res)
            if value == nil then
                snap.failed[sub] = why or "error"
            else
                local field = SUB_FIELDS[sub]
                if field == nil then
                    snap.failed[sub] = "unknown"
                elseif sub == "port-forward" then
                    -- port-forward 的外层是 { cfgs = [...] }
                    snap.forwards = (type(value) == "table" and value.cfgs) or {}
                elseif sub == "node" then
                    -- node 偶尔会返回包着一层的数组，统一成对象
                    if type(value) == "table" and value[1] ~= nil then
                        value = value[1]
                    end
                    snap.node = value
                else
                    snap[field] = value
                end
            end
            done()
        end)

        local argv = M.argv(cfg, sub)
        local ok, started = pcall(noctalia.runAsync, argv, handle, M.TIMEOUT_MS)
        if not ok or started ~= true then
            -- 起不来说明命令不存在 / 被拒绝：当作一次失败，避免 pending 卡住
            handle(nil)
        end
    end
end

-- ── 派生指标 ───────────────────────────────────────────────────────────────

--- cost 归类：local（本机）/ p2p（直连）/ relay（中继）/ other
function M.costOf(peer)
    local cost = tostring((peer and peer.cost) or "")
    local low = cost:lower()
    if low == "" then
        return "other"
    end
    if low:find("local", 1, true) then
        return "local"
    end
    if low:find("relay", 1, true) then
        return "relay"
    end
    if low:find("p2p", 1, true) then
        return "p2p"
    end
    return "other"
end

--- 汇总一份快照：节点计数、延迟分布、丢包面、收发流量
function M.derive(snap)
    local d = {
        total = 0,
        direct = 0,
        relay = 0,
        other = 0,
        best = nil,
        worst = nil,
        sum = 0,
        counted = 0,
        avg = nil,
        lossy = 0,
        lossMax = 0,
        lossSum = 0,
        rx = 0,
        tx = 0,
        own = nil,
        ready = false,
    }

    for _, peer in ipairs((snap and snap.peers) or {}) do
        local cost = M.costOf(peer)
        if cost == "local" then
            d.own = peer
        else
            d.total += 1
            if cost == "p2p" then
                d.direct += 1
            elseif cost == "relay" then
                d.relay += 1
            else
                d.other += 1
            end
            local latency = M.num(peer.lat_ms)
            if latency ~= nil then
                if d.best == nil or latency < d.best then
                    d.best = latency
                end
                if d.worst == nil or latency > d.worst then
                    d.worst = latency
                end
                d.sum += latency
                d.counted += 1
            end
            local loss = M.num(peer.loss_rate)
            if loss ~= nil and loss > 0 then
                d.lossy += 1
                d.lossSum += loss
                if loss > d.lossMax then
                    d.lossMax = loss
                end
            end
        end
        d.rx += M.parseBytes(peer.rx_bytes) or 0
        d.tx += M.parseBytes(peer.tx_bytes) or 0
    end

    if d.counted > 0 then
        d.avg = d.sum / d.counted
    end
    d.ready = d.total > 0
    return d
end

--- 状态分级：off（core 没跑）/ ok / warn / crit
---   延迟按「最优延迟」判，最差值只用于展示——远端节点天然慢，不该让整栏变红
function M.level(cfg, snap, derived)
    if snap == nil then
        return "loading"
    end
    if snap.node == nil then
        return "off"
    end
    local d = derived or M.derive(snap)
    if d.best ~= nil and d.best >= cfg.critLatency then
        return "crit"
    end
    if d.lossMax >= cfg.lossCrit then
        return "crit"
    end
    if d.best ~= nil and d.best >= cfg.warnLatency then
        return "warn"
    end
    if d.avg ~= nil and d.avg >= cfg.warnLatency then
        return "warn"
    end
    -- 丢包按「最差节点」判：单个节点丢包就可能意味着某条链路在丢，
    -- 但也只有超过阈值才降级——偶尔 1% 的抖动不值得把整栏染黄。
    if d.lossMax >= cfg.lossWarn then
        return "warn"
    end
    if cfg.relayWarn and d.relay > 0 then
        return "warn"
    end
    return "ok"
end

-- 主题只有 primary / secondary / tertiary / error 四个可用角色
local LEVEL_ROLE = {
    loading = "on_surface_variant",
    off = "error",
    ok = "primary",
    warn = "tertiary",
    crit = "error",
}

function M.roleOf(level)
    return LEVEL_ROLE[level] or "primary"
end

function M.levelText(level)
    return M.tr("level_" .. tostring(level), tostring(level))
end

--- 单个对等节点的行数据（面板与栏共用）
function M.row(peer, cfg)
    local cost = M.costOf(peer)
    local latency = M.num(peer.lat_ms)
    local loss = M.num(peer.loss_rate)
    local level = "ok"
    if latency ~= nil and latency >= cfg.critLatency then
        level = "crit"
    elseif loss ~= nil and loss >= cfg.lossCrit then
        level = "crit"
    elseif latency ~= nil and latency >= cfg.warnLatency then
        level = "warn"
    elseif (loss ~= nil and loss >= cfg.lossWarn) or cost == "relay" then
        level = "warn"
    end
    return {
        peer = peer,
        hostname = tostring(peer.hostname or "?"),
        ip = M.stripCidr(peer.ipv4),
        cidr = peer.ipv4,
        cost = cost,
        costText = tostring(peer.cost or "-"),
        latency = latency,
        loss = loss,
        level = level,
        proto = tostring(peer.tunnel_proto or "-"),
        nat = M.natName(peer.nat_type),
        version = tostring(peer.version or "-"),
        id = tostring(peer.id or ""),
        rx = M.parseBytes(peer.rx_bytes),
        tx = M.parseBytes(peer.tx_bytes),
    }
end

local COST_ORDER = { ["local"] = 0, p2p = 1, relay = 2, other = 3 }

--- 面板用的行列表：直连在前、中继在后，同级按延迟升序
function M.rows(snap, cfg)
    local out = {}
    for _, peer in ipairs((snap and snap.peers) or {}) do
        local row = M.row(peer, cfg)
        if row.cost ~= "local" then
            table.insert(out, row)
        end
    end
    table.sort(out, function(a, b)
        local oa = COST_ORDER[a.cost] or 9
        local ob = COST_ORDER[b.cost] or 9
        if oa ~= ob then
            return oa < ob
        end
        local la = a.latency or math.huge
        local lb = b.latency or math.huge
        if la ~= lb then
            return la < lb
        end
        return a.hostname < b.hostname
    end)
    return out
end

--- 主机名前缀列表（plugin.toml 的 server_prefix，逗号分隔，中英文逗号都认）
function M.prefixes(cfg)
    local out = {}
    for piece in tostring((cfg and cfg.serverPrefix) or ""):gmatch("[^,，]+") do
        local trimmed = piece:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(out, trimmed:lower())
        end
    end
    return out
end

--- 是否算「服务器节点」：公共共享节点（EasyTier 官方的 PublicServer_* 命名）
--- 注意：不是 cost = relay 的那种中继模式节点，两者无关
function M.isServer(hostname, prefixes)
    local name = tostring(hostname or ""):lower()
    if name == "" then
        return false
    end
    for _, prefix in ipairs(prefixes or {}) do
        if name:find(prefix, 1, true) ~= nil then
            return true
        end
    end
    return false
end

--- 把节点行分成两组：普通设备与服务器节点（公共共享节点）。
--- 面板据此把服务器单独成段并默认折叠。
--- @return table 普通节点行, table 服务器节点行
function M.splitRows(rows, cfg)
    local prefixes = M.prefixes(cfg)
    local normal, servers = {}, {}
    for _, row in ipairs(rows or {}) do
        if M.isServer(row.hostname, prefixes) then
            table.insert(servers, row)
        else
            table.insert(normal, row)
        end
    end
    return normal, servers
end

--- 本机信息（面板顶部卡片）
function M.nodeInfo(snap)
    local node = snap and snap.node
    if type(node) ~= "table" then
        return nil
    end
    local stun = type(node.stun_info) == "table" and node.stun_info or {}
    local publicIp = nil
    if type(stun.public_ip) == "table" and stun.public_ip[1] ~= nil then
        publicIp = tostring(stun.public_ip[1])
    elseif type(node.ip_list) == "table" and type(node.ip_list.public_ipv4) == "table" then
        publicIp = M.ipFromInt(node.ip_list.public_ipv4.addr)
    end

    local udpNat = M.natName(stun.udp_nat_type)
    local tcpNat = M.natName(stun.tcp_nat_type)

    -- 监听器里 ring:// 是内部回环，不算对外服务
    local listeners = {}
    for _, entry in ipairs((type(node.listeners) == "table" and node.listeners) or {}) do
        local text = tostring(entry)
        if not text:find("^ring://") then
            table.insert(listeners, text)
        end
    end

    local proxyCidrs = {}
    for _, cidr in ipairs((type(node.proxy_cidrs) == "table" and node.proxy_cidrs) or {}) do
        table.insert(proxyCidrs, tostring(cidr))
    end

    return {
        hostname = tostring(node.hostname or "?"),
        ip = M.stripCidr(node.ipv4_addr),
        cidr = node.ipv4_addr,
        peerId = tostring(node.peer_id or ""),
        instId = tostring(node.inst_id or ""),
        version = tostring(node.version or ""),
        nat = udpNat or tcpNat,
        udpNat = udpNat,
        tcpNat = tcpNat,
        publicIp = publicIp,
        listeners = listeners,
        proxyCidrs = proxyCidrs,
        network = M.networkName(snap),
        publicPortRange = (type(stun.min_port) == "number" and type(stun.max_port) == "number")
                and string.format("%d-%d", stun.min_port, stun.max_port)
            or nil,
    }
end

--- 网络名从 node.config 的 TOML 文本里取（没有专门的字段）
function M.networkName(snap)
    local text = snap and snap.node and snap.node.config
    if type(text) ~= "string" then
        return nil
    end
    return text:match('network_name%s*=%s*"([^"]*)"')
end

--- 实例 ID 缩略：前 8 位 + 后 4 位
function M.shortId(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    if #value <= 14 then
        return value
    end
    return string.format("%s…%s", value:sub(1, 8), value:sub(-4))
end

--- 连接器里的地址：{ { url = { url = "tcp://…" }, status = 0 }, … } → { {url, ok} }
function M.connectorRows(snap)
    local out = {}
    for _, entry in ipairs((snap and snap.connectors) or {}) do
        local url = nil
        if type(entry) == "table" then
            if type(entry.url) == "table" then
                url = entry.url.url or entry.url.Url
            elseif type(entry.url) == "string" then
                url = entry.url
            end
        end
        if url ~= nil then
            table.insert(out, {
                url = tostring(url),
                status = tonumber(entry.status) or 0,
            })
        end
    end
    return out
end

--- 托盘/栏文本里用的短状态：运行 → 节点数，否则 --
function M.peerCountText(snap, derived)
    if snap == nil or snap.node == nil then
        return "--"
    end
    local d = derived or M.derive(snap)
    return tostring(d.total)
end

--- 运行状态文案（栏与面板共用）
function M.statusText(cfg, snap)
    if snap == nil then
        return M.tr("status_loading", "读取中…")
    end
    if snap.node ~= nil then
        return M.tr("status_running", "运行中")
    end
    if not M.cliAvailable(cfg) then
        return M.tr("status_no_cli", "找不到 easytier-cli")
    end
    if snap.failed.node == "nofork" then
        return M.tr("status_nofork", "无法启动 easytier-cli")
    end
    if snap.failed.node == "timeout" then
        return M.tr("status_timeout", "RPC 超时")
    end
    return M.tr("status_stopped", "未运行（RPC 连不上）")
end

return M
