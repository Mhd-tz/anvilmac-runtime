# AnvilMac runtime

The Wine runtime AnvilMac runs Windows games with, built from pinned,
checksum-verified sources by `scripts/build.sh`, locally or in GitHub Actions (`.github/workflows/build.yml`).

**Independent project.** This is not affiliated with, or endorsed by, WineHQ (the Wine project), CodeWeavers,
Apple, the DXMT project or the x87sidecar project. Wine, CrossOver, macOS, Metal, DXMT and x87sidecar belong to their
respective owners; the names are used only to say what this build contains.

**Source for every build.** Every published build comes with its full corresponding source, as the LGPL requires:
`sources-<package>.tar`, published next to the package. It contains the exact Wine source tarball, every patch, the
build scripts, the exact patched DXMT tree and its submodules, the Vulkan headers/loader sources, and the
source tarballs of the other components. Git metadata is excluded.

**Status:** experimental. Built packages are marked experimental and local-only in their manifest until they pass
AnvilMac's acceptance tests. Only a tested build run's exact files are released (`release.yml`, no rebuild):
`runtime-wine-11.19-1`, `runtime-wine-11.19-2`, `runtime-wine-11.19-7`, `runtime-wine-11.19-9`, `runtime-wine-11.19-10`,
`runtime-wine-11.19-11`, `runtime-wine-11.19-12`, `runtime-wine-11.19-13`, `runtime-wine-11.19-14` (the first with a
signed manifest) and, current since 2026-11-07, `runtime-wine-11.19-15`.

**Releasing (from 11.19-14).** After a build run passes testing, commit `releases/<version>.json` (the tested facts:
`testedMacOS`, each graphics backend's `status` and `evidence`, optionally `license`) and `releases/<version>.md`
(what's new and known problems, in plain words: AnvilMac shows it in Settings › Runtimes) to `main`, then start
`release.yml` with the run id and tag. It builds `<package>.release.json` from the run's manifest and those facts and
signs it with Ed25519 (`<package>.release.json.sig`, Actions secret `RUNTIME_SIGNING_KEY`). AnvilMac lists every
release and installs one only if its manifest is built into the app or carries a valid signature. `releases/11.19-13.*`
show the format (11.19-13 itself was released before signing existed).

## 11.19-15 (released 2026-11-07)

11.19-14 plus **x87sidecar** (Wine patch 0018 and `bin/x87sidecar`, v1.9.1 built from source, MIT): with
`ROSETTA_X87_PATH` set, every 32-bit process Wine creates starts under x87sidecar, which runs its x87 floating-point
code as native ARM64 instead of through Rosetta 2's slow x87 path (manifest launch fix `x87sidecar`: i386 games only,
used when `x87sidecar --probe` accepts the installed Rosetta). Also DXMT patch 0007: a per-frame timing log
(`DXMT_FRAME_LOG`, off unless set) and `DXMT_METAL_CACHE_PATH`.

The exact build run 42412107704 (commit 793c2ba) passed AnvilMac's no-window release checks (35 static checks,
32-bit transitions, timestamps, console, drive map, OpenGL buffers, game video, msync, DXMT frame rate unchanged at
about 120 fps, and an x87 console test: 22.4 s to 0.76 s, 29.5x, same results, hook proven). The owner played Shank,
Max Payne and SPORE with these patches on a local build (Max Payne median 35 to 120 fps) and chose to release the CI
build without playing it again. Released by `release.yml` without a rebuild; package SHA-256
`95aa9bc6d0f5061756aa8c470cff521150fb18dee3661e2f3a0a7ffa248eec99`.

## 11.19-14 (released 2026-11-06)

11.19-13 plus **DXMT frame rate** (DXMT patch 0006): after a present, DXMT's encoding thread writes
`trace:fps:dxmt_present <swapchain> @ approx N fps` about every 1.5 s through Wine's own debug output, only when
`WINEDEBUG` turns the `fps` channel on (manifest diagnostic `dxmt-frame-rate`), so AnvilMac can measure Direct3D 10
and 11 games the way Wine's own Direct3D already reports. Without the channel nothing changes.

The exact build run 42103794617 (commit 9bfe970; attempt 2, after a linker crash in GStreamer's GLib tests on a new
runner image) passed AnvilMac's no-window release checks (source archive equals this repository's patches at that
commit, every patch applied, 32-bit transitions, timestamps, console, drive map, OpenGL buffers, game video in 64- and
32-bit, msync: event set 7.66 to 0.37 us, five pairs 58.8 to 11.4 us, and DXMT frame rate: a hidden Direct3D 11 test
reports about 118 to 120 fps only with the channel on), and the owner played Mothville on it with its frame rate
measured. Released by `release.yml` without a rebuild; package SHA-256
`f9424f07026504c79c0dc027c9d14ebfeaea5fb3dae974da908f0018ac2d825f`. The first release with a signed manifest
(`<package>.release.json.sig`).

## 11.19-13 (released 2026-11-05)

11.19-12 plus **msync** (Wine patch 0017, `WINEMSYNC=1`, manifest launch fix `msync`): waits on Windows events,
mutexes and semaphores use Mach semaphores instead of a round trip through `wineserver`, and uncontended operations
stay inside the game's process. Ported to Wine 11.19 from CrossOver 26.2.0's published source (msync by Marc-Aurel
Zent, LGPL-2.1); provenance and changes are in the patch header. Without the variable Wine behaves as before. AnvilMac
turns it on for game launches, and Game Settings can turn it off per game.

A local build (wineserver and `ntdll.so` from this patch set in a copy of 11.19-12) measured, in a console test under
Rosetta 2 on an M2 Pro: event set 7.7 to 0.39 us, mutex acquire and release 18.9 to 1.40 us, thread hand-off 24.4 to
6.2 us, and 73.9 to 12.5 us with five pairs of threads at once. The exact build run 41898604707 (commit 7b3d81a)
passed AnvilMac's no-window regression checks (the 11.19-12 set plus msync static checks and the sync test on the
package: event set 7.7 to 0.38 us, five pairs 73.9 to 9.9 us), and the owner played several games on it; it was
released by `release.yml` (run 41963046893) without a rebuild; package SHA-256
`ff86a1a04783614394e2e7e374a8bab8fd2921ffb5dad1119459cf61a7bfb2c2`. Known: msync makes thread synchronization
cheaper, not every slowdown: Bink videos in the ReXGlue ports stay slow (an issue in the ports, reported upstream).

## 11.19-12 (released 2026-11-02)

11.19-11 plus automatic macOS fullscreen, for games whose own fullscreen changes the display mode to one macOS doesn't
apply on a scaled Retina display (cropped picture), while a window put into macOS fullscreen with the green button
works:
- **Automatic macOS fullscreen** (Wine patch 0015, `WINEMAC_NATIVE_FULLSCREEN=1`, manifest feature
  `native-fullscreen`): the game's first resizable window enters macOS fullscreen once, as the green button does,
  at the desktop's resolution. In that fullscreen the menu bar and Dock stay hidden, a resize the game makes itself
  doesn't shrink the window, and the pointer stays inside the visible area (below the camera housing), so edge
  scrolling works. Its decisions are logged on the `nativefs` debug channel. Without the variable nothing changes.
- **Cursor after leaving a fullscreen window's content** (patch 0016): the game's cursor is set again when the
  pointer comes back from a screen edge or from outside the window, where macOS shows its own arrow.

Local builds of these patches (only `winemac.so` rebuilt on the released 11.19-11) passed AnvilMac's window check
(test window sizes in 64- and 32-bit, including a resize after entering fullscreen) and the owner's Warcraft III
sessions (fullscreen, hidden menu bar and Dock, edge scrolling). The exact build run 41409431776 (commit acfcc4a)
passed AnvilMac's no-window regression checks, static checks of the new code and its fullscreen window check, and
the owner played Warcraft III on it; it was released by `release.yml` (run 41534620115) without a rebuild; package
SHA-256 `ae8b497b775ae272e2fc43b229e70d90a2102cf4a3e4b739819b1754b42006b6`. Known: macOS may still show its arrow over
the game's cursor on right clicks, and one 32-bit test window froze once in nine runs (cause not found).

## 11.19-11 (released 2026-11-01)

11.19-10 plus game controller fixes:
- **DualShock 4 over Bluetooth** (Wine patch 0011): the pad sends basic input reports until it is asked for its
  calibration data; Wine's report conversion assumes the Linux behaviour, where the kernel always asks. On macOS
  nothing did, so games with their own Sony reader could see no input. winebus now asks once when the pad starts,
  including after a reconnect, and keeps converting reports for ordinary HID/DirectInput readers.
- **DualSense shown as a DualShock 4 or an Xbox 360 controller** (patch 0012, `WINEBUS_DUALSENSE=ds4|xbox`,
  manifest feature `dualsense-presentation`), over USB and Bluetooth, for games whose controller code predates the
  DualSense. Without the variable nothing changes.
- **MSZIP in the Windows Compression API** (patch 0014): Wine only stubbed `Decompress`, handing back compressed
  bytes as if unpacked. The Naruto: The Broken Bond PC port unpacks its shaders this way and showed a black screen;
  it now plays (owner, through D3DMetal).
- **SDL 2.32.10** (zlib licence) for winebus's SDL backend, so Xbox, Switch and other controllers reach games
  (as Xbox controllers where SDL knows them). Before, this runtime was built without SDL, and winebus kept only the
  pads it reads as raw HID. Patch 0013 keeps SDL away from PlayStation pads, which stay on the raw HID path.

Local builds of this code passed owner tests on 11.19-10 with the owner's DualShock 4 and DualSense (startup,
in-game reconnect, both PS5 modes over USB and Bluetooth, two players); patch 0014 on the first 11.19-11 CI build
(run 40989772778) with Broken Bond. The exact build run 41180866336 (commit c66decb) passed AnvilMac's no-window
regression checks and the owner's tests (DualSense over USB in Unruly Heroes and Shank, Broken Bond through
D3DMetal), and was released by `release.yml` (run 41283524299) without a rebuild; package SHA-256
`4c10830d5a26780c2446cd0d0c1b1db33e4769d27ef74491d1eed2cf4cedf4f7`. No non-PlayStation controller was available,
so the SDL path for other controllers is untested. The manifest also checks `winebus.so`, `libSDL2-2.0.0.dylib`
and `cabinet.dll`.

## 11.19-10 (released 2026-10-28)

11.19-9 plus video in games: Wine is built with GStreamer support and the package carries a minimal GStreamer 1.28.8
that decodes with macOS's own codecs. Without it, games that play videos through Media Foundation or DirectShow showed
black for each video's length (Unruly Heroes, 2026-10-27). Released by `release.yml` (run 40773802058) from build run
40590792615 (commit 0c5434c) after AnvilMac's acceptance; package SHA-256
`75cccbff841f947acbef6f5085ed1d67e71765aa4fa87e9ca4aa485d9883de62`.

## 11.19-9 (released 2026-10-26)

11.19-9 combines the fullscreen cursor correction first built as the 11.19-8 candidate (not released on its own) with a
general WoW64 OpenGL shadow-buffer optimization (Wine patch 0010). For explicit-flush write maps, only flushed ranges
are copied to the host buffer; readable and implicit-flush maps keep their preservation behavior. The change has no
game-name checks. The 11.19-7 far-return and DXMT fixes remain included. Released by `release.yml` from build run
40418867481 after AnvilMac's acceptance (no-window checks, window batch, owner sessions); a speedup for every game is
not claimed. The manifest also checks the hash of `opengl32.so` before launch.

## What it builds

| Component | Version | Notes |
|---|---|---|
| Wine | 11.19 (development release) | `patches/wine/series`: Gcenx's Vulkan portability patch, and WineHQ MR !11058's ExtEscape handler (Marc-Aurel Zent) rebased onto 11.19; a diagnostic that logs the start and end of runtime HLSL compiles, only when `WINEDEBUG` enables the `shadertime` channel; a fix for x64 SEH target unwinds (C++ catch blocks cleaned up twice); while a window covers the screen, the Dock and menu bar are hidden so screen edges can't bring back the system arrow over a fullscreen game, and a hidden cursor is reasserted only after a screen edge (from 11.19-9; 11.19-7 and earlier reasserted it on every mouse move, which made the cursor flicker); the driver hooks, DLL search order and macOS `%gs` handling that let Wine load the user's own copy of Apple's D3DMetal (Game Porting Toolkit), all switched off unless AnvilMac passes a verified copy; under Rosetta 2 only, far returns instead of far jumps for wow64cpu's 32/64-bit transitions (random wrong-mode crashes in 32-bit programs; from 11.19-6). 11.19-7 combines both; 11.19-9 adds the cursor change and the OpenGL buffer optimization; 11.19-11 added patches 0011-0014; 11.19-12 adds automatic macOS fullscreen for games that ask for it (patches 0015-0016, `WINEMAC_NATIVE_FULLSCREEN`); 11.19-13 adds msync (patch 0017, `WINEMSYNC`); 11.19-14 adds the DXMT frame-rate patch (DXMT 0006); 11.19-15 (the current release) adds patch 0018: with `ROSETTA_X87_PATH` set, 32-bit processes start under x87sidecar (cooperative handshake from athei/wine, reduced for upstream Wine) |
| DXMT | v0.80 | Direct3D 10/11 on Metal; `patches/dxmt/series`: PR #166 (ExtEscape), one upstream compile fix, upstream's `EnumAdapterByLuid`, a local Wine LUID lookup when Metal and Wine each expose one GPU, and CPU timestamp readback before event-query completion (from 11.19-5); from 11.19-15 a per-frame timing log (`DXMT_FRAME_LOG`, off unless set) and `DXMT_METAL_CACHE_PATH` for Metal's pipeline cache |
| MoltenVK | 1.4.2 | default Vulkan driver, loaded through the Khronos Vulkan loader |
| Vulkan loader | vulkan-sdk-1.4.363.0 | `VK_DRIVER_FILES` picks the driver; AnvilMac sets it from the runtime manifest |
| FreeType | 2.13.3 | Wine's font back end |
| SDL | 2.32.10 | winebus's SDL backend for game controllers other than PlayStation ones (Xbox, Switch and others), zlib licence; PlayStation pads stay on raw HID (patch 0013). From 11.19-11. |
| Wine Mono | 11.3.0 | .NET for Windows programs; the unmodified upstream release that Wine 11.19 asks for, in `share/wine/mono`. Wine Gecko is not bundled. |
| x87sidecar | v1.9.1 | Native arm64 helper (`bin/x87sidecar`, built from source, unmodified, MIT, by Alexander Theissen) that runs the x87 floating-point code of 32-bit programs as ARM64 instead of through Rosetta 2's slow x87 path. Used only when AnvilMac sets `ROSETTA_X87_PATH` for a 32-bit game and `x87sidecar --probe` accepts the installed Rosetta. From 11.19-15. |
| GStreamer | 1.28.8 | Video in games: Wine's winegstreamer (Media Foundation, DirectShow) decodes through macOS's own codecs: VideoToolbox (H.264, HEVC, MPEG-2) and AudioToolbox (AAC, MP3), with the MP4 and Matroska/WebM demuxers; only the needed plugins, no GPL plugins, no FFmpeg. GLib 2.86.3, libffi, PCRE2 and proxy-libintl from GStreamer's pinned wraps. LGPL-2.1-or-later (GStreamer, GLib, proxy-libintl), MIT (libffi), BSD-3-Clause (PCRE2); full sources in the source archive. From 11.19-10. |

**Apple's D3DMetal is not part of this runtime.** Patches 0006-0008 only let Wine load a copy of Apple's Game Porting
Toolkit that the user downloaded from Apple and imported into AnvilMac; AnvilMac verifies Apple's signature before
each launch. With no such copy (or outside AnvilMac) the code stays off and Wine behaves as without the patches.

Every input and its checksum is in `inputs.sh`. A patch that doesn't apply without fuzz fails the build. The target
is Wine 12.0 once it ships.

## Output

`<work>/out/`:
- the package (`.tar.xz`, with `SHA256SUMS` of every file inside);
- its AnvilMac runtime manifest (`.manifest.json`);
- `sources-….tar`: the exact sources, patches and scripts, i.e. the corresponding source for the LGPL components;
- `SHA256SUMS`.

## Licences

- **This repository's own files** (build scripts, workflow, `inputs.sh`, `requirements.txt`, series lists, docs):
  **MIT**, see `LICENSE`.
- **Patches** keep the licence of the project they change, stated in each patch file:
  - `patches/wine/`: LGPL-2.1-or-later, as Wine;
  - `patches/dxmt/`: LGPL-2.1-or-later (DXMT releases after v0.80 are LGPL; v0.80 itself is MIT).
- **Built packages** contain:
  - Wine: LGPL-2.1-or-later;
  - DXMT: v0.80 MIT, plus the LGPL changes above;
  - MoltenVK and the Khronos Vulkan loader: Apache-2.0;
  - FreeType: FTL;
  - x87sidecar: MIT (its `LICENSE`, included as `x87sidecar-LICENSE`; its source is in `sources-….tar`);
  - Wine Mono: mixed: LGPL and MIT for most of Mono, MS-PL and zlib for FNA and its libraries, GPL with an exception
    for SharpZipLib (its `COPYING`, included as `Wine-Mono-COPYING`). Its source tarball is in `sources-….tar`.

  Their licence texts are in `share/doc/anvilmac-runtime/`. Every package is published with `sources-….tar`: the exact
  sources, patches and scripts it was built from.

## Building locally

```sh
scripts/build.sh /path/to/work            # all stages
scripts/build.sh /path/to/work wine       # one stage (fetch toolchain deps wine dxmt package)
```

**Requirements:** Apple silicon with Rosetta 2, Xcode with its Metal toolchain, and Python 3. Nothing is installed
system-wide; everything goes into the work directory.
