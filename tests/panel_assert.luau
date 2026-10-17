--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- tests/panel_assert.luau —— panel.luau 的离线渲染断言
--
-- 跑完 onOpen() 之后检查渲染树：结构是否完整、数据是否显示出来、
-- 服务器节点（公共共享节点）是否与普通节点分段且默认折叠、点了能不能展开，
-- 以及本仓库踩过的坑（按钮必须放在容器末尾，否则会破坏同级渲染）。
-- ══════════════════════════════════════════════════════════════════════════

-- onOpen 会触发一次抓取；假宿主是同步回调，所以这里返回时渲染树已经是最新的
onOpen({})

if rendered == nil then
    error("[FAIL] panel.render 没有被调用", 0)
end

local function walk(node, visit)
    visit(node)
    for _, child in ipairs(node.children or {}) do
        walk(child, visit)
    end
end

-- 每次都重新遍历「当前」渲染树（点开中继后要重新收集一遍）
local function collect()
    local result = { total = 0, texts = {}, kinds = {} }
    walk(rendered, function(node)
        result.total += 1
        result.kinds[node.kind] = (result.kinds[node.kind] or 0) + 1
        local text = node.props and node.props.text
        if type(text) == "string" then
            table.insert(result.texts, text)
        end
    end)
    result.has = function(needle)
        for _, text in ipairs(result.texts) do
            if text:find(needle, 1, true) ~= nil then
                return true
            end
        end
        return false
    end
    return result
end

-- 找到某个可折叠分区的标题行（整行可点，用来展开／折叠）
local function findToggleHead(title)
    local found = nil
    walk(rendered, function(node)
        if node.kind ~= "row" or not (node.props and node.props.onClick) then
            return
        end
        for _, child in ipairs(node.children or {}) do
            local text = child.props and child.props.text
            if text == title then
                found = node
            end
        end
    end)
    return found
end

-- 服务器节点卡片是否存在：以 peerCard 的容器标识（fill = surface_variant/0.35）
-- 包住 hostname 来判断，避免依赖收发字节的显示格式。
local function hasServerCard()
    local found = false
    walk(rendered, function(node)
        if node.kind ~= "column" or (node.props and node.props.fill) ~= "surface_variant/0.35" then
            return
        end
        walk(node, function(inner)
            local text = inner.props and inner.props.text
            if text == "PublicServer_debian" then
                found = true
            end
        end)
    end)
    return found
end

local first = collect()

-- 1. 整体结构：根就是滚动区，第一段是标题行、最后一段是页脚
-- （根是 scroll 而不是 column：宿主在 column 里会把带 flexGrow 的滚动区压扁，
--   与 ylxc-qweather 采用的结构保持一致）
eq(rendered.kind, "scroll", "根节点是滚动区")
eq(rendered.props.padding, 14, "滚动区带内边距")
eq(rendered.children[1].kind, "row", "第一段是标题行")
eq(rendered.children[#rendered.children].kind, "column", "最后一段是页脚")

-- 2. 滚动区要有实际内容（本机卡片、概览、节点列表…）
local scroll = rendered
eq(#scroll.children >= 7, true, "滚动区至少 7 段内容")
eq(scroll.props.gap, 10, "滚动区带间距")

-- 3. 数据真的渲染出来了
eq(first.has("ylxc-t480s"), true, "本机 hostname 已渲染")
eq(first.has("172.24.1.1"), true, "本机虚拟 IP 已渲染")
eq(first.has("ylxc-r9000p"), true, "普通（p2p）节点已渲染")
eq(first.has("183.219.160.42"), true, "公网地址已渲染")
eq(first.has("Symmetric"), true, "NAT 类型已渲染")
eq(first.has("29.4ms"), true, "延迟已格式化渲染")
eq(first.has("tcp://public.easytier.cn:11010"), false, "连接器默认折叠（地址未渲染）")
eq(first.has("ylxc"), true, "网络名已渲染")

-- 4. 服务器节点与普通节点分段，且服务器默认折叠（relay 模式的节点不算服务器）
eq(first.has("服务器"), true, "服务器分区标题已渲染")
eq(first.has("ylxc-phone"), true, "relay 模式节点留在普通组里照常渲染")
eq(hasServerCard(), false, "服务器节点卡片默认折叠（未渲染）")
eq(first.has("展开"), true, "折叠时显示「展开」")

-- 5. 服务器节点：点标题行展开、再点收回（默认折叠）
local serverRow = findToggleHead("服务器")
eq(serverRow ~= nil, true, "服务器分区标题行可点")

serverRow.props.onClick()
local opened = collect()
eq(hasServerCard(), true, "点击后服务器节点卡片渲染出来")
eq(opened.has("收起"), true, "展开后显示「收起」")

serverRow = findToggleHead("服务器")
eq(serverRow ~= nil, true, "展开后服务器标题行仍在")
serverRow.props.onClick()
local folded = collect()
eq(hasServerCard(), false, "再点一次重新折叠")
eq(folded.has("展开"), true, "收回去后又显示「展开」")

-- 6. 路由表与连接器同样可折叠，且默认都是收起状态
local foldedAll = collect()
eq(foldedAll.has("经 ylxc-r9000p"), false, "路由表默认折叠（未渲染）")
eq(foldedAll.has("tcp://public.easytier.cn:11010"), false, "连接器默认折叠（未渲染）")

local routeRow = findToggleHead("路由")
eq(routeRow ~= nil, true, "路由分区标题行可点")
routeRow.props.onClick()
local routesShown = collect()
eq(routesShown.has("经 ylxc-r9000p"), true, "点击后路由表渲染出来")
eq(routesShown.has("tcp://public.easytier.cn:11010"), false, "展开路由不影响连接器")

routeRow = findToggleHead("路由")
routeRow.props.onClick()
eq(collect().has("经 ylxc-r9000p"), false, "再点一次重新折叠路由")

local connRow = findToggleHead("连接器")
eq(connRow ~= nil, true, "连接器分区标题行可点")
connRow.props.onClick()
local connShown = collect()
eq(connShown.has("tcp://public.easytier.cn:11010"), true, "点击后连接器列表渲染出来")
eq(connShown.has("已连接"), true, "连接器状态已渲染")

connRow = findToggleHead("连接器")
connRow.props.onClick()
eq(collect().has("tcp://public.easytier.cn:11010"), false, "再点一次重新折叠连接器")

-- 7. 渲染树规模合理（防止「只剩本机卡片」这种半截渲染再次发生）
eq(first.total > 45, true, string.format("渲染树节点数 %d 应大于 45", first.total))
eq((first.kinds.scroll or 0), 1, "只有一个滚动区")
eq((first.kinds.button or 0) >= 1, true, "至少有刷新按钮")

-- 8. 按钮必须位于其容器的末尾（宿主已知渲染陷阱）
local violations = {}
walk(rendered, function(node)
    local children = node.children or {}
    for index, child in ipairs(children) do
        if child.kind == "button" and index ~= #children then
            table.insert(violations, string.format("%s 容器的第 %d/%d 个子节点是按钮", node.kind, index, #children))
        end
    end
end)
eq(#violations, 0, "按钮都在容器末尾" .. (#violations > 0 and ("（" .. table.concat(violations, "；") .. "）") or ""))

-- 9. 没有加载中的占位文案残留（说明数据链路跑通了）
eq(first.has("正在读取"), false, "不应停留在「正在读取」状态")

print(string.format("面板渲染通过：%d 个节点（%s），文本 %d 条", first.total, "button=" .. tostring(first.kinds.button or 0), #first.texts))
