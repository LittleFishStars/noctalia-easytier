--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- tests/assertions.luau —— lib/easytier.luau 的离线断言
--
-- 样本取真实 easytier-cli 2.6.4 的输出（node/peer/route/connector），
-- 只测纯逻辑：设置兜底、argv 组装、单位换算、派生指标、状态分级、排序、
-- 本机信息提取、连接器解析、状态文案。不启动任何子进程。
-- ══════════════════════════════════════════════════════════════════════════

local e = M

-- 1. 设置读取（getConfig 可能返回字符串/数字/布尔混杂）
local cfg = e.cfg()
eq(cfg.cli, "/usr/bin/easytier-cli", "cfg.cli")
eq(cfg.portal, "127.0.0.1:15888", "cfg.portal")
eq(cfg.instanceName, "default", "cfg.instanceName")
eq(cfg.instanceId, "", "cfg.instanceId")
eq(cfg.refresh, 10, "cfg.refresh")
eq(cfg.warnLatency, 150, "cfg.warnLatency")
eq(cfg.critLatency, 400, "cfg.critLatency")
eq(cfg.relayWarn, true, "cfg.relayWarn")
eq(cfg.lossWarn, 2, "cfg.lossWarn")
eq(cfg.lossCrit, 10, "cfg.lossCrit")
eq(cfg.extras, true, "cfg.extras")
eq(cfg.maxPeers, 64, "cfg.maxPeers")
eq(cfg.serverPrefix, "PublicServer", "cfg.serverPrefix")
eq(cfg.notify, false, "cfg.notify")

-- 2. argv 组装（argv 形式不经过 shell）
local argv = e.argv(cfg, "peer")
eq(table.concat(argv, " "), "/usr/bin/easytier-cli -p 127.0.0.1:15888 -n default -o json peer", "argv(peer)")

local bare = e.argv({ cli = "", portal = "", instanceName = "", instanceId = "" }, "node")
eq(table.concat(bare, " "), "easytier-cli -o json node", "argv(最小参数)")

-- 3. 数值与单位
eq(e.num("29.40"), 29.4, "num 小数")
eq(e.num("-"), nil, "num 空值")
eq(e.num("276.10"), 276.1, "num 大值")
eq(e.num(nil), nil, "num nil")
eq(e.parseBytes("100.47 kB"), 100.47 * 1024, "parseBytes kB")
eq(e.parseBytes("5.87 MB"), 5.87 * 1024 * 1024, "parseBytes MB")
eq(e.parseBytes("1.2 GiB"), 1.2 * 1024 * 1024 * 1024, "parseBytes GiB")
eq(e.parseBytes("junk"), nil, "parseBytes 垃圾")
eq(e.bytes(1024), "1.0K", "bytes 1K")
eq(e.bytes(100481), "98K", "bytes 98K")
eq(e.bytes(6155583), "5.9M", "bytes 5.9M")
eq(e.bytes(512), "512B", "bytes 512B")
eq(e.ms(29.4), "29.4ms", "ms 小数")
eq(e.ms(276.1), "276ms", "ms 整数")
eq(e.ms(1500), "1.50s", "ms 秒")
eq(e.ms(nil), "-", "ms 空")
eq(e.percentText(1.0), "1.0%", "percentText 1.0")
eq(e.percentText(0), "0%", "percentText 0")
eq(e.ipFromInt(0), "0.0.0.0", "ipFromInt 0")
eq(e.ipFromInt(3084623914), "183.219.160.42", "ipFromInt 真实公网地址")
eq(e.stripCidr("172.24.1.1/16"), "172.24.1.1", "stripCidr")
eq(e.natName(6), "Symmetric", "natName 枚举")
eq(e.natName("PortRestricted"), "PortRestricted", "natName 字符串")
eq(e.natName("-"), nil, "natName 空值")
eq(e.shortId("2c7e53fe-47f4-46c3-9db6-58f29e39dc49"), "2c7e53fe…dc49", "shortId")
eq(e.ago(10), "10 秒前", "ago 秒")

-- 4. cost 归类
eq(e.costOf({ cost = "Local" }), "local", "costOf Local")
eq(e.costOf({ cost = "p2p" }), "p2p", "costOf p2p")
eq(e.costOf({ cost = "relay" }), "relay", "costOf relay")
eq(e.costOf({ cost = "weird" }), "other", "costOf 未知")

-- 5. 派生指标（数值取自真实 peer 输出）
local snap = {
    at = os.time(),
    failed = {},
    node = {
        hostname = "ylxc-t480s",
        ipv4_addr = "172.24.1.1/16",
        peer_id = 1062248666,
        inst_id = "2c7e53fe-47f4-46c3-9db6-58f29e39dc49",
        version = "2.6.4",
        listeners = { "ring://abc", "tcp://0.0.0.0:11010", "udp://0.0.0.0:11010" },
        proxy_cidrs = { "10.1.1.0/24" },
        config = 'network_name = "ylxc-net"\ninstance_name = "default"\n',
        stun_info = { udp_nat_type = 6, min_port = 44254, max_port = 56540 },
        ip_list = { public_ipv4 = { addr = 3084623914 } },
    },
    peers = {
        { hostname = "ylxc-t480s", ipv4 = "172.24.1.1", cost = "Local", lat_ms = "0.00", loss_rate = "1.0%", rx_bytes = "1.00 KB", tx_bytes = "2.00 KB", tunnel_proto = "tcp", nat_type = "Symmetric", version = "2.6.4", id = 1062248666 },
        { hostname = "ylxc-r9000p", ipv4 = "172.24.1.2", cost = "p2p", lat_ms = "29.40", loss_rate = "1.0%", rx_bytes = "100.47 kB", tx_bytes = "117.73 kB", tunnel_proto = "tcp", nat_type = "PortRestricted", version = "2.6.4", id = 1 },
        { hostname = "ylxc-phone", ipv4 = "172.24.1.3", cost = "relay", lat_ms = "-", loss_rate = "0.0%", rx_bytes = "5.87 MB", tx_bytes = "1.03 MB", tunnel_proto = "udp", nat_type = "Symmetric", version = "2.6.4", id = 2 },
    },
    routes = {
        { hostname = "ylxc-r9000p", ipv4 = "172.24.1.2", next_hop_hostname = "ylxc-r9000p", next_hop_lat = "0", path_len = 1, path_latency = "29.40" },
    },
    connectors = {
        { url = { url = "tcp://public.easytier.cn:11010" }, status = 0 },
        { url = { url = "wss://et.chinokou.cn/" }, status = 1 },
    },
}

local d = e.derive(snap)
eq(d.total, 2, "derive.total（不含本机）")
eq(d.direct, 1, "derive.direct")
eq(d.relay, 1, "derive.relay")
eq(d.other, 0, "derive.other")
eq(d.best, 29.4, "derive.best")
eq(d.worst, 29.4, "derive.worst")
eq(d.avg, 29.4, "derive.avg")
eq(d.counted, 1, "derive.counted（中继无延迟样本）")
eq(d.lossy, 1, "derive.lossy")
eq(d.lossMax, 1.0, "derive.lossMax")
eq(d.rx, 100.47 * 1024 + 5.87 * 1024 * 1024 + 1024, "derive.rx（含本机那一行）")
eq(d.ready, true, "derive.ready")
eq(d.own.hostname, "ylxc-t480s", "derive.own")

-- 6. 状态分级
eq(e.level(cfg, nil, nil), "loading", "level 未加载")
eq(e.level(cfg, { failed = {} }, nil), "off", "level core 未运行")
eq(e.level(cfg, snap, d), "warn", "level 出现中继 → warn")

local function fake(overrides)
    local base = { total = 1, direct = 1, relay = 0, other = 0, best = 29.4, worst = 29.4, avg = 29.4, counted = 1, lossy = 0, lossMax = 0, ready = true }
    for key, value in pairs(overrides or {}) do
        base[key] = value
    end
    return base
end

eq(e.level(cfg, snap, fake()), "ok", "level 全绿")
eq(e.level(cfg, snap, fake({ best = 200, avg = 200, worst = 200 })), "warn", "level 延迟过告警线")
eq(e.level(cfg, snap, fake({ best = 500, avg = 500, worst = 500 })), "crit", "level 延迟过严重线")
eq(e.level(cfg, snap, fake({ lossy = 1, lossMax = 1 })), "ok", "level 1% 丢包不降级（低于告警阈值）")
eq(e.level(cfg, snap, fake({ lossy = 1, lossMax = 5 })), "warn", "level 5% 丢包 → warn")
eq(e.level(cfg, snap, fake({ lossy = 1, lossMax = 12 })), "crit", "level 12% 丢包 → crit")
eq(e.level(cfg, snap, fake({ relay = 1, direct = 0, avg = 200 })), "warn", "level 平均延迟过线")

-- 7. 排序与行数据（直连在前、中继在后）
local rows = e.rows(snap, cfg)
eq(#rows, 2, "rows 排除本机")
eq(rows[1].hostname, "ylxc-r9000p", "rows[1] 为直连")
eq(rows[2].hostname, "ylxc-phone", "rows[2] 为中继")
eq(rows[1].cost, "p2p", "rows[1].cost")
eq(rows[1].ip, "172.24.1.2", "rows[1].ip")
eq(rows[1].latency, 29.4, "rows[1].latency")
eq(rows[1].level, "ok", "rows[1].level（1% 丢包不降级）")
eq(rows[2].level, "warn", "rows[2].level（中继）")
eq(rows[2].latency, nil, "rows[2].latency（无样本）")
-- 7b. 分段：普通设备与服务器节点（公共共享节点）分开
--     「服务器节点」指的是 PublicServer_* 这类公共共享节点，与 cost = relay 无关
local normal, servers = e.splitRows(rows, cfg)
eq(#normal, 2, "splitRows 普通组 2 个（relay 模式节点也算普通设备）")
eq(normal[1].hostname, "ylxc-r9000p", "普通组含 p2p 节点")
eq(normal[2].hostname, "ylxc-phone", "普通组含 relay 模式节点")
eq(#servers, 0, "样本里没有公共服务器 → 服务器组为空")

local mixed = e.rows({ peers = {
    { hostname = "YlxcServer", ipv4 = "172.24.0.1", cost = "p2p", lat_ms = "12.00" },
    { hostname = "PublicServer_debian", ipv4 = "", cost = "p2p", lat_ms = "30.60" },
    { hostname = "PublicServer_Arisu", ipv4 = "", cost = "p2p", lat_ms = "29.00" },
} }, cfg)
local plain, shared = e.splitRows(mixed, cfg)
eq(#plain, 1, "服务器组摘走后普通组剩 1 个")
eq(plain[1].hostname, "YlxcServer", "自己的服务器（有虚拟 IP、名不含前缀）算普通节点")
eq(#shared, 2, "两个 PublicServer_* 归入服务器组（按 server_prefix 前缀）")

-- 前缀表可配置，且认中英文逗号
eq(#e.prefixes({ serverPrefix = "PublicServer, EasyTier公共，node" }), 3, "prefixes 拆三项")
eq(e.isServer("publicserver_debian", { "publicserver" }), true, "isServer 忽略大小写")
eq(e.isServer("ylxc-r9000p", { "publicserver" }), false, "isServer 普通名字不算")
eq(#e.splitRows({}), 0, "splitRows 空表不报错")
eq(#e.splitRows(nil), 0, "splitRows nil 不报错")
-- 8. 本机信息
local info = e.nodeInfo(snap)
eq(info.hostname, "ylxc-t480s", "info.hostname")
eq(info.ip, "172.24.1.1", "info.ip")
eq(info.network, "ylxc-net", "info.network（从 config 文本提取）")
eq(info.nat, "Symmetric", "info.nat")
eq(info.publicPortRange, "44254-56540", "info.publicPortRange")
eq(#info.listeners, 2, "info.listeners（滤掉 ring://）")
eq(info.proxyCidrs[1], "10.1.1.0/24", "info.proxyCidrs")
eq(info.publicIp, "183.219.160.42", "info.publicIp（整数回退）")
eq(e.nodeInfo({ failed = {} }), nil, "nodeInfo 无数据时为 nil")

-- 9. 连接器与状态文案
local conns = e.connectorRows(snap)
eq(#conns, 2, "connectorRows")
eq(conns[1].url, "tcp://public.easytier.cn:11010", "connector url")
eq(conns[1].status, 0, "connector 已连接")
eq(conns[2].status, 1, "connector 未连接")
eq(e.statusText(cfg, nil), "读取中…", "statusText 加载中")
eq(e.statusText(cfg, snap), "运行中", "statusText 运行中")
eq(e.statusText(cfg, { failed = {} }), "未运行（RPC 连不上）", "statusText 未运行")
eq(e.statusText(cfg, { failed = { node = "timeout" } }), "RPC 超时", "statusText 超时")
eq(e.peerCountText(snap, d), "2", "peerCountText")
eq(e.peerCountText(nil, nil), "--", "peerCountText 无数据")

print(string.format("全部通过：%d 项断言", checks))
