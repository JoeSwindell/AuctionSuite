# Uploading AuctionSuite 0.2.3 to CurseForge

## 1. Create the project (first time only)
CurseForge → Authors → Create Project → World of Warcraft → Addons.

| Field | Value |
|---|---|
| Name | AuctionSuite |
| Summary | Auction house tools for WoW: Forever in one window: disenchant deals and suffix finder, priced by AHledger. |
| Main category | Auction & Economy |
| Additional categories | Professions, Bags & Inventory (optional) |
| License | All Rights Reserved (or MIT if you want others to reuse the code) |
| Avatar | `curseforge-icon.png` |
| Description | paste `curseforge-description.md` (set the editor to Markdown) |

## 2. Upload the file
Project → Files → Upload File.

| Field | Value |
|---|---|
| File | `AuctionSuite-0.2.3.zip` |
| Display name | AuctionSuite 0.2.3 |
| Release type | **Alpha** |
| Game version | WoW Forever 1.60.1 |
| Changelog | paste `CHANGELOG.md` (type: Markdown) |

## 3. Relations (important)
Project → Relations → add **AHledger** as a **Required Dependency**. The CurseForge app then
installs AHledger with AuctionSuite. If AHledger isn't on CurseForge, leave the "Requires AHledger"
note at the top of the description and link where to get it.

Also fix the AHledger link in the description if its CurseForge address isn't
`curseforge.com/wow/addons/ahledger`.

## 4. After it's approved
- Alpha files aren't shown to people who only take Release files. Testers need to set
  AuctionSuite to "Alpha" in the CurseForge app (right-click → Release Type → Alpha).
- Ask testers to check whether the **Buy** button works. That's the main open question.

## Automatic packaging

The repository is set up for automatic packaging. Two ways:

**Locally:** `python tools/package.py` checks everything (Lua compiles with LuaJIT, all four TOC
versions match, no BOMs, every file a TOC lists exists), then writes
`dist/AuctionSuite-<version>.zip`. `--check-only` skips the zip.

**On GitHub** (`.github/workflows/release.yml`, using the BigWigs packager and `.pkgmeta`):
1. Push the repository to GitHub.
2. Bump `## Version` in all four TOCs, add the release notes at the top of `CHANGELOG.md`, and
   commit.
3. Tag and push the tag: `git tag v0.2.3` then `git push origin v0.2.3`.
4. The workflow runs the checks, builds the zip and attaches it to a GitHub release. Tags with
   "alpha" or "beta" in them are marked as such.

To upload to CurseForge automatically as well, add `## X-Curse-Project-ID: <id>` to
`AuctionSuite/AuctionSuite.toc` (the ID is on the project page once it is approved), and add a
repository secret `CF_API_KEY` with an API token from curseforge.com → My Profile → API Tokens.
For Wago: `## X-Wago-ID: <id>` and a `WAGO_API_TOKEN` secret. Without them those uploads are skipped.
