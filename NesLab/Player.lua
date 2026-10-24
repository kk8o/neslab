-- 游戏机界面：一个窗口四页——游戏库（卡带列表、详情、开始）、加载（进度条）、游戏（画面 + 工具栏 + 暂停菜单）、
-- 键位（设置与测试，在 Binds.lua）。
-- 卡带是独立的按需加载插件（NesLab_<游戏名拼音>，tools/nes2cart.py 生成）：游戏库从插件列表里认出带 X-NesLab-Cart 的，
-- 不加载就能列出名字、类型、大小；开始游戏时才 LoadAddOn 读进来。
-- 存档 NesLabDB：缩放、静音、选中的卡带、每张卡带玩了几次 / 上次时间。
-- 键位（键盘 A、键盘 B、手柄三套，各属 P1 或 P2）在 Binds.lua：NesLab.KeyAction / PadAction 把键查成操作（UP…START、TURBO_A/B、SAVE、LOAD、
-- PAUSE），M 静音、Esc 菜单固定，左摇杆固定当十字键。游戏库里回车 / Start / A 开始选中的游戏，手柄 B 关闭。
-- 窗口开着时手柄只管这里，不动角色。
local _, ns = ...
local band, bor = bit.band, bit.bor

local FONT = STANDARD_TEXT_FONT
local GOLD = { 0.79, 0.67, 0.44 }
local FRAME = 1 / 60.0988                      -- NTSC 帧率
local TITLE_H, BAR_H, PAD = 28, 34, 10
local GAME_MIN_W, GAME_MIN_H = 600, 420
local COLS, ROWS, GAP = 5, 3, 8                 -- 游戏库：封面卡片 5 列 3 行，滚轮翻行
local CARD_W, CARD_H = 136, 176
local COVER_W, COVER_H = 128, 120               -- 标题画面 256×240 的一半
local DOCK_H = 74                               -- 底栏：选中的游戏 + 开始
local LIB_W = PAD * 2 + COLS * CARD_W + (COLS - 1) * GAP
local LIB_H = TITLE_H + PAD + ROWS * CARD_H + (ROWS - 1) * GAP + GAP + DOCK_H + PAD

local BUTTON = { A = 1, B = 2, SELECT = 4, START = 8, UP = 16, DOWN = 32, LEFT = 64, RIGHT = 128 }
local HELP_SHORT = "按键可以在「键位」里查看、修改和测试 · 支持手柄"
-- 无限工坊（NesLab 就是 AI 用它写出来、调试好的）：游戏库标题栏、加载页、小地图提示里各一句，点了给网址复制
local WORKSHOP_URL = "https://wuxianwow.com/workshop"
local WORKSHOP_AD = "用无限工坊制作 · 让 AI 帮你写魔兽插件"
local WORKSHOP_TIP = { "NesLab 是 AI 用无限工坊写出来、调试好的。",
	"无限工坊把 AI 连上你的游戏：写插件、改插件、看报错、截图调试，", "说清楚想要什么，剩下的交给它。" }
NesLab.WORKSHOP_URL, NesLab.WORKSHOP_AD = WORKSHOP_URL, WORKSHOP_AD

local P = {}                                   -- 界面状态
NesLab.player = P

------------------------------------------------------------------------------------------------------------------------
-- 小工具

local function Fill(parent, layer, r, g, b, a, sub)
	local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
	t:SetColorTexture(r, g, b, a or 1)
	return t
end

local function Panel(f, r, g, b, a)
	local edge = Fill(f, "BACKGROUND", 0, 0, 0, 1, -8)
	edge:SetPoint("TOPLEFT", -1, 1)
	edge:SetPoint("BOTTOMRIGHT", 1, -1)
	f.bg = Fill(f, "BACKGROUND", r, g, b, a or 1, -7)
	f.bg:SetAllPoints()
end

local function Text(parent, size, r, g, b)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(FONT, size, "")
	fs:SetShadowOffset(1, -1)
	fs:SetTextColor(r or 1, g or 1, b or 1)
	fs:SetJustifyH("LEFT")
	return fs
end

local function Look(b, hover)
	if b.primary and b:IsEnabled() then
		b.bg:SetColorTexture(hover and 0.86 or 0.79, hover and 0.74 or 0.67, hover and 0.50 or 0.44, 1)
		b.text:SetTextColor(0.08, 0.07, 0.05)
	elseif b.selected then
		b.bg:SetColorTexture(0.25, 0.21, 0.14, 1)
		b.text:SetTextColor(unpack(GOLD))
	else
		b.bg:SetColorTexture(hover and 0.22 or 0.16, hover and 0.20 or 0.16, hover and 0.16 or 0.18, 1)
		if hover then b.text:SetTextColor(unpack(GOLD)) else b.text:SetTextColor(1, 1, 1) end
	end
	if not b:IsEnabled() then b.text:SetTextColor(0.42, 0.42, 0.42) end
end

local function Button(parent, w, h, label, onClick, primary)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h)
	Panel(b, 0.16, 0.16, 0.18, 1)
	b.text = Text(b, 13)
	b.text:SetPoint("CENTER")
	b.text:SetJustifyH("CENTER")
	b.text:SetText(label)
	b.primary = primary
	b:SetScript("OnEnter", function(s) Look(s, true) end)
	b:SetScript("OnLeave", function(s) Look(s, false) end)
	b:SetScript("OnEnable", function(s) Look(s, false) end)
	b:SetScript("OnDisable", function(s) Look(s, false) end)
	b:SetScript("OnClick", onClick)
	function b:SetLabel(s) self.text:SetText(s) end
	function b:SetSelected(v)
		self.selected = v
		Look(self, false)
	end
	Look(b, false)
	return b
end

NesLab.ui = { Fill = Fill, Panel = Panel, Text = Text, Button = Button, GOLD = GOLD, PAD = PAD, TITLE_H = TITLE_H,
	LIB_W = LIB_W, LIB_H = LIB_H }

local function DB()
	NesLabDB = NesLabDB or {}
	local db = NesLabDB
	db.scale = db.scale or 2
	db.carts = db.carts or {}
	return db
end

------------------------------------------------------------------------------------------------------------------------
-- 卡带

-- 插件列表里的卡带（不加载）；卡带插件加载时调 NesLab.RegisterRom（Nes.lua）
function NesLab.ScanCarts()
	local list = {}
	for i = 1, C_AddOns.GetNumAddOns() do
		if C_AddOns.GetAddOnMetadata(i, "X-NesLab-Cart") == "1" then
			local addon, _, _, loadable, reason = C_AddOns.GetAddOnInfo(i)
			local id = C_AddOns.GetAddOnMetadata(i, "X-NesLab-Id") or addon
			list[#list + 1] = {
				addon = addon, id = id, name = C_AddOns.GetAddOnMetadata(i, "X-NesLab-Name") or id,
				kind = C_AddOns.GetAddOnMetadata(i, "X-NesLab-Mapper") or "",
				size = tonumber(C_AddOns.GetAddOnMetadata(i, "X-NesLab-Size") or "") or 0,
				battery = C_AddOns.GetAddOnMetadata(i, "X-NesLab-Battery") == "1",
				cover = C_AddOns.GetAddOnMetadata(i, "X-NesLab-Cover") == "1" and ("Interface\\AddOns\\" .. addon .. "\\cover") or nil,
				-- 按需加载的插件没加载前 loadable 为假、reason = DEMAND_LOADED，这是正常的「可以加载」
				loadable = loadable or reason == "DEMAND_LOADED" or C_AddOns.IsAddOnLoaded(addon), reason = reason,
			}
		end
	end
	local carts = DB().carts
	table.sort(list, function(a, b)
		local la, lb = carts[a.id] and carts[a.id].last or 0, carts[b.id] and carts[b.id].last or 0
		if la ~= lb then return la > lb end
		return a.name < b.name
	end)
	return list
end

------------------------------------------------------------------------------------------------------------------------
-- 窗口与四页

local function SetSize(w, h)
	P.win:SetSize(w, h)
end

local function ShowPage(name)
	if name ~= "binds" then P.capture = nil end
	P.search:ClearFocus()
	P.copy.edit:ClearFocus()
	for k, f in pairs(P.pages) do f:SetShown(k == name) end
	P.search:SetShown(name == "library")
	P.ad:SetShown(name == "library" or name == "binds")
	P.copy:Hide()
	P.page = name
end

local function Card(parent)
	local r = CreateFrame("Button", nil, parent)
	r:SetSize(CARD_W, CARD_H)
	r.edge = Fill(r, "BACKGROUND", 0, 0, 0, 1, -8)
	r.edge:SetPoint("TOPLEFT", -1, 1)
	r.edge:SetPoint("BOTTOMRIGHT", 1, -1)
	r.bg = Fill(r, "BACKGROUND", 0.10, 0.10, 0.11, 1, -7)
	r.bg:SetAllPoints()
	r.shade = Fill(r, "BORDER", 0, 0, 0, 1)        -- 封面底：没有封面时衬着默认图标
	r.shade:SetSize(COVER_W, COVER_H)
	r.shade:SetPoint("TOP", 0, -4)
	r.cover = r:CreateTexture(nil, "ARTWORK")
	r.cover:SetPoint("CENTER", r.shade)
	r.name = Text(r, 13)
	r.name:SetPoint("TOPLEFT", r.shade, "BOTTOMLEFT", 2, -8)
	r.name:SetWidth(COVER_W - 4)
	r.name:SetWordWrap(false)
	r.sub = Text(r, 11, 0.55, 0.55, 0.55)
	r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -5)
	r.sub:SetWidth(COVER_W - 4)
	r.sub:SetWordWrap(false)
	r:SetScript("OnEnter", function(s) s.hover = true NesLab.PaintCard(s) end)
	r:SetScript("OnLeave", function(s) s.hover = false NesLab.PaintCard(s) end)
	r:SetScript("OnClick", function(s)
		DB().selected = s.cart.id
		NesLab.RefreshLibrary()
	end)
	r:SetScript("OnDoubleClick", function(s) if s.cart.loadable then NesLab.Launch(s.cart) end end)
	return r
end

function NesLab.PaintCard(r)
	local sel = P.sel == r.cart
	if sel then
		r.edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
		r.edge:SetPoint("TOPLEFT", -2, 2)
		r.edge:SetPoint("BOTTOMRIGHT", 2, -2)
	else
		r.edge:SetColorTexture(0, 0, 0, 1)
		r.edge:SetPoint("TOPLEFT", -1, 1)
		r.edge:SetPoint("BOTTOMRIGHT", 1, -1)
	end
	local v = sel and 0.16 or r.hover and 0.14 or 0.10
	r.bg:SetColorTexture(v, v * 0.96, v * 0.88, 1)
	if sel or r.hover then r.name:SetTextColor(unpack(GOLD)) else r.name:SetTextColor(1, 1, 1) end
end

local function BuildLibrary(win)
	local f = CreateFrame("Frame", nil, win)
	f:SetPoint("TOPLEFT", PAD, -(TITLE_H + PAD))
	f:SetPoint("BOTTOMRIGHT", -PAD, PAD)

	local grid = CreateFrame("Frame", nil, f)
	grid:SetPoint("TOPLEFT")
	grid:SetPoint("TOPRIGHT")
	grid:SetHeight(ROWS * CARD_H + (ROWS - 1) * GAP)
	grid:EnableMouseWheel(true)
	grid:SetScript("OnMouseWheel", function(_, d)
		local maxRow = math.max(0, math.ceil(#P.carts / COLS) - ROWS)
		P.offset = math.max(0, math.min((P.offset or 0) - d, maxRow))
		NesLab.RefreshLibrary()
	end)
	f.cards = {}
	for i = 1, COLS * ROWS do
		local r = Card(grid)
		r:SetPoint("TOPLEFT", ((i - 1) % COLS) * (CARD_W + GAP), -math.floor((i - 1) / COLS) * (CARD_H + GAP))
		f.cards[i] = r
	end

	local d = CreateFrame("Frame", nil, f)
	d:SetPoint("BOTTOMLEFT")
	d:SetPoint("BOTTOMRIGHT")
	d:SetHeight(DOCK_H)
	Panel(d, 0.08, 0.08, 0.09, 1)
	d.name = Text(d, 18, unpack(GOLD))
	d.name:SetPoint("TOPLEFT", 14, -10)
	d.name:SetWidth(320)
	d.name:SetWordWrap(false)
	d.info = Text(d, 12, 0.75, 0.75, 0.75)
	d.info:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -6)
	d.info:SetWidth(320)
	d.info:SetWordWrap(false)
	d.help = Text(d, 11, 0.5, 0.5, 0.5)
	d.help:SetPoint("TOPLEFT", d.info, "BOTTOMLEFT", 0, -5)
	d.help:SetWidth(320)
	d.help:SetWordWrap(false)
	d.start = Button(d, 120, 34, "开始游戏", function() if P.sel then NesLab.Launch(P.sel) end end, true)
	d.start:SetPoint("RIGHT", -14, 0)
	d.sound = Button(d, 84, 26, "", function()
		DB().muted = not DB().muted
		NesLab.RefreshLibrary()
	end)
	d.sound:SetPoint("RIGHT", d.start, "LEFT", -14, 0)
	d.scale3 = Button(d, 40, 26, "3×", function() DB().scale = 3 NesLab.RefreshLibrary() end)
	d.scale3:SetPoint("RIGHT", d.sound, "LEFT", -10, 0)
	d.scale2 = Button(d, 40, 26, "2×", function() DB().scale = 2 NesLab.RefreshLibrary() end)
	d.scale2:SetPoint("RIGHT", d.scale3, "LEFT", -4, 0)
	d.binds = Button(d, 52, 26, "键位", function() NesLab.ShowBinds() end)
	d.binds:SetPoint("RIGHT", d.scale2, "LEFT", -10, 0)
	d.pager = Text(d, 11, 0.5, 0.5, 0.5)
	d.pager:SetPoint("TOPRIGHT", -14, -8)
	d.pager:SetJustifyH("RIGHT")
	f.dock = d

	f.empty = Text(f, 13, 0.6, 0.6, 0.6)
	f.empty:SetPoint("CENTER", grid)
	f.empty:SetJustifyH("CENTER")
	f.empty:SetSpacing(6)
	f.emptyText = ("还没有卡带\n\n添加游戏：python NesLab\\tools\\nes2cart.py 游戏.nes <id> \"名字\"\n转换完重启游戏")
	f.grid = grid
	return f
end

local function BuildLoading(win)
	local f = CreateFrame("Frame", nil, win)
	f:SetPoint("TOPLEFT", PAD, -(TITLE_H + PAD))
	f:SetPoint("BOTTOMRIGHT", -PAD, PAD)
	f.name = Text(f, 22, unpack(GOLD))
	f.name:SetPoint("CENTER", 0, 40)
	f.name:SetJustifyH("CENTER")
	f.cover = f:CreateTexture(nil, "ARTWORK")
	f.cover:SetSize(COVER_W, COVER_H)
	f.cover:SetPoint("BOTTOM", f.name, "TOP", 0, 16)
	local bar = CreateFrame("Frame", nil, f)
	bar:SetSize(320, 10)
	bar:SetPoint("CENTER", 0, 0)
	Panel(bar, 0.12, 0.12, 0.13, 1)
	bar.fill = Fill(bar, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 1)
	bar.fill:SetPoint("TOPLEFT")
	bar.fill:SetPoint("BOTTOMLEFT")
	f.bar = bar
	f.step = Text(f, 12, 0.7, 0.7, 0.7)
	f.step:SetPoint("TOP", bar, "BOTTOM", 0, -12)
	f.step:SetJustifyH("CENTER")
	f.back = Button(f, 120, 28, "返回游戏库", function() NesLab.ShowLibrary() end)
	f.back:SetPoint("TOP", f.step, "BOTTOM", 0, -20)
	local ad = Text(f, 11, 0.5, 0.5, 0.5)
	ad:SetPoint("BOTTOM", 0, 6)
	ad:SetJustifyH("CENTER")
	ad:SetText(WORKSHOP_AD .. " · " .. WORKSHOP_URL:gsub("^https://", ""))
	return f
end

local function BuildGame(win)
	local f = CreateFrame("Frame", nil, win)
	f:SetAllPoints()
	f.holder = CreateFrame("Frame", nil, f)
	f.holder:SetPoint("TOP", 0, -TITLE_H)
	local bar = CreateFrame("Frame", nil, f)
	bar:SetPoint("BOTTOMLEFT", PAD, 6)
	bar:SetPoint("BOTTOMRIGHT", -PAD, 6)
	bar:SetHeight(24)
	f.lib = Button(bar, 76, 24, "游戏库", function() NesLab.ShowLibrary() end)
	f.lib:SetPoint("LEFT")
	f.pause = Button(bar, 60, 24, "暂停", function() NesLab.SetPaused(not P.paused) end)
	f.pause:SetPoint("LEFT", f.lib, "RIGHT", 6, 0)
	f.reset = Button(bar, 60, 24, "重置", function() NesLab.Reset() end)
	f.reset:SetPoint("LEFT", f.pause, "RIGHT", 6, 0)
	f.mute = Button(bar, 60, 24, "", function() NesLab.ToggleMute() end)
	f.mute:SetPoint("LEFT", f.reset, "RIGHT", 6, 0)
	f.save = Button(bar, 52, 24, "存档", function() NesLab.SaveState() end)
	f.save:SetPoint("LEFT", f.mute, "RIGHT", 12, 0)
	f.load = Button(bar, 52, 24, "读档", function() NesLab.LoadState() end)
	f.load:SetPoint("LEFT", f.save, "RIGHT", 6, 0)
	f.toast = CreateFrame("Frame", nil, f.holder)       -- 画面上方的短提示（存档、读档）
	f.toast:SetFrameLevel(f.holder:GetFrameLevel() + 310)
	f.toast:SetPoint("TOP", 0, -8)
	f.toast:SetSize(220, 26)
	Fill(f.toast, "BACKGROUND", 0, 0, 0, 0.75):SetAllPoints()
	f.toast.text = Text(f.toast, 13, unpack(GOLD))
	f.toast.text:SetPoint("CENTER")
	f.toast:Hide()
	f.stats = Text(bar, 11, 0.55, 0.55, 0.55)
	f.stats:SetPoint("RIGHT")
	f.stats:SetJustifyH("RIGHT")

	local o = CreateFrame("Frame", nil, f.holder)
	o:SetAllPoints()
	o:SetFrameLevel(f.holder:GetFrameLevel() + 300)
	o:EnableMouse(true)
	Fill(o, "BACKGROUND", 0, 0, 0, 0.72):SetAllPoints()
	o.title = Text(o, 22, unpack(GOLD))
	o.title:SetPoint("CENTER", 0, 60)
	o.title:SetJustifyH("CENTER")
	o.title:SetText("已暂停")
	o.help = Text(o, 12, 0.8, 0.8, 0.8)
	o.help:SetPoint("TOP", o.title, "BOTTOM", 0, -12)
	o.help:SetJustifyH("CENTER")
	o.help:SetSpacing(4)
	o.help:SetWidth(460)
	local go = Button(o, 100, 28, "继续", function() NesLab.SetPaused(false) end, true)
	go:SetPoint("TOP", o.help, "BOTTOM", -110, -18)
	local rs = Button(o, 100, 28, "重置", function() NesLab.Reset() NesLab.SetPaused(false) end)
	rs:SetPoint("LEFT", go, "RIGHT", 10, 0)
	local lb = Button(o, 100, 28, "游戏库", function() NesLab.ShowLibrary() end)
	lb:SetPoint("LEFT", rs, "RIGHT", 10, 0)
	o:Hide()
	f.overlay = o
	f.screens = {}
	return f
end

local function Build()
	if P.win then return end
	local old = _G.NesLabPlayer                        -- 热加载前的旧窗口：藏起来，也别再接手柄
	if old then
		old:Hide()
		if not InCombatLockdown() then
			old:EnableGamePadButton(false)
			old:EnableGamePadStick(false)
		end
	end
	local w = CreateFrame("Frame", "NesLabPlayer", UIParent)
	w:SetFrameStrata("DIALOG")
	w:SetToplevel(true)
	w:SetMovable(true)
	w:EnableMouse(true)
	w:SetClampedToScreen(true)
	Panel(w, 0.06, 0.06, 0.07, 0.97)
	local bar = CreateFrame("Frame", nil, w)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(TITLE_H)
	Fill(bar, "ARTWORK", 0.11, 0.11, 0.12, 1):SetAllPoints()
	local line = Fill(bar, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 0.6, 1)
	line:SetPoint("BOTTOMLEFT")
	line:SetPoint("BOTTOMRIGHT")
	line:SetHeight(1)
	bar:EnableMouse(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", function() w:StartMoving() end)
	bar:SetScript("OnDragStop", function() w:StopMovingOrSizing() end)
	P.title = Text(bar, 14, unpack(GOLD))
	P.title:SetPoint("LEFT", 10, 0)
	local close = Button(bar, 22, 20, "×", function() NesLab.Close() end)
	close:SetPoint("RIGHT", -4, 0)
	local search = CreateFrame("EditBox", nil, bar)       -- 游戏库搜索：按名字筛
	search:SetSize(180, 20)
	search:SetPoint("RIGHT", close, "LEFT", -10, 0)
	search:SetAutoFocus(false)
	search:SetFont(FONT, 12, "")
	search:SetTextInsets(8, 8, 0, 0)
	Panel(search, 0.05, 0.05, 0.06, 1)
	search.hint = Text(search, 12, 0.45, 0.45, 0.45)
	search.hint:SetPoint("LEFT", 8, 0)
	search.hint:SetText("搜索游戏")
	search:SetScript("OnTextChanged", function(s)
		local t = strtrim(s:GetText() or "")
		s.hint:SetShown(t == "")
		P.filter = t ~= "" and t:lower() or nil
		P.offset = 0
		if P.page == "library" then NesLab.RefreshLibrary() end
	end)
	search:SetScript("OnEscapePressed", function(s) s:SetText("") s:ClearFocus() end)
	search:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
	P.search = search

	-- 标题栏里的无限工坊：悬停看介绍，点击弹出网址（魔兽里开不了网页，只能复制）
	local ad = CreateFrame("Button", nil, bar)
	ad:SetHeight(20)
	ad:SetPoint("RIGHT", search, "LEFT", -16, 0)
	ad.text = Text(ad, 11, 0.55, 0.55, 0.55)
	ad.text:SetPoint("RIGHT")
	ad.text:SetText(WORKSHOP_AD)
	ad:SetWidth(ad.text:GetStringWidth() + 4)
	ad:SetScript("OnEnter", function(s)
		s.text:SetTextColor(unpack(GOLD))
		GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
		GameTooltip:AddLine("无限工坊", unpack(GOLD))
		for _, l in ipairs(WORKSHOP_TIP) do GameTooltip:AddLine(l, 1, 1, 1) end
		GameTooltip:AddLine("点击复制网址：" .. WORKSHOP_URL, 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	ad:SetScript("OnLeave", function(s)
		s.text:SetTextColor(0.55, 0.55, 0.55)
		GameTooltip:Hide()
	end)
	ad:SetScript("OnClick", function() NesLab.ShowCopy(WORKSHOP_URL) end)
	P.ad = ad

	local copy = CreateFrame("Frame", nil, w)            -- 复制网址的小框
	copy:SetSize(320, 64)
	copy:SetPoint("TOP", 0, -(TITLE_H + 8))
	copy:SetFrameLevel(w:GetFrameLevel() + 50)
	Panel(copy, 0.10, 0.10, 0.11, 1)
	copy.edit = CreateFrame("EditBox", nil, copy)
	copy.edit:SetSize(296, 22)
	copy.edit:SetPoint("TOP", 0, -10)
	copy.edit:SetFont(FONT, 12, "")
	copy.edit:SetTextInsets(6, 6, 0, 0)
	copy.edit:SetAutoFocus(false)
	Panel(copy.edit, 0.05, 0.05, 0.06, 1)
	copy.edit:SetScript("OnEscapePressed", function() copy:Hide() end)
	copy.edit:SetScript("OnEnterPressed", function() copy:Hide() end)
	copy.edit:SetScript("OnTextChanged", function(s, user) if user then s:SetText(copy.url) s:HighlightText() end end)
	copy.edit:SetScript("OnEditFocusLost", function() copy:Hide() end)
	local hint = Text(copy, 11, 0.6, 0.6, 0.6)
	hint:SetPoint("BOTTOM", 0, 9)
	hint:SetJustifyH("CENTER")
	hint:SetText("Ctrl+C 复制，Esc 关闭")
	copy:Hide()
	P.copy = copy
	w:SetPoint("CENTER")
	w:Hide()
	P.win = w
	P.pages = { library = BuildLibrary(w), loading = BuildLoading(w), game = BuildGame(w), binds = NesLab.BuildBinds(w) }
	if not tContains(UISpecialFrames, "NesLabPlayer") then tinsert(UISpecialFrames, "NesLabPlayer") end             -- 游戏库 / 键位页按 Esc 关窗口（游戏页的 Esc 自己接管当菜单）
	w:SetScript("OnHide", function(self)
		if P.win ~= self or self:IsShown() then return end   -- 只是界面整体藏起来（Alt+Z）：不停游戏
		NesLab.StopGame()
		NesLab.CapturePad(false)
	end)
	w:SetScript("OnKeyDown", function(self, k) NesLab.OnKey(self, k, true) end)
	w:SetScript("OnKeyUp", function(self, k) NesLab.OnKey(self, k, false) end)
	w:SetScript("OnGamePadButtonDown", function(_, b) NesLab.OnPad(b, true) end)
	w:SetScript("OnUpdate", function() NesLab.SyncHeld() end)   -- 每帧核对按住的键（松开没收到的补上）
	w:SetScript("OnGamePadButtonUp", function(_, b) NesLab.OnPad(b, false) end)
	w:SetScript("OnGamePadStick", function(_, stick, x, y) NesLab.OnPadStick(stick, x, y) end)
end

------------------------------------------------------------------------------------------------------------------------
NesLab.ui.SetSize, NesLab.ui.ShowPage = SetSize, ShowPage

-- 游戏库

-- 封面：卡带里的 cover.tga 是 256×256，上面 240 行是标题画面。没有封面用默认图标
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_EngGizmos_20"
local function SetCover(tex, cart)
	if cart.cover then
		tex:SetTexture(cart.cover)
		tex:SetTexCoord(0, 1, 0, 240 / 256)
	else
		tex:SetTexture(DEFAULT_ICON)
		tex:SetTexCoord(0, 1, 0, 1)
	end
end

function NesLab.RefreshLibrary()
	local f = P.pages.library
	local db = DB()
	P.allCarts = P.allCarts or NesLab.ScanCarts()      -- 插件列表只在打开游戏库时扫一遍，翻页 / 搜索用缓存
	P.carts = P.allCarts
	if P.filter then
		local hit = {}
		for _, c in ipairs(P.allCarts) do
			if c.name:lower():find(P.filter, 1, true) then hit[#hit + 1] = c end
		end
		P.carts = hit
	end
	P.sel = nil
	for _, c in ipairs(P.carts) do
		if c.id == db.selected then P.sel = c end
	end
	P.sel = P.sel or P.carts[1]
	local rows = math.ceil(#P.carts / COLS)
	P.offset = math.max(0, math.min(P.offset or 0, rows - ROWS))
	local first = P.offset * COLS
	for i, r in ipairs(f.cards) do
		local c = P.carts[first + i]
		r.cart = c
		if c then
			r.name:SetText(c.name)
			local played = db.carts[c.id]
			r.sub:SetText(c.kind .. (played and ("  ·  玩过 " .. played.plays .. " 次") or ""))
			SetCover(r.cover, c)
			if c.cover then r.cover:SetSize(COVER_W, COVER_H) else r.cover:SetSize(48, 48) end
			r.cover:SetDesaturated(not c.loadable)
			NesLab.PaintCard(r)
			r:Show()
		else
			r:Hide()
		end
	end
	f.empty:SetShown(#P.carts == 0)
	f.empty:SetText(P.filter and "没有名字里带「" .. P.filter .. "」的游戏" or f.emptyText)
	local d = f.dock
	d.pager:SetText(rows > ROWS and string.format("第 %d-%d 行 / 共 %d 行 · 滚轮翻页", P.offset + 1, P.offset + ROWS, rows) or "")
	if P.sel then
		local c, played = P.sel, db.carts[P.sel.id]
		d.name:SetText(c.name)
		local parts = { c.kind, c.size .. " KB" }
		if c.battery then parts[#parts + 1] = db.saves and db.saves[c.id] and "有存档" or "可存档" end
		if played then parts[#parts + 1] = "玩过 " .. played.plays .. " 次 · 上次 " .. date("%m-%d %H:%M", played.last) end
		d.info:SetText(table.concat(parts, " · "))
		d.help:SetText(c.loadable and HELP_SHORT
			or "|cffff6655这张卡带加载不了（" .. tostring(c.reason) .. "），在插件列表里启用后重启游戏|r")
		d.start:SetEnabled(c.loadable)
	else
		d.name:SetText("")
		d.info:SetText("")
		d.help:SetText("")
		d.start:SetEnabled(false)
	end
	d.scale2:SetSelected(db.scale == 2)
	d.scale3:SetSelected(db.scale == 3)
	d.sound:SetLabel(db.muted and "声音：关" or "声音：开")
end

function NesLab.ShowLibrary()
	Build()
	NesLab.StopGame()
	SetSize(LIB_W, LIB_H)
	P.allCarts = nil
	P.title:SetText("NesLab · 游戏库")
	ShowPage("library")
	NesLab.RefreshLibrary()
	P.win:Show()
	NesLab.CapturePad(true)
	if not InCombatLockdown() then P.win:EnableKeyboard(true) end
end

function NesLab.Close()
	if not P.win then return end
	NesLab.StopGame()
	NesLab.CapturePad(false)
	P.win:Hide()
end

------------------------------------------------------------------------------------------------------------------------
-- 加载与运行

-- 画面按放大倍数各留一套，换游戏时换贴图（贴图块都复用，不会每玩一个游戏多一套）
local function Screen(rom, scale)
	local g = P.pages.game
	local scr = g.screens[scale]
	if not scr then
		scr = NesLab.NewScreen(g.holder, rom, scale)
		g.screens[scale] = scr
	elseif scr.rom ~= rom then
		scr.SetRom(rom)
	else
		scr.Invalidate()                                -- 同一张卡带重开：新机器，画面缓存作废
	end
	for k, s in pairs(g.screens) do s.frame:SetShown(k == scale) end
	scr.frame:ClearAllPoints()
	scr.frame:SetPoint("TOPLEFT")
	g.holder:SetSize(256 * scale, 240 * scale)
	return scr
end

-- 分几步加载，每步之间让出一帧，进度条走得动
function NesLab.Launch(cart)
	Build()
	if InCombatLockdown() then return print("|cff66ccffNesLab|r 战斗中不能开游戏") end
	NesLab.StopGame()
	local db = DB()
	local scale = db.scale
	local f = P.pages.loading
	SetSize(math.max(GAME_MIN_W, 256 * scale + PAD * 2), math.max(GAME_MIN_H, 240 * scale + TITLE_H + BAR_H + 4))
	P.title:SetText("NesLab · " .. cart.name)
	ShowPage("loading")
	P.win:Show()
	f.name:SetText(cart.name)
	SetCover(f.cover, cart)
	f.cover:SetShown(cart.cover ~= nil)
	f.back:Hide()
	local token = {}
	P.loading = token
	local rom, m, scr
	local steps = {
		{ "读取卡带", function()
			rom = NesLab.roms[cart.id]
			if not rom then
				local ok, reason = C_AddOns.LoadAddOn(cart.addon)
				rom = NesLab.roms[cart.id]
				if not rom then return "读不到卡带（" .. tostring(reason or (ok and "数据缺失" or "加载失败")) .. "）" end
			end
		end },
		{ "准备 CPU", function() m = NesLab.NewMachine(rom) end },
		{ "准备画面", function() scr = Screen(rom, scale) end },
		{ "开机", function()
			m.Frame()
			scr.Render(m.ppu)
		end },
	}
	local i = 0
	local function Next()
		if P.loading ~= token then return end
		i = i + 1
		local s = steps[i]
		if not s then
			P.loading = nil
			return NesLab.StartGame(cart, rom, m, scr, scale)
		end
		f.step:SetText(s[1] .. "……")
		f.bar.fill:SetWidth(math.max(1, 320 * (i - 1) / #steps))
		local ok, err = pcall(s[2])
		if not ok or err then
			P.loading = nil
			f.step:SetText("|cffff6655" .. tostring(err) .. "|r")
			f.back:Show()
			return
		end
		C_Timer.After(0.08, Next)
	end
	Next()
end

function NesLab.StartGame(cart, rom, m, scr, scale)
	local db = DB()
	local g = P.pages.game
	local rec = db.carts[cart.id] or { plays = 0 }
	rec.plays, rec.last = rec.plays + 1, time()
	db.carts[cart.id], db.selected = rec, cart.id
	SetSize(256 * scale + PAD * 2, 240 * scale + TITLE_H + BAR_H + 4)
	ShowPage("game")
	P.cart, P.rom, P.m, P.scr = cart, rom, m, scr
	P.turbo, P.turbo2 = 0, 0
	if rom.battery then                            -- 带电池的卡带：读回上次的存档
		db.saves = db.saves or {}
		m.LoadSave(db.saves[rom.id])
	end
	local snd = NesLab.NewSound()
	snd.enabled = not db.muted
	m.sound, m.apu.onEvent, m.apu.onDmc = snd, snd.Event, snd.Dmc
	snd.cartId, snd.dmcDir, snd.PrgOffset = rom.id, "Interface\\AddOns\\" .. cart.addon .. "\\dmc\\", m.apu.PrgOffset
	P.snd = snd
	g.mute:SetLabel(db.muted and "声音：关" or "声音：开")
	NesLab.SetPaused(InCombatLockdown())            -- 加载途中进了战斗：先暂停（这时键盘、手柄都没接管）
	local acc, frames, cpuMs, drawMs, shown, last = 0, 0, 0, 0, 0, GetTime()
	g:SetScript("OnUpdate", function(_, elapsed)
		if P.paused then return end
		if ((P.m.pad.held or 0) ~= 0 or (P.m.pad2.held or 0) ~= 0) and GetCurrentKeyBoardFocus() then   -- 输入框抢了键盘：全放开
			NesLab.ReleaseAll()
		end
		acc = math.min(acc + elapsed, 0.1)
		local ran = 0
		while acc >= FRAME and ran < 3 do         -- 跟不上就少画几帧，模拟照常跑
			local t = debugprofilestop()
			if P.turbo ~= 0 or P.turbo2 ~= 0 then
				P.turboTick = (P.turboTick or 0) + 1
				local on = P.turboTick % 4 < 2
				local p1, p2 = P.m.pad, P.m.pad2
				p1.buttons = on and bor(p1.held or 0, P.turbo) or (p1.held or 0)
				p2.buttons = on and bor(p2.held or 0, P.turbo2) or (p2.held or 0)
			end
			P.m.Frame()
			cpuMs = cpuMs + debugprofilestop() - t
			acc, ran, frames = acc - FRAME, ran + 1, frames + 1
		end
		if ran > 0 then
			local t = debugprofilestop()
			P.scr.Render(P.m.ppu)
			drawMs = drawMs + debugprofilestop() - t
			shown = shown + 1
		end
		if GetTime() - last >= 1 then
			NesLab.SaveBattery()
			g.stats:SetFormattedText("%d 帧 · %.1f ms", shown, (frames > 0 and cpuMs / frames or 0)
				+ (shown > 0 and drawMs / shown or 0))
			NesLab.perf = { frames = frames, shown = shown, cpuMs = frames > 0 and cpuMs / frames or 0,
				drawMs = shown > 0 and drawMs / shown or 0 }
			frames, shown, cpuMs, drawMs, last = 0, 0, 0, 0, GetTime()
		end
	end)
	NesLab.machine = m
	if not InCombatLockdown() then P.win:EnableKeyboard(true) end
end

-- 存档内存有变化就存（每秒查一次；退出、重置前也存）
function NesLab.SaveBattery()
	local m = P.m
	if not (m and m.rom.battery and m.wramDirty) then return end
	m.wramDirty = false
	local db = DB()
	db.saves = db.saves or {}
	db.saves[m.rom.id] = m.SaveData()
end

function NesLab.StopGame()
	P.loading = nil
	if not P.win then return end
	NesLab.SaveBattery()
	local g = P.pages.game
	g:SetScript("OnUpdate", nil)
	g.overlay:Hide()
	if P.snd then P.snd.StopAll() end
	P.m, P.snd, P.paused = nil, nil, false
	NesLab.machine = nil
	if not InCombatLockdown() then P.win:EnableKeyboard(false) end
end

function NesLab.SetPaused(v)
	if not P.m then return end
	P.paused = v
	local g = P.pages.game
	g.overlay:SetShown(v)
	if v then g.overlay.help:SetText(NesLab.HelpLong()) end
	g.pause:SetLabel(v and "继续" or "暂停")
	if v and P.snd then P.snd.StopAll() end
	NesLab.ReleaseAll()
end

function NesLab.Reset()
	if not P.rom then return end
	NesLab.SaveBattery()
	local m = NesLab.NewMachine(P.rom)
	if P.rom.battery then m.LoadSave(DB().saves and DB().saves[P.rom.id]) end
	m.sound, m.apu.onEvent, m.apu.onDmc = P.snd, P.snd and P.snd.Event, P.snd and P.snd.Dmc
	if P.snd then P.snd.PrgOffset = m.apu.PrgOffset end
	if P.snd then P.snd.StopAll() end
	if P.scr then P.scr.Invalidate() end           -- 新机器：画面缓存作废
	P.m, NesLab.machine = m, m
end

local toastToken = 0
local function Toast(msg)
	local t = P.pages.game.toast
	t.text:SetText(msg)
	t:SetWidth(t.text:GetStringWidth() + 32)
	t:Show()
	toastToken = toastToken + 1
	local mine = toastToken
	C_Timer.After(1.6, function() if toastToken == mine then t:Hide() end end)
end

-- 即时存档：每张卡带一格，存在 NesLabDB.states[卡带 id]
function NesLab.SaveState()
	if not P.m then return end
	local db = DB()
	db.states = db.states or {}
	db.states[P.rom.id] = { time = time(), data = P.m.SaveState() }
	Toast("已存档 " .. date("%H:%M:%S"))
end

function NesLab.LoadState()
	if not P.m then return end
	local db = DB()
	local st = db.states and db.states[P.rom.id]
	if not st then return Toast("这张卡带还没有即时存档") end
	if not P.m.LoadState(st.data) then return Toast("存档格式不对，读不了") end
	if P.snd then P.snd.StopAll() end
	NesLab.ReleaseAll()
	if P.paused then NesLab.SetPaused(false) end
	Toast("已读档（" .. date("%m-%d %H:%M", st.time) .. " 存的）")
end

-- 连发：按住期间由主循环每 4 帧按一下；pl = 1 / 2
function NesLab.Turbo(nes, on, pl)
	local m, f = BUTTON[nes], pl == 2 and "turbo2" or "turbo"
	P[f] = on and bor(P[f] or 0, m) or band(P[f] or 0, 255 - m)
end

-- 两个手柄全部放开（暂停、读档、输入框抢键盘时）
function NesLab.ReleaseAll()
	if P.m then
		local p1, p2 = P.m.pad, P.m.pad2
		p1.buttons, p1.held, p2.buttons, p2.held = 0, 0, 0, 0
	end
	P.turbo, P.turbo2, P.stickBits = 0, 0, 0
end

function NesLab.ToggleMute()
	local db = DB()
	db.muted = not db.muted
	if P.snd then
		P.snd.enabled = not db.muted
		if db.muted then P.snd.StopAll() end
	end
	if P.pages then P.pages.game.mute:SetLabel(db.muted and "声音：关" or "声音：开") end
end

-- 按住的键记在 held，machine 读的 buttons = held 再叠上连发（每帧在主循环合成；没开连发时这里直接同步）
local function SetHeld(pad, held)
	pad.held = held
	if P.turbo == 0 and P.turbo2 == 0 then pad.buttons = held end
end
local function Press(nes, down, pl)
	local m, pad = BUTTON[nes], pl == 2 and P.m.pad2 or P.m.pad
	local held = pad.held or 0
	SetHeld(pad, down and bor(held, m) or band(held, 255 - m))
end

-- 游戏页上一个操作（键盘、手柄共用）；pl = 这个键属于 P1 还是 P2；返回是否用掉了这个键
local function GameAction(act, down, pl)
	if act == "TURBO_A" or act == "TURBO_B" then
		local nes = act == "TURBO_A" and "A" or "B"
		if not down or not P.paused then NesLab.Turbo(nes, down, pl) end
		if not down then                                   -- 连发全松开了：按住的键照原样
			local pad = pl == 2 and P.m.pad2 or P.m.pad
			if P.turbo == 0 and P.turbo2 == 0 then pad.buttons = pad.held or 0 end
		end
		return true
	end
	if BUTTON[act] then
		if not down then
			Press(act, false, pl)
		elseif P.paused then
			if act == "A" or act == "START" then NesLab.SetPaused(false) end
		else
			Press(act, true, pl)
		end
		return true
	end
	if not act or not down then return act ~= nil end
	if act == "SAVE" then
		NesLab.SaveState()
	elseif act == "LOAD" then
		NesLab.LoadState()
	elseif act == "PAUSE" then
		NesLab.SetPaused(not P.paused)
	end
	return true
end

-- 键盘：游戏库只拦回车 / Start 键，游戏页只拦用到的键，键位页全拦
-- 各页处理一个键，返回是否用掉了它
local function PageKey(self, k, down)
	if P.page == "binds" then return NesLab.BindsKey(self, k, down) end
	if P.page == "library" then
		local go = down and (k == "ENTER" or NesLab.KeyAction(k) == "START") and P.sel and P.sel.loadable
		if go then NesLab.Launch(P.sel) end
		return go
	end
	if P.page ~= "game" or not P.m then return false end
	if k == "ESCAPE" then
		if down then NesLab.SetPaused(not P.paused) end
		return true
	elseif k == "M" then
		if down then NesLab.ToggleMute() end
		return true
	end
	local act, pl = NesLab.KeyAction(k)
	return GameAction(act, down, pl)
end

-- 键盘：按下时用掉的键记下来，松开时也只拦这些；按下前就按着的键、没用到的键，松开都照常给游戏
-- （否则角色会一直往一个方向走）
local keysDown = {}
function NesLab.OnKey(self, k, down)
	if InCombatLockdown() then return end
	if down then
		local used = PageKey(self, k, true) and true or false
		keysDown[k] = used or nil
		self:SetPropagateKeyboardInput(not used)
	else
		local mine = keysDown[k]
		keysDown[k] = nil
		self:SetPropagateKeyboardInput(not mine)
		if mine then PageKey(self, k, false) end
	end
end

-- 弹出一个选中的网址给玩家复制
function NesLab.ShowCopy(url)
	local c = P.copy
	c.url = url
	c:Show()
	c.edit:SetText(url)
	c.edit:SetFocus()
	c.edit:HighlightText()
end

-- 手柄：窗口开着时接管（不传给角色移动、动作条）；战斗中不改
function NesLab.CapturePad(on)
	if not P.win or InCombatLockdown() then return end
	P.win:EnableGamePadButton(on)
	P.win:EnableGamePadStick(on)
end

local function MoveSelection(dx, dy)
	local list = P.carts or {}
	local at = 1
	for i, c in ipairs(list) do
		if c == P.sel then at = i end
	end
	local to = math.max(1, math.min(#list, at + dx + dy * COLS))
	if not list[to] then return end
	DB().selected = list[to].id
	local row = math.floor((to - 1) / COLS)            -- 选中的卡片翻进可见范围
	if row < (P.offset or 0) then P.offset = row elseif row >= (P.offset or 0) + ROWS then P.offset = row - ROWS + 1 end
	NesLab.RefreshLibrary()
end

local NAV = { UP = { 0, -1 }, DOWN = { 0, 1 }, LEFT = { -1, 0 }, RIGHT = { 1, 0 } }

local padDown = {}
function NesLab.OnPad(b, down)
	if InCombatLockdown() then return end
	padDown[b] = down or nil
	if P.page == "binds" then return NesLab.BindsPad(b, down) end
	local act, pl = NesLab.PadAction(b)
	if P.page == "library" then
		if not down then return end
		if NAV[act] then
			MoveSelection(NAV[act][1], NAV[act][2])
		elseif (act == "A" or act == "START") and P.sel and P.sel.loadable then
			NesLab.Launch(P.sel)
		elseif act == "B" then
			NesLab.Close()
		end
		return
	end
	if P.page ~= "game" or not P.m then return end
	GameAction(act, down, pl)
end

-- 核对按住的键：切出窗口、换游戏、聊天框抢走键盘时，松开那一下可能没送到这个窗口，
-- 模拟器就以为一直按着。每帧问一次游戏「这个键现在真的按着吗」，没按着就补一次松开
function NesLab.SyncHeld()
	if InCombatLockdown() then return end
	for k in pairs(keysDown) do
		if not IsKeyDown(k) then
			keysDown[k] = nil
			PageKey(P.win, k, false)
		end
	end
	if next(padDown) then
		local id = C_GamePad.GetActiveDeviceID()
		local st = id and C_GamePad.GetDeviceMappedState(id)
		for b in pairs(padDown) do
			local i = C_GamePad.ButtonBindingToIndex(b)
			if not (st and i and st.buttons[i + 1]) then NesLab.OnPad(b, false) end
		end
	end
end

-- 左摇杆当十字键（过半才算按下）；只改摇杆自己按下的方向，不碰十字键 / 键盘按住的
local STICK_DIRS = BUTTON.UP + BUTTON.DOWN + BUTTON.LEFT + BUTTON.RIGHT
function NesLab.OnPadStick(stick, x, y)
	if stick ~= "Left" or InCombatLockdown() then return end
	if P.page == "binds" then return NesLab.BindsStick(x, y) end
	local bits = 0
	if x > 0.5 then bits = bits + BUTTON.RIGHT elseif x < -0.5 then bits = bits + BUTTON.LEFT end
	if y > 0.5 then bits = bits + BUTTON.UP elseif y < -0.5 then bits = bits + BUTTON.DOWN end
	local old = P.stickBits or 0
	if bits == old then return end
	P.stickBits = bits
	if P.page == "library" then
		local pressed = band(bits, 255 - old)            -- 新推到的方向挪一格
		if band(pressed, BUTTON.UP) ~= 0 then MoveSelection(0, -1) end
		if band(pressed, BUTTON.DOWN) ~= 0 then MoveSelection(0, 1) end
		if band(pressed, BUTTON.LEFT) ~= 0 then MoveSelection(-1, 0) end
		if band(pressed, BUTTON.RIGHT) ~= 0 then MoveSelection(1, 0) end
		return
	end
	if P.page ~= "game" or not P.m or P.paused then return end
	local pad = NesLab.PadPlayer() == 2 and P.m.pad2 or P.m.pad    -- 左摇杆跟着手柄那套归谁
	SetHeld(pad, bor(band(pad.held or 0, 255 - band(old, STICK_DIRS)), bits))
end

-- 进战斗：暂停、放开键盘（战斗中改按键传递是受保护的）
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event)
	if not P.win then return end
	if event == "PLAYER_REGEN_DISABLED" then
		if P.m then NesLab.SetPaused(true) end
		P.win:SetPropagateKeyboardInput(true)
		P.win:EnableKeyboard(false)
		P.win:EnableGamePadButton(false)
		P.win:EnableGamePadStick(false)
	elseif P.win:IsShown() then
		if P.m or P.page == "library" or P.page == "binds" then P.win:EnableKeyboard(true) end
		NesLab.CapturePad(true)
	end
end)

-- 兼容旧的调用：按卡带 id 直接开
function NesLab.Play(id)
	for _, c in ipairs(NesLab.ScanCarts()) do
		if c.id == id then return NesLab.Launch(c) end
	end
	print("|cff66ccffNesLab|r 没有这张卡带：" .. tostring(id))
end

function NesLab.Stop()
	NesLab.Close()
end

SLASH_NESLAB1 = "/neslab"
SlashCmdList["NESLAB"] = function(msg)
	local cmd, arg = strsplit(" ", strtrim(msg or ""), 2)
	if cmd == "play" and arg then return NesLab.Play(arg) end
	if cmd == "bench" then                         -- 测速在可选的 NesLab_Dev 插件里
		if not NesLab.BenchCpu and not C_AddOns.LoadAddOn("NesLab_Dev") then
			return print("|cff66ccffNesLab|r 测速要装 NesLab_Dev（开发自检，可选）")
		end
		local r = NesLab.BenchCpu(30, true)
		return print(string.format("|cff66ccffNesLab|r CPU：每帧 %.2f ms，%.2f 百万条指令/秒", r.msPerFrame, r.mips))
	end
	if cmd == "minimap" then return NesLab.ToggleMinimapButton() end
	NesLab.Toggle()
end

function NesLab.Toggle()
	if P.win and P.win:IsShown() then return NesLab.Close() end
	NesLab.ShowLibrary()
end
