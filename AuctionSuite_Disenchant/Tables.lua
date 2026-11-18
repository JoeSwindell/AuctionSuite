-- AuctionSuite_Disenchant: disenchanting tables for World of Warcraft: Forever (vanilla rules).
--
-- Sources (checked November 2026):
--   * Warcraft Wiki, "Disenchanting tables" (warcraft.wiki.gg/wiki/Disenchanting_tables): uncommon
--     armor and weapon brackets by item level with chances and quantities, rare and epic results.
--   * wow-professions.com, "WoW Forever Disenchanting Guide": the same tiers keyed by required level
--     (item level - 5 for greens), the 75/20 armor and 20/75 weapon split, rare 100% shard with a
--     ~0.5% Nexus Crystal, epics 100% shard (level 50 and under) or crystal; any Enchanting skill can
--     disenchant anything on Forever.
--   * AHledger 0.15.0's own estimate (Options.lua), which uses the same brackets.
-- Brackets are by item level, the game's actual key; required level + 5 is the fallback when an
-- item's level is not known yet.
local _, ns = ...

local T = {}
ns.Tables = T

-- Materials ----------------------------------------------------------------------------------
local STRANGE, SOUL, VISION, DREAM, ILLUSION = 10940, 11083, 11137, 11176, 16204
local LMAGIC, GMAGIC = 10938, 10939
local LASTRAL, GASTRAL = 10998, 11082
local LMYSTIC, GMYSTIC = 11134, 11135
local LNETHER, GNETHER = 11174, 11175
local LETERNAL, GETERNAL = 16202, 16203
local SGLIMMER, LGLIMMER = 10978, 11084
local SGLOW, LGLOW = 11138, 11139
local SRADIANT, LRADIANT = 11177, 11178
local SBRILLIANT, LBRILLIANT = 14343, 14344
local NEXUS = 20725

-- Short names for the deals list, and English names while the client has not cached the item.
T.NAMES = {
    [STRANGE] = { "Strange Dust", "Strange" }, [SOUL] = { "Soul Dust", "Soul" },
    [VISION] = { "Vision Dust", "Vision" }, [DREAM] = { "Dream Dust", "Dream" },
    [ILLUSION] = { "Illusion Dust", "Illusion" },
    [LMAGIC] = { "Lesser Magic Essence", "LMagic" }, [GMAGIC] = { "Greater Magic Essence", "GMagic" },
    [LASTRAL] = { "Lesser Astral Essence", "LAstral" }, [GASTRAL] = { "Greater Astral Essence", "GAstral" },
    [LMYSTIC] = { "Lesser Mystic Essence", "LMystic" }, [GMYSTIC] = { "Greater Mystic Essence", "GMystic" },
    [LNETHER] = { "Lesser Nether Essence", "LNether" }, [GNETHER] = { "Greater Nether Essence", "GNether" },
    [LETERNAL] = { "Lesser Eternal Essence", "LEternal" }, [GETERNAL] = { "Greater Eternal Essence", "GEternal" },
    [SGLIMMER] = { "Small Glimmering Shard", "SGlimmer" }, [LGLIMMER] = { "Large Glimmering Shard", "LGlimmer" },
    [SGLOW] = { "Small Glowing Shard", "SGlowing" }, [LGLOW] = { "Large Glowing Shard", "LGlowing" },
    [SRADIANT] = { "Small Radiant Shard", "SRadiant" }, [LRADIANT] = { "Large Radiant Shard", "LRadiant" },
    [SBRILLIANT] = { "Small Brilliant Shard", "SBrilliant" }, [LBRILLIANT] = { "Large Brilliant Shard", "LBrilliant" },
    [NEXUS] = { "Nexus Crystal", "Nexus" },
}

-- Three lesser essences combine into a greater one and back, so each is worth at least a third
-- (or three times) the other.
T.ESSENCE_PAIRS = {
    { LMAGIC, GMAGIC }, { LASTRAL, GASTRAL }, { LMYSTIC, GMYSTIC }, { LNETHER, GNETHER }, { LETERNAL, GETERNAL },
}

-- Uncommon (green) brackets --------------------------------------------------------------------
-- from item level, dust { id, min, max }, essence { id, min, max }, shard id or nil,
-- armor chances { dust, essence, shard }, weapon chances { dust, essence, shard }
local UNCOMMON = {
    { 5,  { STRANGE, 1, 2 },  { LMAGIC, 1, 2 },   nil,        { 0.80, 0.20, 0 },    { 0.20, 0.80, 0 } },
    { 16, { STRANGE, 2, 3 },  { GMAGIC, 1, 2 },   SGLIMMER,   { 0.75, 0.20, 0.05 }, { 0.20, 0.75, 0.05 } },
    { 21, { STRANGE, 4, 6 },  { LASTRAL, 1, 2 },  SGLIMMER,   { 0.75, 0.15, 0.10 }, { 0.15, 0.75, 0.10 } },
    { 26, { SOUL, 1, 2 },     { GASTRAL, 1, 2 },  LGLIMMER,   { 0.75, 0.20, 0.05 }, { 0.20, 0.75, 0.05 } },
    { 31, { SOUL, 2, 5 },     { LMYSTIC, 1, 2 },  SGLOW,      { 0.75, 0.20, 0.05 }, { 0.20, 0.75, 0.05 } },
    { 36, { VISION, 1, 2 },   { GMYSTIC, 1, 2 },  LGLOW,      { 0.75, 0.20, 0.05 }, { 0.20, 0.75, 0.05 } },
    { 41, { VISION, 2, 5 },   { LNETHER, 1, 2 },  SRADIANT,   { 0.75, 0.20, 0.05 }, { 0.20, 0.75, 0.05 } },
    { 46, { DREAM, 1, 2 },    { GNETHER, 1, 2 },  LRADIANT,   { 0.75, 0.20, 0.05 }, { 0.20, 0.75, 0.05 } },
    { 51, { DREAM, 2, 5 },    { LETERNAL, 1, 2 }, SBRILLIANT, { 0.75, 0.20, 0.05 }, { 0.22, 0.75, 0.03 } },
    { 56, { ILLUSION, 1, 2 }, { GETERNAL, 1, 2 }, LBRILLIANT, { 0.75, 0.20, 0.05 }, { 0.22, 0.75, 0.03 } },
    { 61, { ILLUSION, 2, 5 }, { GETERNAL, 2, 3 }, LBRILLIANT, { 0.75, 0.20, 0.05 }, { 0.22, 0.75, 0.03 } },
}

-- Rare (blue): one shard, by item level. 56 and up: 0.5% Nexus Crystal instead.
local RARE = {
    { 1, SGLIMMER }, { 26, LGLIMMER }, { 31, SGLOW }, { 36, LGLOW }, { 41, SRADIANT },
    { 46, LRADIANT }, { 51, SBRILLIANT }, { 56, LBRILLIANT },
}

-- Epic (purple): from item level, id, min, max. Below 40 the tables list nothing (vanilla has
-- almost no such epics); the rare shard of that level is used, one each, as the nearest guess.
local EPIC = {
    { 40, SRADIANT, 2, 4 }, { 46, LRADIANT, 2, 4 }, { 51, SBRILLIANT, 2, 4 },
    { 56, NEXUS, 1, 1 }, { 61, NEXUS, 1, 2 },
}

local function Bracket(list, ilvl)
    local found = nil
    for _, row in ipairs(list) do
        if ilvl >= row[1] then found = row end
    end
    return found
end

-- The possible results of disenchanting one item, as a list of
-- { id, min, max, chance }, plus guessed = true when the tables have no entry for it.
-- quality 2 uncommon, 3 rare, 4 epic; weapon = true for weapons (classID 2).
function T.Yield(quality, ilvl, weapon)
    if not quality or not ilvl or ilvl < 1 then return nil end
    if quality == 2 then
        if ilvl < 5 then return nil end
        local b = Bracket(UNCOMMON, ilvl)
        local chances = weapon and b[6] or b[5]
        local out = {
            { b[2][1], b[2][2], b[2][3], chances[1] },
            { b[3][1], b[3][2], b[3][3], chances[2] },
        }
        if b[4] and chances[3] > 0 then out[#out + 1] = { b[4], 1, 1, chances[3] } end
        return out
    elseif quality == 3 then
        local b = Bracket(RARE, ilvl)
        if ilvl >= 56 then
            return { { b[2], 1, 1, 0.995 }, { NEXUS, 1, 1, 0.005 } }
        end
        return { { b[2], 1, 1, 1 } }
    elseif quality == 4 then
        local b = Bracket(EPIC, ilvl)
        if b then return { { b[2], b[3], b[4], 1 } } end
        local r = Bracket(RARE, ilvl)
        local out = { { r[2], 1, 1, 1 } }
        out.guessed = true
        return out
    end
    return nil
end

-- Which items can be disenchanted at all: uncommon to epic weapons and armor that equip.
local NOT_GEAR = {
    [""] = true, INVTYPE_BODY = true, INVTYPE_TABARD = true, INVTYPE_BAG = true, INVTYPE_QUIVER = true,
    INVTYPE_AMMO = true, INVTYPE_NON_EQUIP = true, INVTYPE_NON_EQUIP_IGNORE = true,
}
local FISHING_POLE = 20

-- Green+ gear the game refuses to disenchant. Items made by the Enchanting profession can't be
-- disenchanted (Warcraft Wiki, "Enchanting ingredients"), so Enchanting's wands are excluded.
-- Players can hide anything else they find by right-clicking a deal.
T.NOT_DISENCHANTABLE = {
    [11287] = "Lesser Magic Wand",
    [11288] = "Greater Magic Wand",
    [11289] = "Lesser Mystic Wand",
    [11290] = "Greater Mystic Wand",
}

function T.CanDisenchant(classID, subClassID, equipLoc, quality)
    if classID ~= 2 and classID ~= 4 then return false end
    if quality and (quality < 2 or quality > 4) then return false end
    if NOT_GEAR[equipLoc or ""] then return false end
    if classID == 2 and subClassID == FISHING_POLE then return false end
    return true
end

T.AH_CUT = 0.05 -- the auction house keeps 5% of every sale
