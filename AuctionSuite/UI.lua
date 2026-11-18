-- AuctionSuite UI: one "AuctionSuite" tab on the auction house window that opens a Blizzard-style
-- window docked to the right of the house, with a page (and a bottom tab) per module. Also the
-- shared widgets modules build with: a sortable scrolling list, a purchase bar and money text.
--
-- Collisions avoided:
--   * Blizzard's auction house tabs are not touched; the AuctionSuite tab is a separate button
--     anchored after the last one, so Blizzard's tab code never sees it (no taint).
--   * AHledger adds a scan button inside the search bar and a posting panel (AHledgerPostingPanel)
--     at the house's top right while selling. The window docks at the house's right edge, and moves
--     right of that panel while it shows.
local _, ns = ...
local AS = ns.AS

local UI = {}
AS.UI = UI

local GetItemQualityColor = (C_Item and C_Item.GetItemQualityColor) or GetItemQualityColor

local FRAME_W, FRAME_H = 700, 540
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_Coin_02"

local window
local pages = {}   -- module name -> page frame
local tabs = {}    -- index -> tab button
local current      -- module name shown
local ahTab        -- the AuctionSuite tab on the auction house

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
function UI.Money(copper)
    if not copper then return "" end
    copper = math.floor(copper + 0.5)
    local neg = copper < 0
    if neg then copper = -copper end
    local text
    if GetMoneyString then
        text = GetMoneyString(copper, true)
    else
        text = ("%dg %ds %dc"):format(copper / 10000, (copper / 100) % 100, copper % 100)
    end
    return neg and ("-" .. text) or text
end

-- Gold, silver, copper without icons and without empty parts ("1g 5s").
function UI.ShortMoney(copper)
    if not copper then return "" end
    copper = math.floor(copper + 0.5)
    local neg = copper < 0
    if neg then copper = -copper end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = "|cffffd700" .. g .. "g|r" end
    if s > 0 then parts[#parts + 1] = "|cffc7c7cf" .. s .. "s|r" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = "|cffeda55f" .. c .. "c|r" end
    return (neg and "-" or "") .. table.concat(parts, " ")
end

function UI.QualityHex(quality)
    if GetItemQualityColor and quality then
        local _, _, _, hex = GetItemQualityColor(quality)
        if hex then return "|c" .. hex end
    end
    return "|cffffffff"
end

function UI.DisplayName(link)
    return type(link) == "string" and link:match("|h%[(.-)%]|h") or nil
end

-- A second tooltip for AuctionSuite's own figures, so nothing is ever added to GameTooltip's item
-- lines (where AHledger draws its price block).
function UI.InfoTooltip()
    if not UI.info then
        UI.info = CreateFrame("GameTooltip", "AuctionSuiteInfoTooltip", UIParent, "GameTooltipTemplate")
    end
    return UI.info
end

------------------------------------------------------------------------
-- Sortable scrolling list
------------------------------------------------------------------------
-- UI.CreateList(parent, opts) returns a frame with :SetItems(items), :Refresh(), :SetSelected(item).
-- opts.columns = { { key, title, width (0 = fill), justify, sort = true } ... }
-- opts.cell(item, key) -> text;  opts.icon(item) -> texture (shown before the first column)
-- opts.onClick(item, mouseButton);  opts.onEnter(rowFrame, item);  opts.onLeave(rowFrame, item)
-- opts.onSort(key) when a sortable header is clicked;  opts.rowHeight (20)
function UI.CreateList(parent, opts)
    local rowH = opts.rowHeight or 20
    local list = CreateFrame("Frame", nil, parent)
    list.items, list.offset, list.rows = {}, 0, {}

    local header = CreateFrame("Frame", nil, list)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT", -22, 0)
    header:SetHeight(18)
    list.header = header

    local body = CreateFrame("Frame", nil, list)
    body:SetPoint("TOPLEFT", 0, -20)
    body:SetPoint("BOTTOMRIGHT", -22, 0)
    body:EnableMouseWheel(true)
    list.body = body

    -- Column x positions; a width of 0 takes what the fixed columns leave.
    local function Layout()
        local total = body:GetWidth() or 600
        local fixed = rowH + 4
        for _, col in ipairs(opts.columns) do fixed = fixed + (col.width or 0) + 6 end
        local x = rowH + 4
        for _, col in ipairs(opts.columns) do
            col.x = x
            col.w = (col.width and col.width > 0) and col.width or math.max(40, total - fixed)
            x = x + col.w + 6
        end
    end

    list.headers = {}
    for _, col in ipairs(opts.columns) do
        local b = CreateFrame("Button", nil, header)
        b:SetHeight(18)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetAllPoints()
        fs:SetJustifyH(col.justify or "LEFT")
        fs:SetText(col.title or "")
        b.text = fs
        if col.sort and opts.onSort then
            b:SetScript("OnClick", function() opts.onSort(col.key) end)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        end
        list.headers[col.key] = b
    end
    local line = header:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 0, -1)
    line:SetPoint("BOTTOMRIGHT", 0, -1)
    line:SetColorTexture(1, 0.82, 0, 0.25)

    local slider = CreateFrame("Slider", nil, list)
    slider:SetOrientation("VERTICAL")
    slider:SetWidth(16)
    slider:SetPoint("TOPLEFT", body, "TOPRIGHT", 4, 0)
    slider:SetPoint("BOTTOMLEFT", body, "BOTTOMRIGHT", 4, 0)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(0, 0, 0, 0.35)
    slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    local thumb = slider:GetThumbTexture()
    if thumb then thumb:SetSize(18, 24) end
    slider:SetMinMaxValues(0, 0)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:SetValue(0)
    list.slider = slider

    local function Visible()
        return math.max(1, math.floor((body:GetHeight() or rowH) / rowH))
    end

    local function GetRow(i)
        if list.rows[i] then return list.rows[i] end
        local row = CreateFrame("Button", nil, body)
        row:SetHeight(rowH)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * rowH)
        row:SetPoint("RIGHT", body, "RIGHT")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local sel = row:CreateTexture(nil, "BACKGROUND")
        sel:SetAllPoints()
        sel:SetColorTexture(1, 0.82, 0, 0.15)
        sel:Hide()
        row.sel = sel
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(rowH - 2, rowH - 2)
        row.icon:SetPoint("LEFT", 2, 0)
        row.cells = {}
        for _, col in ipairs(opts.columns) do
            local fs = row:CreateFontString(nil, "OVERLAY", col.font or "GameFontHighlightSmall")
            fs:SetJustifyH(col.justify or "LEFT")
            fs:SetWordWrap(false)
            row.cells[col.key] = fs
        end
        row:SetScript("OnClick", function(self, button)
            if self.item and opts.onClick then opts.onClick(self.item, button) end
        end)
        row:SetScript("OnEnter", function(self)
            if self.item and opts.onEnter then opts.onEnter(self, self.item) end
        end)
        row:SetScript("OnLeave", function(self)
            if opts.onLeave then opts.onLeave(self, self.item) end
            GameTooltip:Hide()
            if UI.info then UI.info:Hide() end
        end)
        list.rows[i] = row
        return row
    end

    function list:UpdateRows()
        Layout()
        for _, col in ipairs(opts.columns) do
            local h = self.headers[col.key]
            h:ClearAllPoints()
            h:SetPoint("LEFT", header, "LEFT", col.x, 0)
            h:SetWidth(col.w)
        end
        local n = Visible()
        for i = 1, n do
            local row = GetRow(i)
            local item = self.items[self.offset + i]
            row.item = item
            if item then
                row.icon:SetTexture(opts.icon and opts.icon(item) or nil)
                for _, col in ipairs(opts.columns) do
                    local fs = row.cells[col.key]
                    fs:ClearAllPoints()
                    fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
                    fs:SetWidth(col.w)
                    fs:SetText(opts.cell(item, col.key) or "")
                end
                row.sel:SetShown(item == self.selected)
                row:Show()
            else
                row:Hide()
            end
        end
        for i = n + 1, #self.rows do self.rows[i]:Hide() end
    end

    function list:SetOffset(value)
        local maxOffset = math.max(0, #self.items - Visible())
        self.offset = math.max(0, math.min(maxOffset, math.floor(value + 0.5)))
        slider:SetMinMaxValues(0, maxOffset)
        if slider:GetValue() ~= self.offset then
            slider:SetValue(self.offset)
        else
            self:UpdateRows()
        end
    end

    function list:SetItems(items, keepOffset)
        self.items = items or {}
        self:SetOffset(keepOffset and self.offset or 0)
    end

    function list:Refresh()
        self:SetOffset(self.offset)
    end

    function list:SetSelected(item)
        self.selected = item
        self:UpdateRows()
    end

    slider:SetScript("OnValueChanged", function(_, value)
        list.offset = math.floor(value + 0.5)
        list:UpdateRows()
    end)
    local function Wheel(_, delta) list:SetOffset(list.offset - delta * 3) end
    body:SetScript("OnMouseWheel", Wheel)
    slider:EnableMouseWheel(true)
    slider:SetScript("OnMouseWheel", Wheel)
    body:SetScript("OnSizeChanged", function() if list:IsVisible() then list:Refresh() end end)
    return list
end

------------------------------------------------------------------------
-- Purchase bar: finds the clicked listing on the house, then a Buy button the player clicks
------------------------------------------------------------------------
-- bar:Select(req, opts) with req = { itemID, link, buyout, count, name, icon, quality }
-- opts.describe(found) -> extra text for the found auction (e.g. the profit at that price)
-- opts.onBought(req, found) after a purchase completes
function UI.CreatePurchaseBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(26)

    local icon = bar:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", 2, 0)
    bar.icon = icon

    local buy = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    buy:SetSize(150, 22)
    buy:SetPoint("RIGHT", -2, 0)
    buy:SetText("Buy")
    buy:Disable()
    bar.buy = buy

    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetPoint("RIGHT", buy, "LEFT", -8, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetText("|cff999999Click a row to find that auction on the house; then Buy.|r")
    bar.text = text

    local function NameOf(req)
        local name = UI.DisplayName(req.link) or req.name or ("item:" .. tostring(req.itemID))
        return UI.QualityHex(req.quality) .. name .. "|r"
    end

    function bar:Clear(message)
        self.req, self.found, self.opts = nil, nil, nil
        icon:SetTexture(nil)
        buy:Disable()
        buy:SetText("Buy")
        text:SetText(message or "|cff999999Click a row to find that auction on the house; then Buy.|r")
    end

    -- Rewrites the found auction's line, e.g. after the module's value for it changed.
    function bar:Redescribe()
        local req, info = self.req, self.found
        if not req or not info then return end
        local extra = self.opts and self.opts.describe and self.opts.describe(info) or ""
        local note = info.exact and "" or (info.sameSuffix and "  |cffffd200(cheapest now)|r" or "  |cffffd200(other suffix)|r")
        text:SetText(UI.QualityHex(req.quality) .. (UI.DisplayName(info.link) or UI.DisplayName(req.link) or req.name or "?")
            .. "|r" .. note .. (extra ~= "" and ("  " .. extra) or ""))
    end

    function bar:Select(req, opts)
        self.req, self.found, self.opts = req, nil, opts or {}
        icon:SetTexture(req.icon)
        buy:Disable()
        buy:SetText("Buy")
        if not AS.ahOpen then
            text:SetText(NameOf(req) .. "  |cffff7f7fopen the auction house to buy|r")
            return
        end
        text:SetText(NameOf(req) .. "  |cffffd200finding the auction...|r")
        AS.Data.FindAuction(req, function(state, info, forReq)
            if bar.req ~= forReq then return end
            if state == "waiting" then
                text:SetText(NameOf(req) .. "  |cffffd200" .. tostring(info) .. "|r")
            elseif state == "searching" then
                text:SetText(NameOf(req) .. "  |cffffd200searching...|r")
            elseif state == "found" then
                bar.found = info
                bar:Redescribe()
                buy:SetText("Buy " .. UI.ShortMoney(info.buyout))
                buy:SetEnabled(GetMoney() >= info.buyout)
            elseif state == "notfound" or state == "cancelled" then
                if info ~= "replaced" then
                    text:SetText(NameOf(req) .. "  |cffff7f7f" .. tostring(info) .. "|r")
                end
            end
        end)
    end

    buy:SetScript("OnClick", function()
        local found, req = bar.found, bar.req
        if not found then return end
        if AS.Data.Buy(found) then
            buy:Disable()
            text:SetText((UI.DisplayName(found.link) or "auction") .. "  |cffffd200buying...|r")
            bar.bought = { req = req, found = found, opts = bar.opts }
        end
    end)
    buy:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Buy this auction")
        GameTooltip:AddLine("Buys out the auction shown at the price on the button.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    buy:SetScript("OnLeave", GameTooltip_Hide)

    -- Called by the owning module from its onPurchase.
    function bar:OnPurchase(auctionID)
        local b = self.bought
        if not b or b.found.auctionID ~= auctionID then return end
        self.bought = nil
        if b.opts and b.opts.onBought then AS.SafeCall(b.opts.onBought, b.req, b.found) end
        self:Clear("|cff00ff00Bought|r " .. (UI.DisplayName(b.found.link) or "") .. " for " .. UI.ShortMoney(b.found.buyout))
    end

    return bar
end

------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------
local function SetPortrait(f, texture)
    texture = texture or DEFAULT_ICON
    if f.SetPortraitToAsset and pcall(f.SetPortraitToAsset, f, texture) then return end
    local p = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
        or (f.GetName and f:GetName() and _G[f:GetName() .. "Portrait"])
    if p and p.SetTexture then
        if SetPortraitToTexture then pcall(SetPortraitToTexture, p, texture) else p:SetTexture(texture) end
    end
end

local function SetTitle(f, text)
    if f.SetTitle then f:SetTitle(text)
    elseif f.TitleText then f.TitleText:SetText(text)
    elseif f.TitleContainer and f.TitleContainer.TitleText then f.TitleContainer.TitleText:SetText(text) end
end

local function AuctionHouse()
    return AuctionHouseFrame or AuctionFrame
end

-- Docks the window at the auction house's right edge, or right of AHledger's posting panel while
-- that shows. A window the player dragged stays where they put it.
function UI.Dock()
    if not window then return end
    window:ClearAllPoints()
    local pos = AS.db and AS.db.pos
    if pos then
        window:SetPoint(pos[1] or "CENTER", UIParent, pos[1] or "CENTER", pos[2] or 0, pos[3] or 0)
        return
    end
    local ah = AuctionHouse()
    if ah and ah:IsShown() then
        local posting = _G.AHledgerPostingPanel
        if posting and posting:IsVisible() then
            window:SetPoint("TOPLEFT", posting, "TOPRIGHT", 4, 28)
        else
            window:SetPoint("TOPLEFT", ah, "TOPRIGHT", 2, 0)
        end
        window.dockedTo = posting and posting:IsVisible() and posting or ah
    else
        window:SetPoint("CENTER")
        window.dockedTo = nil
    end
end

local function SelectTabVisual(index)
    if PanelTemplates_SetTab and window.numTabs then
        if pcall(PanelTemplates_SetTab, window, index) then return end
    end
    for i, t in ipairs(tabs) do
        if i == index then t:LockHighlight() else t:UnlockHighlight() end
    end
end

local function EnsurePage(def)
    local page = pages[def.name]
    if page then return page end
    page = CreateFrame("Frame", "AuctionSuitePage_" .. def.name, window)
    page:SetAllPoints(window)
    -- ButtonFrameTemplate's Inset is a child frame drawn over the window's own regions; pages and
    -- everything on them sit above it.
    page:SetFrameLevel((window.Inset and window.Inset:GetFrameLevel() or window:GetFrameLevel()) + 10)
    page:Hide()
    pages[def.name] = page
    return page
end

function UI.ShowPage(name)
    if not window then return end
    local def = AS.modules[name] or AS.moduleList[1]
    if not def then
        SetTitle(window, "AuctionSuite")
        window.empty:Show()
        return
    end
    window.empty:Hide()
    for other, page in pairs(pages) do
        if other ~= def.name and page:IsShown() then
            page:Hide()
            local o = AS.modules[other]
            if o and o.onHide then AS.SafeCall(o.onHide, page) end
        end
    end
    local page = EnsurePage(def)
    if not page.built then
        page.built = true
        AS.SafeCall(def.createPanel, page)
    end
    current = def.name
    AS.db.page = def.name
    SetTitle(window, "AuctionSuite - " .. def.title)
    SetPortrait(window, def.icon)
    page:Show()
    if def.onShow then AS.SafeCall(def.onShow, page) end
    for i, d in ipairs(AS.moduleList) do
        if d == def then SelectTabVisual(i) end
    end
end

local function LayoutTabs()
    if not window then return end
    for i, def in ipairs(AS.moduleList) do
        local tab = tabs[i]
        if not tab then
            local ok
            ok, tab = pcall(CreateFrame, "Button", "AuctionSuiteFrameTab" .. i, window, "PanelTabButtonTemplate")
            if not ok then
                ok, tab = pcall(CreateFrame, "Button", "AuctionSuiteFrameTab" .. i, window, "CharacterFrameTabButtonTemplate")
            end
            if not ok then
                tab = CreateFrame("Button", "AuctionSuiteFrameTab" .. i, window, "UIPanelButtonTemplate")
                tab:SetSize(110, 24)
            end
            tab:SetID(i)
            tabs[i] = tab
        end
        tab:SetText(def.title)
        if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
        tab:ClearAllPoints()
        if i == 1 then
            tab:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 12, 2)
        else
            tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", -15, 0)
        end
        tab:SetScript("OnClick", function()
            if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
            UI.ShowPage(def.name)
        end)
        tab:Show()
    end
    window.Tabs = tabs
    window.numTabs = #AS.moduleList
    if PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs, window, #AS.moduleList) end
end

local function CreateWindow()
    local ok, f = pcall(CreateFrame, "Frame", "AuctionSuiteFrame", UIParent, "ButtonFrameTemplate")
    if not ok then
        f = CreateFrame("Frame", "AuctionSuiteFrame", UIParent, "BasicFrameTemplateWithInset")
    end
    window = f
    f:SetSize(FRAME_W, FRAME_H)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        AS.db.pos = { point, x, y }
    end)
    if ButtonFrameTemplate_HideButtonBar and f.Inset then ButtonFrameTemplate_HideButtonBar(f) end
    tinsert(UISpecialFrames, "AuctionSuiteFrame")
    SetTitle(f, "AuctionSuite")
    SetPortrait(f, DEFAULT_ICON)

    local empty = CreateFrame("Frame", nil, f)
    empty:SetAllPoints()
    empty:SetFrameLevel((f.Inset and f.Inset:GetFrameLevel() or f:GetFrameLevel()) + 10)
    local msg = empty:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    msg:SetPoint("CENTER")
    msg:SetWidth(FRAME_W - 120)
    msg:SetText("No AuctionSuite modules are loaded.\nEnable AuctionSuite_SuffixFinder, AuctionSuite_Disenchant or AuctionSuite_VendorDeals in the AddOns list.")
    f.empty = empty

    -- Keep the dock right of AHledger's posting panel as it comes and goes.
    local elapsed = 0
    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < 0.5 then return end
        elapsed = 0
        if AS.db.pos then return end
        local posting = _G.AHledgerPostingPanel
        local want = (posting and posting:IsVisible()) and posting or AuctionHouse()
        if want ~= self.dockedTo then UI.Dock() end
    end)
    f:SetScript("OnShow", function()
        if ahTab and PanelTemplates_SelectTab then pcall(PanelTemplates_SelectTab, ahTab) end
    end)
    f:SetScript("OnHide", function()
        if ahTab and PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, ahTab) end
        local def = current and AS.modules[current]
        if def and def.onHide and pages[current] then AS.SafeCall(def.onHide, pages[current]) end
    end)
    f:Hide()
    LayoutTabs()
    return f
end

function UI.OnModuleRegistered()
    if window then
        LayoutTabs()
        if window:IsShown() and not current then UI.ShowPage(AS.db.page) end
    end
end

function UI.Show()
    window = window or CreateWindow()
    UI.Dock()
    window:Show()
    UI.ShowPage(current or AS.db.page)
end

function UI.Toggle()
    if window and window:IsShown() then window:Hide() else UI.Show() end
end

function UI.IsShown()
    return window and window:IsShown() or false
end

------------------------------------------------------------------------
-- The auction house tab
------------------------------------------------------------------------
local function LastBlizzardTab()
    local ah = AuctionHouseFrame
    if ah and type(ah.Tabs) == "table" then
        local last
        for _, t in ipairs(ah.Tabs) do
            if t ~= ahTab and t.IsShown and t:IsShown() then last = t end
        end
        if last then return last end
    end
    if AuctionFrame and AuctionFrame.numTabs then
        return _G["AuctionFrameTab" .. AuctionFrame.numTabs]
    end
    return nil
end

local function PlaceAHTab()
    if not ahTab then return end
    local last = LastBlizzardTab()
    ahTab:ClearAllPoints()
    if last then
        ahTab:SetPoint("LEFT", last, "RIGHT", -15, 0)
    else
        ahTab:SetPoint("TOPLEFT", AuctionHouse(), "BOTTOMLEFT", 300, 2)
    end
end

function UI.HookAuctionHouse()
    local ah = AuctionHouse()
    if ahTab or not ah then return end
    local ok, tab = pcall(CreateFrame, "Button", "AuctionSuiteAHTab", ah, "PanelTabButtonTemplate")
    if not ok then
        ok, tab = pcall(CreateFrame, "Button", "AuctionSuiteAHTab", ah, "CharacterFrameTabButtonTemplate")
    end
    if not ok then
        tab = CreateFrame("Button", "AuctionSuiteAHTab", ah, "UIPanelButtonTemplate")
        tab:SetSize(110, 24)
    end
    ahTab = tab
    tab:SetText("AuctionSuite")
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
    if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, tab) end
    tab:SetScript("OnClick", function()
        if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
        AS:LoadModules()
        AS.Data.EnsureSnapshot()
        UI.Toggle()
    end)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("AuctionSuite")
        GameTooltip:AddLine("Suffix Finder, Disenchant and Vendor deals, with prices from AHledger.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", GameTooltip_Hide)
    PlaceAHTab()
end

function UI.OnAuctionHouseShow()
    UI.HookAuctionHouse()
    PlaceAHTab()
    if AS.db.autoOpen then
        local wasShown = UI.IsShown()
        UI.Show()
        window.openedWithHouse = not wasShown
    elseif window and window:IsShown() then
        UI.Dock()
    end
end

function UI.OnAuctionHouseClosed()
    if not window then return end
    if window.openedWithHouse then
        window.openedWithHouse = nil
        window:Hide()
    else
        UI.Dock()
    end
end
