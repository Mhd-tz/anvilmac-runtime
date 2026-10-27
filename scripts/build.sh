#!/bin/bash
# Reproducible AnvilMac runtime build: Wine (pinned release + patches/wine/series), DXMT (pinned release +
# patches/dxmt/series), the libraries the runtime bundles, packaging and the AnvilMac runtime manifest.
# The same script runs on a developer Mac (AnvilMac's Scripts/runtime/ci-dryrun.sh, under its write guard) and in
# GitHub Actions (.github/workflows/build.yml). It writes only inside $WORK.
#
# Usage: scripts/build.sh <work dir> [stage…]
#   stages (default: all, in order): fetch toolchain deps gstreamer wine dxmt package
# Output: <work>/out/<package>.tar.xz, <package>.manifest.json, SHA256SUMS, sources-<package>.tar (LGPL source offer)
set -euo pipefail
WORK="$(mkdir -p "$1" && cd "$1" && pwd -P)"; shift
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$REPO/inputs.sh"
STAGES=("$@"); [ ${#STAGES[@]} -gt 0 ] || STAGES=(fetch toolchain deps gstreamer wine dxmt package)

DL="$WORK/downloads"; SRC="$WORK/src"; BLD="$WORK/build"; TC="$WORK/toolchain"; DEPS="$WORK/deps"
STAGE="$WORK/stage"; OUT="$WORK/out"; LOGS="$WORK/logs"
mkdir -p "$DL" "$SRC" "$BLD" "$TC" "$DEPS" "$STAGE" "$OUT" "$LOGS" "$WORK/tmp"
# MACOSX_DEPLOYMENT_TARGET is passed only to Wine and the libraries bundled with it (Gcenx's 10.15). DXMT keeps its
# own: exported to everything, it made Apple's Metal compiler default to Metal 2.2, which DXMT's shaders can't use
# ("'kernel' attribute requires … macos-metal2.3", dry run 2026-10-16).
DEPLOY="MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
unset MACOSX_DEPLOYMENT_TARGET
export TMPDIR="$WORK/tmp" LC_ALL=C LANG=C
# Optional local wrappers, supplied explicitly by the guarded build harness (not used in CI).
SYSPATH="${ANVIL_BUILD_SHIMS:+$ANVIL_BUILD_SHIMS:}/usr/bin:/bin:/usr/sbin:/sbin"
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
    fetch_file "$WINE_MONO_URL" "$WINE_MONO_SHA" >/dev/null
    fetch_file "$WINE_MONO_SRC_URL" "$WINE_MONO_SRC_SHA" >/dev/null
    mkdir -p "$DL/pip"
    python3 -m pip download -q --no-cache-dir --require-hashes --only-binary=:all: -d "$DL/pip" -r "$REPO/requirements.txt" \
        || fail "pip download"
    git_at "$VULKAN_HEADERS_REPO" "$VULKAN_HEADERS_TAG" "$VULKAN_HEADERS_COMMIT" "$SRC/Vulkan-Headers"
    git_at "$VULKAN_LOADER_REPO" "$VULKAN_LOADER_TAG" "$VULKAN_LOADER_COMMIT" "$SRC/Vulkan-Loader"
    git_at "$DXMT_REPO" "$DXMT_TAG" "$DXMT_COMMIT" "$SRC/dxmt" recursive
    git_at "$GST_REPO" "$GST_TAG" "$GST_COMMIT" "$SRC/gstreamer"
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

gstreamer() {
    step "GStreamer $GST_TAG (x86_64): game video through macOS's own decoders"
    # Video: applemedia's vtdec (H.264, HEVC, MPEG-2 through VideoToolbox). Audio: osxaudio's atdec (AAC, MP3 through
    # AudioToolbox). Demuxers (MP4, Matroska/WebM), parsers and the conversions Wine's winegstreamer uses. Every other
    # optional feature is off. Quirks (1.28.8): core's check library must stay enabled (plugins-good's docs need its
    # helper); plugins-bad's own gl option must be on for applemedia to link GStreamer's GL library.
    local b="$BLD/gstreamer" e
    if [ ! -f "$DEPS/lib/libgstreamer-1.0.0.dylib" ]; then
        timed gst-setup /usr/bin/env "$DEPLOY" CC='/usr/bin/clang -arch x86_64' CXX='/usr/bin/clang++ -arch x86_64' \
            OBJC='/usr/bin/clang -arch x86_64' OBJCXX='/usr/bin/clang++ -arch x86_64' /usr/bin/arch -x86_64 /bin/bash -c \
            "PATH='$TC/venv/bin:$SYSPATH' meson setup '$b' '$SRC/gstreamer' --prefix='$DEPS' --libdir=lib --buildtype=release \
            --wrap-mode=default -Dauto_features=disabled -Dbase=enabled -Dgood=enabled -Dbad=enabled -Dugly=disabled \
            -Dlibav=disabled -Ddevtools=disabled -Dges=disabled -Drtsp_server=disabled -Dpython=disabled -Dtls=disabled \
            -Dlibnice=disabled -Dgpl=disabled -Dtests=disabled -Dexamples=disabled -Dintrospection=disabled -Dnls=disabled \
            -Ddoc=disabled -Dgst-full=disabled -Dorc=disabled -Dqt5=disabled -Dqt6=disabled -Dwebrtc=disabled \
            -Dbenchmarks=disabled -Dgst-examples=disabled -Dtools=enabled -Dgstreamer:tools=enabled -Dgstreamer:check=enabled \
            -Dgstreamer:ptp-helper=disabled -Dgst-plugins-base:app=enabled -Dgst-plugins-base:audioconvert=enabled \
            -Dgst-plugins-base:audioresample=enabled -Dgst-plugins-base:videoconvertscale=enabled \
            -Dgst-plugins-base:playback=enabled -Dgst-plugins-base:typefind=enabled -Dgst-plugins-base:gl=enabled \
            -Dgst-plugins-base:gl-graphene=disabled -Dgst-plugins-base:gl-png=disabled -Dgst-plugins-base:gl-jpeg=disabled \
            -Dgst-plugins-base:tools=enabled -Dgst-plugins-good:isomp4=enabled -Dgst-plugins-good:matroska=enabled \
            -Dgst-plugins-good:audioparsers=enabled -Dgst-plugins-good:videofilter=enabled \
            -Dgst-plugins-good:deinterlace=enabled -Dgst-plugins-good:osxaudio=enabled -Dgst-plugins-good:wavparse=enabled \
            -Dgst-plugins-good:id3demux=enabled -Dgst-plugins-bad:applemedia=enabled -Dgst-plugins-bad:videoparsers=enabled \
            -Dgst-plugins-bad:gl=enabled"
        timed gst-build /usr/bin/env "$DEPLOY" /usr/bin/arch -x86_64 /bin/bash -c "PATH='$TC/venv/bin:$SYSPATH' meson install -C '$b'"
    fi
    # Every element Wine and game videos need must be there.
    for e in decodebin videoconvert audioconvert audioresample videoflip deinterlace capsfilter qtdemux matroskademux \
             h264parse h265parse aacparse mpegaudioparse vtdec atdec; do
        /usr/bin/env -i HOME="$WORK/tmp" TMPDIR="$WORK/tmp" DYLD_LIBRARY_PATH="$DEPS/lib" \
            GST_PLUGIN_SYSTEM_PATH_1_0="$DEPS/lib/gstreamer-1.0" GST_REGISTRY_1_0="$WORK/tmp/gst-registry.bin" \
            /usr/bin/arch -x86_64 "$DEPS/bin/gst-inspect-1.0" "$e" > /dev/null 2>&1 || fail "GStreamer element missing: $e"
    done
    ls "$DEPS/lib/gstreamer-1.0" | tee "$LOGS/gstreamer-plugins.txt"
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
            --without-gssapi --with-gstreamer --without-inotify --without-krb5 --with-mingw='$TC/$MINGW_WINE/bin/clang' \
            --without-netapi --with-opencl --without-opengl --without-oss --without-pcap --without-pcsclite --with-pthread \
            --without-pulse --without-sane --without-sdl --without-udev --with-unwind --without-usb --without-v4l2 --with-vulkan \
            --without-wayland --without-x \
            CC='/usr/bin/clang -arch x86_64' OBJC='/usr/bin/clang -arch x86_64' CFLAGS=-O2 OBJCFLAGS=-O2 CROSSCFLAGS=-O2 \
            CPPFLAGS='-I$DEPS/include' LDFLAGS='-L$DEPS/lib' \
            FREETYPE_CFLAGS='-I$DEPS/include/freetype2' FREETYPE_LIBS='-L$DEPS/lib -lfreetype' \
            ac_cv_lib_soname_freetype=libfreetype.6.dylib ac_cv_lib_soname_vulkan=libvulkan.1.dylib \
            GSTREAMER_CFLAGS='-I$DEPS/include/gstreamer-1.0 -I$DEPS/include/glib-2.0 -I$DEPS/lib/glib-2.0/include' \
            GSTREAMER_LIBS='-L$DEPS/lib -lgstvideo-1.0 -lgstaudio-1.0 -lgsttag-1.0 -lgstbase-1.0 -lgstreamer-1.0 -lgobject-2.0 -lglib-2.0'"
        grep -E '^#define (SONAME_LIBFREETYPE|SONAME_LIBVULKAN|HAVE_FT2BUILD_H)' "$b/include/config.h" | tee "$LOGS/wine-config.txt"
        grep -q SONAME_LIBVULKAN "$LOGS/wine-config.txt" && grep -q SONAME_LIBFREETYPE "$LOGS/wine-config.txt" \
            || fail "configure did not enable FreeType and Vulkan (logs/wine-configure.log)"
    fi
    timed wine-make /usr/bin/env "$DEPLOY" /usr/bin/arch -x86_64 /bin/bash -c "cd '$b' && PATH='$TC/bison/bin:$SYSPATH:$TC/$MINGW_WINE/bin' make -j$NCPU"
    rm -rf "$STAGE/wine"
    timed wine-install /usr/bin/env "$DEPLOY" /usr/bin/arch -x86_64 /bin/bash -c "cd '$b' && PATH='$TC/bison/bin:$SYSPATH:$TC/$MINGW_WINE/bin' make install DESTDIR='$STAGE/wine'"
    "$STAGE/wine/bin/wine" --version | tee "$LOGS/wine-version.txt"
    [ -f "$STAGE/wine/lib/wine/x86_64-unix/winegstreamer.so" ] || fail "winegstreamer was not built (GStreamer not found?)"
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
    local name="anvilmac-runtime-wine-$WINE_VERSION-$RUNTIME_RELEASE-dxmt-0.80-x86_64" pkg root L f
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
    # Wine Mono, shared install: Wine finds share/wine/mono/wine-mono-<version> and uses it without copying it into
    # each prefix (as in Gcenx's packages). Wine Gecko is not bundled.
    mkdir -p "$root/share/wine/mono"
    tar -xJf "$DL/$(basename "$WINE_MONO_URL")" -C "$root/share/wine/mono"
    [ -d "$root/share/wine/mono/wine-mono-$WINE_MONO_VERSION" ] || fail "Wine Mono did not unpack to wine-mono-$WINE_MONO_VERSION"
    # GStreamer for winegstreamer: its libraries next to Wine's (not the test library or GObject introspection), the
    # plugins in lib/gstreamer-1.0 and the plugin scanner in libexec. AnvilMac sets GST_PLUGIN_SYSTEM_PATH_1_0 and
    # GST_PLUGIN_SCANNER_1_0 to them and GST_REGISTRY_1_0 into the game's prefix (manifest launchEnvironment).
    mkdir -p "$L/gstreamer-1.0" "$root/libexec/gstreamer-1.0"
    for f in "$DEPS"/lib/lib*.dylib; do
        [ -L "$f" ] && continue
        case "$(basename "$f")" in libgst*|libglib-*|libgobject-*|libgmodule-*|libgio-*|libgthread-*|libintl*|libffi*|libpcre2-*) ;; *) continue ;; esac
        case "$(basename "$f")" in libgstcheck-*) continue ;; esac
        cp "$f" "$L/"
    done
    cp "$DEPS"/lib/gstreamer-1.0/*.dylib "$L/gstreamer-1.0/"
    cp "$DEPS/libexec/gstreamer-1.0/gst-plugin-scanner" "$root/libexec/gstreamer-1.0/"
    for f in "$L"/gstreamer-1.0/*.dylib "$root/libexec/gstreamer-1.0/gst-plugin-scanner" "$L"/libg*.dylib "$L"/libintl*.dylib \
             "$L"/libffi*.dylib "$L"/libpcre2-*.dylib "$L/wine/x86_64-unix/winegstreamer.so"; do
        otool -L "$f" | awk 'NR>1 {print $1}' | grep "^$DEPS/lib/" | while read -r d; do
            install_name_tool -change "$d" "@rpath/$(basename "$d")" "$f"; done
        otool -l "$f" | awk '/LC_RPATH/{getline; getline; print $2}' | grep "^$DEPS" | while read -r d; do
            install_name_tool -delete_rpath "$d" "$f"; done
    done
    for f in "$L"/gstreamer-1.0/*.dylib; do install_name_tool -add_rpath @loader_path/../ "$f"; codesign -f -s - "$f" 2>/dev/null; done
    install_name_tool -add_rpath @loader_path/../../lib/ "$root/libexec/gstreamer-1.0/gst-plugin-scanner"
    codesign -f -s - "$root/libexec/gstreamer-1.0/gst-plugin-scanner" 2>/dev/null
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
    cp "$SRC/gstreamer/subprojects/gstreamer/COPYING" "$root/share/doc/anvilmac-runtime/GStreamer-COPYING"
    cp "$(ls -d "$SRC"/gstreamer/subprojects/glib-*/ | head -1)COPYING" "$root/share/doc/anvilmac-runtime/GLib-COPYING"
    cp "$(ls -d "$SRC"/gstreamer/subprojects/libffi*/ | head -1)LICENSE" "$root/share/doc/anvilmac-runtime/libffi-LICENSE"
    cp "$(ls -d "$SRC"/gstreamer/subprojects/pcre2-*/ | head -1)LICENCE.md" "$root/share/doc/anvilmac-runtime/PCRE2-LICENCE.md"
    cp "$(ls -d "$SRC"/gstreamer/subprojects/proxy-libintl-*/ | head -1)COPYING" "$root/share/doc/anvilmac-runtime/proxy-libintl-COPYING"
    # Wine Mono's binary release has no licence file; its source's COPYING lists each part's licence (LGPL, MIT, MS-PL,
    # zlib, SharpZipLib's GPL with exception).
    tar -xJOf "$DL/$(basename "$WINE_MONO_SRC_URL")" "wine-mono-$WINE_MONO_VERSION/COPYING" > "$root/share/doc/anvilmac-runtime/Wine-Mono-COPYING" \
        && [ -s "$root/share/doc/anvilmac-runtime/Wine-Mono-COPYING" ] || fail "Wine Mono's COPYING not found"
    { echo "AnvilMac runtime: Wine $WINE_VERSION + DXMT $DXMT_TAG, built $(date -u +%F) from pinned sources."
      echo "Wine patches:"; grep -v '^#' "$REPO/patches/wine/series"
      echo "DXMT patches:"; grep -v '^#' "$REPO/patches/dxmt/series"
      echo "Wine Mono $WINE_MONO_VERSION (unmodified upstream release; its source, wine-mono-$WINE_MONO_VERSION-src.tar.xz, is in the source archive)."
      echo "GStreamer $GST_TAG ($GST_COMMIT) with GLib, libffi, PCRE2 and proxy-libintl from its wraps (sources, including the downloaded wraps, in the source archive)."
      echo "Corresponding source: sources-$name.tar, published with this package."; } > "$root/share/doc/anvilmac-runtime/NOTICE-AnvilMac.txt"
    ( cd "$pkg" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 ) > "$pkg/SHA256SUMS"
    ( cd "$OUT" && tar -cJf "$name.tar.xz" "$name" )
    # LGPL source offer: Wine/Mono tarballs plus the exact patched DXMT tree, including its submodules.
    # Patches and a Git URL alone do not include the corresponding DXMT source. Exclude Git metadata and the
    # build marker, not source files. The other Git-fetched library sources are included too.
    ( cd "$WORK" && tar --exclude=.git --exclude=.anvil-patched -cf "$OUT/sources-$name.tar" \
        downloads/*.tar* src/dxmt src/Vulkan-Headers src/Vulkan-Loader src/gstreamer \
        -C "$REPO" LICENSE README.md inputs.sh requirements.txt patches scripts .github )
    python3 "$REPO/scripts/manifest.py" "$pkg" "$OUT/$name.manifest.json"
    ( cd "$OUT" && shasum -a 256 "$name.tar.xz" "sources-$name.tar" "$name.manifest.json" ) > "$OUT/SHA256SUMS"
    cat "$OUT/SHA256SUMS"; du -sh "$pkg" "$OUT/$name.tar.xz"
}

for s in "${STAGES[@]}"; do "$s"; done
step "done; timings in logs/timings.tsv"
cat "$LOGS/timings.tsv"
