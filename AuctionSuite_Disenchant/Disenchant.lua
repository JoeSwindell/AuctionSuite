-- AuctionSuite_Disenchant: green, blue and purple weapons and armor listed for less than the
-- expected value of what disenchanting them gives, at AHledger's prices, after the auction house's
-- 5% cut on selling the materials. Runs on its own whenever the house opens or new listing data
-- arrives; the deals are sorted by profit. Clicking a deal finds that auction on the house and the
-- Buy button buys it (a purchase needs the player's click).
local ADDON, ns = ...
local AS = AuctionSuite
local T = ns.Tables
local UI = AS.UI
local Prices = AS.Prices

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoad = C_Item and C_Item.RequestLoadItemDataByID

local DE = {}
ns.DE = DE

local DEFAULTS = {
    minProfit = 1,      -- copper after the 5% cut: show every deal (the user's choice in DisenchantDeals)
    minReturn = 0,      -- percent of the buyout
    average = false,    -- false: value one disenchant at its most likely result, lowest quantity
                        -- true: value it at the average over many disenchants (/asd average)
    sortKey = "profit",
    sortAsc = false,
    stats = { bought = 0, spent = 0, expected = 0 },
    excluded = {},      -- itemID -> name, items the player hid (right-click) as not disenchantable
}

local db
local searchText = "" -- lower-case item name filter from the search box

local function IsExcluded(itemID)
    if not itemID then return false end
    if T.NOT_DISENCHANTABLE[itemID] then return true end
    return db ~= nil and db.excluded ~= nil and db.excluded[itemID] ~= nil
end
DE.IsExcluded = IsExcluded
local deals = {}       -- the current deals, sorted
local checked = 0      -- disenchantable listings looked at in the last pass
local unpriced = 0     -- of those, how many had no material prices
local loading = 0      -- items whose level was not cached yet
local snapshot         -- the data the deals came from
local bought = {}      -- "itemID:buyout" -> count bought from this snapshot
local page, list, summary, source, purchase, minProfitBox, minReturnBox

------------------------------------------------------------------------
-- Valuation
------------------------------------------------------------------------
local itemCache = {} -- itemID -> { quality, ilvl, weapon, yield, name } or false (not disenchantable)

local function ItemInfo(itemID, row)
    local c = itemCache[itemID]
    if c ~= nil then return c end
    local name, _, quality, ilvl, minLevel = GetItemInfo(itemID)
    if not name then
        if RequestLoad then pcall(RequestLoad, itemID) end
        return nil -- not cached yet; asked for it
    end
    quality = quality or row.quality
    -- Forever's disenchant results follow the item's required level, not its item level
    -- (wow-professions.com Forever guide). The tables are bracketed by item level, where
    -- required level + 5 lines up with the bracket, so the required level picks the bracket.
    -- Only items with no level requirement fall back to their item level.
    local req = (minLevel and minLevel > 0) and minLevel or nil
    if req then ilvl = req + 5 elseif not ilvl or ilvl < 1 then ilvl = nil end
    local inst = AS.Data.Instant(itemID)
    if not ilvl or not T.CanDisenchant(inst.classID, inst.subClassID, inst.equipLoc, quality) then
        itemCache[itemID] = false
        return false
    end
    local yield = T.Yield(quality, ilvl, inst.classID == 2)
    if not yield then
        itemCache[itemID] = false
        return false
    end
    c = { quality = quality, ilvl = ilvl, req = req or 0, weapon = inst.classID == 2, yield = yield, name = name }
    itemCache[itemID] = c
    return c
end

-- Unit sale value of each material for this pass, with lesser and greater essences valued at the
-- better of their own price and the other's (3 lesser = 1 greater). A live price from searching
-- the house (clicking a deal does that) wins over AHledger's for 10 minutes.
local matValue
local function BuildMatValues()
    matValue = {}
    local function V(id)
        if matValue[id] == nil then
            local live = AS.Data.LivePrice and AS.Data.LivePrice(id)
            matValue[id] = live or Prices.SellValue(id) or false
        end
        return matValue[id] or nil
    end
    for id in pairs(T.NAMES) do V(id) end
    for _, pair in ipairs(T.ESSENCE_PAIRS) do
        local lesser, greater = V(pair[1]), V(pair[2])
        if lesser and greater then
            matValue[pair[1]] = math.max(lesser, greater / 3)
            matValue[pair[2]] = math.max(greater, lesser * 3)
        elseif greater and not lesser then
            matValue[pair[1]] = greater / 3
        elseif lesser and not greater then
            matValue[pair[2]] = lesser * 3
        end
    end
end

-- The most likely result of a disenchant (highest chance; the first listed on a tie).
local function TopYield(yield)
    local top
    for _, y in ipairs(yield) do
        if not top or y[4] > top[4] then top = y end
    end
    return top
end

-- Material value of one item after the auction house cut, and whether every counted material had
-- a price. By default this is one disenchant: the most likely material at its lowest quantity
-- (75% Vision Dust x2-5 counts as 2 Vision Dust). With `average` on, it is the average over many
-- disenchants: chance x average quantity x price, summed over every result.
local evCache
local function ExpectedValue(info)
    local cached = evCache[info]
    if cached then return cached[1], cached[2] end
    local total, complete, any = 0, true, false
    if db.average then
        for _, y in ipairs(info.yield) do
            local value = matValue[y[1]]
            if value then
                total = total + value * ((y[2] + y[3]) / 2) * y[4]
                any = true
            else
                complete = false
            end
        end
    else
        local top = TopYield(info.yield)
        local value = top and matValue[top[1]]
        if value then
            total = value * top[2]
            any = true
        end
    end
    local ev = any and total * (1 - T.AH_CUT) or nil
    evCache[info] = { ev, complete }
    return ev, complete
end

local function Wants(row)
    if not row.buyout or row.buyout <= 0 then return false end
    if not T.CanDisenchant(row.classID, row.subClassID, row.equipLoc, row.quality) then return false end
    if AS.IsMine(row.owner) then return false end
    return true
end
DE.Wants = Wants

------------------------------------------------------------------------
-- Finding the deals
------------------------------------------------------------------------
local SORTS = {
    profit = function(d) return d.profit end,
    value = function(d) return d.ev end,
    buyout = function(d) return d.buyout end,
    name = function(d) return d.name or "" end,
    roi = function(d) return d.roi end,
}

local function SortDeals()
    local key, asc = SORTS[db.sortKey] or SORTS.profit, db.sortAsc
    table.sort(deals, function(a, b)
        local x, y = key(a), key(b)
        if x == y then return a.profit > b.profit end
        if asc then return x < y end
        return x > y
    end)
end

local Redraw

function DE.Evaluate()
    deals, checked, unpriced, loading = {}, 0, 0, 0
    if not snapshot then
        if Redraw then Redraw() end
        return
    end
    BuildMatValues()
    evCache = {}
    local seenBought = {}
    local minProfit, minReturn = db.minProfit or 0, (db.minReturn or 0) / 100
    for _, row in ipairs(snapshot.rows) do
        if Wants(row) and not IsExcluded(row.itemID) then
            local info = ItemInfo(row.itemID, row)
            if info == nil then
                loading = loading + 1
            elseif info and (searchText == "" or (info.name or ""):lower():find(searchText, 1, true)) then
                checked = checked + 1
                local key = row.itemID .. ":" .. row.buyout
                if bought[key] and (seenBought[key] or 0) < bought[key] then
                    seenBought[key] = (seenBought[key] or 0) + 1 -- bought already: skip one such listing
                else
                    local ev, complete = ExpectedValue(info)
                    if not ev then
                        unpriced = unpriced + 1
                    else
                        local count = row.count or 1
                        local value = ev * count
                        local profit = value - row.buyout
                        local roi = profit / row.buyout
                        if profit >= minProfit and roi >= minReturn then
                            deals[#deals + 1] = {
                                row = row, itemID = row.itemID, link = row.link, name = info.name,
                                icon = row.icon, quality = info.quality, ilvl = info.ilvl, req = info.req, weapon = info.weapon,
                                count = count, buyout = row.buyout, ev = value, profit = profit, roi = roi,
                                yield = info.yield, complete = complete, guessed = info.yield.guessed,
                            }
                        end
                    end
                end
            end
        end
    end
    SortDeals()
    if Redraw then Redraw() end
end

-- Re-runs at most once a second while item data loads.
local evalPending = false
local function EvaluateSoon()
    if evalPending then return end
    evalPending = true
    C_Timer.After(1, function()
        evalPending = false
        DE.Evaluate()
    end)
end

------------------------------------------------------------------------
-- Text
------------------------------------------------------------------------
local function MatName(id, short)
    local n = T.NAMES[id]
    if short and n then return n[2] end
    return GetItemInfo(id) or (n and n[1]) or ("item " .. id)
end

local function Range(y)
    if y[2] == y[3] then return tostring(y[2]) end
    return y[2] .. "-" .. y[3]
end

local function LikelyMats(d)
    local sorted = {}
    for _, y in ipairs(d.yield) do sorted[#sorted + 1] = y end
    table.sort(sorted, function(a, b) return a[4] > b[4] end)
    local parts = {}
    for _, y in ipairs(sorted) do
        local pct = y[4] * 100
        parts[#parts + 1] = ("%s %s %s"):format(Range(y), MatName(y[1], true),
            pct >= 1 and ("%d%%"):format(pct + 0.5) or ("%.1f%%"):format(pct))
    end
    return table.concat(parts, ", ")
end

local function Money(c)
    return UI.ShortMoney(c)
end

-- The player's Enchanting skill, or nil without Enchanting (from DisenchantDeals 0.1). On Forever
-- any skill can disenchant everything, so this is shown as a note, never used as a filter.
local function EnchantingSkill()
    if not GetProfessions or not GetProfessionInfo then return nil end
    local ok, a, b = pcall(GetProfessions)
    if not ok then return nil end
    for _, index in ipairs({ a, b }) do
        if index then
            local okInfo, name, _, rank, _, _, _, skillLine = pcall(GetProfessionInfo, index)
            if okInfo and (skillLine == ENCHANTING_SKILL_LINE or name == "Enchanting") then return rank or 1 end
        end
    end
    return nil
end

local function SourceText()
    if not snapshot then
        return "No listing data yet. AHledger scans the house when it opens (about once every 15 minutes)."
    end
    local what = snapshot.source == "live" and "Listing read" or "AHledger's saved scan"
    local text = ("%s %s"):format(what, AS.TimeAgo(snapshot.time))
    if snapshot.partial then text = text .. " (partial)" end
    if snapshot.source ~= "live" then text = text .. "; listings may have sold since" end
    if AS.Data.IsReading() then
        local done, total = AS.Data.ReadProgress()
        text = text .. ("  |cffffd200reading the new listing %d / %d|r"):format(done, total)
    end
    return text
end

------------------------------------------------------------------------
-- The page
------------------------------------------------------------------------
local function ShowDealTooltip(rowFrame, d)
    GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
    if d.link then GameTooltip:SetHyperlink(d.link) else GameTooltip:SetItemByID(d.itemID) end
    GameTooltip:Show()
    local tip = UI.InfoTooltip()
    tip:SetOwner(rowFrame, "ANCHOR_NONE")
    tip:ClearAllPoints()
    tip:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -2)
    tip:AddLine("Disenchant value (AuctionSuite)", 1, 0.82, 0)
    tip:AddLine(("%s, %s"):format(d.weapon and "Weapon" or "Armor",
        _G["ITEM_QUALITY" .. d.quality .. "_DESC"] or ""), 0.8, 0.8, 0.8)
    tip:AddLine("Likely materials:", 1, 0.82, 0)
    local top = TopYield(d.yield)
    for _, y in ipairs(d.yield) do
        local v = matValue and matValue[y[1]]
        local pct = y[4] * 100
        local c = (db.average or y == top) and 1 or 0.55 -- grey: not counted in the value
        tip:AddDoubleLine(("%s%% %s x %s"):format(pct >= 1 and ("%d"):format(pct + 0.5) or ("%.1f"):format(pct),
            Range(y), MatName(y[1])),
            v and (Money(v) .. " each" .. (AS.Data.HasLivePrice and AS.Data.HasLivePrice(y[1]) and " |cff00ff00(live)|r" or ""))
                or "|cffff7f7fno price|r", c, c, c, c, c, c)
    end
    tip:AddLine(" ")
    if db.average then
        tip:AddDoubleLine("Average value, after 5% cut", Money(d.ev), 1, 1, 1, 1, 1, 1)
    else
        tip:AddDoubleLine(("Value: %d %s, after 5%% cut"):format(top and top[2] or 0, top and MatName(top[1]) or "?"),
            Money(d.ev), 1, 1, 1, 1, 1, 1)
    end
    tip:AddDoubleLine("Buyout" .. (d.count > 1 and (" (" .. d.count .. ")") or ""), Money(d.buyout), 1, 1, 1, 1, 1, 1)
    tip:AddDoubleLine("Profit", Money(d.profit) .. (" (%d%%)"):format(d.roi * 100 + 0.5), 0, 1, 0, 0, 1, 0)
    if not d.complete then tip:AddLine("Some materials have no price; counted as zero.", 1, 0.5, 0.5, true) end
    if d.guessed then tip:AddLine("No table entry for an epic this low; one shard assumed.", 1, 0.5, 0.5, true) end
    if db.average then
        tip:AddLine("Value is the average over many disenchants; one item can come out lower. /asd average switches back.", 0.6, 0.6, 0.6, true)
    else
        tip:AddLine("Value is the most likely result at its lowest quantity. /asd average values it at the average instead.", 0.6, 0.6, 0.6, true)
    end
    tip:AddLine("Right-click: hide this item (e.g. it can't be disenchanted)", 0.6, 0.8, 1)
    tip:AddLine(Prices.CREDIT, 0.5, 0.5, 0.5)
    tip:Show()
end

local function DescribeFound(d)
    return function(found)
        local qty = found.quantity or 1
        local profit = (d.ev / d.count) * qty - found.buyout
        local color = profit > 0 and "|cff00ff00" or "|cffff7f7f"
        local state = d.checking and "  |cffffd200checking material prices...|r"
            or (d.live and "  |cff999999(live prices)|r" or "")
        return ("value %s, profit %s%s|r%s"):format(Money((d.ev / d.count) * qty), color, Money(profit), state)
    end
end

-- Every material this deal can give, plus the other size of any essence (they convert).
local function MaterialsOf(d)
    local ids, seen = {}, {}
    local function add(id) if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    for _, y in ipairs(d.yield) do
        add(y[1])
        for _, pair in ipairs(T.ESSENCE_PAIRS) do
            if pair[1] == y[1] then add(pair[2]) elseif pair[2] == y[1] then add(pair[1]) end
        end
    end
    return ids
end

-- Re-values one deal from the latest material prices (live ones where we have them).
local function Revalue(d)
    BuildMatValues()
    evCache = {}
    local ev, complete = ExpectedValue({ yield = d.yield })
    if ev then
        d.ev = ev * d.count
        d.profit = d.ev - d.buyout
        d.roi = d.profit / d.buyout
        d.complete = complete
    end
end

-- Clicking a deal: the auction itself is looked up live (purchase bar), then every material it
-- can disenchant into is searched on the house, and the deal is re-valued at those prices.
local function CheckLivePrices(d)
    d.checking, d.live = true, nil
    if list then list:Refresh() end
    local started = AS.Data.QueryPrices(MaterialsOf(d), nil, function()
        d.checking = nil
        d.live = true
        Revalue(d)
        if list then list:Refresh() end
        if purchase then purchase:Redescribe() end
    end)
    if not started then d.checking = nil end
end

local function OnDealClick(d, button)
    if button == "RightButton" then
        -- "This can't be disenchanted": hide the item from now on.
        if d.itemID then
            db.excluded = db.excluded or {}
            db.excluded[d.itemID] = d.name or ("item " .. d.itemID)
            AS.Print((d.name or "Item") .. " hidden from Disenchant deals. /asd unhide " .. d.itemID .. " to undo.")
            DE.Evaluate()
        end
        return
    end
    local insertLink = ChatEdit_InsertLink or (ChatFrameUtil and ChatFrameUtil.InsertLink)
    if d.link and IsModifiedClick("CHATLINK") and insertLink and insertLink(d.link) then return end
    list:SetSelected(d)
    purchase:Select({
        itemID = d.itemID, link = d.link, buyout = d.buyout, count = d.count, name = d.name,
        icon = d.icon, quality = d.quality,
    }, {
        describe = DescribeFound(d),
        onBought = function(_, found)
            local key = d.itemID .. ":" .. d.buyout
            bought[key] = (bought[key] or 0) + 1
            local st = db.stats
            st.bought = st.bought + 1
            st.spent = st.spent + found.buyout
            st.expected = st.expected + (d.ev / d.count) * (found.quantity or 1)
            list.selected = nil
            DE.Evaluate()
        end,
    })
    CheckLivePrices(d)
end

local function NumberBox(parent, width, value, onChange)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(6)
    box:SetText(tostring(value))
    box:SetScript("OnEnterPressed", box.ClearFocus)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEditFocusLost", function(self)
        local n = tonumber(self:GetText())
        if not n then self:SetText(tostring(value)) return end
        onChange(n)
    end)
    return box
end

-- "1g 50s 25c", "1g50s", "75s", "30c" -> copper. A bare number counts as silver. nil if unreadable.
local function ParseMoney(text)
    text = (text or ""):lower():gsub("%s+", "")
    if text == "" then return nil end
    if text:match("^%d+$") then return tonumber(text) * 100 end
    local total, rest = 0, text
    for amount, unit in text:gmatch("(%d+)([gsc])") do
        total = total + tonumber(amount) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
    end
    rest = rest:gsub("%d+[gsc]", "")
    if rest ~= "" then return nil end
    return total
end

-- copper -> "1g 50s 25c" (only the parts that aren't zero; "0c" for nothing).
local function MoneyText(c)
    c = math.floor(c or 0)
    local g, s, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if cp > 0 or #parts == 0 then parts[#parts + 1] = cp .. "c" end
    return table.concat(parts, " ")
end

local function MoneyBox(parent, width, value, onChange)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(16)
    box:SetText(MoneyText(value))
    box:SetScript("OnEnterPressed", box.ClearFocus)
    box:SetScript("OnEscapePressed", function(self) self.cancel = true; self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function(self)
        local c = not self.cancel and ParseMoney(self:GetText())
        self.cancel = nil
        if c then value = math.max(1, c); onChange(value) end
        self:SetText(MoneyText(value))
    end)
    box:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Minimum profit")
        GameTooltip:AddLine("Type gold, silver and copper, like 1g 50s 25c, 75s or 30c, then press Enter. A plain number counts as silver.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    box:SetScript("OnLeave", GameTooltip_Hide)
    return box
end

local function CreatePanel(p)
    page = p

    summary = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    summary:SetPoint("TOPLEFT", 72, -36)
    summary:SetJustifyH("LEFT")

    local pctLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pctLabel:SetPoint("TOPRIGHT", -16, -38)
    pctLabel:SetText("%")
    minReturnBox = NumberBox(p, 32, db.minReturn, function(n)
        db.minReturn = n
        DE.Evaluate()
    end)
    minReturnBox:SetPoint("RIGHT", pctLabel, "LEFT", -4, 0)
    local returnLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    returnLabel:SetPoint("RIGHT", minReturnBox, "LEFT", -10, 0)
    returnLabel:SetText("Min return")

    minProfitBox = MoneyBox(p, 90, db.minProfit or 1, function(c)
        db.minProfit = c -- at least 1c: every listing below its value
        DE.Evaluate()
    end)
    minProfitBox:SetPoint("RIGHT", returnLabel, "LEFT", -14, 0)
    local profitLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profitLabel:SetPoint("RIGHT", minProfitBox, "LEFT", -10, 0)
    profitLabel:SetText("Min profit")

    -- Item name search
    local okSearch, search = pcall(CreateFrame, "EditBox", nil, p, "SearchBoxTemplate")
    if not okSearch then search = CreateFrame("EditBox", nil, p, "InputBoxTemplate") end
    search:SetSize(140, 20)
    search:SetPoint("RIGHT", profitLabel, "LEFT", -18, 0)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        local text = strtrim(self:GetText() or ""):lower()
        if text ~= searchText then
            searchText = text
            DE.Evaluate()
        end
    end)
    search:HookScript("OnEnterPressed", search.ClearFocus)
    summary:SetPoint("RIGHT", search, "LEFT", -12, 0)
    summary:SetWordWrap(false)

    source = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    source:SetPoint("TOPLEFT", 72, -58)
    source:SetPoint("RIGHT", -16, 0)
    source:SetJustifyH("LEFT")
    source:SetWordWrap(false)

    list = UI.CreateList(p, {
        columns = {
            { key = "name", title = "Item", width = 0, sort = true },
            { key = "buyout", title = "Buyout", width = 90, justify = "RIGHT", sort = true },
            { key = "value", title = "Value", width = 90, justify = "RIGHT", sort = true },
            { key = "profit", title = "Profit", width = 90, justify = "RIGHT", sort = true },
        },
        icon = function(d) return d.icon end,
        cell = function(d, key)
            if key == "name" then
                local name = UI.DisplayName(d.link) or d.name or "?"
                if d.count > 1 then name = name .. " x" .. d.count end
                return UI.QualityHex(d.quality) .. name .. "|r"
            elseif key == "buyout" then return Money(d.buyout)
            elseif key == "value" then
                if d.checking then return "|cffffd200checking...|r" end
                return Money(d.ev) .. (d.complete and "" or "*") .. (d.live and " |cff00ff00•|r" or "")
            elseif key == "profit" then return Money(d.profit)
            end
        end,
        onClick = OnDealClick,
        onEnter = ShowDealTooltip,
        onSort = function(key)
            local map = { name = "name", buyout = "buyout", value = "value", profit = "profit" }
            key = map[key] or "profit"
            if db.sortKey == key then
                db.sortAsc = not db.sortAsc
            else
                db.sortKey, db.sortAsc = key, (key == "name" or key == "buyout")
            end
            SortDeals()
            list:SetItems(deals)
        end,
    })
    list:SetPoint("TOPLEFT", 14, -76)
    list:SetPoint("BOTTOMRIGHT", -14, 64)

    purchase = UI.CreatePurchaseBar(p)
    purchase:SetPoint("BOTTOMLEFT", 14, 32)
    purchase:SetPoint("BOTTOMRIGHT", -14, 32)

    local credit = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    credit:SetPoint("BOTTOMRIGHT", -16, 12)
    credit:SetText(Prices.CREDIT)

    p.stats = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.stats:SetPoint("BOTTOMLEFT", 16, 12)
    p.stats:SetPoint("RIGHT", credit, "LEFT", -12, 0)
    p.stats:SetJustifyH("LEFT")
    p.stats:SetWordWrap(false)

    Redraw()
end

Redraw = function()
    if not page or not page:IsVisible() or not list then return end
    if snapshot then
        summary:SetText(("%d deals  |cffaaaaaafrom %d disenchantable listings%s%s|r"):format(#deals, checked,
            unpriced > 0 and (", %d without material prices"):format(unpriced) or "",
            loading > 0 and (", %d loading"):format(loading) or ""))
    else
        summary:SetText("No deals yet")
    end
    source:SetText(SourceText())
    local keep = list.selected
    list.selected = nil
    for _, d in ipairs(deals) do
        if keep and d.row == keep.row then list.selected = d end
    end
    list:SetItems(deals, true)
    local st = db.stats
    local skill = EnchantingSkill()
    local ench = skill and ("Enchanting %d (any skill can disenchant everything on Forever)"):format(skill)
        or "|cffff8040No Enchanting on this character|r"
    if st.bought > 0 then
        page.stats:SetText(("%s  |  Bought %d for %s, expected value %s"):format(ench, st.bought, Money(st.spent), Money(st.expected)))
    else
        page.stats:SetText(ench .. "  |  * = some materials unpriced")
    end
end

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    AuctionSuite_DisenchantDB = AuctionSuite_DisenchantDB or {}
    db = AS.CopyDefaults(AuctionSuite_DisenchantDB, DEFAULTS)
    AS.CopyDefaults(db.stats, DEFAULTS.stats)
    AS:RegisterModule({
        name = "Disenchant",
        title = "Disenchant",
        icon = "Interface\\Icons\\INV_Enchant_Disenchant",
        order = 20,
        wants = Wants,
        createPanel = CreatePanel,
        onData = function(snap)
            if snap ~= snapshot then
                bought = {}
                snapshot = snap
            end
            DE.Evaluate()
        end,
        onProgress = function()
            if source and page and page:IsVisible() then source:SetText(SourceText()) end
        end,
        onItemInfo = function()
            if loading > 0 then EvaluateSoon() end
            if list and page and page:IsVisible() then list:Refresh() end
        end,
        onShow = function() DE.Evaluate() end,
        onPurchase = function(auctionID) if purchase then purchase:OnPurchase(auctionID) end end,
    })
end)

------------------------------------------------------------------------
-- Slash commands (/asd): manage items hidden as "can't be disenchanted"
------------------------------------------------------------------------
SLASH_AUCTIONSUITEDE1 = "/asd"
SlashCmdList.AUCTIONSUITEDE = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if not db then
        AS.Print("Disenchant isn't loaded yet; open the auction house first.")
        return
    end
    db.excluded = db.excluded or {}
    local id = tonumber(rest) or tonumber((rest or ""):match("item:(%d+)"))
    if (cmd == "hide" or cmd == "unhide") and id then
        if cmd == "hide" then
            db.excluded[id] = (GetItemInfo(id)) or ("item " .. id)
            AS.Print(db.excluded[id] .. " hidden from Disenchant deals.")
        elseif T.NOT_DISENCHANTABLE[id] then
            AS.Print(T.NOT_DISENCHANTABLE[id] .. " is on the built-in list of items that can't be disenchanted.")
        else
            db.excluded[id] = nil
            AS.Print(((GetItemInfo(id)) or ("item " .. id)) .. " will be listed again.")
        end
        DE.Evaluate()
    elseif cmd == "average" or cmd == "avg" then
        db.average = not db.average
        AS.Print(db.average and "Disenchant value: average over many disenchants"
            or "Disenchant value: one disenchant, most likely result at its lowest quantity")
        DE.Evaluate()
    elseif cmd == "hidden" then
        local n = 0
        for hid, name in pairs(db.excluded) do AS.Print(("hidden: %s (%d)"):format(tostring(name), hid)); n = n + 1 end
        for bid, name in pairs(T.NOT_DISENCHANTABLE) do AS.Print(("built in: %s (%d) - can't be disenchanted"):format(name, bid)) end
        if n == 0 then AS.Print("you haven't hidden any items.") end
    else
        AS.Print("/asd hide <item> | /asd unhide <item> | /asd hidden - right-click a deal to hide it | /asd average - toggle average value")
    end
end
