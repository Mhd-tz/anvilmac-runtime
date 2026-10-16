# AnvilMac runtime

The Wine runtime AnvilMac runs Windows games with, built from pinned,
checksum-verified sources by `scripts/build.sh`, locally or in GitHub Actions (`.github/workflows/build.yml`).

**Status:** experimental. Built packages are marked experimental and local-only in their manifest until they pass
AnvilMac's acceptance tests. Nothing here is a release yet.

## What it builds

| Component | Version | Notes |
|---|---|---|
| Wine | 11.19 (development release) | `patches/wine/series`: Gcenx's Vulkan portability patch, and WineHQ MR !11058's ExtEscape handler (Marc-Aurel Zent) rebased onto 11.19 |
| DXMT | v0.80 | Direct3D 10/11 on Metal; `patches/dxmt/series`: PR #166 (ExtEscape) and one upstream compile fix |
| MoltenVK | 1.4.2 | default Vulkan driver, loaded through the Khronos Vulkan loader |
| Vulkan loader | vulkan-sdk-1.4.363.0 | `VK_DRIVER_FILES` picks the driver; AnvilMac sets it from the runtime manifest |
| FreeType | 2.13.3 | Wine's font back end |

Every input and its checksum is in `inputs.sh`. A patch that doesn't apply without fuzz fails the build. The target
is Wine 12.0 once it ships.

## Output

`<work>/out/`:
- the package (`.tar.xz`, with `SHA256SUMS` of every file inside);
- its AnvilMac runtime manifest (`.manifest.json`);
- `sources-….tar`: the exact sources, patches and scripts, i.e. the corresponding source for the LGPL components;
- `SHA256SUMS`.

## Licences

- **Wine:** LGPL-2.1-or-later. The patches under `patches/wine` carry Wine's licence.
- **DXMT:** v0.80 is MIT; the changes in `patches/dxmt` are LGPL-2.1-or-later.
- **MoltenVK, the Vulkan loader:** Apache-2.0.
- **FreeType:** the FreeType License (FTL).

Licence texts ship in each package under `share/doc/anvilmac-runtime/`. The build scripts' own licence is to be decided by the owner.

## Building locally

```sh
scripts/build.sh /path/to/work            # all stages
scripts/build.sh /path/to/work wine       # one stage (fetch toolchain deps wine dxmt package)
```

**Requirements:** Apple silicon with Rosetta 2, Xcode with its Metal toolchain, and Python 3. Nothing is installed
system-wide; everything goes into the work directory.
