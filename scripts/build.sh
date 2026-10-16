#!/bin/bash
# Reproducible AnvilMac runtime build: Wine (pinned release + patches/wine/series), DXMT (pinned release +
# patches/dxmt/series), the libraries the runtime bundles, packaging and the AnvilMac runtime manifest.
# The same script runs on a developer Mac (AnvilMac's Scripts/runtime/ci-dryrun.sh, under its write guard) and in
# GitHub Actions (.github/workflows/build.yml). It writes only inside $WORK.
#
# Usage: scripts/build.sh <work dir> [stage…]
#   stages (default: all, in order): fetch toolchain deps wine dxmt package
# Output: <work>/out/<package>.tar.xz, <package>.manifest.json, SHA256SUMS, sources-<package>.tar (LGPL source offer)
set -euo pipefail
WORK="$(mkdir -p "$1" && cd "$1" && pwd -P)"; shift
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$REPO/inputs.sh"
STAGES=("$@"); [ ${#STAGES[@]} -gt 0 ] || STAGES=(fetch toolchain deps wine dxmt package)

DL="$WORK/downloads"; SRC="$WORK/src"; BLD="$WORK/build"; TC="$WORK/toolchain"; DEPS="$WORK/deps"
STAGE="$WORK/stage"; OUT="$WORK/out"; LOGS="$WORK/logs"
mkdir -p "$DL" "$SRC" "$BLD" "$TC" "$DEPS" "$STAGE" "$OUT" "$LOGS" "$WORK/tmp"
# MACOSX_DEPLOYMENT_TARGET is passed only to Wine and the libraries bundled with it (Gcenx's 10.15). DXMT keeps its
# own: exported to everything, it made Apple's Metal compiler default to Metal 2.2, which DXMT's shaders can't use
# ("'kernel' attribute requires … macos-metal2.3", dry run 2026-10-16).
DEPLOY="MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
unset MACOSX_DEPLOYMENT_TARGET
export TMPDIR="$WORK/tmp" LC_ALL=C LANG=C
SYSPATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH="$SYSPATH"
NCPU="$(sysctl -n hw.ncpu)"

step() { printf '\n=== [%s] %s\n' "$(date +%T)" "$*"; }
fail() { printf '\n*** BUILD FAILED: %s ***\n' "$*" >&2; exit 1; }
timed() { # timed <label> <command…>: logged to logs/<label>.log, wall time and disk use recorded
    local label="$1" t0 rc; shift
    t0=$(date +%s)
    set +e; "$@" > "$LOGS/$label.log" 2>&1; rc=$?; set -e
    printf '%s\t%ss\texit %s\tdisk %s\n' "$label" "$(( $(date +%s) - t0 ))" "$rc" "$(du -sh "$WORK" | cut -f1)" >> "$LOGS/timings.tsv"
    echo "$label: exit $rc after $(( $(date +%s) - t0 ))s (logs/$label.log)"
    [ $rc = 0 ] || { tail -20 "$LOGS/$label.log" >&2; fail "$label"; }
}
fetch_file() { # fetch_file <url> <sha256> -> path
    local f="$DL/$(basename "$1")" got
    [ -f "$f" ] || curl -fL -sS --retry 3 -o "$f" "$1" || fail "download $1"
    got="$(shasum -a 256 "$f" | cut -d' ' -f1)"
    [ "$got" = "$2" ] || fail "checksum mismatch for $(basename "$f"): got $got, expected $2"
    echo "$f"
}
git_at() { # git_at <repo> <tag> <commit> <dir> [--recursive]: shallow clone of a tag, commit verified
    if [ ! -d "$4/.git" ]; then
        git clone -q --depth 1 --branch "$2" ${5:+--recurse-submodules} "$1" "$4" || fail "clone $1"
    fi
    [ "$(git -C "$4" rev-parse HEAD)" = "$3" ] || fail "$1 $2 is not commit $3"
}

fetch() {
    step "fetch and verify inputs"
    fetch_file "$WINE_URL" "$WINE_SHA" >/dev/null
    fetch_file "$MINGW_WINE_URL" "$MINGW_WINE_SHA" >/dev/null
    fetch_file "$MINGW_DXMT_URL" "$MINGW_DXMT_SHA" >/dev/null
    fetch_file "$BISON_URL" "$BISON_SHA" >/dev/null
    fetch_file "$FREETYPE_URL" "$FREETYPE_SHA" >/dev/null
    fetch_file "$MOLTENVK_URL" "$MOLTENVK_SHA" >/dev/null
    fetch_file "$SHAIN_WINE_URL" "$SHAIN_WINE_SHA" >/dev/null
    mkdir -p "$DL/pip"
    python3 -m pip download -q --no-cache-dir --require-hashes --only-binary=:all: -d "$DL/pip" -r "$REPO/requirements.txt" \
        || fail "pip download"
    git_at "$VULKAN_HEADERS_REPO" "$VULKAN_HEADERS_TAG" "$VULKAN_HEADERS_COMMIT" "$SRC/Vulkan-Headers"
    git_at "$VULKAN_LOADER_REPO" "$VULKAN_LOADER_TAG" "$VULKAN_LOADER_COMMIT" "$SRC/Vulkan-Loader"
    git_at "$DXMT_REPO" "$DXMT_TAG" "$DXMT_COMMIT" "$SRC/dxmt" recursive
    git_at https://github.com/llvm/llvm-project.git "$LLVM_TAG" "$LLVM_COMMIT" "$SRC/llvm-project"
    ( cd "$WORK" && shasum -a 256 downloads/*.* downloads/pip/* ) > "$LOGS/inputs.sha256"
    git -C "$SRC/dxmt" submodule status --recursive > "$LOGS/dxmt-submodules.txt"
}

toolchain() {
    step "toolchains: llvm-mingw ×2, bison, Python tools, LLVM 15 (DXMT)"
    local m
    for m in "$MINGW_WINE" "$MINGW_DXMT"; do [ -d "$TC/$m" ] || tar -xJf "$DL/$m.tar.xz" -C "$TC"; done
    if [ ! -x "$TC/bison/bin/bison" ]; then
        rm -rf "$BLD/bison-3.8.2"; tar -xJf "$DL/bison-3.8.2.tar.xz" -C "$BLD"
        timed tc-bison /bin/bash -c "cd '$BLD/bison-3.8.2' && ./configure --prefix='$TC/bison' --disable-nls gl_cv_func_unlink_parent_fails=yes && make -j$NCPU && make install"
    fi
    if [ ! -x "$TC/venv/bin/meson" ]; then
        python3 -m venv "$TC/venv"
        timed tc-pip "$TC/venv/bin/pip" install -q --no-index --no-cache-dir --require-hashes --find-links "$DL/pip" -r "$REPO/requirements.txt"
    fi
    [ -d "$TC/shain-wine" ] || { mkdir -p "$TC/shain-wine"; tar -xzf "$DL/wine.tar.gz" -C "$TC/shain-wine"; }
    if [ ! -f "$TC/llvm-darwin/lib/libLLVMCore.a" ]; then
        timed tc-llvm15 /bin/bash -c "PATH='$TC/venv/bin:$SYSPATH' cmake -B '$BLD/llvm-darwin' -S '$SRC/llvm-project/llvm' \
            -DCMAKE_INSTALL_PREFIX='$TC/llvm-darwin' -DCMAKE_OSX_ARCHITECTURES=x86_64 -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
            -DLLVM_ENABLE_ASSERTIONS=On -DLLVM_ENABLE_ZSTD=Off -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD='' \
            -DLLVM_BUILD_TOOLS=Off -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off -G Ninja \
            && PATH='$TC/venv/bin:$SYSPATH' cmake --build '$BLD/llvm-darwin' && PATH='$TC/venv/bin:$SYSPATH' cmake --install '$BLD/llvm-darwin'"
        rm -rf "$BLD/llvm-darwin"      # disk: keep only the install
    fi
}

deps() {
    step "bundled libraries (x86_64): FreeType, Vulkan loader, MoltenVK"
    if [ ! -f "$DEPS/lib/libfreetype.6.dylib" ]; then
        rm -rf "$BLD/freetype-2.13.3"; tar -xJf "$DL/freetype-2.13.3.tar.xz" -C "$BLD"
        timed dep-freetype /usr/bin/env "$DEPLOY" /usr/bin/arch -x86_64 /bin/bash -c "cd '$BLD/freetype-2.13.3' && ./configure --prefix='$DEPS' \
            CC='/usr/bin/clang -arch x86_64' --without-harfbuzz --without-png --without-brotli --without-bzip2 --with-zlib=no \
            --enable-shared --disable-static && make -j$NCPU && make install"
    fi
    if [ ! -f "$DEPS/lib/libvulkan.1.dylib" ]; then
        timed dep-vulkan-headers /bin/bash -c "PATH='$TC/venv/bin:$SYSPATH' cmake -S '$SRC/Vulkan-Headers' -B '$BLD/vulkan-headers' \
            -DCMAKE_INSTALL_PREFIX='$DEPS' -G Ninja && PATH='$TC/venv/bin:$SYSPATH' cmake --install '$BLD/vulkan-headers'"
        timed dep-vulkan-loader /usr/bin/env "$DEPLOY" /bin/bash -c "PATH='$TC/venv/bin:$SYSPATH' cmake -S '$SRC/Vulkan-Loader' -B '$BLD/vulkan-loader' -G Ninja \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_INSTALL_PREFIX='$DEPS' \
            -DVULKAN_HEADERS_INSTALL_DIR='$DEPS' -DBUILD_TESTS=OFF -DCMAKE_IGNORE_PREFIX_PATH='/opt/homebrew;/usr/local' \
            && PATH='$TC/venv/bin:$SYSPATH' cmake --build '$BLD/vulkan-loader' && PATH='$TC/venv/bin:$SYSPATH' cmake --install '$BLD/vulkan-loader'"
    fi
    if [ ! -f "$DEPS/lib/libMoltenVK.dylib" ]; then
        rm -rf "$BLD/moltenvk"; mkdir -p "$BLD/moltenvk"; tar -xf "$DL/MoltenVK-macos.tar" -C "$BLD/moltenvk"
        cp "$(find "$BLD/moltenvk" -path '*dynamic*' -name libMoltenVK.dylib | head -1)" "$DEPS/lib/libMoltenVK.dylib"
        cp "$(find "$BLD/moltenvk" -name LICENSE | head -1)" "$DEPS/MoltenVK-LICENSE" 2>/dev/null || true
    fi
    lipo -info "$DEPS/lib/libfreetype.6.dylib" "$DEPS/lib/libvulkan.1.dylib" "$DEPS/lib/libMoltenVK.dylib"
}

wine() {
    step "Wine $WINE_VERSION: patches, configure (x86_64, WoW64), build, install"
    local s="$SRC/$WINE_DIR" b="$BLD/wine" p
    if [ ! -d "$s" ]; then
        tar -xzf "$DL/$(basename "$WINE_URL")" -C "$SRC"
        while read -r p; do
            case "$p" in ''|'#'*) continue ;; esac
            ( cd "$s" && patch -p1 -F0 -s < "$REPO/patches/wine/$p" ) || fail "patch does not apply: $p"
            echo "applied $p $(shasum -a 256 "$REPO/patches/wine/$p" | cut -c1-16)" >> "$LOGS/wine-patches.txt"
        done < "$REPO/patches/wine/series"
    fi
    mkdir -p "$b"
    if [ ! -f "$b/Makefile" ]; then
        timed wine-configure /usr/bin/env "$DEPLOY" /usr/bin/arch -x86_64 /bin/bash -c "cd '$b' && PATH='$TC/bison/bin:$SYSPATH:$TC/$MINGW_WINE/bin' '$s/configure' \
            --build=x86_64-apple-darwin --prefix=/ --enable-archs=i386,x86_64 --enable-win64 --disable-tests --disable-winebth_sys \
            --disable-winemenubuilder --without-alsa --without-capi --with-coreaudio --without-cups --without-dbus --without-ffmpeg \
            --without-fontconfig --with-freetype --without-gettext --without-gettextpo --without-gphoto --without-gnutls \
            --without-gssapi --without-gstreamer --without-inotify --without-krb5 --with-mingw='$TC/$MINGW_WINE/bin/clang' \
            --without-netapi --with-opencl --without-opengl --without-oss --without-pcap --without-pcsclite --with-pthread \
            --without-pulse --without-sane --without-sdl --without-udev --with-unwind --without-usb --without-v4l2 --with-vulkan \
            --without-wayland --without-x \
            CC='/usr/bin/clang -arch x86_64' OBJC='/usr/bin/clang -arch x86_64' CFLAGS=-O2 OBJCFLAGS=-O2 CROSSCFLAGS=-O2 \
            CPPFLAGS='-I$DEPS/include' LDFLAGS='-L$DEPS/lib' \
            FREETYPE_CFLAGS='-I$DEPS/include/freetype2' FREETYPE_LIBS='-L$DEPS/lib -lfreetype' \
            ac_cv_lib_soname_freetype=libfreetype.6.dylib ac_cv_lib_soname_vulkan=libvulkan.1.dylib"
        grep -E '^#define (SONAME_LIBFREETYPE|SONAME_LIBVULKAN|HAVE_FT2BUILD_H)' "$b/include/config.h" | tee "$LOGS/wine-config.txt"
        grep -q SONAME_LIBVULKAN "$LOGS/wine-config.txt" && grep -q SONAME_LIBFREETYPE "$LOGS/wine-config.txt" \
            || fail "configure did not enable FreeType and Vulkan (logs/wine-configure.log)"
    fi
    timed wine-make /usr/bin/env "$DEPLOY" /usr/bin/arch -x86_64 /bin/bash -c "cd '$b' && PATH='$TC/bison/bin:$SYSPATH:$TC/$MINGW_WINE/bin' make -j$NCPU"
    rm -rf "$STAGE/wine"
    timed wine-install /usr/bin/env "$DEPLOY" /usr/bin/arch -x86_64 /bin/bash -c "cd '$b' && PATH='$TC/bison/bin:$SYSPATH:$TC/$MINGW_WINE/bin' make install DESTDIR='$STAGE/wine'"
    "$STAGE/wine/bin/wine" --version | tee "$LOGS/wine-version.txt"
}

dxmt() {
    step "DXMT $DXMT_TAG: patches, build (win64 with native winemetal.so, win32)"
    local d="$SRC/dxmt" p a out extra
    if [ ! -f "$d/.anvil-patched" ]; then
        while read -r p; do
            case "$p" in ''|'#'*) continue ;; esac
            git -C "$d" apply "$REPO/patches/dxmt/$p" || fail "DXMT patch does not apply: $p"
            echo "applied $p $(shasum -a 256 "$REPO/patches/dxmt/$p" | cut -c1-16)" >> "$LOGS/dxmt-patches.txt"
        done < "$REPO/patches/dxmt/series"
        touch "$d/.anvil-patched"
    fi
    for a in win64 win32; do
        out="$BLD/dxmt-$a"; extra=""; [ $a = win64 ] && extra="-Dnative_llvm_path=$TC/llvm-darwin"
        [ -f "$out/build.ninja" ] || timed "dxmt-$a-setup" /bin/bash -c "cd '$d' && PATH='$TC/venv/bin:$SYSPATH:$TC/$MINGW_DXMT/bin' meson setup \
            --cross-file build-$a.txt $extra -Dwine_install_path='$TC/shain-wine' '$out' --buildtype release --prefix '$out/install' --strip"
        timed "dxmt-$a-build" /bin/bash -c "PATH='$TC/venv/bin:$SYSPATH:$TC/$MINGW_DXMT/bin' meson compile -C '$out' && PATH='$TC/venv/bin:$SYSPATH:$TC/$MINGW_DXMT/bin' meson install -C '$out'"
    done
}

package() {
    step "package"
    local name="anvilmac-runtime-wine-$WINE_VERSION-dxmt-0.80-x86_64" pkg root L f
    pkg="$OUT/$name"; root="$pkg/Contents/Resources/wine"; L="$root/lib"
    rm -rf "$pkg"; mkdir -p "$root"
    cp -R "$STAGE/wine/." "$root/"
    # Bundled libraries next to Wine's own, found through the rpaths below (dlopen of a leaf name searches the
    # caller's LC_RPATH entries): win32u.so opens libfreetype.6.dylib and libvulkan.1.dylib.
    for f in libfreetype.6.dylib libvulkan.1.dylib libMoltenVK.dylib; do cp -L "$DEPS/lib/$f" "$L/$f"; done
    mkdir -p "$root/share/vulkan/icd.d"
    printf '%s\n' '{' '    "file_format_version": "1.0.1",' '    "ICD": {' \
        '        "library_path": "../../../lib/libMoltenVK.dylib",' "        \"api_version\": \"1.4.0\"," '        "is_portability_driver": true' \
        '    }' '}' > "$root/share/vulkan/icd.d/MoltenVK_icd.json"
    # DXMT: d3d11/dxgi/d3d10core/winemetal as Wine builtins, winemetal.so on the Unix side.
    for a in x86_64:win64 i386:win32; do
        for f in d3d11 dxgi d3d10core winemetal; do
            cp "$(find "$BLD/dxmt-${a#*:}/install" -name "$f.dll" | head -1)" "$L/wine/${a%%:*}-windows/$f.dll"
        done
    done
    cp "$(find "$BLD/dxmt-win64/install" -name winemetal.so | head -1)" "$L/wine/x86_64-unix/winemetal.so"
    # Install ids and rpaths as in Gcenx's packaging: leaf ids, @loader_path/ and @loader_path/../../ (lib/).
    for f in "$L"/*.dylib "$L"/wine/x86_64-unix/*.so; do
        install_name_tool -id "$(basename "$f")" "$f" 2>/dev/null || true
        for rp in @loader_path/ @loader_path/../../; do
            otool -l "$f" | grep -q "path $rp " || install_name_tool -add_rpath "$rp" "$f" 2>/dev/null || true
        done
        codesign -f -s - "$f" 2>/dev/null
    done
    # Licences and notices.
    mkdir -p "$root/share/doc/anvilmac-runtime"
    cp "$SRC/$WINE_DIR/COPYING.LIB" "$root/share/doc/anvilmac-runtime/Wine-COPYING.LIB"
    cp "$SRC/$WINE_DIR/LICENSE" "$root/share/doc/anvilmac-runtime/Wine-LICENSE"
    cp "$BLD/freetype-2.13.3/docs/FTL.TXT" "$root/share/doc/anvilmac-runtime/FreeType-FTL.TXT"
    cp "$SRC/Vulkan-Loader/LICENSE.txt" "$root/share/doc/anvilmac-runtime/Vulkan-Loader-LICENSE.txt"
    [ -f "$DEPS/MoltenVK-LICENSE" ] && cp "$DEPS/MoltenVK-LICENSE" "$root/share/doc/anvilmac-runtime/MoltenVK-LICENSE"
    cp "$SRC/dxmt/LICENSE" "$root/share/doc/anvilmac-runtime/DXMT-LICENSE" 2>/dev/null || true
    { echo "AnvilMac runtime: Wine $WINE_VERSION + DXMT $DXMT_TAG, built $(date -u +%F) from pinned sources."
      echo "Wine patches:"; grep -v '^#' "$REPO/patches/wine/series"
      echo "DXMT patches:"; grep -v '^#' "$REPO/patches/dxmt/series"
      echo "Corresponding source: sources-$name.tar, published with this package."; } > "$root/share/doc/anvilmac-runtime/NOTICE-AnvilMac.txt"
    ( cd "$pkg" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 ) > "$pkg/SHA256SUMS"
    ( cd "$OUT" && tar -cJf "$name.tar.xz" "$name" )
    # LGPL source offer: the exact Wine source, every patch, the build scripts and the other sources' tarballs.
    ( cd "$WORK" && tar -cf "$OUT/sources-$name.tar" downloads/*.tar* downloads/MoltenVK-macos.tar \
        -C "$REPO" LICENSE README.md inputs.sh requirements.txt patches scripts .github )
    python3 "$REPO/scripts/manifest.py" "$pkg" "$OUT/$name.manifest.json"
    ( cd "$OUT" && shasum -a 256 "$name.tar.xz" "sources-$name.tar" "$name.manifest.json" ) > "$OUT/SHA256SUMS"
    cat "$OUT/SHA256SUMS"; du -sh "$pkg" "$OUT/$name.tar.xz"
}

for s in "${STAGES[@]}"; do "$s"; done
step "done; timings in logs/timings.tsv"
cat "$LOGS/timings.tsv"
