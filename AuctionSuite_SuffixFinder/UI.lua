-- AuctionSuite_SuffixFinder: the Suffix Finder page (filters and results) in the AuctionSuite window.
-- Ported from SuffixFinder 0.1's UI.lua; the window became a page and a purchase bar was added.
local _, ns = ...
local SF = ns.SF
local AS = AuctionSuite

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemSubClassInfo = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
local GetItemQualityColor = (C_Item and C_Item.GetItemQualityColor) or GetItemQualityColor

local ROW_H = 20

local frame
local rows = {}
local offset = 0
local results = {}

------------------------------------------------------------------------
-- Slot and type labels
------------------------------------------------------------------------
local SLOT_OF = {
    INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder", INVTYPE_CLOAK = "Back",
    INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest", INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands",
    INVTYPE_WAIST = "Waist", INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Finger",
    INVTYPE_TRINKET = "Trinket", INVTYPE_2HWEAPON = "Two-Hand", INVTYPE_WEAPON = "One-Hand",
    INVTYPE_WEAPONMAINHAND = "Main Hand", INVTYPE_WEAPONOFFHAND = "Off Hand", INVTYPE_SHIELD = "Shield",
    INVTYPE_HOLDABLE = "Held in Off-hand", INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged",
    INVTYPE_THROWN = "Ranged", INVTYPE_RELIC = "Relic",
}
local SLOT_ORDER = {
    "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet", "Finger", "Trinket",
    "Two-Hand", "One-Hand", "Main Hand", "Off Hand", "Shield", "Held in Off-hand", "Ranged", "Relic",
}

local function SlotOf(item)
    return SLOT_OF[item.equipLoc or ""] or "Other"
end

local function TypeKey(item)
    return (item.classID or 0) * 100 + (item.subClassID or 0)
end

local typeNames = {}
local function TypeName(key)
    if typeNames[key] then return typeNames[key] end
    local classID, subID = math.floor(key / 100), key % 100
    local name = GetItemSubClassInfo and GetItemSubClassInfo(classID, subID)
    if classID == 4 and subID == 0 then name = "Misc (rings, necks, cloaks)" end
    typeNames[key] = name or ("Type " .. key)
    return typeNames[key]
end

local function Money(copper)
    if not copper or copper <= 0 then return "" end
    if GetMoneyString then return GetMoneyString(copper, true) end
    return ("%dg %ds %dc"):format(copper / 10000, (copper / 100) % 100, copper % 100)
end

local function QualityHex(quality)
    if GetItemQualityColor and quality then
        local _, _, _, hex = GetItemQualityColor(quality)
        if hex then return "|c" .. hex end
    end
    return "|cff1eff00"
end

local function BaseName(item)
    local base = GetItemInfo(item.itemID)
    if base then return base end
    local full = SF.DisplayName(item.link) or ""
    return (full:gsub(" " .. item.suffix:gsub("%p", "%%%0") .. "$", ""))
end

------------------------------------------------------------------------
-- Filtering and sorting
------------------------------------------------------------------------
local function AnySet(t)
    return next(t) ~= nil
end

-- Every filter except the one named `skip` (so a menu can count what its own choices would show).
local function Passes(item, f, skip)
    if skip ~= "suffix" and AnySet(f.suffixes) and not f.suffixes[item.suffix] then return false end
    if skip ~= "slot" and AnySet(f.slots) and not f.slots[SlotOf(item)] then return false end
    if skip ~= "type" and AnySet(f.types) and not f.types[TypeKey(item)] then return false end
    if f.usable and not item.usable then return false end
    if f.minLevel and item.level < f.minLevel then return false end
    if f.maxLevel and item.level > f.maxLevel then return false end
    if f.maxPrice and (not item.buyout or item.buyout > f.maxPrice) then return false end
    if f.text ~= "" then
        local name = (SF.DisplayName(item.link) or ""):lower()
        if not name:find(f.text, 1, true) then return false end
    end
    return true
end

local SORTS = {
    price = function(item) return item.buyout or math.huge end,
    level = function(item) return item.level end,
    name = function(item) return SF.DisplayName(item.link) or "" end,
    suffix = function(item) return item.suffix end,
}

local function BuildResults()
    local f = SF.filters
    results = {}
    for _, item in ipairs(SF.items or {}) do
        if Passes(item, f) then results[#results + 1] = item end
    end
    local key, asc = SORTS[f.sortKey] or SORTS.price, f.sortAsc
    table.sort(results, function(a, b)
        local x, y = key(a), key(b)
        if x == y then
            local pa, pb = a.buyout or math.huge, b.buyout or math.huge
            if pa ~= pb then return pa < pb end
            return a.link < b.link
        end
        if asc then return x < y end
        return x > y
    end)
end

------------------------------------------------------------------------
-- Handing a result's name to the player
------------------------------------------------------------------------
-- The Blizzard auction house window is never driven from here (calling its search from addon code
-- taints it, and buying there is then blocked). The base name goes into the page's own box for
-- Ctrl+C, and the purchase bar finds the auction through C_AuctionHouse and buys it on a click.
function SF.ShowItemName(item)
    local box = frame and frame.copyBox
    if not box then return end
    box.name = BaseName(item)
    box:SetText(box.name)
    box:SetFocus()
    box:HighlightText()
    frame.copyHint:SetText(("Ctrl+C, paste in the auction house search, then pick the one %s"):format(item.suffix))
end

------------------------------------------------------------------------
-- Rows
------------------------------------------------------------------------
local Refresh, UpdateRows

local function RowOnEnter(self)
    if not self.item then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(self.item.link)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: find this auction to buy, and copy its name", 0.6, 0.8, 1)
    GameTooltip:AddLine("Shift-click: link  ·  Ctrl-click: try on", 0.6, 0.8, 1)
    GameTooltip:Show()
end

local function RowOnClick(self)
    local item = self.item
    if not item then return end
    local insertLink = ChatEdit_InsertLink or (ChatFrameUtil and ChatFrameUtil.InsertLink)
    if IsModifiedClick("CHATLINK") and insertLink and insertLink(item.link) then return end
    if IsModifiedClick("DRESSUP") and DressUpItemLink then
        DressUpItemLink(item.link)
        return
    end
    SF.ShowItemName(item)
    if frame.purchase then
        frame.purchase:Select({
            itemID = item.itemID, link = item.link, buyout = item.buyout, count = item.count,
            name = BaseName(item), icon = item.icon, quality = item.quality,
        }, {
            onBought = function()
                for i, it in ipairs(SF.items or {}) do
                    if it == item then table.remove(SF.items, i) break end
                end
                Refresh()
            end,
        })
    end
end

local function GetRow(i)
    if rows[i] then return rows[i] end
    local row = CreateFrame("Button", nil, frame.list)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", frame.list, "RIGHT")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:RegisterForClicks("LeftButtonUp")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ROW_H - 2, ROW_H - 2)
    row.icon:SetPoint("LEFT", 2, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", ROW_H + 4, 0)
    row.name:SetWidth(260)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.stats = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.stats:SetPoint("LEFT", 290, 0)
    row.stats:SetWidth(170)
    row.stats:SetJustifyH("LEFT")
    row.stats:SetWordWrap(false)

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("LEFT", 466, 0)
    row.level:SetWidth(28)

    row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.price:SetPoint("RIGHT", -4, 0)
    row.price:SetJustifyH("RIGHT")

    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", RowOnClick)
    rows[i] = row
    return row
end

local function VisibleRows()
    return math.max(1, math.floor((frame.list:GetHeight() or ROW_H) / ROW_H))
end

UpdateRows = function()
    local n = VisibleRows()
    for i = 1, n do
        local row = GetRow(i)
        local item = results[offset + i]
        row.item = item
        if item then
            row.icon:SetTexture(item.icon)
            row.name:SetText(QualityHex(item.quality) .. (SF.DisplayName(item.link) or "?") .. "|r")
            row.stats:SetText(SF.StatsText(item.link) or "")
            row.level:SetText(item.level > 0 and item.level or "")
            if item.buyout then
                row.price:SetText(Money(item.buyout))
            else
                row.price:SetText("|cff999999bid|r " .. Money(item.bid))
            end
            row:Show()
        else
            row:Hide()
        end
    end
    for i = n + 1, #rows do rows[i]:Hide() end
end

local function SetOffset(value)
    local maxOffset = math.max(0, #results - VisibleRows())
    offset = math.max(0, math.min(maxOffset, math.floor(value + 0.5)))
    frame.slider:SetMinMaxValues(0, maxOffset)
    if frame.slider:GetValue() ~= offset then
        frame.slider:SetValue(offset) -- calls UpdateRows through OnValueChanged
    else
        UpdateRows()
    end
end

local function FooterText()
    if SF.IsReading() then
        local done, total = SF.ReadProgress()
        return ("Reading the auction list... %d / %d"):format(done, total)
    end
    if not SF.scanTime then
        return "No listing read yet. Open the auction house: AHledger scans it on open (about once every 15 minutes)."
    end
    return ("%d shown of %d suffix items  ·  scanned %s%s"):format(#results, #(SF.items or {}),
        SF.TimeAgo(SF.scanTime), SF.scanPartial and " (partial)" or "")
end

Refresh = function()
    if not frame or not frame:IsShown() then return end
    BuildResults()
    SetOffset(offset)
    frame.footer:SetText(FooterText())
    local f = SF.filters
    local function label(base, set, count)
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        if n == 0 then return base .. ": All" end
        if n == 1 then return base .. ": " .. (count or next(set)) end
        return ("%s: %d"):format(base, n)
    end
    frame.suffixBtn:SetText(label("Suffix", f.suffixes))
    frame.slotBtn:SetText(label("Slot", f.slots))
    local onlyType = next(f.types)
    frame.typeBtn:SetText(label("Type", f.types, onlyType and TypeName(onlyType)))
    frame.usable:SetChecked(f.usable)
    frame.presetBtn:SetText(SF.ActivePreset() or "Presets")
end
SF.Refresh = Refresh
SF.OnData = Refresh
SF.OnProgress = function()
    if frame and frame:IsShown() then frame.footer:SetText(FooterText()) end
end
SF.OnItemInfo = function()
    if frame and frame:IsShown() then UpdateRows() end
end
SF.OnPurchase = function(auctionID)
    if frame and frame.purchase then frame.purchase:OnPurchase(auctionID) end
end

------------------------------------------------------------------------
-- Filter menus
------------------------------------------------------------------------
local KEEP_OPEN = MenuResponse and MenuResponse.Refresh

-- Counts items per value of one filter dimension, with every other filter applied.
local function Counts(skip, valueOf)
    local counts = {}
    for _, item in ipairs(SF.items or {}) do
        if Passes(item, SF.filters, skip) then
            local v = valueOf(item)
            counts[v] = (counts[v] or 0) + 1
        end
    end
    return counts
end

local function Toggle(set, key)
    if set[key] then set[key] = nil else set[key] = true end
    offset = 0
    Refresh()
    return KEEP_OPEN
end

local function Clear(set)
    for k in pairs(set) do set[k] = nil end
    offset = 0
    Refresh()
end

local function OpenMenu(owner, generator)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        SF.Print("this client has no menu system SuffixFinder can use")
        return
    end
    MenuUtil.CreateContextMenu(owner, generator)
end

local function SuffixMenu(owner)
    OpenMenu(owner, function(_, root)
        local set = SF.filters.suffixes
        root:CreateButton("All suffixes", function() Clear(set) end)
        root:CreateDivider()
        local counts = Counts("suffix", function(item) return item.suffix end)
        local names = {}
        for s in pairs(counts) do names[#names + 1] = s end
        for s in pairs(set) do if not counts[s] then names[#names + 1] = s end end
        table.sort(names)
        for _, s in ipairs(names) do
            root:CreateCheckbox(("%s (%d)"):format(s, counts[s] or 0),
                function() return set[s] == true end,
                function() return Toggle(set, s) end)
        end
        if #names == 0 then root:CreateTitle("No suffix items in the last scan") end
    end)
end

local function SlotMenu(owner)
    OpenMenu(owner, function(_, root)
        local set = SF.filters.slots
        root:CreateButton("All slots", function() Clear(set) end)
        root:CreateDivider()
        local counts = Counts("slot", SlotOf)
        for _, s in ipairs(SLOT_ORDER) do
            if counts[s] or set[s] then
                root:CreateCheckbox(("%s (%d)"):format(s, counts[s] or 0),
                    function() return set[s] == true end,
                    function() return Toggle(set, s) end)
            end
        end
    end)
end

local function TypeMenu(owner)
    OpenMenu(owner, function(_, root)
        local set = SF.filters.types
        root:CreateButton("All types", function() Clear(set) end)
        root:CreateDivider()
        local counts = Counts("type", TypeKey)
        local keys = {}
        for k in pairs(counts) do keys[#keys + 1] = k end
        for k in pairs(set) do if not counts[k] then keys[#keys + 1] = k end end
        table.sort(keys)
        local lastClass
        for _, k in ipairs(keys) do
            local classID = math.floor(k / 100)
            if lastClass and classID ~= lastClass then root:CreateDivider() end
            lastClass = classID
            root:CreateCheckbox(("%s (%d)"):format(TypeName(k), counts[k] or 0),
                function() return set[k] == true end,
                function() return Toggle(set, k) end)
        end
    end)
end

------------------------------------------------------------------------
-- Presets: save the current filters under a name, apply or delete them later
------------------------------------------------------------------------
local FillBoxes

-- The name prompt is SuffixFinder's own small panel, not a StaticPopup: Blizzard reuses those
-- popups for its own confirmations, and an addon showing one can taint them.
local function SavePresetFromBox()
    local box = frame.saveBox
    local name = strtrim(box:GetText() or "")
    if name == "" then return end
    local existed = AuctionSuite_SuffixFinderDB.presets[name] ~= nil
    SF.SavePreset(name)
    SF.Print(("%s preset \"%s\""):format(existed and "updated" or "saved", name))
    frame.savePanel:Hide()
    Refresh()
end

local function ShowSavePanel()
    local box = frame.saveBox
    frame.savePanel:Show()
    box:SetText(SF.ActivePreset() or "")
    box:SetFocus()
    box:HighlightText()
end

local function PresetMenu(owner)
    OpenMenu(owner, function(_, root)
        local names = SF.PresetNames()
        local active = SF.ActivePreset()
        if #names == 0 then root:CreateTitle("No presets yet") end
        for _, name in ipairs(names) do
            root:CreateRadio(name,
                function() return name == active end,
                function()
                    SF.ApplyPreset(name)
                    offset = 0
                    if FillBoxes then FillBoxes() end
                    Refresh()
                end)
        end
        root:CreateDivider()
        root:CreateButton("Save current filters as...", ShowSavePanel)
        if #names > 0 then
            local delete = root:CreateButton("Delete preset")
            for _, name in ipairs(names) do
                delete:CreateButton(name, function()
                    SF.DeletePreset(name)
                    SF.Print(("deleted preset \"%s\""):format(name))
                    Refresh()
                end)
            end
        end
    end)
end

------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------
local function NumberBox(parent, width, onChange)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(7)
    box:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        local n = tonumber(self:GetText())
        onChange(n)
        offset = 0
        Refresh()
    end)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    return box
end

local function Label(parent, text, anchor, x)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", anchor, "RIGHT", x or 6, 0)
    fs:SetText(text)
    return fs
end

local function Header(parent, text, x, sortKey)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(80, 16)
    b:SetPoint("TOPLEFT", x, -112)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT")
    fs:SetText(text)
    b:SetWidth(fs:GetStringWidth() + 12)
    b:SetScript("OnClick", function()
        local f = SF.filters
        if f.sortKey == sortKey then f.sortAsc = not f.sortAsc else f.sortKey, f.sortAsc = sortKey, true end
        offset = 0
        Refresh()
    end)
    return b
end

FillBoxes = function()
    local f = SF.filters
    frame.search:SetText(f.text or "")
    frame.minLevel:SetText(f.minLevel and tostring(f.minLevel) or "")
    frame.maxLevel:SetText(f.maxLevel and tostring(f.maxLevel) or "")
    frame.maxPrice:SetText(f.maxPrice and tostring(math.floor(f.maxPrice / 10000)) or "")
end

function SF.CreatePanel(page)
    local f = page
    frame = f

    -- Row 1: name search and the three menus
    local okSearch, search = pcall(CreateFrame, "EditBox", nil, f, "SearchBoxTemplate")
    if not okSearch then search = CreateFrame("EditBox", nil, f, "InputBoxTemplate") end
    search:SetSize(130, 20)
    search:SetPoint("TOPLEFT", 72, -34)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        SF.filters.text = strtrim(self:GetText() or ""):lower()
        offset = 0
        Refresh()
    end)
    f.search = search

    local function MenuButton(width, onClick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(width, 22)
        b:SetScript("OnClick", onClick)
        return b
    end
    -- Right-aligned so the row always ends inside the frame: [search] [suffix] [slot] [type]
    f.typeBtn = MenuButton(150, TypeMenu)
    f.typeBtn:SetPoint("TOPRIGHT", -14, -33)
    f.slotBtn = MenuButton(120, SlotMenu)
    f.slotBtn:SetPoint("RIGHT", f.typeBtn, "LEFT", -4, 0)
    f.suffixBtn = MenuButton(170, SuffixMenu)
    f.suffixBtn:SetPoint("RIGHT", f.slotBtn, "LEFT", -4, 0)
    for _, b in ipairs({ f.typeBtn, f.slotBtn, f.suffixBtn }) do
        local fs = b:GetFontString()
        if fs then
            fs:SetPoint("LEFT", 8, 0)
            fs:SetPoint("RIGHT", -8, 0)
            fs:SetWordWrap(false)
        end
    end

    -- Row 2: level range, max price, usable, reset
    local lvlLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lvlLabel:SetPoint("TOPLEFT", 72, -70)
    lvlLabel:SetText("Level")
    f.minLevel = NumberBox(f, 30, function(n) SF.filters.minLevel = n end)
    f.minLevel:SetPoint("LEFT", lvlLabel, "RIGHT", 10, 0)
    local dash = Label(f, "to", f.minLevel, 6)
    f.maxLevel = NumberBox(f, 30, function(n) SF.filters.maxLevel = n end)
    f.maxLevel:SetPoint("LEFT", dash, "RIGHT", 10, 0)

    local priceLabel = Label(f, "Max gold", f.maxLevel, 16)
    f.maxPrice = NumberBox(f, 50, function(n) SF.filters.maxPrice = n and n * 10000 or nil end)
    f.maxPrice:SetPoint("LEFT", priceLabel, "RIGHT", 10, 0)

    local usable = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    usable:SetSize(24, 24)
    usable:SetPoint("LEFT", f.maxPrice, "RIGHT", 12, 0)
    local usableText = usable.Text or usable.text
    if usableText then usableText:SetText("Usable only") end
    usable:SetScript("OnClick", function(self)
        SF.filters.usable = self:GetChecked() and true or false
        offset = 0
        Refresh()
    end)
    usable:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Usable only")
        GameTooltip:AddLine("Items the character who was logged in during the scan could use.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    usable:SetScript("OnLeave", GameTooltip_Hide)
    f.usable = usable

    local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reset:SetSize(60, 22)
    reset:SetPoint("TOPRIGHT", -14, -66)
    reset:SetText("Reset")
    reset:SetScript("OnClick", function()
        SF.ResetFilters()
        FillBoxes()
        offset = 0
        Refresh()
    end)

    local presets = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    presets:SetSize(110, 22)
    presets:SetPoint("RIGHT", reset, "LEFT", -4, 0)
    presets:SetScript("OnClick", PresetMenu)
    local presetText = presets:GetFontString()
    if presetText then
        presetText:SetPoint("LEFT", 8, 0)
        presetText:SetPoint("RIGHT", -8, 0)
        presetText:SetWordWrap(false)
    end
    f.presetBtn = presets

    -- "Save current filters as..." name panel, shown under the Presets button
    local panel = CreateFrame("Frame", nil, f)
    panel:SetSize(250, 56)
    panel:SetPoint("TOPRIGHT", reset, "BOTTOMRIGHT", 0, -4)
    panel:SetFrameLevel(f:GetFrameLevel() + 20)
    panel:EnableMouse(true)
    local panelBg = panel:CreateTexture(nil, "BACKGROUND")
    panelBg:SetAllPoints()
    panelBg:SetColorTexture(0.05, 0.05, 0.05, 0.95)
    local panelTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panelTitle:SetPoint("TOPLEFT", 8, -6)
    panelTitle:SetText("Save current filters as preset:")
    local saveBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    saveBox:SetSize(150, 20)
    saveBox:SetPoint("BOTTOMLEFT", 12, 6)
    saveBox:SetAutoFocus(false)
    saveBox:SetMaxLetters(40)
    saveBox:SetScript("OnEnterPressed", SavePresetFromBox)
    saveBox:SetScript("OnEscapePressed", function() panel:Hide() end)
    local saveBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    saveBtn:SetSize(70, 22)
    saveBtn:SetPoint("LEFT", saveBox, "RIGHT", 8, 0)
    saveBtn:SetText("Save")
    saveBtn:SetScript("OnClick", SavePresetFromBox)
    panel:Hide()
    f.savePanel, f.saveBox = panel, saveBox

    -- Column headers (click to sort)
    Header(f, "Item", 40, "name")
    Header(f, "Suffix stats", 304, "suffix")
    Header(f, "Lvl", 476, "level")
    local priceHeader = Header(f, "Buyout", 0, "price")
    priceHeader:ClearAllPoints()
    priceHeader:SetPoint("TOPRIGHT", -40, -112)

    -- Results list with a mouse-wheel scroll and a slider
    local list = CreateFrame("Frame", nil, f)
    list:SetPoint("TOPLEFT", 14, -130)
    list:SetPoint("BOTTOMRIGHT", -34, 92)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta) SetOffset(offset - delta * 3) end)
    list:SetScript("OnSizeChanged", function() if f:IsShown() then SetOffset(offset) end end)
    f.list = list

    local slider = CreateFrame("Slider", nil, f)
    slider:SetOrientation("VERTICAL")
    slider:SetWidth(16)
    slider:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
    slider:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 6, 0)
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
    slider:SetScript("OnValueChanged", function(_, value)
        offset = math.floor(value + 0.5)
        UpdateRows()
    end)
    slider:EnableMouseWheel(true)
    slider:SetScript("OnMouseWheel", function(_, delta) SetOffset(offset - delta * 3) end)
    f.slider = slider

    -- Copy row: a clicked result's base name, selected, ready for Ctrl+C
    local copyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    copyLabel:SetPoint("BOTTOMLEFT", 18, 68)
    copyLabel:SetText("Name:")
    local copyBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    copyBox:SetSize(220, 20)
    copyBox:SetPoint("LEFT", copyLabel, "RIGHT", 10, 0)
    copyBox:SetAutoFocus(false)
    copyBox:SetScript("OnTextChanged", function(self, user)
        if user then -- read-only: typing puts the name back
            self:SetText(self.name or "")
            self:HighlightText()
        end
    end)
    copyBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    copyBox:SetScript("OnEnterPressed", copyBox.ClearFocus)
    copyBox:SetScript("OnEscapePressed", copyBox.ClearFocus)
    f.copyBox = copyBox
    f.copyHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.copyHint:SetPoint("LEFT", copyBox, "RIGHT", 8, 0)
    f.copyHint:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    f.copyHint:SetJustifyH("LEFT")
    f.copyHint:SetWordWrap(false)
    f.copyHint:SetText("Click a result to copy its name for the auction house search")

    -- Purchase bar: the clicked result found on the house, and a Buy button
    f.purchase = AS.UI.CreatePurchaseBar(f)
    f.purchase:SetPoint("BOTTOMLEFT", 14, 32)
    f.purchase:SetPoint("BOTTOMRIGHT", -14, 32)

    -- Footer
    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.footer:SetPoint("BOTTOMLEFT", 16, 12)
    f.footer:SetPoint("RIGHT", -16, 0)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(false)

    f:SetScript("OnShow", function()
        FillBoxes()
        Refresh()
    end)
    FillBoxes()
    return f
end
SF.FillBoxes = function() if frame then FillBoxes() end end
