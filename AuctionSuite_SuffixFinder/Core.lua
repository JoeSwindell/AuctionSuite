-- AuctionSuite_SuffixFinder: the SuffixFinder addon as an AuctionSuite module. Browse auction
-- house weapons and armor by random suffix ("of the Tiger") with slot, type, level and price filters.
--
-- Ported from SuffixFinder 0.1. What changed:
--   * the full listing is read by the AuctionSuite core, the same way SuffixFinder 0.1 read it:
--     repeat list updates for the same list are ignored, rows are read in 10 ms slices with a pcall
--     each, and what was read is kept if the list is cleared. This module keeps the rows with a
--     suffix and saves them, partial reads included.
--   * the module never asks for a full listing (no ReplicateItems): AHledger does that on open.
--   * the window is a page in the AuctionSuite window; saved data is AuctionSuite_SuffixFinderDB.
local ADDON, ns = ...
local AS = AuctionSuite

local SF = {}
ns.SF = SF

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemStats = (C_Item and C_Item.GetItemStats) or GetItemStats

local CLASS_WEAPON, CLASS_ARMOR = 2, 4
local MAX_MARKETS = 4           -- realm+faction scans kept in saved variables
local RESOLVE_PASSES = 3        -- re-tries for items whose base name was not cached yet

-- Presets a new install starts with; the player can apply, overwrite or delete them like their own.
local STARTER_PRESETS = {
    ["Ret Paladin"] = { suffixes = { "of the Tiger", "of Strength", "of the Bear", "of Power", "of the Beast", "of the Gorilla", "of the Knight" } },
    ["Tank"] = { suffixes = { "of the Bear", "of Stamina", "of Defense", "of the Champion", "of the Defender", "of the Knight", "of the Monkey" } },
    ["Healer"] = { suffixes = { "of Healing", "of the Physician", "of the Prophet", "of the Hierophant", "of the Eagle", "of the Owl", "of Intellect" } },
    ["Caster DPS"] = { suffixes = { "of Magic", "of the Sorcerer", "of the Elder", "of the Channeler", "of the Eagle", "of Intellect" } },
    ["Agility DPS"] = { suffixes = { "of the Monkey", "of the Tiger", "of Agility", "of the Falcon", "of the Wolf", "of the Bandit", "of Power" } },
}

-- Suffix names, used only to recognize a suffix while an item's base name is still uncached.
local KNOWN = {}
for _, s in ipairs({
    "Agility", "Arcane Protection", "Arcane Wrath", "the Bandit", "the Bear", "the Beast", "Blocking", "the Boar",
    "the Champion", "the Channeler", "Concentration", "Defense", "the Defender", "the Eagle", "the Elder",
    "the Falcon", "Fiery Wrath", "Fire Protection", "Frost Protection", "Frozen Wrath", "the Gorilla", "Healing",
    "the Hierophant", "Holy Wrath", "Intellect", "the Invoker", "the Knight", "Magic", "Marksmanship",
    "the Monkey", "Nature Protection", "Nature's Wrath", "the Owl", "the Physician", "Power", "the Prophet",
    "Regeneration", "Shadow Protection", "Shadow Wrath", "the Soldier", "the Sorcerer", "Sorcery", "Spirit",
    "Stamina", "Strength", "the Tiger", "the Whale", "the Wolf",
}) do KNOWN["of " .. s] = true end
SF.KNOWN = KNOWN

------------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------------
function SF.Print(...)
    print("|cffe6cc80AuctionSuite|r |cffffd200Suffix Finder|r:", ...)
end

function SF.Market()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or "?"
    return realm .. "-" .. (UnitFactionGroup("player") or "?")
end

SF.Now = AS.Now
SF.TimeAgo = AS.TimeAgo
SF.SuffixID = AS.Data.SuffixID

function SF.DisplayName(link)
    return type(link) == "string" and link:match("|h%[(.-)%]|h") or nil
end

-- The suffix text of a linked item ("of the Tiger"), or nil when it has none.
-- base is the item's base name when known (nil while the item is uncached).
-- Returns suffix, settled: settled is false when the answer may change once the base name loads.
-- Without a base name, a known suffix name is trusted only when `final` (the last try), since a
-- base name can itself end in one ("Robe of Power").
function SF.SuffixOf(link, base, final)
    local full = SF.DisplayName(link)
    if not full or full == "" then return nil, false end
    if base and base ~= "" then
        if base == full then return nil, true end
        if full:sub(1, #base + 1) == base .. " " then
            local rest = full:sub(#base + 2)
            if rest:find("^of ") then return rest, true end
        end
    end
    -- Last " of " in the name: "Overlord's Chestplate of the Tiger" -> "of the Tiger".
    local tail = full:match(".* (of .+)$")
    if not tail then return nil, base ~= nil end
    if SF.SuffixID(link) ~= 0 then return tail, true end
    if base then return nil, true end
    if final and KNOWN[tail] then return tail, true end
    return nil, false
end

------------------------------------------------------------------------
-- Stats text ("+15 Str +15 Agi") from the item link, cached per link
------------------------------------------------------------------------
local STAT_ABBR = {
    { "STRENGTH", "Str" }, { "AGILITY", "Agi" }, { "STAMINA", "Sta" }, { "INTELLECT", "Int" },
    { "SPIRIT", "Spi" }, { "RANGED_ATTACK_POWER", "RAP" }, { "ATTACK_POWER", "AP" },
    { "SPELL_HEALING", "Heal" }, { "HEALING", "Heal" }, { "SPELL_DAMAGE", "SpellDmg" },
    { "SPELL_POWER", "SP" }, { "DEFENSE", "Def" }, { "EXPERTISE", "Exp" }, { "HIT", "Hit" },
    { "CRIT", "Crit" }, { "BLOCK", "Block" }, { "DODGE", "Dodge" }, { "PARRY", "Parry" },
    { "MANA_REGENERATION", "MP5" }, { "HEALTH_REGEN", "HP5" },
    { "RESISTANCE1", "HolyRes" }, { "RESISTANCE2", "FireRes" }, { "RESISTANCE3", "NatRes" },
    { "RESISTANCE4", "FrostRes" }, { "RESISTANCE5", "ShadowRes" }, { "RESISTANCE6", "ArcRes" },
}
local SKIP_STAT = { RESISTANCE0_NAME = true, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = true }

local function Abbrev(key)
    for _, pair in ipairs(STAT_ABBR) do
        if key:find(pair[1], 1, true) then return pair[2] end
    end
    local label = _G[key]
    if type(label) == "string" and label ~= "" then return label end
    return (key:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):lower())
end

local statCache = {}
function SF.StatsText(link)
    if statCache[link] then return statCache[link] end
    if not GetItemStats then return "" end
    local ok, stats = pcall(GetItemStats, link)
    if not ok or type(stats) ~= "table" then return nil end
    local parts = {}
    for key, value in pairs(stats) do
        if not SKIP_STAT[key] and not key:find("SOCKET", 1, true) and type(value) == "number" and value ~= 0 then
            parts[#parts + 1] = { Abbrev(key), value }
        end
    end
    if #parts == 0 then return nil end -- not cached yet, most likely
    table.sort(parts, function(a, b) return a[1] < b[1] end)
    local out = {}
    for i, p in ipairs(parts) do out[i] = ("+%d %s"):format(p[2], p[1]) end
    statCache[link] = table.concat(out, " ")
    return statCache[link]
end

------------------------------------------------------------------------
-- Saved data
------------------------------------------------------------------------
local DEFAULT_FILTERS = {
    suffixes = {},   -- [suffix] = true; empty means all
    slots = {},      -- [slot label] = true; empty means all
    types = {},      -- [type key] = true; empty means all
    minLevel = nil,
    maxLevel = nil,
    maxPrice = nil,  -- copper
    usable = true,
    text = "",
    sortKey = "price",
    sortAsc = true,
}

local CopyDefaults = AS.CopyDefaults

function SF.ResetFilters()
    AuctionSuite_SuffixFinderDB.filters = CopyDefaults({}, DEFAULT_FILTERS)
    SF.filters = AuctionSuite_SuffixFinderDB.filters
end

------------------------------------------------------------------------
-- Presets: named snapshots of the filters (not the name search or sort order)
------------------------------------------------------------------------
local PRESET_FIELDS = { "suffixes", "slots", "types", "minLevel", "maxLevel", "maxPrice", "usable" }

local function CopySet(set)
    local out = {}
    for k, v in pairs(set or {}) do out[k] = v end
    return out
end

function SF.PresetNames()
    local names = {}
    for name in pairs(AuctionSuite_SuffixFinderDB.presets) do names[#names + 1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function SF.SavePreset(name)
    name = strtrim(name or "")
    if name == "" then return false end
    local f, p = SF.filters, {}
    for _, k in ipairs(PRESET_FIELDS) do
        p[k] = type(f[k]) == "table" and CopySet(f[k]) or f[k]
    end
    AuctionSuite_SuffixFinderDB.presets[name] = p
    return true
end

function SF.ApplyPreset(name)
    local p = AuctionSuite_SuffixFinderDB.presets[name]
    if not p then return false end
    local f = SF.filters
    for _, k in ipairs(PRESET_FIELDS) do
        if type(DEFAULT_FILTERS[k]) == "table" then
            f[k] = CopySet(p[k])
        elseif p[k] ~= nil then
            f[k] = p[k]
        else
            f[k] = DEFAULT_FILTERS[k]
        end
    end
    return true
end

function SF.DeletePreset(name)
    AuctionSuite_SuffixFinderDB.presets[name] = nil
end

-- Which preset the current filters match exactly, if any.
function SF.ActivePreset()
    local f = SF.filters
    local function same(a, b)
        if type(a) == "table" or type(b) == "table" then
            a, b = a or {}, b or {}
            for k in pairs(a) do if not b[k] then return false end end
            for k in pairs(b) do if not a[k] then return false end end
            return true
        end
        return a == b
    end
    for _, name in ipairs(SF.PresetNames()) do
        local p, match = AuctionSuite_SuffixFinderDB.presets[name], true
        for _, k in ipairs(PRESET_FIELDS) do
            local pv = p[k]
            if pv == nil then pv = DEFAULT_FILTERS[k] end
            if not same(f[k], pv) then match = false break end
        end
        if match then return name end
    end
end

local function InitDB()
    AuctionSuite_SuffixFinderDB = AuctionSuite_SuffixFinderDB or {}
    local db = AuctionSuite_SuffixFinderDB
    db.scans = db.scans or {}
    db.filters = CopyDefaults(db.filters or {}, DEFAULT_FILTERS)
    if not db.presets then
        db.presets = {}
        for name, p in pairs(STARTER_PRESETS) do
            local set = {}
            for _, s in ipairs(p.suffixes) do set[s] = true end
            db.presets[name] = { suffixes = set, usable = true }
        end
    end
    SF.filters = db.filters
end

-- Loads the newest saved scan for this realm and faction.
local function LoadScan()
    local scan = AuctionSuite_SuffixFinderDB.scans[SF.Market()]
    SF.items = scan and scan.items or {}
    SF.scanTime = scan and scan.time
    SF.scanTotal = scan and scan.total
    SF.scanPartial = scan and scan.partial
end

local function SaveScan(r)
    local scans = AuctionSuite_SuffixFinderDB.scans
    scans[r.market] = { time = r.time, total = r.count, partial = r.partial or nil, items = r.items }
    local keys = {}
    for k in pairs(scans) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return (scans[a].time or 0) > (scans[b].time or 0) end)
    for i = MAX_MARKETS + 1, #keys do scans[keys[i]] = nil end
end

------------------------------------------------------------------------
-- Turning the core's listing rows into suffix items
------------------------------------------------------------------------
local building -- { market, time, count, partial, cut, items, pending, pass }

local function Notify()
    if SF.OnData then SF.OnData() end
end

-- Returns true when the row should be looked at again (its base name was not cached yet).
local function TryRow(b, row, final)
    local base = GetItemInfo(row.itemID) -- base name for a bare id; nil until cached (and starts the load)
    local suffix, settled = SF.SuffixOf(row.link, base, final)
    if not suffix then return not settled end
    local minLevel = select(5, GetItemInfo(row.link))
    b.items[#b.items + 1] = {
        link = row.link,
        itemID = row.itemID,
        icon = row.icon,
        quality = row.quality,
        suffix = suffix,
        equipLoc = row.equipLoc,
        classID = row.classID,
        subClassID = row.subClassID,
        level = (minLevel and minLevel > 0 and minLevel) or row.level or 0,
        usable = row.usable and true or false,
        count = row.count or 1,
        buyout = row.buyout,
        bid = row.bid or 0,
    }
    return false
end

-- One odd row must not throw away a 170,000-row read.
local function SafeTry(b, row, final)
    local ok, again = pcall(TryRow, b, row, final)
    if ok then return again end
    b.errors = (b.errors or 0) + 1
    if b.errors == 1 then
        AuctionSuite_SuffixFinderDB.lastError = { msg = tostring(again), at = SF.Now() }
    end
    return false
end

local function FinishBuild()
    local b = building
    building = nil
    if not b then return end
    b.partial = b.partial or (#b.pending > 0) or nil
    local old = AuctionSuite_SuffixFinderDB.scans[b.market]
    if b.partial and #b.items == 0 and old and old.items and #old.items > 0 then
        -- An empty partial read (the house closed at once) would only replace a good scan with nothing.
        SF.Print(("the listing went away before any suffix items were read; kept the scan from %s."):format(SF.TimeAgo(old.time)))
        Notify()
        return
    end
    SaveScan(b)
    LoadScan()
    local note = ""
    if b.cut then
        note = (" (the list went away after %d of %d rows; saved what was read)"):format(b.read or 0, b.count)
    elseif #b.pending > 0 then
        note = (" (%d items had not loaded)"):format(#b.pending)
    end
    SF.Print(("%d suffix items in %d listings%s."):format(#b.items, b.count, note))
    if b.errors then
        SF.Print(("%d rows could not be read; first error: %s"):format(b.errors,
            tostring(AuctionSuite_SuffixFinderDB.lastError and AuctionSuite_SuffixFinderDB.lastError.msg)))
    end
    Notify()
end

local function ResolvePending()
    local b = building
    if not b then return end
    b.pass = b.pass + 1
    local final = b.pass >= RESOLVE_PASSES
    local again = b.pending
    b.pending = {}
    for _, row in ipairs(again) do
        if SafeTry(b, row, final) then b.pending[#b.pending + 1] = row end
    end
    if #b.pending == 0 or final then
        FinishBuild()
    else
        C_Timer.After(1, function() if building == b then ResolvePending() end end)
    end
end

-- Weapons and armor of uncommon quality or better, from a listing read this session (AHledger's
-- saved scans carry no item links, so no suffix).
function SF.Wants(row)
    if not row.live then return false end
    if row.quality and row.quality < 2 then return false end
    return row.classID == CLASS_WEAPON or row.classID == CLASS_ARMOR
end

-- A listing the core read this session. The saved suffix scan stays until one arrives.
function SF.OnSnapshot(snapshot)
    if type(snapshot) ~= "table" or snapshot.source ~= "live" then return end
    if SF.lastSnapshot == snapshot then return end
    SF.lastSnapshot = snapshot
    local b = {
        market = SF.Market(), time = snapshot.time, count = snapshot.total or 0, read = snapshot.read,
        partial = snapshot.partial, cut = snapshot.partial, items = {}, pending = {}, pass = 0,
    }
    building = b
    for _, row in ipairs(snapshot.rows) do
        if row.link and SF.Wants(row) then
            if SafeTry(b, row, false) then b.pending[#b.pending + 1] = row end
        end
    end
    if #b.pending == 0 then
        FinishBuild()
    else
        if SF.OnProgress then SF.OnProgress() end
        C_Timer.After(1, function() if building == b then ResolvePending() end end)
    end
end

function SF.IsReading()
    return AS.Data.IsReading() or building ~= nil
end

function SF.ReadProgress()
    return AS.Data.ReadProgress()
end

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    InitDB()
    LoadScan()
    AS:RegisterModule({
        name = "SuffixFinder",
        title = "Suffix Finder",
        icon = "Interface\\Icons\\INV_Sword_39",
        order = 10,
        wants = SF.Wants,
        createPanel = function(page) SF.CreatePanel(page) end,
        onData = SF.OnSnapshot,
        onProgress = function() if SF.OnProgress then SF.OnProgress() end end,
        onItemInfo = function() if SF.OnItemInfo then SF.OnItemInfo() end end,
        onShow = function() if SF.Refresh then SF.Refresh() end end,
        onPurchase = function(auctionID) if SF.OnPurchase then SF.OnPurchase(auctionID) end end,
    })
end)

------------------------------------------------------------------------
-- Slash commands (/asf; the standalone SuffixFinder keeps /sf)
------------------------------------------------------------------------
SLASH_AUCTIONSUITESF1 = "/asf"
SlashCmdList.AUCTIONSUITESF = function(msg)
    msg = strtrim((msg or ""):lower())
    if msg == "reset" then
        SF.ResetFilters()
        if SF.FillBoxes then SF.FillBoxes() end
        Notify()
        SF.Print("filters reset")
    elseif msg == "status" then
        local done, total = SF.ReadProgress()
        SF.Print(("reading the listing: %s"):format(SF.IsReading() and ("%d / %d"):format(done, total) or "no"))
        SF.Print(("saved scan for %s: %s, %d suffix items in %s listings%s"):format(SF.Market(),
            SF.TimeAgo(SF.scanTime), #(SF.items or {}), tostring(SF.scanTotal or 0), SF.scanPartial and " (partial)" or ""))
        local e = AuctionSuite_SuffixFinderDB.lastError
        if e then SF.Print(("last read error (%s): %s"):format(SF.TimeAgo(e.at), tostring(e.msg))) end
    elseif msg == "help" then
        SF.Print("/asf - open the Suffix Finder page | /asf status - what was read | /asf reset - clear filters")
    else
        AS.Data.EnsureSnapshot()
        AS.UI.Show()
        AS.UI.ShowPage("SuffixFinder")
    end
end
