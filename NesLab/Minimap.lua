-- 小地图按钮：左键开关游戏库，拖动沿小地图边挪位置（角度存 NesLabDB.minimap）。/neslab minimap 显示 / 隐藏。
local ICON = "Interface\\Icons\\INV_Gizmo_GoblingTonkController"   -- 游戏自带的遥控器图标

local btn

local function Place()
	local a = math.rad(NesLabDB.minimap.angle)
	local r = Minimap:GetWidth() / 2 + 10
	btn:ClearAllPoints()
	btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function Drag()
	local mx, my = Minimap:GetCenter()
	local x, y = GetCursorPosition()
	local s = Minimap:GetEffectiveScale()
	NesLabDB.minimap.angle = math.deg(math.atan2(y / s - my, x / s - mx))
	Place()
end

local function Build()
	if btn then return end
	if _G.NesLabMinimapButton then _G.NesLabMinimapButton:Hide() end   -- 热加载前的旧按钮
	btn = CreateFrame("Button", "NesLabMinimapButton", Minimap)
	btn:SetSize(31, 31)
	btn:SetFrameStrata("MEDIUM")
	btn:SetFrameLevel(8)
	btn:RegisterForClicks("LeftButtonUp")
	btn:RegisterForDrag("LeftButton")
	btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local bg = btn:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetSize(20, 20)
	bg:SetPoint("TOPLEFT", 7, -5)
	local icon = btn:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetSize(20, 20)
	icon:SetPoint("TOPLEFT", 6, -6)
	btn.icon = icon
	local border = btn:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	btn:SetScript("OnClick", function() NesLab.Toggle() end)
	btn:SetScript("OnDragStart", function(s) s:SetScript("OnUpdate", Drag) end)
	btn:SetScript("OnDragStop", function(s) s:SetScript("OnUpdate", nil) end)
	btn:SetScript("OnMouseDown", function() icon:SetPoint("TOPLEFT", 7, -7) end)
	btn:SetScript("OnMouseUp", function() icon:SetPoint("TOPLEFT", 6, -6) end)
	btn:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_LEFT")
		GameTooltip:AddDoubleLine("NesLab 游戏机", C_AddOns.GetAddOnMetadata("NesLab", "Version") or "", 0.79, 0.67, 0.44, 0.55, 0.55, 0.55)
		GameTooltip:AddLine("点击：打开 / 关闭游戏库", 1, 1, 1)
		GameTooltip:AddLine("拖动：沿小地图挪位置", 0.7, 0.7, 0.7)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(NesLab.WORKSHOP_AD, 0.55, 0.55, 0.55)
		GameTooltip:AddLine((NesLab.WORKSHOP_URL:gsub("^https://", "")), 0.55, 0.55, 0.55)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function NesLab.UpdateMinimapButton()
	NesLabDB = NesLabDB or {}
	NesLabDB.minimap = NesLabDB.minimap or { angle = 200, hide = false }
	if NesLabDB.minimap.hide then
		if btn then btn:Hide() end
		return
	end
	Build()
	Place()
	btn:Show()
end

function NesLab.ToggleMinimapButton()
	NesLabDB = NesLabDB or {}
	NesLabDB.minimap = NesLabDB.minimap or { angle = 200 }
	NesLabDB.minimap.hide = not NesLabDB.minimap.hide
	NesLab.UpdateMinimapButton()
	print("|cff66ccffNesLab|r 小地图按钮已" .. (NesLabDB.minimap.hide and "隐藏，/neslab minimap 再显示" or "显示"))
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function() NesLab.UpdateMinimapButton() end)
if IsLoggedIn() then NesLab.UpdateMinimapButton() end     -- 热加载
