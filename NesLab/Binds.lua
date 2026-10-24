-- 键位：三套——键盘 A、键盘 B、手柄，每套每个操作一个键，每套属于 P1 或 P2（存 NesLabDB.binds，player 记归属）；
-- 默认键盘 A（WASD）= P1、键盘 B（方向键）= P2、手柄 = P1。即时存档 / 读档 / 暂停不分玩家。还有一页「键位」设置与测试：
-- 点格子再按新键（Esc 取消、右键清空），平时按任何键 / 手柄，对应的那一行会亮，左摇杆的位置也画出来。
-- 左摇杆固定当十字键用；M 静音、Esc 菜单固定。Player.lua 里的键盘 / 手柄处理都从这里查。
local P = NesLab.player                           -- 每个对外函数开头会重新取（Player.lua 单独重载时换了新表）

local ACTIONS = {
	{ "UP", "上" }, { "DOWN", "下" }, { "LEFT", "左" }, { "RIGHT", "右" },
	{ "A", "A" }, { "B", "B" }, { "SELECT", "Select" }, { "START", "Start / 确认" },
	{ "TURBO_A", "连发 A" }, { "TURBO_B", "连发 B" },
	{ "SAVE", "即时存档" }, { "LOAD", "读档" }, { "PAUSE", "暂停" },
}
local LABEL = {}
for _, a in ipairs(ACTIONS) do LABEL[a[1]] = a[2] end
local DEVICES = { "kb", "kb2", "pad" }
local DEFAULTS = {
	kb = { UP = "W", DOWN = "S", LEFT = "A", RIGHT = "D", A = "K", B = "J", SELECT = "SPACE", START = "ENTER",
		TURBO_A = "I", TURBO_B = "U", SAVE = "F5", LOAD = "F9", PAUSE = "P" },
	kb2 = { UP = "UP", DOWN = "DOWN", LEFT = "LEFT", RIGHT = "RIGHT", A = ".", B = ",", SELECT = "'", START = "/" },
	-- 手柄按位置：右键 = A、下键 = B（和 NES 手柄一样），上键 / 左键连发
	pad = { UP = "PADDUP", DOWN = "PADDDOWN", LEFT = "PADDLEFT", RIGHT = "PADDRIGHT", A = "PAD2", B = "PAD1",
		SELECT = "PADBACK", START = "PADFORWARD", TURBO_A = "PAD4", TURBO_B = "PAD3",
		SAVE = "PADLTRIGGER", LOAD = "PADRTRIGGER", PAUSE = "PADRSHOULDER" },
}
local DEFAULT_PLAYER = { kb = 1, kb2 = 2, pad = 1 }
local SET_NAME = { kb = "键盘 A", kb2 = "键盘 B", pad = "手柄" }
local FIXED_KEYS = { ESCAPE = true, M = true }    -- 不让绑：菜单、静音

local lookup                                      -- { kb = 键 → 操作, kbp = 键 → 玩家, pad = …, padp = … }

local function Binds()
	NesLabDB = NesLabDB or {}
	local b = NesLabDB.binds
	if type(b) ~= "table" then
		b = {}
		NesLabDB.binds = b
	end
	if b.v ~= 2 then                                  -- 第 2 版：键盘 B 改成 P2 那套（原来是 P1 的备用键）
		b.v, b.kb2, b.player = 2, nil, nil
	end
	for _, dev in ipairs(DEVICES) do
		if type(b[dev]) ~= "table" then b[dev] = {} end
	end
	if type(b.player) ~= "table" then
		b.player = {}
		for k, v in pairs(DEFAULT_PLAYER) do b.player[k] = v end
	end
	-- 存档里没有的操作（旧版本还没有这个操作）补默认键；"" 是玩家清空的，不动。默认键已被别的操作占了就不补
	for _, dev in ipairs(DEVICES) do
		for act, key in pairs(DEFAULTS[dev]) do
			if b[dev][act] == nil then
				local used = false
				for _, d2 in ipairs(dev == "pad" and { "pad" } or { "kb", "kb2" }) do
					for _, k in pairs(b[d2]) do
						if k == key then used = true end
					end
				end
				b[dev][act] = used and "" or key
			end
		end
	end
	return b
end

local function Rebuild()
	local b = Binds()
	lookup = { kb = {}, kbp = {}, pad = {}, padp = {} }
	for _, dev in ipairs(DEVICES) do
		local into, who = dev == "pad" and lookup.pad or lookup.kb, dev == "pad" and lookup.padp or lookup.kbp
		for act, key in pairs(b[dev]) do
			if key ~= "" then
				into[key], who[key] = act, b.player[dev] or 1
			end
		end
	end
end

-- 键 → 操作, 玩家（1 / 2）
function NesLab.KeyAction(key)
	if not lookup then Rebuild() end
	return lookup.kb[key], lookup.kbp[key]
end

function NesLab.PadAction(button)
	if not lookup then Rebuild() end
	return lookup.pad[button], lookup.padp[button]
end

function NesLab.PadPlayer()                       -- 手柄（含左摇杆）属于哪个玩家
	return Binds().player.pad or 1
end

-- 显示名：游戏自己的按键文字（手柄会按手柄型号显示按钮图标）
local function KeyName(key)
	if not key or key == "" then return "—" end
	local t = GetBindingText and GetBindingText(key) or key
	return (t and t ~= "") and t or key
end
NesLab.KeyName = KeyName

-- 暂停菜单里的说明：按当前键位生成
function NesLab.HelpLong()
	local b = Binds()
	local function Line(dev)
		local t = {}
		for _, a in ipairs(ACTIONS) do
			local k = b[dev][a[1]]
			if k and k ~= "" then t[#t + 1] = a[2] .. " " .. KeyName(k) end
		end
		return table.concat(t, " · ")
	end
	local out = {}
	for _, dev in ipairs(DEVICES) do
		local l = Line(dev)
		if l ~= "" then out[#out + 1] = SET_NAME[dev] .. "（P" .. (b.player[dev] or 1) .. "）：" .. l end
	end
	out[#out + 1] = "M 静音 · Esc 菜单 · 键位在游戏库的「键位」里改"
	return table.concat(out, "\n")
end

------------------------------------------------------------------------------------------------------------------------
-- 设置页

local ROW_H = 30

function NesLab.BuildBinds(win)
	P = NesLab.player
	local ui = NesLab.ui
	local Text, Button, Fill, Panel, GOLD = ui.Text, ui.Button, ui.Fill, ui.Panel, ui.GOLD
	local f = CreateFrame("Frame", nil, win)
	f:SetPoint("TOPLEFT", ui.PAD, -(ui.TITLE_H + ui.PAD))
	f:SetPoint("BOTTOMRIGHT", -ui.PAD, ui.PAD)

	local tip = Text(f, 12, 0.7, 0.7, 0.7)
	tip:SetPoint("TOPLEFT", 4, -2)
	tip:SetText("点格子再按新键（Esc 取消，右键清空），点 P1 / P2 换这一套归谁。平时按任何键或手柄，对应的那一行会亮。")

	local x = { 0, 150, 290, 430 }                   -- 操作、键盘 A、键盘 B、手柄 四列
	local t0 = Text(f, 12, unpack(GOLD))
	t0:SetPoint("TOPLEFT", 12, -28)
	t0:SetText("操作")
	f.who = {}
	for j, dev in ipairs(DEVICES) do
		local t = Text(f, 12, unpack(GOLD))
		t:SetPoint("TOPLEFT", x[j + 1] + 12, -28)
		t:SetText(SET_NAME[dev])
		local who = Button(f, 40, 20, "", function()       -- 这一套给 P1 还是 P2
			local b = Binds()
			b.player[dev] = (b.player[dev] or 1) == 1 and 2 or 1
			Rebuild()
			NesLab.RefreshBinds()
		end)
		who:SetPoint("LEFT", t, "RIGHT", 8, 0)
		f.who[dev] = who
	end

	f.rows = {}
	for i, a in ipairs(ACTIONS) do
		local r = CreateFrame("Frame", nil, f)
		r:SetSize(565, ROW_H - 2)
		r:SetPoint("TOPLEFT", 0, -48 - (i - 1) * ROW_H)
		r.bg = Fill(r, "BACKGROUND", 0.10, 0.10, 0.11, 1)
		r.bg:SetAllPoints()
		r.lit = Fill(r, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 1)
		r.lit:SetPoint("TOPLEFT")
		r.lit:SetPoint("BOTTOMLEFT")
		r.lit:SetWidth(4)
		r.lit:Hide()
		r.label = Text(r, 13)
		r.label:SetPoint("LEFT", 12, 0)
		r.label:SetText(a[2])
		r.cells = {}
		for j, dev in ipairs(DEVICES) do
			local c = Button(r, 130, ROW_H - 6, "", function() end)
			c:SetPoint("LEFT", x[j + 1], 0)
			c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			c:SetScript("OnClick", function(_, mouse)
				if mouse == "RightButton" then
					Binds()[dev][a[1]] = ""
					P.capture = nil
					Rebuild()
					NesLab.RefreshBinds()
				else
					P.capture = { dev = dev, action = a[1] }
					NesLab.RefreshBinds()
				end
			end)
			r.cells[dev] = c
		end
		f.rows[a[1]] = r
	end

	-- 右侧：左摇杆和最近一次按键
	local box = CreateFrame("Frame", nil, f)
	box:SetSize(120, 120)
	box:SetPoint("TOPRIGHT", -16, -48)
	Panel(box, 0.08, 0.08, 0.09, 1)
	local cross1 = Fill(box, "ARTWORK", 0.25, 0.25, 0.27, 1)
	cross1:SetSize(1, 120)
	cross1:SetPoint("CENTER")
	local cross2 = Fill(box, "ARTWORK", 0.25, 0.25, 0.27, 1)
	cross2:SetSize(120, 1)
	cross2:SetPoint("CENTER")
	box.dot = Fill(box, "OVERLAY", GOLD[1], GOLD[2], GOLD[3], 1)
	box.dot:SetSize(10, 10)
	box.dot:SetPoint("CENTER")
	local bl = Text(f, 12, 0.7, 0.7, 0.7)
	bl:SetPoint("BOTTOM", box, "TOP", 0, 6)
	bl:SetText("左摇杆")
	f.stick = box
	f.last = Text(f, 12, 0.85, 0.85, 0.85)
	f.last:SetPoint("TOP", box, "BOTTOM", 0, -14)
	f.last:SetWidth(130)
	f.last:SetJustifyH("CENTER")
	f.last:SetSpacing(4)
	f.device = Text(f, 11, 0.55, 0.55, 0.55)
	f.device:SetPoint("TOP", f.last, "BOTTOM", 0, -14)
	f.device:SetWidth(130)
	f.device:SetJustifyH("CENTER")

	local back = Button(f, 120, 30, "返回游戏库", function() NesLab.ShowLibrary() end, true)
	back:SetPoint("BOTTOMRIGHT", 0, 0)
	local reset = Button(f, 100, 30, "恢复默认", function()
		NesLabDB.binds = nil
		P.capture = nil
		Rebuild()
		NesLab.RefreshBinds()
	end)
	reset:SetPoint("RIGHT", back, "LEFT", -10, 0)
	return f
end

function NesLab.RefreshBinds()
	P = NesLab.player
	local f = P.pages and P.pages.binds
	if not f then return end
	local b = Binds()
	for _, dev in ipairs(DEVICES) do
		local p2 = (b.player[dev] or 1) == 2
		f.who[dev]:SetLabel(p2 and "P2" or "P1")
		f.who[dev]:SetSelected(p2)
	end
	for _, a in ipairs(ACTIONS) do
		local r = f.rows[a[1]]
		for _, dev in ipairs(DEVICES) do
			local c = r.cells[dev]
			local cap = P.capture and P.capture.dev == dev and P.capture.action == a[1]
			c:SetLabel(cap and "|cffffd36b按新键……|r" or KeyName(b[dev][a[1]]))
			c:SetSelected(cap)
		end
	end
	local id = C_GamePad and C_GamePad.GetActiveDeviceID and C_GamePad.GetActiveDeviceID()
	local st = id and C_GamePad.GetDeviceMappedState(id)
	f.device:SetText(st and ("手柄：" .. st.name) or "没有检测到手柄\n（游戏设置里打开手柄后再试）")
end

local function Light(action, on)
	local f = P.pages.binds
	P.held = P.held or {}
	if action then P.held[action] = on or nil end
	for act, r in pairs(f.rows) do
		local lit = P.held[act] or (P.stickHeld and P.stickHeld[act])
		r.lit:SetShown(lit and true or false)
		r.bg:SetColorTexture(lit and 0.20 or 0.10, lit and 0.18 or 0.10, lit and 0.13 or 0.11, 1)
	end
end

local function Assign(dev, key)
	local b = Binds()
	local act = P.capture.action
	for other, k in pairs(b[dev]) do                  -- 同一设备上别的操作用了这个键：让给新操作
		if k == key and other ~= act then b[dev][other] = "" end
	end
	if dev ~= "pad" then                              -- 键盘和备用键盘也不能重复
		local twin = dev == "kb" and "kb2" or "kb"
		for other, k in pairs(b[twin]) do
			if k == key then b[twin][other] = "" end
		end
	end
	b[dev][act] = key
	P.capture = nil
	Rebuild()
	NesLab.RefreshBinds()
end

-- 键盘：设置页上按下的键都留在这页（返回 true = 用掉了；松开的拦不拦由 Player 按按下时记的决定）
function NesLab.BindsKey(self, key, down)
	P = NesLab.player
	local f = P.pages.binds
	if down and P.capture and P.capture.dev ~= "pad" then
		if key == "ESCAPE" then
			P.capture = nil
			NesLab.RefreshBinds()
			return true
		end
		if not FIXED_KEYS[key] then Assign(P.capture.dev, key) end
		return true
	end
	if down and key == "ESCAPE" then
		if P.capture then
			P.capture = nil
			NesLab.RefreshBinds()
		else
			NesLab.ShowLibrary()
		end
		return true
	end
	local act, pl = NesLab.KeyAction(key)
	if down then f.last:SetText("键盘 " .. KeyName(key) .. "\n" .. (act and ("→ P" .. pl .. " " .. LABEL[act]) or "（没绑）")) end
	Light(act, down)
	return true
end

function NesLab.BindsPad(button, down)
	P = NesLab.player
	local f = P.pages.binds
	if down and P.capture and P.capture.dev == "pad" then return Assign("pad", button) end
	local act, pl = NesLab.PadAction(button)
	if down then f.last:SetText("手柄 " .. KeyName(button) .. "\n" .. (act and ("→ P" .. pl .. " " .. LABEL[act]) or "（没绑）")) end
	Light(act, down)
end

function NesLab.BindsStick(x, y)
	P = NesLab.player
	local f = P.pages.binds
	f.stick.dot:SetPoint("CENTER", x * 55, y * 55)
	P.stickHeld = { RIGHT = x > 0.5, LEFT = x < -0.5, UP = y > 0.5, DOWN = y < -0.5 }
	Light(nil)
end

function NesLab.ShowBinds()
	P = NesLab.player
	local ui = NesLab.ui
	ui.SetSize(ui.LIB_W, ui.LIB_H)
	P.title:SetText("NesLab · 键位")
	P.capture, P.held, P.stickHeld = nil, {}, nil
	ui.ShowPage("binds")
	NesLab.RefreshBinds()
	P.pages.binds.last:SetText("按任意键或手柄测试")
	P.pages.binds.stick.dot:SetPoint("CENTER")
	Light(nil)
end
