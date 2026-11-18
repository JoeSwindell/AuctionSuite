# AuctionSuite

One auction house suite for World of Warcraft: Forever (client 1.60.1, `## Interface: 16001`),
built on **AHledger**. It has four addons:

| Folder | What it is |
|---|---|
| `AuctionSuite` | Core: module registry, data layer over AHledger, the AuctionSuite tab and window |
| `AuctionSuite_SuffixFinder` | Module: browse gear by random suffix ("of the Tiger"), with slot, type, level and price filters, plus presets |
| `AuctionSuite_Disenchant` | Module: gear listed below the value of its disenchant materials, sorted by profit |
| `AuctionSuite_VendorDeals` | Module: items listed below what a vendor pays for them, sorted by profit |

The modules are load-on-demand. The core loads them when the auction house opens, or when you
type `/asuite`.

## Install

Copy (or junction) the four folders into `World of Warcraft\_forever_\Interface\AddOns\`.
**AHledger must be installed and enabled** (`## Dependencies: AHledger`).

## Use

- Open the auction house. The AuctionSuite window docks at its right edge, with a page per module
  (tabs along the bottom of the window). The **AuctionSuite** tab after Blizzard's
  Buy / Sell / Auctions tabs toggles it.
- `/asuite` toggles the window anywhere. Other commands:
  - `/asuite status`: data sources, AHledger's scanner state, and loaded modules
  - `/asuite auto`: toggles opening with the auction house
  - `/asuite reset`: docks the window again after you drag it
- `/asf` opens the Suffix Finder page. `/asf status` and `/asf reset` work as `/sf` did in the
  standalone addon. The standalone addon keeps `/sf`.
- **Disenchant** needs no setup. It refreshes when the house opens and whenever new listing data
  arrives. Hover a deal to see the material breakdown. Clicking a deal also searches the house for
  the current price of each material it can give and re-values it. Click it to find that auction on the house,
  then click **Buy**. The list shows item, buyout, expected value and profit; the
  likely materials are in the hover tooltip. The search box filters deals by name as you type. By
  default every profitable deal is shown (min profit 1 copper, no minimum return); both limits can
  be raised at the top right. Min profit takes gold, silver and copper ("1g 50s 25c", "1g50s",
  "75s", "30c"; a plain number counts as silver). The footer shows your Enchanting skill as a
  note: on Forever any skill can disenchant everything.
- **Vendor Deals** needs no setup either. It lists items whose buyout is below what a vendor pays
  for them (`GetItemInfo` sell price per unit × stack size), best profit first. No auction house
  cut applies, because a vendor pays in full. Every deal with at least 1 copper profit is shown;
  raise the minimum at the top right. Hover a deal for the vendor price per unit, the stack size
  and the profit. Click it to find the auction and **Buy**, then sell the items at any vendor.
  Right-click a deal to hide that item; `/asv hidden` lists hidden items, `/asv unhide <id>` brings
  one back, and `/asv` opens the page. It only covers this direction: AHledger already marks the
  other one (buy from a vendor, sell at auction) at merchants.
- **Suffix Finder**: same filters, presets and columns as SuffixFinder 0.1. Clicking a result
  copies its base name (Ctrl+C) and finds the auction for the Buy button.

## How it relates to AHledger (what is relied on)

AHledger 0.15.0 exposes a public, read-only global, `AHledgerAPI` (its `API.lua`, `API.VERSION = 1`).
AuctionSuite uses:

| AHledger item | Used for | If missing |
|---|---|---|
| `AHledgerAPI.GetPrice(itemID)`: `median`, `median7d`, `minBuyout` | All prices (`AuctionSuite.Prices`) | No prices; a warning is printed at login |
| `AHledgerAPI.CREDIT` | Credit line on the Disenchant page, as AHledger's API terms ask | A built-in copy of the same text |
| `AHledgerAPI.GetTableInfo()`, `GetAddonVersion()` | `/asuite status` only | Shows "none" |
| `AHledgerScanButton` text (`Scanning...`, `Saving ...`, `No reply`, other) | Whether AHledger's scan is running; read only | Treated as idle |
| `AHledgerDB.scans[i]` = `{ realm, faction, ts, data = "itemID:stack:buyout:bid:timeLeft;..." }` | Listings when no full listing arrives this session (AHledger's 15-minute throttle) | Waits for a live listing |
| `AHledgerPostingPanel` visibility | Moving the docked window right of AHledger's posting panel | Docks at the house's edge |

Rules the suite keeps:

- **No second price store.** Prices are read from AHledger on demand. The only thing kept is the
  lowest unit buyout seen in this session's listing, used so material values never exceed what
  they list for right now.
- **No full scans.** `C_AuctionHouse.ReplicateItems` is never called. AHledger requests the full
  listing when the house opens, and the suite reads that same client-side list
  (`REPLICATE_ITEM_LIST_UPDATE`). It waits while AHledger is still packing it, so the two big
  reads don't stack in the same frames.
- **Targeted queries only while AHledger is idle.** Item and name searches (clicking a row) are
  queued while AHledger's button says `Scanning`/`Saving`.
- **No tooltip lines.** Nothing hooks GameTooltip. AHledger draws its price and disenchant lines
  on item tooltips; AuctionSuite's own figures go in a separate `AuctionSuiteInfoTooltip` under the
  item tooltip, only when hovering a row in its own lists.
- **Distinct names.** Globals `AuctionSuite`, `AuctionSuiteDB`, `AuctionSuite_SuffixFinderDB`,
  `AuctionSuite_DisenchantDB`, `AuctionSuite_VendorDealsDB`; frames `AuctionSuiteFrame`, `AuctionSuiteAHTab`,
  `AuctionSuiteFrameTab<n>`, `AuctionSuitePage_<module>`, `AuctionSuiteInfoTooltip`; slash
  `/asuite`, `/auctionsuite`, `/asf`, `/asd`, `/asv`.
- **No tab collisions.** The AuctionSuite tab is a separate button placed after the last visible
  Blizzard tab, not added to `AuctionHouseFrame.Tabs`, so Blizzard's tab code is untouched.
  AHledger adds no tabs. Its scan button sits inside the search bar, and its posting panel at the
  house's top right, which the window moves around.

## Module API

A module is a load-on-demand addon whose toc has:

```
## Dependencies: AuctionSuite
## LoadOnDemand: 1
## X-AuctionSuite-Module: 1
```

It registers once, from its own `ADDON_LOADED`:

```lua
local AS = AuctionSuite
AS:RegisterModule({
    name = "MyModule",             -- unique key (required)
    title = "My Module",           -- tab label (required)
    icon = "Interface\\Icons\\INV_Misc_Coin_02", -- window portrait while the page shows
    order = 30,                    -- tab order, lower first (default 100)
    wants = function(row) return row.classID == 4 end, -- keep this listing row?
    createPanel = function(page) end, -- build your UI into `page`, once, on first show
    onData = function(snapshot) end,  -- new listing data (also on registration if data exists)
    onProgress = function(done, total) end, -- the full listing is being read
    onItemInfo = function() end,      -- item data arrived (throttled, twice a second at most)
    onShow = function(page) end, onHide = function(page) end,
    onPurchase = function(auctionID) end, -- a purchase made with AuctionSuite.Data.Buy completed
})
```

`page` covers the whole window and is raised above ButtonFrameTemplate's Inset, so everything you
create on it is visible. The title bar is at the top. Leave about 72 px on the left of the top
40 px for the portrait.

### Rows and snapshots

`wants(row)` is called for every listing row before its item link is read. Keep it cheap. Rows
that any module wants are kept and passed to every module. Row fields:

`itemID, name, count, quality, level` (required level), `usable, buyout` (whole listing, copper,
nil for bid-only), `bid, owner, classID, subClassID, equipLoc, icon, link` (nil in AHledger saved
scans), `live` (true when read from this session's listing).

`snapshot = { source = "live" | "ahledger", time, total, read, partial, rows }`. A live read that
loses its list (the house closes) is published with `partial = true` and the rows read so far.

### Shared services (`AuctionSuite.*`)

| Call | Returns / does |
|---|---|
| `Prices.Get(id)` | AHledger's full price record or nil |
| `Prices.Market(id)` | median, else 7-day median, else lowest buyout |
| `Prices.Lowest(id)` | lowest unit buyout in this session's listing, else AHledger's |
| `Prices.SellValue(id)` | `min(Market, Lowest)`: what a unit should sell for now |
| `Prices.CREDIT` | AHledger's credit line; show it where its prices appear |
| `Data.IsAHledgerBusy()`, `Data.AHledgerPhase()` | AHledger's scanner state |
| `Data.IsReading()`, `Data.ReadProgress()` | the suite's own read of the listing |
| `Data.FindAuction(req, cb)` | targeted search for one auction (queued while AHledger scans) |
| `Data.QueryPrices(itemIDs, onPrice, onDone)` | live search of a few items' current prices, one at a time, after `FindAuction` finds its auction and while AHledger is idle; `onPrice(itemID, unit, qty)` (unit = cheapest price covering 3 units, nil if none listed) |
| `Data.LivePrice(itemID)`, `Data.HasLivePrice(itemID)` | a live price from the last 10 minutes, if any |
| `bar:Redescribe()` | redraw the purchase bar's line after the module's value for it changed |
| `Data.Buy(found)` | `C_AuctionHouse.PlaceBid`; call only from a click |
| `Data.Instant(itemID)` | cached `GetItemInfoInstant` fields |
| `UI.CreateList(parent, opts)` | sortable scrolling list (see UI.lua) |
| `UI.CreatePurchaseBar(parent)` | "find this auction, then Buy" bar; call `bar:OnPurchase(id)` from `onPurchase` |
| `UI.Money`, `UI.ShortMoney`, `UI.QualityHex`, `UI.DisplayName`, `UI.InfoTooltip()` | helpers |
| `IsMine(owner)` | true for the player's own listings (handles Forever surnames) |
| `SafeCall(fn, ...)`, `Print(...)`, `TimeAgo(t)`, `CopyDefaults(dst, src)` | utilities |

## Disenchant valuation

Tables are in `AuctionSuite_Disenchant/Tables.lua`, with sources: Warcraft Wiki's "Disenchanting
tables", wow-professions.com's Forever disenchanting guide, and AHledger's own brackets.
Forever's results follow required level, so the bracket is chosen at required level + 5 (the item
level a vanilla green of that requirement has); items with no level requirement use their item
level. The item levels below are those bracket levels.

- **Uncommon armor:** dust 75% (80% at item level 5-15), essence 20% (15% at 21-25), shard 5%
  (10% at 21-25, none below 16).
- **Uncommon weapons:** dust 20% (15% at 21-25, 22% from 51), essence 75% (80% at 5-15), shard
  5% (3% from 51).
- **Rare:** one shard of the level; from item level 56, a 0.5% Nexus Crystal.
- **Epic:** 2-4 Small Radiant (40-45), 2-4 Large Radiant (46-50), 2-4 Small Brilliant (51-55),
  1 Nexus (56-60), 1-2 Nexus (61+).
- **Material value:** `min(AHledger median, lowest listed now)`. Lesser and greater essences are
  each worth at least a third (or three times) the other, since they convert.
- **Expected value** = sum of chance × average quantity × value, × 0.95 (the auction house cut).
- **Deal:** profit = expected value × count − buyout, more than zero by default. These defaults
  carry over the user's choices from the earlier standalone DisenchantDeals.
  Your own listings and items that can't be disenchanted (shirts, tabards, fishing poles, bags)
  are skipped.

## Vendor deal valuation

- **Vendor value** = the item's sell price (the 11th return of `GetItemInfo`, per unit) × the
  listing's stack size. AHledger isn't used here; it stays the price source everywhere else.
- **Profit** = vendor value − buyout, at least 1 copper by default. Items vendors won't buy (no
  sell price), bid-only listings, your own listings and items you hid are skipped.
- Items not cached yet are requested once and counted as "loading" until their data arrives.

## Known limitations

- Not yet run in the live client. The logic was tested under LuaJIT with a mocked game API, but
  frame templates and auction house search and buy behavior need the in-game test below.
- Listings from AHledger's saved scan may be minutes to hours old. The page says how old, and a
  click checks the live house before Buy is enabled.
- If the game blocks `C_AuctionHouse.PlaceBid` for addons on Forever, the suite prints which call
  was blocked. Suffix Finder still copies the name for Blizzard's own search.
- Saved data from the standalone SuffixFinder (`SuffixFinderDB`) isn't migrated. Presets start
  from the same five starters.
