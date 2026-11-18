-- AuctionSuite data layer:
--   Prices    AHledger's prices through AHledgerAPI, plus the lowest live listing seen this session
--   Listings  the auction house's full listing, read once per listing and handed to the modules
--   Search    a targeted item search to find one auction to buy, run only while AHledger is idle
--   Buy       C_AuctionHouse.PlaceBid from a hardware click
--
-- Listing rows (what modules get in snapshot.rows, and in wants(row) before the link is read):
--   itemID, name, count, quality, level (required level), usable, buyout (whole listing, copper),
--   bid, owner, classID, subClassID, equipLoc, icon, link (nil for AHledger saved scans),
--   live (true when read from the client's listing this session)
local _, ns = ...
local AS = ns.AS

local Data = {}
AS.Data = Data

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local FRAME_BUDGET_MS = 10      -- time spent reading the listing per frame
local ROWS_PER_FRAME = 2000     -- rows per frame when there is no clock
local SAME_LIST_SECONDS = 120   -- a repeat update with the same row count this soon is the same list
local LINK_RETRIES = 3          -- passes for rows whose link was not readable yet
local AHLEDGER_WAIT_MAX = 60    -- seconds to hold a read back while AHledger saves the same list
local SEARCH_ITEM_WAIT = 4      -- seconds before an item search falls back to a name search
local SEARCH_GIVE_UP = 20       -- seconds before a search is reported as not found

local clock = debugprofilestop

------------------------------------------------------------------------
-- Prices (AHledger)
------------------------------------------------------------------------
local Prices = {}
AS.Prices = Prices

Prices.CREDIT = (AHledgerAPI and AHledgerAPI.CREDIT) or "Prices from AHledger (ahledger.com)"

local liveMin = {} -- itemID -> lowest unit buyout in the listing read this session

-- AHledger's full price record for an item (see AHledger API.lua), or nil.
function Prices.Get(itemID)
    if not AHledgerAPI or not itemID then return nil end
    return AHledgerAPI.GetPrice(itemID)
end

-- The market value: AHledger's latest median, else its 7-day median, else its lowest buyout.
function Prices.Market(itemID)
    local p = Prices.Get(itemID)
    if not p then return nil end
    return p.median or p.median7d or p.minBuyout
end

-- The lowest unit buyout known: this session's listing when read, else AHledger's.
function Prices.Lowest(itemID)
    local live = liveMin[itemID]
    if live then return live end
    local p = Prices.Get(itemID)
    return p and p.minBuyout or nil
end

-- What a stack of `itemID` should sell for per unit: the market value, but never above what it
-- is listed for right now (a seller has to match the cheapest listing).
function Prices.SellValue(itemID)
    local market, lowest = Prices.Market(itemID), Prices.Lowest(itemID)
    if market and lowest then return math.min(market, lowest) end
    return market or lowest
end

function Prices.IsSnapshot()
    local info = AHledgerAPI and AHledgerAPI.GetTableInfo and AHledgerAPI.GetTableInfo()
    return info and info.snapshot or false, info
end

------------------------------------------------------------------------
-- AHledger's scanner state
------------------------------------------------------------------------
-- AHledger exposes no scan state in its API. Its scan button (AHledgerScanButton, in the auction
-- house search bar) shows "Scanning... 12s" while it waits for the server, "Saving 31,000 /
-- 53,074" while it packs the listing, and "No reply 190s" once the server has dropped the request.
-- Only the button's text is read; nothing of AHledger's is changed.
function Data.AHledgerPhase()
    local b = _G.AHledgerScanButton
    if type(b) ~= "table" or not b.GetText then return "unknown" end
    local ok, text = pcall(b.GetText, b)
    if not ok or type(text) ~= "string" then return "unknown" end
    if text:find("^Scanning") then return "waiting" end
    if text:find("^Saving") then return "saving" end
    return "idle" -- includes "No reply": the server dropped that request
end

function Data.IsAHledgerBusy()
    local phase = Data.AHledgerPhase()
    return phase == "waiting" or phase == "saving"
end

------------------------------------------------------------------------
-- Snapshots
------------------------------------------------------------------------
-- AS.snapshot = { source = "live" | "ahledger", time, total, partial, rows }

local instant = {} -- itemID -> { classID, subClassID, equipLoc, icon }
local function Instant(itemID)
    local c = instant[itemID]
    if c then return c end
    local _, _, _, equipLoc, icon, classID, subClassID = GetItemInfoInstant(itemID)
    c = { classID = classID, subClassID = subClassID, equipLoc = equipLoc, icon = icon }
    instant[itemID] = c
    return c
end
Data.Instant = Instant

local function Wanted(row)
    for _, def in ipairs(AS.moduleList) do
        if def.wants then
            local ok, yes = pcall(def.wants, row)
            if ok and yes then return true end
        end
    end
    return false
end

local function Publish(snapshot)
    AS.snapshot = snapshot
    AS:Broadcast("onData", snapshot)
end

------------------------------------------------------------------------
-- Reading the client's full listing (the replicate list AHledger requested)
------------------------------------------------------------------------
-- The read is the one SuffixFinder 0.1 settled on after a 173,445-row listing never finished:
-- the client fires REPLICATE_ITEM_LIST_UPDATE more than once per listing, so an update for a list
-- the size of the one being read (or read under two minutes ago) is the same list and is ignored;
-- rows are read in 10 ms slices with each row isolated by pcall; and when the list is cleared under
-- the read (the house closes), what was read is kept and published as partial.
local reader       -- the read in progress
local lastRead     -- { count, at } of the last finished read
local heldCount    -- a read waiting for AHledger to finish saving the same list
local heldSince

local function ReadRow(r, i)
    local name, icon, count, quality, usable, level, _, minBid, _, buyout, bid, _, _, owner, ownerFull, _, itemID =
        C_AuctionHouse.GetReplicateItemInfo(i)
    if not itemID or itemID <= 0 then return false end
    count = (count and count > 0) and count or 1
    if buyout and buyout > 0 then
        local unit = buyout / count
        local m = r.min[itemID]
        if not m or unit < m then r.min[itemID] = unit end
    end
    local c = Instant(itemID)
    local row = {
        itemID = itemID,
        name = name,
        count = count,
        quality = quality,
        level = level or 0,
        usable = usable and true or false,
        buyout = (buyout and buyout > 0) and buyout or nil,
        bid = (bid and bid > 0 and bid) or minBid or 0,
        owner = ownerFull or owner,
        classID = c.classID,
        subClassID = c.subClassID,
        equipLoc = c.equipLoc,
        icon = icon or c.icon,
        live = true,
    }
    if not Wanted(row) then return false end
    row.link = C_AuctionHouse.GetReplicateItemLink(i)
    r.rows[#r.rows + 1] = row
    if not row.link then r.retry[#r.retry + 1] = { i, row } end
    return true
end

local function SafeReadRow(r, i)
    local ok, err = pcall(ReadRow, r, i)
    if ok then return end
    r.errors = (r.errors or 0) + 1
    if r.errors == 1 and AS.db then
        AS.db.lastError = { msg = tostring(err), row = i, at = AS.Now() }
    end
end

local function FinishRead()
    local r = reader
    reader = nil
    if not r then return end
    lastRead = { count = r.count, at = AS.Now() }
    for id, unit in pairs(r.min) do liveMin[id] = unit end
    local note = ""
    if r.cut then
        note = (" (the list went away after %d of %d rows; kept what was read)"):format(r.index, r.count)
    end
    if r.errors then
        AS.Print(("%d listing rows could not be read; first error: %s"):format(r.errors,
            tostring(AS.db and AS.db.lastError and AS.db.lastError.msg)))
    end
    if note ~= "" then AS.Print("auction listing read" .. note) end
    Publish({
        source = "live",
        time = r.time,
        total = r.count,
        read = r.index,
        partial = r.cut or nil,
        rows = r.rows,
    })
end

local Step
local function ScheduleStep(delay)
    local r = reader
    C_Timer.After(delay or 0, function()
        if reader == r then Step() end
    end)
end

-- Reads rows for about FRAME_BUDGET_MS (everything when `all`), then yields a frame.
Step = function(all)
    local r = reader
    if not r then return end
    local live = C_AuctionHouse.GetNumReplicateItems()
    if live ~= r.count then
        if live and live > 0 then
            Data.StartRead() -- a different list replaced this one
        else
            r.cut = true
            FinishRead()
        end
        return
    end
    local ok, err = pcall(function()
        if r.index < r.count then
            local deadline = (not all and clock) and (clock() + FRAME_BUDGET_MS) or nil
            local i, count = r.index, r.count
            local stop = (all or deadline) and count or math.min(count, i + ROWS_PER_FRAME)
            while i < stop do
                SafeReadRow(r, i)
                i = i + 1
                if deadline and i % 200 == 0 and clock() > deadline then break end
            end
            r.index = i
            if not all and r.index < r.count then return end
        end
        if #r.retry > 0 and r.pass < LINK_RETRIES then
            r.pass = all and LINK_RETRIES or (r.pass + 1)
            local again = r.retry
            r.retry = {}
            for _, entry in ipairs(again) do
                local link = C_AuctionHouse.GetReplicateItemLink(entry[1])
                if link then entry[2].link = link else r.retry[#r.retry + 1] = entry end
            end
        end
    end)
    if not ok then
        AS.Print("could not finish reading the auction listing: " .. tostring(err))
        if AS.db then AS.db.lastError = { msg = tostring(err), at = AS.Now() } end
        r.cut = true
        FinishRead()
        return
    end
    AS:Broadcast("onProgress", r.index, r.count)
    if r.index < r.count then
        ScheduleStep(0)
    elseif #r.retry > 0 and r.pass < LINK_RETRIES then
        ScheduleStep(1)
    else
        FinishRead()
    end
end

function Data.StartRead()
    heldCount = nil
    local count = C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems()
    if not count or count <= 0 then return end
    reader = { time = AS.Now(), count = count, index = 0, rows = {}, retry = {}, pass = 0, min = {} }
    AS:Broadcast("onProgress", 0, count)
    ScheduleStep(0)
end

-- Holds a new read back while AHledger packs the same listing (both reading 170,000 rows in the
-- same frames would double the stutter), then starts it.
local function StartWhenAHledgerIdle()
    if not heldCount then return end
    if not Data.IsAHledgerBusy() or AS.Now() - heldSince > AHLEDGER_WAIT_MAX then
        Data.StartRead()
    else
        C_Timer.After(0.5, StartWhenAHledgerIdle)
    end
end

local function OnListUpdate()
    local count = C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems()
    if not count or count <= 0 then return end
    if reader and reader.count == count then return end
    if heldCount == count then return end
    if not reader and lastRead and lastRead.count == count and AS.Now() - lastRead.at < SAME_LIST_SECONDS then
        return
    end
    AS:LoadModules()
    reader = nil
    heldCount, heldSince = count, AS.Now()
    C_Timer.After(0.2, StartWhenAHledgerIdle)
end
AS.On("REPLICATE_ITEM_LIST_UPDATE", OnListUpdate)

function Data.IsReading()
    return reader ~= nil or heldCount ~= nil
end

function Data.ReadProgress()
    if reader then return reader.index, reader.count end
    if heldCount then return 0, heldCount end
    return 0, 0
end

------------------------------------------------------------------------
-- AHledger's saved scan, for when no listing arrives this session
------------------------------------------------------------------------
-- AHledgerDB.scans[i] = { realm = GetRealmName(), faction = UnitFactionGroup("player"), ts = unix
-- seconds, count, full = true, data = "itemID:stack:buyout:bid:timeLeft;..." } (AHledger.lua
-- finishScan). Read only; a field that is missing or of the wrong type skips the scan.
function Data.LatestAHledgerScan()
    local db = _G.AHledgerDB
    if type(db) ~= "table" or type(db.scans) ~= "table" then return nil end
    local realm, faction = GetRealmName(), UnitFactionGroup("player")
    for i = #db.scans, 1, -1 do
        local s = db.scans[i]
        if type(s) == "table" and s.realm == realm and s.faction == faction and type(s.data) == "string"
            and type(s.ts) == "number" then
            return s
        end
    end
    return nil
end

local parsing -- the saved scan being parsed

local function ParseSaved(scan)
    if parsing and parsing.scan == scan then return end
    local co = coroutine.create(function()
        local rows, min, n = {}, {}, 0
        local deadline = clock and (clock() + FRAME_BUDGET_MS)
        for id, stack, buyout, bid in scan.data:gmatch("(%d+):(%d+):(%d+):(%d+):%d*") do
            id, stack, buyout, bid = tonumber(id), tonumber(stack) or 1, tonumber(buyout) or 0, tonumber(bid) or 0
            n = n + 1
            if id and id > 0 then
                if stack < 1 then stack = 1 end
                if buyout > 0 then
                    local unit = buyout / stack
                    if not min[id] or unit < min[id] then min[id] = unit end
                end
                local c = Instant(id)
                local row = {
                    itemID = id, count = stack, buyout = buyout > 0 and buyout or nil, bid = bid,
                    classID = c.classID, subClassID = c.subClassID, equipLoc = c.equipLoc, icon = c.icon,
                    level = 0, usable = true, live = false,
                }
                local ok, yes = pcall(Wanted, row)
                if ok and yes then rows[#rows + 1] = row end
            end
            if n % 200 == 0 then
                if clock then
                    if clock() > deadline then
                        coroutine.yield()
                        deadline = clock() + FRAME_BUDGET_MS
                    end
                elseif n % ROWS_PER_FRAME == 0 then
                    coroutine.yield()
                end
            end
        end
        return rows, min, n
    end)
    parsing = { scan = scan, co = co }
    local function Resume()
        if not parsing or parsing.co ~= co then return end
        local ok, rows, min, n = coroutine.resume(co)
        if not ok then
            parsing = nil
            AS.Print("could not read AHledger's saved scan: " .. tostring(rows))
            return
        end
        if coroutine.status(co) ~= "dead" then
            C_Timer.After(0, Resume)
            return
        end
        parsing = nil
        -- A live listing that arrived meanwhile wins.
        if AS.snapshot and AS.snapshot.source == "live" and AS.snapshot.time >= scan.ts then return end
        for id, unit in pairs(min) do
            if not liveMin[id] then liveMin[id] = unit end
        end
        Publish({ source = "ahledger", time = scan.ts, total = n, rows = rows })
    end
    Resume()
end

-- Makes sure the modules have something to show: AHledger's newest saved scan, unless a listing
-- read this session is at least as new.
function Data.EnsureSnapshot()
    if reader then return end
    local scan = Data.LatestAHledgerScan()
    if not scan then return end
    local snap = AS.snapshot
    if snap and snap.time and snap.time >= scan.ts then return end
    ParseSaved(scan)
end

function Data.OnAuctionHouseShow()
    -- AHledger starts its scan on this same event when its 15-minute allowance permits; the saved
    -- scan fills in meanwhile and is replaced once a full listing is read.
    C_Timer.After(0.5, Data.EnsureSnapshot)
end

function Data.OnAuctionHouseClosed()
    -- The list is still readable during this event: read what is left now rather than lose it.
    if heldCount and not reader then Data.StartRead() end
    if reader then Step(true) end
    Data.CancelSearch("the auction house closed")
end

------------------------------------------------------------------------
-- Finding one auction to buy
------------------------------------------------------------------------
-- req = { itemID, link (optional), buyout (whole listing), count, name }
-- callback(state, info):
--   "waiting"  info = text to show (AHledger scanning, server busy)
--   "searching"
--   "found"    info = { auctionID, buyout, link, quantity, exact } (exact: same suffix, price not higher)
--   "notfound" / "cancelled" (info = reason)
local search

local function ItemFields(link)
    local s = type(link) == "string" and link:match("item:([%-%d:]*)")
    if not s then return nil end
    local t, n = {}, 0
    for field in (s .. ":"):gmatch("([^:]*):") do
        n = n + 1
        t[n] = field
    end
    return t
end

-- The random suffix id of an item link (item string field 7), 0 without one.
function Data.SuffixID(link)
    local f = ItemFields(link)
    return f and tonumber(f[7]) or 0
end

local function Report(state, info)
    local s = search
    if not s then return end
    if state == "found" or state == "notfound" or state == "cancelled" then
        if state ~= "found" then search = nil end
    end
    AS.SafeCall(s.callback, state, info, s.req)
end

local function SortsByBuyout()
    local order = Enum and Enum.AuctionHouseSortOrder
    if order and order.Buyout then
        return { { sortOrder = order.Buyout, reverseSort = false } }
    end
    return {}
end

local function SendItemQuery(itemKey)
    search.sentAt = AS.Now()
    search.itemKeys[#search.itemKeys + 1] = itemKey
    C_AuctionHouse.SendSearchQuery(itemKey, SortsByBuyout(), true)
end

local function Ready()
    if C_AuctionHouse.IsThrottledMessageSystemReady then
        return C_AuctionHouse.IsThrottledMessageSystemReady()
    end
    return true
end

local function Pump(s)
    if not s or search ~= s then return end
    C_Timer.After(0.25, function() Pump(s) end)
    if not AS.ahOpen then
        Report("cancelled", "the auction house is closed")
        return
    end
    if AS.Now() - s.started > SEARCH_GIVE_UP + (s.waited or 0) then
        if s.best then
            search = nil -- the auction found stays selected; stop listening
            return
        end
        Report("notfound", "no matching auction found; it may have sold")
        return
    end
    if Data.IsAHledgerBusy() then
        s.waited = (s.waited or 0) + 0.25
        Report("waiting", "waiting for AHledger's scan to finish...")
        return
    end
    if not Ready() then
        Report("waiting", "waiting for the auction house...")
        return
    end
    if s.state == "queued" then
        s.state = "item"
        Report("searching")
        SendItemQuery(C_AuctionHouse.MakeItemKey(s.req.itemID))
    elseif s.state == "item" and not s.best and AS.Now() - s.sentAt >= SEARCH_ITEM_WAIT then
        -- Items with a random suffix can be keyed by suffix; a name search lists every variant.
        local name = s.req.name or GetItemInfo(s.req.itemID)
        if name then
            s.state = "browse"
            s.sentAt = AS.Now()
            C_AuctionHouse.SendBrowseQuery({ searchString = name, sorts = {}, filters = {} })
        end
    elseif s.state == "browse" and #s.pendingKeys > 0 then
        SendItemQuery(table.remove(s.pendingKeys, 1))
    end
end

function Data.FindAuction(req, callback)
    if search then Report("cancelled", "replaced") end
    search = { req = req, callback = callback, state = "queued", started = AS.Now(), itemKeys = {}, pendingKeys = {} }
    if not (C_AuctionHouse and C_AuctionHouse.SendSearchQuery and C_AuctionHouse.MakeItemKey) then
        Report("cancelled", "this client has no item search")
        return
    end
    Pump(search)
end

function Data.CancelSearch(reason)
    if search then Report("cancelled", reason or "cancelled") end
    search = nil
end

local function ConsiderResults(itemKey)
    local s = search
    if not s or type(itemKey) ~= "table" or itemKey.itemID ~= s.req.itemID then return end
    local n = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
    local wantSuffix = s.req.link and Data.SuffixID(s.req.link) or nil
    local unitCap = s.req.buyout and (s.req.buyout / (s.req.count or 1)) * 1.0001 or nil
    local best, bestScore
    for i = 1, n do
        local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if info and info.auctionID and info.buyoutAmount and info.buyoutAmount > 0 and not info.containsOwnerItem then
            local qty = info.quantity or 1
            local sameSuffix = (wantSuffix == nil) or (Data.SuffixID(info.itemLink) == wantSuffix)
            local exact = sameSuffix and unitCap ~= nil and (info.buyoutAmount / qty) <= unitCap
            -- Prefer the listed auction (same suffix, same price or less), then the same suffix, then cheapest.
            local score = (exact and 0 or (sameSuffix and 1 or 2)) * 1e15 + info.buyoutAmount / qty
            if not bestScore or score < bestScore then
                bestScore = score
                best = { auctionID = info.auctionID, buyout = info.buyoutAmount, link = info.itemLink,
                         quantity = qty, exact = exact, sameSuffix = sameSuffix }
            end
        end
    end
    if best and (not s.bestScore or bestScore < s.bestScore) then
        s.best, s.bestScore = best, bestScore
        Report("found", best)
    end
end

AS.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey) ConsiderResults(itemKey) end)
AS.On("ITEM_SEARCH_RESULTS_ADDED", function(itemKey) ConsiderResults(itemKey) end)
AS.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
    local s = search
    if not s or s.state ~= "browse" or not C_AuctionHouse.GetBrowseResults then return end
    for _, result in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
        local key = result.itemKey
        if key and key.itemID == s.req.itemID then
            local seen = false
            for _, k in ipairs(s.itemKeys) do
                if k.itemID == key.itemID and (k.itemSuffix or 0) == (key.itemSuffix or 0)
                    and (k.itemLevel or 0) == (key.itemLevel or 0) then seen = true end
            end
            if not seen then s.pendingKeys[#s.pendingKeys + 1] = key end
        end
    end
end)

------------------------------------------------------------------------
-- Live prices for a few items (e.g. a deal's disenchant materials)
------------------------------------------------------------------------
-- Data.QueryPrices(itemIDs, onPrice, onDone)
--   Searches the house for each item, one at a time, after the auction search above has found
--   its auction, and only while AHledger isn't scanning. onPrice(itemID, unit, quantity) is called
--   for each item (unit = nil when none are listed), onDone() after the last one.
-- Data.LivePrice(itemID) -> unit price from a search in the last LIVE_FOR seconds, or nil.
local PRICE_DEPTH = 3   -- unit price that covers this many units, so one odd cheap listing can't skew it
local PRICE_WAIT = 4    -- seconds to wait for one item's results before counting it as not listed
local LIVE_FOR = 600    -- seconds a live price is trusted
local priceQueue, priceCurrent, priceTicker = {}, nil, nil
local livePrices = {}   -- itemID -> { unit, qty, at } (unit nil: nothing listed)

function Data.LivePrice(itemID)
    local p = livePrices[itemID]
    if p and AS.Now() - p.at <= LIVE_FOR then return p.unit, p.qty, p.at end
    return nil
end

function Data.HasLivePrice(itemID)
    local p = livePrices[itemID]
    return p ~= nil and AS.Now() - p.at <= LIVE_FOR
end

local function FinishPrice(unit, qty)
    local c = priceCurrent
    if not c then return end
    priceCurrent = nil
    livePrices[c.itemID] = { unit = unit, qty = qty or 0, at = AS.Now() }
    AS.SafeCall(c.job.onPrice, c.itemID, unit, qty or 0)
    c.job.left = c.job.left - 1
    if c.job.left <= 0 then AS.SafeCall(c.job.onDone) end
end

-- Cheapest unit price covering PRICE_DEPTH units from a list of { unit, qty }.
local function DepthPrice(listings)
    table.sort(listings, function(a, b) return a[1] < b[1] end)
    local seen, total = 0, 0
    for _, l in ipairs(listings) do total = total + l[2] end
    local need = math.min(PRICE_DEPTH, total)
    for _, l in ipairs(listings) do
        seen = seen + l[2]
        if seen >= need then return math.floor(l[1]), total end
    end
    return nil, 0
end

local function PricePump()
    if priceCurrent then
        if GetTime() - priceCurrent.sentAt > PRICE_WAIT then FinishPrice(nil, 0) end
        return
    end
    if #priceQueue == 0 then
        if priceTicker then priceTicker:Cancel(); priceTicker = nil end
        return
    end
    if not AS.ahOpen then
        wipe(priceQueue)
        return
    end
    if search and not search.best then return end -- the deal's own auction is looked up first
    if Data.IsAHledgerBusy() or not Ready() then return end
    local nextItem = table.remove(priceQueue, 1)
    priceCurrent = { itemID = nextItem.itemID, job = nextItem.job, sentAt = GetTime() }
    C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(nextItem.itemID), SortsByBuyout(), true)
end

function Data.QueryPrices(itemIDs, onPrice, onDone)
    if not (C_AuctionHouse and C_AuctionHouse.SendSearchQuery and C_AuctionHouse.MakeItemKey) or not AS.ahOpen then
        AS.SafeCall(onDone)
        return false
    end
    -- A new request replaces whatever was still waiting from an earlier click.
    wipe(priceQueue)
    local job = { onPrice = onPrice, onDone = onDone, left = 0 }
    for _, id in ipairs(itemIDs) do
        job.left = job.left + 1
        priceQueue[#priceQueue + 1] = { itemID = id, job = job }
    end
    if job.left == 0 then AS.SafeCall(onDone) return true end
    if not priceTicker then priceTicker = C_Timer.NewTicker(0.25, PricePump) end
    PricePump()
    return true
end

-- Stackable materials come back as commodity results, everything else as item results.
AS.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    local c = priceCurrent
    if not c or itemID ~= c.itemID or not C_AuctionHouse.GetNumCommoditySearchResults then return end
    local listings = {}
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and r.unitPrice > 0 and (r.quantity or 0) > 0 and not r.containsOwnerItem then
            listings[#listings + 1] = { r.unitPrice, r.quantity }
        end
    end
    FinishPrice(DepthPrice(listings))
end)

AS.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    local c = priceCurrent
    if not c or type(itemKey) ~= "table" or itemKey.itemID ~= c.itemID then return end
    local listings = {}
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount and r.buyoutAmount > 0 and not r.containsOwnerItem then
            local qty = r.quantity or 1
            listings[#listings + 1] = { r.buyoutAmount / qty, qty }
        end
    end
    FinishPrice(DepthPrice(listings))
end)

------------------------------------------------------------------------
-- Buying (only from a click: PlaceBid needs a hardware event)
------------------------------------------------------------------------
local pendingBuy

function Data.Buy(found)
    if not found or not found.auctionID then return false end
    if not AS.ahOpen then
        AS.Print("open the auction house first")
        return false
    end
    if GetMoney() < found.buyout then
        AS.Print("not enough money for that auction")
        return false
    end
    pendingBuy = { auctionID = found.auctionID, at = AS.Now() }
    C_AuctionHouse.PlaceBid(found.auctionID, found.buyout)
    search = nil
    return true
end

local function PurchaseDone(auctionID)
    if pendingBuy and (auctionID == nil or auctionID == pendingBuy.auctionID) then
        local id = pendingBuy.auctionID
        pendingBuy = nil
        AS:Broadcast("onPurchase", id)
    end
end
AS.On("AUCTION_HOUSE_PURCHASE_COMPLETED", PurchaseDone)
AS.On("AUCTION_HOUSE_AUCTION_WON", PurchaseDone) -- not every build has both

------------------------------------------------------------------------
-- /asuite status
------------------------------------------------------------------------
function Data.PrintStatus()
    local api = AHledgerAPI and ("AHledger " .. tostring(AHledgerAPI.GetAddonVersion())) or "AHledgerAPI missing"
    local snap, info = Prices.IsSnapshot()
    AS.Print(("prices: %s, market %s, table %s%s"):format(api,
        tostring(info and info.market), info and AS.TimeAgo(info.updated) or "none",
        snap and " (shipped snapshot)" or ""))
    AS.Print(("AHledger scanner: %s"):format(Data.AHledgerPhase()))
    local live = C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
    local done, total = Data.ReadProgress()
    AS.Print(("listing rows on the client: %d | reading: %s"):format(live or 0,
        Data.IsReading() and ("%d / %d"):format(done, total) or "no"))
    local s = AS.snapshot
    if s then
        AS.Print(("data: %s, %s, %d rows kept of %d%s"):format(
            s.source == "live" and "listing read this session" or "AHledger's saved scan",
            AS.TimeAgo(s.time), #s.rows, s.total or 0, s.partial and " (partial)" or ""))
    else
        AS.Print("data: none yet (open the auction house)")
    end
    local mods = {}
    for _, def in ipairs(AS.moduleList) do mods[#mods + 1] = def.title end
    AS.Print("modules: " .. (#mods > 0 and table.concat(mods, ", ") or "none loaded"))
    local e = AS.db and AS.db.lastError
    if e then AS.Print(("last read error (%s): %s"):format(AS.TimeAgo(e.at), tostring(e.msg))) end
end
