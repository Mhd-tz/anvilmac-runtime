# Pinned inputs for the AnvilMac runtime build. Every download is verified by SHA-256 (or by git commit id) before
# use; a mismatch stops the build. Checked 2026-10-15. Change a pin only together with its checksum.

# --- Wine ------------------------------------------------------------------------------------------------------------
WINE_VERSION=11.19
WINE_URL=https://gitlab.winehq.org/wine/wine/-/archive/wine-11.19/wine-wine-11.19.tar.gz
WINE_SHA=73eb0b02dfc0cb0ff4f4d8d36c5786261e9725ac91968ae4d4e4b9a498c4087f   # = Gcenx wine-devel Portfile (macports-wine 092031f7)
WINE_DIR=wine-wine-11.19

# --- Toolchains ------------------------------------------------------------------------------------------------------
# llvm-mingw for Wine's PE parts (Gcenx's ports use MacPorts' current llvm-mingw; we pin the release used for 11.0_1).
MINGW_WINE=llvm-mingw-20260407-ucrt-macos-universal
MINGW_WINE_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20260407/$MINGW_WINE.tar.xz
MINGW_WINE_SHA=801b49549ae39043d7195062eede67916b5ab46318a89e3b8209dc8f49441abb      # GitHub release asset digest
# llvm-mingw for DXMT (DXMT's own CI uses this release).
MINGW_DXMT=llvm-mingw-20251216-ucrt-macos-universal
MINGW_DXMT_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20251216/$MINGW_DXMT.tar.xz
MINGW_DXMT_SHA=38bb5e48ec3e0ce95fb901f4efff0bd6ffa966d1b32539a6510af816a959d160      # GitHub release asset digest
BISON_URL=https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz                               # Wine needs bison >= 3.0
BISON_SHA=9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2
# Python build tools (requirements.txt pins versions and wheel hashes).
# LLVM 15.0.7 for DXMT's native winemetal part (DXMT CI recipe): git tag, commit verified.
LLVM_TAG=llvmorg-15.0.7
LLVM_COMMIT=8dfdcc7b7bf66834a761bd8de445840ef68e4d1a
# 3Shain's wine v8.16 headers and tools, used by DXMT's build (DXMT CI). No upstream checksum exists: this hash was
# recorded on first download (2026-10-14) and is enforced from then on.
SHAIN_WINE_URL=https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz
SHAIN_WINE_SHA=289c7f19e270a3d3d0a6fdb07691b176c70a0795f6811e5255cba82425de4f10

# --- Libraries bundled with the runtime --------------------------------------------------------------------------------
# FreeType: Wine's font back end (Gcenx configures --with-freetype). Checksum: FreeType 2.13.3 release announcement.
FREETYPE_URL=https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz
FREETYPE_SHA=0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
# Khronos Vulkan loader + headers (Apache-2.0): win32u.so loads libvulkan.1.dylib, which loads the driver named by
# VK_DRIVER_FILES (AnvilMac sets it per launch; the runtime's default is MoltenVK).
VULKAN_LOADER_REPO=https://github.com/KhronosGroup/Vulkan-Loader.git
VULKAN_LOADER_TAG=vulkan-sdk-1.4.363.0
VULKAN_LOADER_COMMIT=fa218055ff4948b159f31d43f800c808a13d51df
VULKAN_HEADERS_REPO=https://github.com/KhronosGroup/Vulkan-Headers.git
VULKAN_HEADERS_TAG=vulkan-sdk-1.4.363.0
VULKAN_HEADERS_COMMIT=6802bb4733b63ed5efd3adb308a6c885ef180ea1
# MoltenVK (Apache-2.0), official macOS release build.
MOLTENVK_VERSION=1.4.2
MOLTENVK_URL=https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar
MOLTENVK_SHA=f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e      # GitHub release asset digest

# Wine Mono (.NET for Windows programs), the version Wine 11.19 asks for (dlls/appwiz.cpl/addons.c MONO_VERSION; the
# release's x86 .msi digest equals Wine's compiled-in MONO_SHA). Unpacked into share/wine/mono, where Wine uses it in
# place; its source ships in the source archive. Wine Gecko is not bundled (owner, 2026-10-16).
WINE_MONO_VERSION=11.3.0
WINE_MONO_URL=https://github.com/madewokherd/wine-mono/releases/download/wine-mono-11.3.0/wine-mono-11.3.0-x86.tar.xz
WINE_MONO_SHA=54a1b0111c3fe4b785eae688af94d27e64995707ad648b6fee8000381b80d298       # GitHub release asset digest
WINE_MONO_SRC_URL=https://github.com/madewokherd/wine-mono/releases/download/wine-mono-11.3.0/wine-mono-11.3.0-src.tar.xz
WINE_MONO_SRC_SHA=9f4f03285fbeed484980efbb1eba1c19069244aea401d2ff1585e3990782edf7   # GitHub release asset digest

# --- DXMT (Direct3D 10/11 on Metal) ------------------------------------------------------------------------------------
DXMT_REPO=https://github.com/3Shain/dxmt.git
DXMT_TAG=v0.80
DXMT_COMMIT=589adb780354b461645b29999cefaf533594ee99      # v0.80 = MIT; patches/dxmt adds LGPL-2.1+ changes (#166)

# --- Build settings ----------------------------------------------------------------------------------------------------
MACOSX_DEPLOYMENT_TARGET=10.15                             # as Gcenx's builds
RUNTIME_ID=anvilmac-wine-11.19-dxmt-0.80-x86_64
RUNTIME_NAME="AnvilMac Runtime (Wine 11.19 + DXMT 0.80)"
