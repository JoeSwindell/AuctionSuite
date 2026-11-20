# AuctionSuite

**Auction house tools for World of Warcraft: Forever, in one window, built on AHledger's prices.**

> **Alpha:** this is an early test release, so expect rough edges. Buying through AuctionSuite's
> Buy button is still being tested. If the game blocks a purchase, buy the item in Blizzard's
> Buy tab instead, and please tell us in the comments.

AuctionSuite adds one window beside the auction house, with a page for each tool. It doesn't
run its own price scans or keep its own price database. It uses **AHledger's** prices and reads
the same auction listing AHledger already requests, so the two never compete for scans.

> **Requires [AHledger](https://www.curseforge.com/wow/addons/ahledger).** The CurseForge app
> installs it automatically.

## Included tools

### Disenchant Deals
Gear on the auction house that's worth more as enchanting materials than it costs.

- Every green, blue and epic weapon or armor piece with a buyout is valued against current
  prices for dusts, essences, shards and Nexus Crystals.
- Listings below their disenchant value are shown best profit first: item, buyout, value and
  profit. The value is what one disenchant most likely gives you, at the lowest quantity (75%
  Vision Dust ×2-5 counts as 2 Vision Dust). `/asd average` switches to the average over many
  disenchants.
- **Hover a deal for the likely materials:** each material's chance, quantity and price, plus
  the value and your profit.
- **Live check on click:** clicking a deal looks up that auction and searches the current price
  of every material it can disenchant into, then recalculates the value and profit before you
  buy.
- **Search by name** to find a specific item.
- **Minimum profit in gold, silver and copper** (`1g 50s 25c`, `75s`, `30c`), plus a minimum
  return percentage.
- Accounts for the 5% auction house cut.
- Skips items the game won't disenchant, like Enchanting-made wands. Right-click any deal to
  hide it for good.
- Fully automatic, with no setup. It refreshes when the house opens and whenever new listings
  arrive.
- On Forever, any Enchanting skill can disenchant everything. The footer shows your skill.

### Vendor Deals
Items on the auction house that a vendor would pay more for than their buyout.

- Every listing with a buyout is checked against the item's vendor sell price × stack size.
- Deals are shown best profit first: item, quantity, buyout, what the vendor pays, profit and
  return. Hover one for the vendor price per unit, the stack size and the profit.
- No auction house cut: vendors pay in full. Minimum profit is adjustable.
- Right-click a deal to hide that item.
- Fully automatic, with no setup. AHledger already marks the opposite direction at merchants
  (buy from a vendor, sell at auction), so this only covers buying at auction.

### Suffix Finder
Browse auction house gear by random suffix: "of the Tiger", "of the Bear", "of the Monkey" and
the rest.

- Filter by suffix, slot, armor or weapon type, level and price.
- Save your favorite searches as presets.
- Click a result to find that auction, then buy it.

## How to use

1. Install AuctionSuite and AHledger.
2. Open the auction house. The AuctionSuite window docks beside it. Use the **AuctionSuite** tab
   (after Buy / Sell / Auctions) to show or hide it.
3. Pick a page from the tabs along the bottom of the window.
4. Click a row to find that auction, then click **Buy**. Purchases always need your click; no
   addon can buy for you.

## Commands

| Command | What it does |
|---|---|
| `/asuite` | Show or hide the window anywhere |
| `/asuite status` | Data sources, AHledger's scanner state, loaded modules |
| `/asuite auto` | Turn opening with the auction house on or off |
| `/asuite reset` | Dock the window again after dragging it |
| `/asf` | Open the Suffix Finder page |
| `/asd hidden` | List items hidden from Disenchant Deals |
| `/asd hide <item>` / `/asd unhide <item>` | Hide an item from Disenchant Deals, or bring it back |
| `/asd average` | Value disenchants at the average over many instead of the most likely result |
| `/asv` | Open the Vendor Deals page (`/asv hidden`, `/asv unhide <id>`) |

## Plays nicely with AHledger

- **No duplicate scans:** AuctionSuite never requests a full listing. It reads the one AHledger
  already asks for. The only searches it makes are small ones when you click a deal (that
  auction and its materials), and they wait while AHledger is scanning.
- **No duplicate tooltips:** AHledger keeps its tooltip price lines. AuctionSuite adds nothing to
  item tooltips.
- **No tab conflicts:** AuctionSuite adds one tab and moves its window around AHledger's posting
  panel.

## For addon authors

AuctionSuite is modular. A new tool is a small load-on-demand addon that registers with one call
and gets the shared listing data, prices, list widgets and purchase bar. The README in the
download documents the module API.

## Notes

- Prices come from AHledger. AuctionSuite shows AHledger's credit line where its prices appear.
- If no full listing has arrived this session (the server allows one about every 15 minutes),
  the pages use AHledger's last saved scan and show how old it is. Clicking a deal checks the
  live house before **Buy** is enabled.
- If you also have the standalone **DisenchantDeals**, you only need one of them. Both use
  AHledger's prices; AuctionSuite's Disenchant page adds search and sits alongside the other
  tools.
- The disenchant value is the most likely result, which you get most of the time (about 75%
  for green items). The rest of the time you get a different material, worth more or less.

Free, no automation, nothing paywalled. Feedback and bug reports are welcome in the comments.
