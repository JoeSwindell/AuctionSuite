# AuctionSuite 0.2.2

## Disenchant page
- **Value is now per item:** what one disenchant most likely gives you, at the lowest quantity
  (75% Vision Dust ×2-5 counts as 2 Vision Dust), after the 5% cut. Profit, minimum return and
  the bought-items total use that value. Previously it was the average over many disenchants.
- The tooltip greys out the results that aren't counted and names the counted one
  ("Value: 2 Vision Dust, after 5% cut").
- New `/asd average` switches back to the average over many disenchants.

# AuctionSuite 0.2.1

- Releases are now packaged automatically from the GitHub repository. No in-game changes since
  0.2.0.
- The version shown by `/asuite status` now matches the TOC (it still said 0.1.0-alpha2).

# AuctionSuite 0.2.0

## New
- **Vendor Deals page** (new module `AuctionSuite_VendorDeals`): auction house items listed for
  less than a vendor pays for them, best profit first. Profit = vendor sell price × stack size −
  buyout (vendors pay in full, so there's no auction house cut). Every deal with at least 1 copper
  profit is shown, and the minimum is adjustable. Hover for the price per unit, stack size and
  profit. Click to find the auction and buy it; right-click to hide an item. `/asv`,
  `/asv hidden`, `/asv unhide <id>`.
- Uses the listing AuctionSuite already reads from AHledger's scan; no new scans.

## Disenchant page
- **Live prices when you click a deal:** the auction is looked up live, then every material the
  item can disenchant into is searched on the auction house. The deal's value and profit are
  recalculated at those current prices (marked with a green dot, and "(live)" in the tooltip).
  Live prices are kept for 10 minutes and used for every other deal with the same materials.
- **Search by name:** a search box filters deals as you type.
- **Min profit in gold, silver and copper:** type "1g 50s 25c", "1g50s", "75s" or "30c" (a plain
  number counts as silver). The box shows the value back as "1g 50s 25c".
- **No level column:** on Forever any Enchanting skill can disenchant any item, so the iLvl column
  is gone.
- **Likely materials moved to the hover tooltip**, under a "Likely materials:" heading. The list
  has wider Buyout, Value and Profit columns and more room for item names.

## Known issues
- Buying from AuctionSuite's Buy button is still being tested. If the game blocks a purchase,
  buy the item in Blizzard's Buy tab and let us know in the comments.

# AuctionSuite 0.1.0

First public alpha. Requires AHledger.

## Features
- One AuctionSuite window docked beside the auction house, with a page per module and an
  **AuctionSuite** tab after Buy / Sell / Auctions.
- All prices come from AHledger. AuctionSuite never requests its own full scan; it reads the
  one AHledger already does.
- **Disenchant page:** gear listed below the value of its disenchant materials, best profit
  first, with a full material breakdown on hover. Automatic, with no setup.
  - Skips items the game won't disenchant, including Enchanting-made wands (Lesser and
    Greater Magic Wand, Lesser and Greater Mystic Wand).
  - Right-click a deal to hide it for good. `/asd hidden` lists hidden items and `/asd unhide`
    brings one back.
- **Suffix Finder page:** browse gear by random suffix ("of the Tiger", "of the Bear"...), with
  slot, type, level and price filters and saved presets.
- Commands: `/asuite`, `/asuite status`, `/asuite auto`, `/asuite reset`, `/asf`, `/asd`.
- Module API for other addon authors (see the README in the download).

## Known issues
- **Buying from AuctionSuite's Buy button is still being tested.** If the game blocks the
  purchase ("Interface action failed because of an AddOn"), search for the item in
  Blizzard's Buy tab and buy it there. Please report it in the comments.
- If no full scan has arrived this session, pages use AHledger's last saved scan, which can be
  minutes to hours old. The page shows its age.
- Disenchant values are averages over many disenchants. A single item can come out lower.
- Settings from the old standalone SuffixFinder aren't carried over.
