-- AuctionSuite core: the module registry, saved settings, events, loading the modules when the
-- auction house opens, and slash commands.
--
-- AuctionSuite depends on AHledger and stays out of its way:
--   * prices come from AHledgerAPI (AHledger's public, read-only API); there is no second price store
--   * the suite never calls C_AuctionHouse.ReplicateItems: it reads the full listing AHledger asks for
--     when the house opens, or AHledger's newest saved scan when no listing arrives (Data.lua)
--   * targeted item searches (clicking a row to buy) wait while AHledger's scan is running
--   * no tooltip hooks at all, so AHledger's price block is never repeated
--   * every global, frame and saved variable starts with "AuctionSuite"
local ADDON, ns = ...

local AS = {}
ns.AS = AS
AuctionSuite = AS -- the one global the core defines; modules reach the core through it

AS.VERSION = "0.2.2"
AS.ADDON = ADDON
AS.modules = {}      -- name -> module definition
AS.moduleList = {}   -- definitions sorted by order, then title
AS.ahOpen = false

local LoadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local GetNumAddOns = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
local GetAddOnInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

------------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------------
function AS.Print(...)
    print("|cffe6cc80AuctionSuite|r:", ...)
end

function AS.Now()
    return (GetServerTime and GetServerTime()) or time()
end

function AS.TimeAgo(t)
    if not t then return "never" end
    local d = math.max(0, AS.Now() - t)
    if d < 60 then return "just now" end
    if d < 3600 then return ("%d min ago"):format(d / 60) end
    if d < 86400 then return ("%d h ago"):format(d / 3600) end
    return ("%d days ago"):format(d / 86400)
end

-- Runs a module callback; an error in one module goes to the error handler and never stops the
-- core or the other modules.
function AS.SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = xpcall(fn, function(err)
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(err) end
        return err
    end, ...)
    if ok then return a, b end
    return nil
end

function AS.CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = type(v) == "table" and AS.CopyDefaults({}, v) or v
        end
    end
    return dst
end

-- Forever characters have surnames, and UnitName returns them as a second value. A listing's
-- owner can come back as either form, so both count as the player.
function AS.IsMine(owner)
    if type(owner) ~= "string" or owner == "" then return false end
    local first, surname = UnitName("player")
    if not first then return false end
    if owner == first then return true end
    if surname and surname ~= "" and owner == (first .. " " .. surname) then return true end
    local short = owner:match("^([^%-]+)%-") -- "Name-Realm"
    return short == first or (surname and short == (first .. " " .. surname)) or false
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local DEFAULTS = {
    autoOpen = true,   -- open the AuctionSuite window with the auction house
    page = nil,        -- the module page shown last
    pos = nil,         -- { point, x, y } once the window has been dragged off the auction house
}

local function InitDB()
    AuctionSuiteDB = AuctionSuiteDB or {}
    AS.db = AS.CopyDefaults(AuctionSuiteDB, DEFAULTS)
end

------------------------------------------------------------------------
-- Module registry
------------------------------------------------------------------------
-- AuctionSuite:RegisterModule(def). See README.md for the full contract. Fields:
--   name        unique key (string, required)
--   title       tab label (required)
--   icon        texture path for the window portrait while the page shows
--   order       tab position (lower first, default 100)
--   wants(row)  keep this listing row when the full listing is read (see Data.lua for the row)
--   createPanel(page)       build the module's UI into `page`, once, the first time it shows
--   onData(snapshot)        new listing data (also called on registration if data exists)
--   onProgress(done, total) the full listing is being read
--   onItemInfo()            item data arrived from the server (throttled to twice a second)
--   onShow(page) / onHide(page)
--   onPurchase(auctionID)   an auction bought through AuctionSuite:Buy completed
function AS:RegisterModule(def)
    if type(def) ~= "table" or type(def.name) ~= "string" or def.name == "" then
        error("AuctionSuite:RegisterModule: def.name must be a non-empty string", 2)
    end
    if type(def.title) ~= "string" then
        error("AuctionSuite:RegisterModule: def.title must be a string", 2)
    end
    if self.modules[def.name] then
        error("AuctionSuite:RegisterModule: a module named " .. def.name .. " is already registered", 2)
    end
    def.order = tonumber(def.order) or 100
    self.modules[def.name] = def
    local list = self.moduleList
    list[#list + 1] = def
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.title < b.title
    end)
    if self.UI and self.UI.OnModuleRegistered then self.UI.OnModuleRegistered(def) end
    if self.snapshot then
        C_Timer.After(0, function() AS.SafeCall(def.onData, AS.snapshot) end)
    end
    return def
end

function AS:GetModule(name)
    return self.modules[name]
end

-- Calls `method` on every registered module.
function AS:Broadcast(method, ...)
    for _, def in ipairs(self.moduleList) do
        if def[method] then AS.SafeCall(def[method], ...) end
    end
end

-- Loads every installed, enabled module addon (load on demand, X-AuctionSuite-Module in its toc).
local moduleAddonsLoaded = false
function AS:LoadModules()
    if moduleAddonsLoaded or not GetNumAddOns then return end
    moduleAddonsLoaded = true
    for i = 1, GetNumAddOns() do
        local name, _, _, loadable, reason = GetAddOnInfo(i)
        if type(name) == "string" and name ~= ADDON then
            local tag = GetAddOnMetadata and GetAddOnMetadata(name, "X-AuctionSuite-Module")
            if tag and not IsAddOnLoaded(name) and reason ~= "DISABLED" and reason ~= "MISSING" then
                local ok, loaded, why = pcall(LoadAddOn, name)
                if not ok then
                    AS.Print(("could not load %s: %s"):format(name, tostring(loaded)))
                elseif not loaded and why ~= "DISABLED" then
                    AS.Print(("could not load %s (%s)"):format(name, tostring(why)))
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local events = CreateFrame("Frame")
AS.eventFrame = events
local handlers = {}

-- Registers a core event handler. Unknown events (another client build) are skipped, not fatal.
function AS.On(event, fn)
    if not handlers[event] then
        if not pcall(events.RegisterEvent, events, event) then return false end
        handlers[event] = {}
    end
    table.insert(handlers[event], fn)
    return true
end

events:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do AS.SafeCall(fn, ...) end
end)

local SUITE = { AuctionSuite = true, AuctionSuite_SuffixFinder = true, AuctionSuite_Disenchant = true,
    AuctionSuite_VendorDeals = true }

local function OnBlocked(event)
    return function(addonName, func)
        if not SUITE[addonName] then return end
        AS.Print(("the game blocked %s from calling |cffffd200%s|r (%s). Please report this."):format(
            tostring(addonName), tostring(func), event))
        if AS.db then AS.db.blocked = { addon = addonName, fn = tostring(func), event = event, at = AS.Now() } end
    end
end
AS.On("ADDON_ACTION_FORBIDDEN", OnBlocked("ADDON_ACTION_FORBIDDEN"))
AS.On("ADDON_ACTION_BLOCKED", OnBlocked("ADDON_ACTION_BLOCKED"))

AS.On("ADDON_LOADED", function(name)
    if name == ADDON then
        InitDB()
        if IsAddOnLoaded("Blizzard_AuctionHouseUI") and AS.UI then AS.UI.HookAuctionHouse() end
    elseif name == "Blizzard_AuctionHouseUI" and AS.UI then
        AS.UI.HookAuctionHouse()
    end
end)

AS.On("PLAYER_LOGIN", function()
    if not AHledgerAPI then
        AS.Print("AHledger's API (AHledgerAPI) is missing; prices are unavailable. Update AHledger.")
    end
end)

AS.On("AUCTION_HOUSE_SHOW", function()
    AS.ahOpen = true
    AS:LoadModules()
    if AS.Data then AS.Data.OnAuctionHouseShow() end
    -- Next frame: the auction house UI may load and show in response to this same event.
    C_Timer.After(0, function()
        if AS.ahOpen and AS.UI then AS.UI.OnAuctionHouseShow() end
    end)
end)

AS.On("AUCTION_HOUSE_CLOSED", function()
    if AS.Data then AS.Data.OnAuctionHouseClosed() end
    AS.ahOpen = false
    if AS.UI then AS.UI.OnAuctionHouseClosed() end
end)

local itemInfoPending = false
AS.On("GET_ITEM_INFO_RECEIVED", function()
    if itemInfoPending then return end
    itemInfoPending = true
    C_Timer.After(0.5, function()
        itemInfoPending = false
        AS:Broadcast("onItemInfo")
    end)
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
SLASH_AUCTIONSUITE1 = "/asuite"
SLASH_AUCTIONSUITE2 = "/auctionsuite"
SlashCmdList.AUCTIONSUITE = function(msg)
    msg = strtrim((msg or ""):lower())
    if msg == "auto" then
        AS.db.autoOpen = not AS.db.autoOpen
        AS.Print("open with the auction house: " .. (AS.db.autoOpen and "on" or "off"))
    elseif msg == "status" then
        AS.Data.PrintStatus()
    elseif msg == "reset" then
        AS.db.pos = nil
        if AS.UI then AS.UI.Dock() end
        AS.Print("window docked to the auction house again")
    elseif msg == "help" then
        AS.Print("/asuite - toggle the window | /asuite status - data sources | /asuite auto - toggle opening with the auction house | /asuite reset - dock the window again")
    else
        AS:LoadModules()
        AS.Data.EnsureSnapshot()
        AS.UI.Toggle()
    end
end
