-- AuctionSuite_VendorDeals: auction house listings whose buyout is below what a vendor pays for the
-- items (buy on the house, sell to any vendor). Vendor prices come from item info (GetItemInfo's
-- sellPrice, per unit); the listings are the ones the core already has from AHledger's scan. No
-- auction house cut applies: a vendor pays the full price. Runs on its own whenever the house opens
-- or new listing data arrives. AHledger already marks the opposite direction at merchants (buy from
-- a vendor, sell at auction), so this module only looks at the auction house.
local ADDON, ns = ...
local AS = AuctionSuite
local UI = AS.UI

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoad = C_Item and C_Item.RequestLoadItemDataByID

local VD = {}
ns.VD = VD

local DEFAULTS = {
    minProfit = 1,      -- copper: show every deal
    sortKey = "profit",
    sortAsc = false,
    stats = { bought = 0, spent = 0, vendor = 0 },
    excluded = {},      -- itemID -> name, items the player hid (right-click)
}

local db
local deals = {}       -- the current deals, sorted
local checked = 0      -- listings with a vendor price looked at in the last pass
local loading = 0      -- listings whose item data was not cached yet
local snapshot         -- the data the deals came from
local bought = {}      -- "itemID:buyout" -> count bought from this snapshot
local page, list, summary, source, purchase, minProfitBox

local function IsExcluded(itemID)
    return itemID ~= nil and db ~= nil and db.excluded ~= nil and db.excluded[itemID] ~= nil
end

------------------------------------------------------------------------
-- Vendor prices
------------------------------------------------------------------------
local vendor = {}    -- itemID -> { price = copper per unit, name, quality } or false (no sell price)
local requested = {} -- itemIDs asked for once

-- The item's vendor sell price per unit and its info, false when vendors won't buy it, nil while
-- the item is not cached (it is requested once).
local function VendorInfo(itemID)
    local v = vendor[itemID]
    if v ~= nil then return v end
    local name, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
    if not name then
        if not requested[itemID] then
            requested[itemID] = true
            if RequestLoad then pcall(RequestLoad, itemID) end
        end
        return nil
    end
    if not sellPrice or sellPrice <= 0 then
        vendor[itemID] = false
        return false
    end
    v = { price = sellPrice, name = name, quality = quality }
    vendor[itemID] = v
    return v
end

-- Keep a listing row when it can be a deal: it has a buyout, isn't the player's, and the vendor
-- pays more than the buyout (or the item isn't cached yet, so it is checked later).
local function Wants(row)
    if not row.buyout or row.buyout <= 0 then return false end
    if AS.IsMine(row.owner) then return false end
    local v = VendorInfo(row.itemID)
    if v == false then return false end
    if v and v.price * (row.count or 1) <= row.buyout then return false end
    return true
end
VD.Wants = Wants

------------------------------------------------------------------------
-- Finding the deals
------------------------------------------------------------------------
local SORTS = {
    profit = function(d) return d.profit end,
    vendor = function(d) return d.vendor end,
    buyout = function(d) return d.buyout end,
    count = function(d) return d.count end,
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

function VD.Evaluate()
    deals, checked, loading = {}, 0, 0
    if not snapshot then
        if Redraw then Redraw() end
        return
    end
    local seenBought = {}
    local minProfit = math.max(1, db.minProfit or 1)
    for _, row in ipairs(snapshot.rows) do
        if row.buyout and row.buyout > 0 and not IsExcluded(row.itemID) and not AS.IsMine(row.owner) then
            local v = VendorInfo(row.itemID)
            if v == nil then
                loading = loading + 1
            elseif v then
                checked = checked + 1
                local count = row.count or 1
                local value = v.price * count
                local profit = value - row.buyout
                if profit >= minProfit then
                    local key = row.itemID .. ":" .. row.buyout
                    if bought[key] and (seenBought[key] or 0) < bought[key] then
                        seenBought[key] = (seenBought[key] or 0) + 1 -- bought already: skip one such listing
                    else
                        deals[#deals + 1] = {
                            row = row, itemID = row.itemID, link = row.link, name = v.name,
                            icon = row.icon, quality = v.quality or row.quality, count = count,
                            unit = v.price, buyout = row.buyout, vendor = value, profit = profit,
                            roi = profit / row.buyout,
                        }
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
        VD.Evaluate()
    end)
end

------------------------------------------------------------------------
-- The page
------------------------------------------------------------------------
local function Money(c)
    return UI.ShortMoney(c)
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

local function ShowDealTooltip(rowFrame, d)
    GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
    if d.link then GameTooltip:SetHyperlink(d.link) else GameTooltip:SetItemByID(d.itemID) end
    GameTooltip:Show()
    local tip = UI.InfoTooltip()
    tip:SetOwner(rowFrame, "ANCHOR_NONE")
    tip:ClearAllPoints()
    tip:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -2)
    tip:AddLine("Vendor deal (AuctionSuite)", 1, 0.82, 0)
    tip:AddDoubleLine("Vendor pays, each", Money(d.unit), 1, 1, 1, 1, 1, 1)
    tip:AddDoubleLine("Stack size", tostring(d.count), 1, 1, 1, 1, 1, 1)
    tip:AddDoubleLine("Vendor pays, total", Money(d.vendor), 1, 1, 1, 1, 1, 1)
    tip:AddDoubleLine("Buyout", Money(d.buyout), 1, 1, 1, 1, 1, 1)
    tip:AddDoubleLine("Profit", Money(d.profit) .. (" (%d%%)"):format(d.roi * 100 + 0.5), 0, 1, 0, 0, 1, 0)
    tip:AddLine(" ")
    tip:AddLine("Click: find this auction to buy  ·  Right-click: hide this item", 0.6, 0.8, 1)
    tip:Show()
end

local function DescribeFound(d)
    return function(found)
        local qty = found.quantity or 1
        local profit = d.unit * qty - found.buyout
        local color = profit > 0 and "|cff00ff00" or "|cffff7f7f"
        return ("vendor %s, profit %s%s|r"):format(Money(d.unit * qty), color, Money(profit))
    end
end

local function OnDealClick(d, button)
    if button == "RightButton" then
        if d.itemID then
            db.excluded = db.excluded or {}
            db.excluded[d.itemID] = d.name or ("item " .. d.itemID)
            AS.Print((d.name or "Item") .. " hidden from Vendor deals. /asv unhide " .. d.itemID .. " to undo.")
            VD.Evaluate()
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
            st.vendor = st.vendor + d.unit * (found.quantity or 1)
            list.selected = nil
            VD.Evaluate()
        end,
    })
end

local function CreatePanel(p)
    page = p

    summary = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    summary:SetPoint("TOPLEFT", 72, -36)
    summary:SetJustifyH("LEFT")

    local sLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sLabel:SetPoint("TOPRIGHT", -16, -38)
    sLabel:SetText("silver")
    minProfitBox = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    minProfitBox:SetSize(44, 20)
    minProfitBox:SetAutoFocus(false)
    minProfitBox:SetNumeric(true)
    minProfitBox:SetMaxLetters(6)
    minProfitBox:SetText(tostring(math.floor((db.minProfit or 0) / 100)))
    minProfitBox:SetPoint("RIGHT", sLabel, "LEFT", -4, 0)
    minProfitBox:SetScript("OnEnterPressed", minProfitBox.ClearFocus)
    minProfitBox:SetScript("OnEscapePressed", minProfitBox.ClearFocus)
    minProfitBox:SetScript("OnEditFocusLost", function(self)
        local n = tonumber(self:GetText())
        if not n then
            self:SetText(tostring(math.floor((db.minProfit or 0) / 100)))
            return
        end
        db.minProfit = math.max(1, n * 100) -- 0 silver = any profit
        VD.Evaluate()
    end)
    local profitLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profitLabel:SetPoint("RIGHT", minProfitBox, "LEFT", -10, 0)
    profitLabel:SetText("Min profit")

    source = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    source:SetPoint("TOPLEFT", 72, -58)
    source:SetPoint("RIGHT", -16, 0)
    source:SetJustifyH("LEFT")
    source:SetWordWrap(false)

    list = UI.CreateList(p, {
        columns = {
            { key = "name", title = "Item", width = 0, sort = true },
            { key = "count", title = "Qty", width = 32, justify = "RIGHT", sort = true },
            { key = "buyout", title = "Buyout", width = 84, justify = "RIGHT", sort = true },
            { key = "vendor", title = "Vendor pays", width = 84, justify = "RIGHT", sort = true },
            { key = "profit", title = "Profit", width = 84, justify = "RIGHT", sort = true },
            { key = "roi", title = "Return", width = 50, justify = "RIGHT", sort = true },
        },
        icon = function(d) return d.icon end,
        cell = function(d, key)
            if key == "name" then
                return UI.QualityHex(d.quality) .. (UI.DisplayName(d.link) or d.name or "?") .. "|r"
            elseif key == "count" then return tostring(d.count)
            elseif key == "buyout" then return Money(d.buyout)
            elseif key == "vendor" then return Money(d.vendor)
            elseif key == "profit" then return Money(d.profit)
            elseif key == "roi" then return ("%d%%"):format(d.roi * 100 + 0.5)
            end
        end,
        onClick = OnDealClick,
        onEnter = ShowDealTooltip,
        onSort = function(key)
            if not SORTS[key] then key = "profit" end
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

    p.stats = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.stats:SetPoint("BOTTOMLEFT", 16, 12)
    p.stats:SetPoint("RIGHT", -16, 0)
    p.stats:SetJustifyH("LEFT")
    p.stats:SetWordWrap(false)

    Redraw()
end

Redraw = function()
    if not page or not page:IsVisible() or not list then return end
    if snapshot then
        summary:SetText(("%d deals  |cffaaaaaafrom %d listings vendors buy%s|r"):format(#deals, checked,
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
    if st.bought > 0 then
        page.stats:SetText(("Bought %d for %s; vendors pay %s. Sell them at any vendor."):format(
            st.bought, Money(st.spent), Money(st.vendor)))
    else
        page.stats:SetText("Buy here, sell to any vendor. Vendor prices come from item info; no auction house cut applies.")
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
    AuctionSuite_VendorDealsDB = AuctionSuite_VendorDealsDB or {}
    db = AS.CopyDefaults(AuctionSuite_VendorDealsDB, DEFAULTS)
    AS.CopyDefaults(db.stats, DEFAULTS.stats)
    AS:RegisterModule({
        name = "VendorDeals",
        title = "Vendor Deals",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        order = 30,
        wants = Wants,
        createPanel = CreatePanel,
        onData = function(snap)
            if snap ~= snapshot then
                bought = {}
                snapshot = snap
            end
            VD.Evaluate()
        end,
        onProgress = function()
            if source and page and page:IsVisible() then source:SetText(SourceText()) end
        end,
        onItemInfo = function()
            if loading > 0 then EvaluateSoon() end
            if list and page and page:IsVisible() then list:Refresh() end
        end,
        onShow = function() VD.Evaluate() end,
        onPurchase = function(auctionID) if purchase then purchase:OnPurchase(auctionID) end end,
    })
end)

------------------------------------------------------------------------
-- Slash commands (/asv): items hidden from the vendor deals
------------------------------------------------------------------------
SLASH_AUCTIONSUITEVD1 = "/asv"
SlashCmdList.AUCTIONSUITEVD = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if not db then
        AS.Print("Vendor Deals isn't loaded yet; open the auction house first.")
        return
    end
    db.excluded = db.excluded or {}
    local id = tonumber(rest) or tonumber((rest or ""):match("item:(%d+)"))
    if (cmd == "hide" or cmd == "unhide") and id then
        if cmd == "hide" then
            db.excluded[id] = (GetItemInfo(id)) or ("item " .. id)
            AS.Print(db.excluded[id] .. " hidden from Vendor deals.")
        else
            db.excluded[id] = nil
            AS.Print(((GetItemInfo(id)) or ("item " .. id)) .. " will be listed again.")
        end
        VD.Evaluate()
    elseif cmd == "hidden" then
        local n = 0
        for hid, hname in pairs(db.excluded) do AS.Print(("hidden: %s (%d)"):format(tostring(hname), hid)); n = n + 1 end
        if n == 0 then AS.Print("you haven't hidden any items from Vendor deals.") end
    elseif cmd == "" then
        AS:LoadModules()
        AS.Data.EnsureSnapshot()
        AS.UI.Show()
        AS.UI.ShowPage("VendorDeals")
    else
        AS.Print("/asv - open Vendor Deals | /asv hide <item> | /asv unhide <item> | /asv hidden - right-click a deal to hide it")
    end
end
