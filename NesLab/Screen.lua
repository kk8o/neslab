-- 画面：256 × 240 的 NES 屏，按 scale 放大。背景每条横带一张 33 × 31 的图块网格（多一列一行给半格卷动），
-- 每格三张贴图 = 图块里颜色 1 / 2 / 3 的白色蒙版（来自 tools/nes2cart.py 烘的贴图），各自按调色板着色；
-- 颜色 0 透出底下的「通用背景色」。
-- 省着画：
--   · 横带的卷屏格、图案窗口、图块表、背景调色板都没变 → 整条跳过；
--   · 格子按列放在列框里，列循环复用：横向卷屏时旧列整列挪位置、内容不动，只有新露出来的列要画；
--   · 格子记着（图块号, 调色板组）和那组调色板的版本号：图块变了才重新取贴图，只是颜色变了只改颜色。
-- 精灵 64 个，各一个框：在背景前的放在背景层上面，在背景后的放在下面（背景不透明处自然挡住它）。
-- 一套画面可以换卡带（SetRom）：贴图块全部复用，换游戏不再多建一套。
-- 图案在卡带内存里的游戏（CHR RAM）：图块号先经 p.SLOT 换成贴图里的号（按图块内容查，见 Ppu.lua）。
local band, rshift = bit.band, bit.rshift
local BIT = { 1, 2, 4 }

local COLS, ROWS = 33, 31

-- NES 的 64 色（常见的 2C02 调色板）
local PALETTE = {
	0x7C7C7C, 0x0000FC, 0x0000BC, 0x4428BC, 0x940084, 0xA80020, 0xA81000, 0x881400,
	0x503000, 0x007800, 0x006800, 0x005800, 0x004058, 0x000000, 0x000000, 0x000000,
	0xBCBCBC, 0x0078F8, 0x0058F8, 0x6844FC, 0xD800CC, 0xE40058, 0xF83800, 0xE45C10,
	0xAC7C00, 0x00B800, 0x00A800, 0x00A844, 0x008888, 0x000000, 0x000000, 0x000000,
	0xF8F8F8, 0x3CBCFC, 0x6888FC, 0x9878F8, 0xF878F8, 0xF85898, 0xF87858, 0xFCA044,
	0xF8B800, 0xB8F818, 0x58D854, 0x58F898, 0x00E8D8, 0x787878, 0x000000, 0x000000,
	0xFCFCFC, 0xA4E4FC, 0xB8B8F8, 0xD8B8F8, 0xF8B8F8, 0xF8A4C0, 0xF0D0B0, 0xFCE0A8,
	0xF8D878, 0xD8F878, 0xB8F8B8, 0xB8F8D8, 0x00FCFC, 0xF8D8F8, 0x000000, 0x000000,
}
local R, G, B = {}, {}, {}
for i, c in ipairs(PALETTE) do
	R[i - 1], G[i - 1], B[i - 1] = math.floor(c / 65536) / 255, math.floor(c / 256) % 256 / 255, c % 256 / 255
end

function NesLab.NewScreen(parent, rom, scale)
	local S = scale or 2
	local scr = { S = S }
	local allTex = {}                              -- 建过的所有贴图块（换卡带时换贴图）

	-- 当前卡带的贴图：tools/nes2cart.py 烘的图块蒙版（BLP，老卡带 TGA）；NesLab.debugWhite 时用纯白块看格子
	local atlas, USED, U0, V0, du, dv = nil, {}, {}, {}, 0, 0
	local function LoadRom(r)
		atlas = NesLab.debugWhite and "Interface\\Buttons\\WHITE8X8" or r.atlasBlp or r.atlasPath
		local AW, AH = r.atlasW, r.atlasH
		local SLOTS_PER_ROW = r.slotsPerRow or 32     -- 图案多的卡带贴图更宽
		wipe(USED) wipe(U0) wipe(V0)
		for i = 1, #r.used do USED[i - 1] = tonumber(r.used:sub(i, i)) end
		-- 贴图里第 tile 个图块、颜色 k（1-3）那张蒙版的贴图坐标；往格子里收 1/50 像素，放大后不会采到相邻格子的边
		local eu, ev = 0.02 / AW, 0.02 / AH
		du, dv = 8 / AW - 2 * eu, 8 / AH - 2 * ev
		for s = 0, #r.used * 3 - 1 do
			U0[s], V0[s] = (s % SLOTS_PER_ROW) * 8 / AW + eu, math.floor(s / SLOTS_PER_ROW) * 8 / AH + ev
		end
		scr.rom = r
	end
	LoadRom(rom)

	local root = CreateFrame("Frame", nil, parent)
	root:SetSize(256 * S, 240 * S)
	root:SetClipsChildren(true)
	local base = root:GetFrameLevel()
	scr.frame = root
	local bg = root:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)

	local function NewTex(f, sub)
		local t = f:CreateTexture(nil, "ARTWORK", nil, sub)
		t:SetTexture(atlas, "CLAMP", "CLAMP", "NEAREST")
		t:SetSize(8 * S, 8 * S)
		-- 不按屏幕像素对齐：放大倍数不是整数时，每块各自取整会在两列 / 两行之间漏出一条黑缝
		t:SetSnapToPixelGrid(false)
		t:SetTexelSnappingBias(0)
		t:Hide()
		allTex[#allTex + 1] = t
		return t
	end

	-- 横带：一个裁剪框 + 里面整体挪半格的一层，层里 33 个列框，每列 31 格
	local bands = {}
	local function Band(i)
		local b = bands[i]
		if b then return b end
		local clip = CreateFrame("Frame", nil, root)
		clip:SetClipsChildren(true)
		clip:SetFrameLevel(base + 70)
		local layer = CreateFrame("Frame", nil, clip)
		layer:SetSize(COLS * 8 * S, ROWS * 8 * S)
		b = { clip = clip, layer = layer, cols = {}, colX = {}, cells = {}, rows = 0 }
		bands[i] = b
		return b
	end
	local function Col(b, c)
		local col = b.cols[c]
		if not col then
			col = CreateFrame("Frame", nil, b.layer)
			col:SetSize(8 * S, ROWS * 8 * S)
			b.cols[c] = col
		end
		return col
	end
	-- 新建格子每帧限量：每行都切卷屏的游戏一下要上万个贴图块，一次建完会卡住游戏，分几帧建完
	local NEW_CELLS_PER_FRAME = 400
	local newCells = 0
	local function Cell(b, r, c)
		local k = r * COLS + c
		local cell = b.cells[k]
		if not cell then
			if newCells >= NEW_CELLS_PER_FRAME then return nil end
			newCells = newCells + 1
			local col = Col(b, c)
			cell = { NewTex(col, 1), NewTex(col, 2), NewTex(col, 3) }
			for j = 1, 3 do cell[j]:SetPoint("TOPLEFT", 0, -r * 8 * S) end
			b.cells[k] = cell
		end
		return cell
	end

	local function Paint(texs, tile, palBase, PAL, flipH, flipV)
		local used = USED[tile] or 0
		for k = 1, 3 do
			local t = texs[k]
			if band(used, BIT[k]) ~= 0 then
				local s = tile * 3 + k - 1
				local u, v = U0[s], V0[s]
				if flipH and flipV then
					t:SetTexCoord(u + du, u, v + dv, v)
				elseif flipH then
					t:SetTexCoord(u + du, u, v, v + dv)
				elseif flipV then
					t:SetTexCoord(u, u + du, v + dv, v)
				else
					t:SetTexCoord(u, u + du, v, v + dv)
				end
				local ci = band(PAL[palBase + k], 0x3F)
				t:SetVertexColor(R[ci], G[ci], B[ci])
				t:Show()
			else
				t:Hide()
			end
		end
	end
	local function Recolor(texs, tile, palBase, PAL)  -- 图块没变、只是这组调色板变了
		local used = USED[tile] or 0
		for k = 1, 3 do
			if band(used, BIT[k]) ~= 0 then
				local ci = band(PAL[palBase + k], 0x3F)
				texs[k]:SetVertexColor(R[ci], G[ci], B[ci])
			end
		end
	end

	-- bd：PPU 记的横带（卷屏、背景那张图案表的 4 个 1 KB 窗口 m0-m3）；b：这条横带的画面格子
	local SL, chrGen                                -- CHR RAM：图块号 → 贴图号、图块内容的版本号（Render 时取）
	local function DrawBand(p, b, top, h, bd)
		local VRAM, PAL, NTI, pgen, ntGen, bgGen = p.VRAM, p.PAL, p.NTI, p.pgen, p.ntGen, p.bgPalGen
		local sx, sy = bd.sx % 512, bd.sy % 480
		local x0, fx = math.floor(sx / 8), sx % 8
		local y0, fy = math.floor(sy / 8), sy % 8
		if b.top ~= top or b.h ~= h then                -- 位置、大小、半格偏移变了才重新挂点
			b.top, b.h = top, h
			b.clip:ClearAllPoints()
			b.clip:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -top * S)
			b.clip:SetSize(256 * S, h * S)
		end
		if b.fx ~= fx or b.fy ~= fy then
			b.fx, b.fy = fx, fy
			b.layer:ClearAllPoints()
			b.layer:SetPoint("TOPLEFT", b.clip, "TOPLEFT", -fx * S, fy * S)
		end
		if not b.clip:IsShown() then b.clip:Show() end
		-- 卷屏格、图案窗口、行数、图块表和背景调色板都没变：格子全都不用碰
		local m0, m1, m2, m3 = bd.m0, bd.m1, bd.m2, bd.m3
		local span = h + fy
		if b.x0 == x0 and b.y0 == y0 and b.span == span and b.ntGen == ntGen and b.bgGen == bgGen
			and b.m0 == m0 and b.m1 == m1 and b.m2 == m2 and b.m3 == m3 and b.chrGen == chrGen then
			return
		end
		b.x0, b.y0, b.span, b.ntGen, b.bgGen, b.m0, b.m1, b.m2, b.m3 = x0, y0, span, ntGen, bgGen, m0, m1, m2, m3
		b.chrGen = chrGen
		local M = b.M or {}                             -- 图块号 / 64 → 贴图里的起始号
		b.M = M
		M[0], M[1], M[2], M[3] = m0 * 64, m1 * 64, m2 * 64, m3 * 64
		local rows = math.min(ROWS, math.ceil(span / 8))
		-- 不回绕的列号 ux：卷屏从第 63 列到第 0 列（两张图块表交界）时也是只挪一格，列框不会全部重排
		local ux = b.ux
		if ux then
			ux = ux + (x0 - b.lastX0 + 32) % 64 - 32
		else
			ux = x0
		end
		b.ux, b.lastX0 = ux, x0
		local colX = b.colX
		for c = 0, COLS - 1 do
			-- 第 c 个列框显示图块列 tx（循环复用）：横向卷屏时它只是挪位置，格子里的内容还对得上
			local tx = ux + (c - ux) % COLS
			local px = tx - ux
			if colX[c] ~= px then
				colX[c] = px
				local col = Col(b, c)
				col:ClearAllPoints()
				col:SetPoint("TOPLEFT", b.layer, "TOPLEFT", px * 8 * S, 0)
			end
			local wx = tx % 64
			local ntX, lx = wx >= 32 and 1 or 0, wx % 32
			local ax, sxh = math.floor(lx / 4), lx % 4 >= 2 and 2 or 0
			for r = 0, rows - 1 do
				local ty = (y0 + r) % 60
				local ly = ty % 30
				local off = (ntX + (ty >= 30 and 2 or 0)) * 1024
				local t = VRAM[NTI(off + ly * 32 + lx)]
				local tile = M[math.floor(t / 64)] + t % 64
				if SL then tile = SL[tile] end
				local attr = VRAM[NTI(off + 960 + math.floor(ly / 4) * 8 + ax)]
				local pal = rshift(attr, (ly % 4 >= 2 and 4 or 0) + sxh) % 4
				local cell = Cell(b, r, c)
				local key, gen = tile * 4 + pal, pgen[pal]
				if not cell then
					b.pending = true                      -- 这一帧的新建额度用完了：下一帧接着建
				elseif cell.key ~= key or cell.hidden then
					cell.key, cell.gen, cell.hidden = key, gen, nil
					Paint(cell, tile, pal * 4, PAL)
				elseif cell.gen ~= gen then
					cell.gen = gen
					Recolor(cell, tile, pal * 4, PAL)
				end
			end
			for r = rows, b.rows - 1 do                -- 上一帧多用的行藏起来
				local cell = b.cells[r * COLS + c]
				if cell and not cell.hidden then
					cell.hidden = true
					cell[1]:Hide() cell[2]:Hide() cell[3]:Hide()
				end
			end
		end
		b.rows = rows
		if b.pending then b.pending, b.x0 = nil, nil end  -- 没建完的横带下一帧不能跳过
	end

	-- 精灵
	local sprites = {}
	for i = 0, 63 do
		local f = CreateFrame("Frame", nil, root)
		f:SetSize(8 * S, 16 * S)
		f.top = { NewTex(f, 1), NewTex(f, 2), NewTex(f, 3) }
		f.bottom = { NewTex(f, 1), NewTex(f, 2), NewTex(f, 3) }
		for j = 1, 3 do
			f.top[j]:SetPoint("TOPLEFT", 0, 0)
			f.bottom[j]:SetPoint("TOPLEFT", 0, -8 * S)
		end
		f:Hide()
		sprites[i] = f
	end

	local function Phys(chr1k, w, t)                -- 贴图里的图块号
		local n = chr1k[w + math.floor(t / 64)] * 64 + t % 64
		if SL then return SL[n] end
		return n
	end
	-- 精灵按它第一条线所在的横带画：那条横带的图案窗口、精灵大小、精灵开关
	local function DrawSprites(p)
		local OAM, PAL, pgen = p.OAM, p.PAL, p.pgen
		local pb, nb = p.bands, p.nbands
		for i = 0, 63 do
			local f = sprites[i]
			local y, tile, attr, x = OAM[i * 4], OAM[i * 4 + 1], OAM[i * 4 + 2], OAM[i * 4 + 3]
			local bd = pb[1]
			for j = 2, nb do
				if pb[j].line <= y + 1 then bd = pb[j] else break end
			end
			if y >= 239 or band(bd.mask, 0x10) == 0 then
				if f:IsShown() then f:Hide() end
			else
				local chr1k, tall = bd.c, band(bd.spr, 0x20) ~= 0
				local w8 = band(bd.spr, 8) ~= 0 and 4 or 0               -- 8×8 精灵用哪张图案表
				local key = ((y * 256 + x) * 256 + tile) * 256 + attr
				local gen = pgen[4 + band(attr, 3)]
				if f.key ~= key or f.tbl ~= bd.key or f.chrGen ~= chrGen then
					f.key, f.gen, f.tbl, f.chrGen = key, gen, bd.key, chrGen
					local flipH, flipV = band(attr, 0x40) ~= 0, band(attr, 0x80) ~= 0
					local palBase = 16 + band(attr, 3) * 4
					f:ClearAllPoints()
					f:SetPoint("TOPLEFT", root, "TOPLEFT", x * S, -(y + 1) * S)
					f:SetFrameLevel(base + (band(attr, 0x20) ~= 0 and 1 or 80) + (63 - i))
					if tall then
						local w, t0 = band(tile, 1) * 4, band(tile, 0xFE)
						local a, b2 = Phys(chr1k, w, t0), Phys(chr1k, w, t0 + 1)
						if flipV then a, b2 = b2, a end
						f.ta, f.tb = a, b2
						Paint(f.top, a, palBase, PAL, flipH, flipV)
						Paint(f.bottom, b2, palBase, PAL, flipH, flipV)
					else
						f.ta, f.tb = Phys(chr1k, w8, tile), nil
						Paint(f.top, f.ta, palBase, PAL, flipH, flipV)
						for j = 1, 3 do f.bottom[j]:Hide() end
					end
				elseif f.gen ~= gen then                   -- 只是这组精灵调色板变了
					f.gen = gen
					local palBase = 16 + band(attr, 3) * 4
					Recolor(f.top, f.ta, palBase, PAL)
					if f.tb then Recolor(f.bottom, f.tb, palBase, PAL) end
				end
				if not f:IsShown() then f:Show() end
			end
		end
	end

	scr.debug = { bands = bands, sprites = sprites, U0 = U0, V0 = V0 }   -- 调试用

	function scr.Render(p)
		newCells = 0
		SL = p.SLOT
		if SL then
			p.ResolveChr()
			chrGen = p.chrGen
		else
			chrGen = nil
		end
		local c = band(p.PAL[0], 0x3F)
		if c ~= scr.bgColor then
			scr.bgColor = c
			bg:SetColorTexture(R[c], G[c], B[c], 1)
		end
		local n = p.nbands                                -- 背景开关按横带：关着的横带只露底色
		for i = 1, n do
			local bd = p.bands[i]
			if band(bd.mask, 0x08) ~= 0 then
				local nextLine = i < n and p.bands[i + 1].line or 240
				DrawBand(p, Band(i), bd.line, nextLine - bd.line, bd)
			elseif bands[i] then
				bands[i].clip:Hide()
			end
		end
		for i, b in pairs(bands) do                   -- 关着背景的横带没建过框，表是稀疏的
			if i > n then b.clip:Hide() end
		end
		DrawSprites(p)
	end

	-- 换了一台机器（重置、重开同一张卡带）：记着的「上次画的」全部作废，版本号不会和旧机器的撞上
	function scr.Invalidate()
		for _, t in ipairs(allTex) do t:Hide() end
		for _, b in pairs(bands) do
			b.x0, b.rows = nil, 0
			for _, cell in pairs(b.cells) do cell.key, cell.hidden = nil, true end
			b.clip:Hide()
		end
		for i = 0, 63 do
			sprites[i].key = nil
			sprites[i]:Hide()
		end
		scr.bgColor = nil
	end

	-- 换卡带：贴图块全部换成新卡带的贴图，再作废缓存
	function scr.SetRom(r)
		LoadRom(r)
		for _, t in ipairs(allTex) do t:SetTexture(atlas, "CLAMP", "CLAMP", "NEAREST") end
		scr.Invalidate()
	end

	return scr
end
