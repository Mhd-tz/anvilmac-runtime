#!/usr/bin/env python3
"""Writes the AnvilMac runtime manifest for a built package (AnvilCore RuntimeManifest, formatVersion 1).

Usage: manifest.py <package dir> <out.json>

The package stays experimental and local-only until it passes AnvilMac's acceptance set; graphics backends start as
"untested". `integrity` covers the files AnvilMac checks before every launch (Wine's loader and server, the Unix
libraries it relies on, the bundled libraries and DXMT); SHA256SUMS in the package lists every file.
"""
import hashlib, json, os, re, subprocess, sys

pkg, out = sys.argv[1], sys.argv[2]
root = os.path.join(pkg, "Contents", "Resources", "wine")
env = {}
for line in open(os.path.join(os.path.dirname(__file__), "..", "inputs.sh")):
    line = line.split("#")[0].strip()
    if "=" in line:
        k, v = line.split("=", 1)
        env[k] = re.sub(r"\$(\w+)", lambda m: env.get(m.group(1), m.group(0)), v.strip('"'))   # $VAR from earlier lines

def sha(rel):
    return hashlib.sha256(open(os.path.join(root, rel), "rb").read()).hexdigest()

key_files = ["bin/wine", "bin/wineserver",
             "lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-unix/win32u.so", "lib/wine/x86_64-unix/winemac.so",
             "lib/wine/x86_64-unix/winemetal.so", "lib/wine/x86_64-unix/opengl32.so",
             "lib/libfreetype.6.dylib", "lib/libvulkan.1.dylib", "lib/libMoltenVK.dylib",
             "share/vulkan/icd.d/MoltenVK_icd.json",
             "lib/wine/x86_64-unix/winegstreamer.so", "lib/libgstreamer-1.0.0.dylib", "lib/libglib-2.0.0.dylib"]
key_files += [f"lib/wine/{a}-windows/{d}.dll" for a in ("x86_64", "i386")
              for d in ("d3d11", "dxgi", "d3d10core", "winemetal", "user32", "win32u")]
missing = [f for f in key_files if not os.path.exists(os.path.join(root, f))]
if missing:
    sys.exit(f"manifest: missing files: {missing}")
version = subprocess.run([os.path.join(root, "bin", "wine"), "--version"], capture_output=True, text=True).stdout.strip()

m = {
    "formatVersion": 1,
    "id": env["RUNTIME_ID"],
    "displayName": env["RUNTIME_NAME"] + " (experimental, CI build)",
    "version": env["WINE_VERSION"],
    "wine": {
        "version": env["WINE_VERSION"],
        "build": f"{version} from {env['WINE_URL']} (sha256 {env['WINE_SHA']}) + patches/wine/series; "
                 f"DXMT {env['DXMT_TAG']} ({env['DXMT_COMMIT']}) + patches/dxmt/series; MoltenVK {env['MOLTENVK_VERSION']}; "
                 f"Vulkan loader {env['VULKAN_LOADER_TAG']}",
        "metalLayerInterface": "extescape",
    },
    "source": {
        "url": "(release asset: the .tar.xz next to this manifest)",
        "sha256": "0" * 64,
        "sourceCode": "sources-<package>.tar, published with the package (inputs.sh, patches, scripts, source tarballs)",
        "license": "LGPL-2.1-or-later (Wine); DXMT v0.80 MIT + LGPL-2.1-or-later changes; MoltenVK and the Vulkan loader "
                   "Apache-2.0; FreeType FTL; GStreamer, GLib and proxy-libintl LGPL; libffi MIT; PCRE2 BSD-3-Clause",
    },
    "host": {"architecture": "x86_64", "translation": "rosetta2", "minimumMacOS": "15.0", "testedMacOS": []},
    "layout": {"root": "Contents/Resources/wine", "wine": "bin/wine", "wineserver": "bin/wineserver"},
    "windowsArchitectures": ["x86_64", "i386"],
    "graphics": [
        {"id": "wined3d", "status": "untested", "apis": ["d3d8", "d3d9", "d3d10", "d3d11"], "maxD3DFeatureLevel": "9_3"},
        {"id": "dxmt", "status": "untested", "apis": ["d3d10", "d3d11"], "maxD3DFeatureLevel": "11_1",
         "version": f"{env['DXMT_TAG']} + patches/dxmt/series"},
        {"id": "moltenvk", "status": "untested", "apis": ["vulkan"], "version": env["MOLTENVK_VERSION"]},
        {"id": "dxvk", "status": "absent", "apis": []},
        # Loads the user's own imported copy of Apple's D3DMetal (patches 0006-0008); nothing from Apple is in the package.
        {"id": "d3dmetal", "status": "untested", "apis": ["d3d10", "d3d11", "d3d12"], "maxD3DFeatureLevel": "12_1",
         "userToolkit": True, "selection": {}},
    ],
    "integrity": {f: sha(f) for f in key_files},
    "signing": "adhoc",
    "experimental": True,
    "localOnly": True,
    "prefixComponents": [
        {"source": "lib/wine/x86_64-windows/winemetal.dll", "destination": "drive_c/windows/system32/winemetal.dll"},
        {"source": "lib/wine/i386-windows/winemetal.dll", "destination": "drive_c/windows/syswow64/winemetal.dll"},
    ],
    # Upstream Wine sends WM_POINTER* for the mouse (bug 53847), so AnvilMac's stub warning doesn't apply.
    # Checked on this build with InputProbe, 64- and 32-bit, 2026-10-16.
    "fixesWineStubs": [{"id": "mouse-in-pointer", "architectures": ["x86_64", "i386"]}],
    # patches/wine/0003: runtime HLSL compiles log begin/end on the "shadertime" channel (off unless WINEDEBUG enables it).
    "diagnostics": ["shader-compile-timing"],
    # win32u.so loads the Khronos loader, which loads the driver named here (MoltenVK by default).
    # GStreamer (winegstreamer): only the runtime's own plugins; the plugin registry in the game's prefix, never the
    # user's home folder (@prefix needs AnvilMac with prefix substitution, 2026-10-27).
    "launchEnvironment": {"VK_DRIVER_FILES": "@root/share/vulkan/icd.d/MoltenVK_icd.json",
                          "GST_PLUGIN_SYSTEM_PATH_1_0": "@root/lib/gstreamer-1.0",
                          "GST_PLUGIN_SCANNER_1_0": "@root/libexec/gstreamer-1.0/gst-plugin-scanner",
                          "GST_REGISTRY_1_0": "@prefix/gstreamer-1.0-registry.x86_64.bin"},
}
json.dump(m, open(out, "w"), indent=2)
print(out)
