# ylxc-easytier

Noctalia 的 [EasyTier](https://github.com/EasyTier/EasyTier) 组网状态插件。状态栏一眼看到有几个节点，
点开面板看每个节点的延迟、丢包、走的是直连还是中继，以及路由表、连接器、子网代理和端口转发。

数据全部来自 `easytier-cli -o json` 的只读调用：插件不写 EasyTier 的配置文件、不改运行状态、
不常驻任何进程。

## 功能

栏组件（`bar.luau`）：

- 文字可切：节点状态（默认，未运行时显示「未运行」）、节点数、直连/总数、最优延迟、累计流量、虚拟 IPv4
- 图标与文字按健康度变色：正常 → 主题主色，偏高（延迟高、有丢包、出现中继）→ 主题第三色，掉线/严重 → 告警色
- 悬停提示：网络名、虚拟 IP、公网地址与 NAT 类型、节点/直连/中继数、最优/平均/最差延迟、丢包面、累计收发、版本
- 左键打开详情面板（可在组件手势里改绑），右键立刻刷新
- 可选：core 没在运行时收起整个组件；组网掉线/恢复时弹通知

详情面板（`panel.luau`）：

- 本机卡片：hostname、虚拟 IP、网络名、版本、NAT 类型（UDP/TCP）、公网地址、公网端口范围、实例 ID、Peer ID、监听地址、子网代理
- 概览：节点数、直连、中继、最优/平均/最差延迟、丢包节点数、累计收发
- 节点列表：普通设备与**服务器节点**（公共共享节点，默认按主机名前缀 `PublicServer` 识别）分成两段，**服务器节点默认折叠**、点标题行展开；每行显示 hostname、虚拟 IP、cost、延迟、丢包、隧道协议、NAT 类型、版本、收发字节，丢包节点带进度条；按 cost 与延迟排序，超过上限收进「展开」
- 路由表：目标、虚拟 IP、下一跳（next_hop_hostname / next_hop_lat）、路径跳数与路径延迟
- 连接器：每个 `--peer` 地址的连通状态
- 子网代理与端口转发：读取 `node.proxy_cidrs` 与 `port-forward` 的条目

## 依赖

只需要一个能用的 `easytier-cli`（随 EasyTier 一起发布）：

```bash
easytier-cli -o json peer     # 验证：应输出 JSON
```

命令不在 PATH 里，或者想指定某个版本时，在插件设置里填绝对路径。

## 安装

```bash
git clone https://github.com/LittleFishStars/noctalia-easytier.git ~/.local/share/noctalia/plugins/ylxc-easytier
noctalia plugins enable ylxc/easytier
```

改动 `plugin.toml`（增删设置项、改面板尺寸）后需要重新播种清单：

```bash
noctalia msg plugins disable ylxc/easytier
noctalia msg plugins enable ylxc/easytier
```

只改 `.luau` 代码则保存即热重载（宿主日志：`[plugin-panel] hot reload: reloaded 'xxx.luau'`）。

## 设置

| 设置 | 默认 | 说明 |
| --- | --- | --- |
| `cli_path` | 空 | 留空用 PATH 里的 `easytier-cli` |
| `rpc_portal` | 空（即 `127.0.0.1:15888`） | 传给 `-p`，须与 easytier-core 的 `--rpc-portal` 一致 |
| `instance_name` | 空 | 传给 `-n`，同机多实例时才需要 |
| `instance_id` | 空 | 传给 `-i`，已知实例 ID 时优先用它 |
| `refresh_seconds` | 10 | 重新调用 easytier-cli 的间隔（2–600 秒） |
| `warn_latency_ms` | 150 | 最优延迟达到该值降级为「偏高」 |
| `crit_latency_ms` | 400 | 最优延迟达到该值判为「严重」 |
| `relay_warn` | 开 | 出现中继节点就降级为「偏高」 |
| `loss_warn_percent` | 2 | 任一节点丢包达到该值降级为「偏高」 |
| `loss_crit_percent` | 10 | 任一节点丢包达到该值判为「严重」 |
| `fetch_extras` | 开 | 打开面板时额外读路由/连接器/代理/端口转发 |
| `max_peers` | 64 | 面板直接列出的节点上限 |
| `server_prefix` | `PublicServer` | 主机名含这些前缀的节点算公共服务器节点，单独成段且默认折叠（多个前缀用逗号分隔） |
| `notify_state_change` | 关 | 掉线/恢复时发通知 |
| `display` | `status` | 栏上文字：状态/节点数/直连比/最优延迟/流量/虚拟 IP |
| `glyph` / `show_glyph` | `network` / 开 | 栏上图标 |
| `glyph_color` | `level` | 按状态，或固定某个主题角色 |
| `hide_when_stopped` | 关 | core 未运行时隐藏组件 |

状态判定的优先级：最优延迟 ≥ `crit_latency_ms` 或任一节点丢包 ≥ `loss_crit_percent` → 严重；
最优或平均延迟 ≥ `warn_latency_ms`、任一节点丢包 ≥ `loss_warn_percent`、或出现中继（开启时）→ 偏高；否则正常。
延迟按**最优**延迟判定，最差值只展示——异地节点天然慢，不该让整栏变红。

## 测试

用假宿主（`tests/env.luau`、`tests/env_panel.luau`）替掉 `noctalia` / `ui` / `panel`，
`easytier-cli` 的 JSON 用固定样例，于是在没有 Noctalia、没有 EasyTier 的机器上也能跑：

```bash
cd ~/.local/share/noctalia/plugins/ylxc-easytier
bash tests/run.sh
```

预期输出：

```text
── lib（纯逻辑）────────────────────────────────────────────
全部通过：109 项断言
── panel（完整渲染链）──────────────────────────────────────
面板渲染通过：162 个节点（button=1），文本 78 条
```

里面有几条回归断言，都是开发时真踩到的坑：所有 `ui.button` 必须位于其容器的
**最后一个**子节点（否则宿主会中断同级渲染，后面的卡片整个消失）；渲染树节点数
有下限（防「面板只剩本机卡片」的半截渲染）；根节点必须是滚动区（把带 `flexGrow`
的 `ui.scroll` 放进 `ui.column` 会被压成一条缝）。

## 数据来源

每条子命令一次子进程调用（argv 形式，不经过 shell，实例名带空格也安全），全部并发，
单个失败不影响其余：

| 子命令 | 用到的字段 |
| --- | --- |
| `node` | hostname、ipv4_addr、peer_id、inst_id、version、listeners、proxy_cidrs、stun_info、config（取 `network_name`）、ip_list.public_ipv4 |
| `peer` | hostname、ipv4、cost、lat_ms、loss_rate、rx_bytes、tx_bytes、tunnel_proto、nat_type、version、id |
| `route` | hostname、ipv4、next_hop_ipv4、next_hop_hostname、next_hop_lat、path_len、path_latency |
| `connector` | url.url、status（0 = 已连接） |
| `proxy` | cidr 等（字段随版本变化，取不到就跳过） |
| `port-forward` | cfgs[]（同上） |

`node` 拿不到 = core 没在跑或 RPC 连不上，此时栏显示「未运行」，面板给出诊断卡片
（cli 是否存在、RPC 地址、上次失败原因、重试按钮）。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| 栏一直显示「未运行」 | 确认 `easytier-core` 在跑；`easytier-cli -p 127.0.0.1:15888 -o json node` 能否出 JSON |
| 提示「找不到 easytier-cli」 | 在设置里填绝对路径（例如 `/usr/bin/easytier-cli`） |
| 「RPC 超时」 | core 的 `--rpc-portal` 与插件设置不一致，或 core 正忙 |
| 面板打开慢 | 关掉「面板读取额外信息」 |
| 节点列表不全 | 调大「面板节点上限」，或点「展开」 |
| 看不到服务器节点 | 公共服务器单独成段且默认折叠，点「服务器」那一行展开；网络里没有公共服务器（主机名不含前缀）时不显示该段，前缀可在设置里改 |
| 改了设置不生效 | `noctalia msg config-reload`；改了 `plugin.toml` 需 disable + enable |

## 目录结构

```
ylxc-easytier/
├── plugin.toml            # 清单：设置项、面板尺寸、组件交互绑定
├── bar.luau               # 状态栏组件
├── panel.luau             # 详情面板
├── lib/
│   └── easytier.luau      # 抓取 + 解析 + 格式化（栏与面板共用）
├── tests/
│   ├── run.sh             # 一键跑全部离线测试
│   ├── env.luau           # 假宿主（noctalia API）+ 固定样例数据
│   ├── assertions.luau    # lib 的纯逻辑断言
│   ├── env_panel.luau     # 假宿主 + 假 ui/panel，捕获渲染树
│   └── panel_assert.luau  # 渲染树断言（结构 / 数据 / 按钮位置）
└── translations/
    ├── zh-Hans.json
    └── en.json
```

注意：`.luau` 里的 `require` 路径必须相对当前文件并以 `.luau` 结尾。

## 许可

MIT
