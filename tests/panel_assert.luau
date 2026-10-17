--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- tests/panel_assert.luau —— panel.luau 的离线渲染断言
--
-- 跑完 onOpen() 之后检查渲染树：结构是否完整、数据是否显示出来、
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

local total = 0
local texts = {}
local kinds = {}

walk(rendered, function(node)
    total += 1
    kinds[node.kind] = (kinds[node.kind] or 0) + 1
    local text = node.props and node.props.text
    if type(text) == "string" then
        table.insert(texts, text)
    end
end)

local function hasText(needle)
    for _, text in ipairs(texts) do
        if text:find(needle, 1, true) ~= nil then
            return true
        end
    end
    return false
end

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
eq(hasText("ylxc-t480s"), true, "本机 hostname 已渲染")
eq(hasText("172.24.1.1"), true, "本机虚拟 IP 已渲染")
eq(hasText("ylxc-r9000p"), true, "直连节点已渲染")
eq(hasText("ylxc-phone"), true, "中继节点已渲染")
eq(hasText("183.219.160.42"), true, "公网地址已渲染")
eq(hasText("Symmetric"), true, "NAT 类型已渲染")
eq(hasText("29.4ms"), true, "延迟已格式化渲染")
eq(hasText("tcp://public.easytier.cn:11010"), true, "连接器地址已渲染")
eq(hasText("ylxc"), true, "网络名已渲染")

-- 4. 渲染树规模合理（防止「只剩本机卡片」这种半截渲染再次发生）
eq(total > 60, true, string.format("渲染树节点数 %d 应大于 60", total))
eq((kinds.scroll or 0), 1, "只有一个滚动区")
eq((kinds.button or 0) >= 1, true, "至少有刷新按钮")

-- 5. 按钮必须位于其容器的末尾（宿主已知渲染陷阱）
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

-- 6. 没有加载中的占位文案残留（说明数据链路跑通了）
eq(hasText("正在读取"), false, "不应停留在「正在读取」状态")

print(string.format("面板渲染通过：%d 个节点（%s），文本 %d 条", total, "button=" .. tostring(kinds.button or 0), #texts))
