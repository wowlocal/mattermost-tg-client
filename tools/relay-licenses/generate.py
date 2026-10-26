#!/usr/bin/env python3
"""Generates Telegram/Relay/RelayLicenses.json, the list behind Settings → About Relay → Open Source
Licenses (Phase 4A).

Which components ship is decided by the app's bazel dependency graph (linked code only, no build tools), so the
script takes the list of bazel packages that //Telegram:Telegram depends on and bazel's external repository
directory (for the Rust crates' Cargo.toml and license files). `tools/relay-licenses/update.sh` runs both steps:

    tools/relay-licenses/update.sh          # after a build (needs bazel's output base)

For every component below whose bazel package is in that list it reads the license files from the source tree
(or from a release tarball the tree builds from) and writes name, license, homepage and the texts. Components
whose license file isn't in the tree are listed with what is known and say so; nothing is guessed. Rust crates
are listed with the license expression of their Cargo.toml and their own MIT/BSD/ISC/zlib notice files.

Standard library only.
"""

import json
import os
import re
import sys
import tarfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUTPUT = os.path.join(ROOT, "Telegram", "Relay", "RelayLicenses.json")

NOT_IN_TREE = "The license file is not included in this source tree. License as stated by the project; see its homepage."
UNDETERMINED = "Not determined"

# name, license, homepage, bazel package (any matching package = shipped), license files
# (paths, or "tarball:<path>!<member suffix>"), optional note.
COMPONENTS = [
    ("Texture (AsyncDisplayKit)", "Apache-2.0 and BSD", "https://github.com/TextureGroup/Texture",
     ["//submodules/AsyncDisplayKit"], ["submodules/AsyncDisplayKit/LICENSE"], None),
    ("lottie-ios", "Apache-2.0", "https://github.com/airbnb/lottie-ios",
     ["//submodules/lottie-ios"], ["submodules/lottie-ios/LICENSE"], None),
    ("rlottie", "LGPL-2.1 and others (see text)", "https://github.com/Samsung/rlottie",
     ["//submodules/rlottie"], ["submodules/rlottie/rlottie/COPYING", "submodules/rlottie/rlottie/licenses/COPYING.LGPL",
                                "submodules/rlottie/rlottie/licenses/COPYING.FTL", "submodules/rlottie/rlottie/licenses/COPYING.PIX",
                                "submodules/rlottie/rlottie/licenses/COPYING.RPD", "submodules/rlottie/rlottie/licenses/COPYING.STB"], None),
    ("tlottie", "MIT", None, ["//submodules/tlottie"], ["submodules/tlottie/tlottie/LICENSE"], None),
    ("FFmpeg 8.1.2", "LGPL-2.1-or-later", "https://ffmpeg.org",
     ["//submodules/ffmpeg"], ["submodules/ffmpeg/Sources/FFMpeg/ffmpeg-8.1.2/LICENSE.md",
                               "submodules/ffmpeg/Sources/FFMpeg/ffmpeg-8.1.2/COPYING.LGPLv2.1"],
     "Built without --enable-gpl and --enable-nonfree (submodules/ffmpeg/Sources/FFMpeg/build-ffmpeg-bazel.sh)."),
    ("dav1d", "BSD-2-Clause", "https://code.videolan.org/videolan/dav1d",
     ["//third-party/dav1d"], ["third-party/dav1d/dav1d/COPYING"], None),
    ("libvpx", "BSD-3-Clause", "https://chromium.googlesource.com/webm/libvpx",
     ["//third-party/libvpx"], ["third-party/libvpx/libvpx/LICENSE", "third-party/libvpx/libvpx/PATENTS"], None),
    ("libjxl", "BSD-3-Clause", "https://github.com/libjxl/libjxl",
     ["//third-party/libjxl"], ["third-party/libjxl/libjxl/LICENSE", "third-party/libjxl/libjxl/PATENTS"], None),
    ("libwebp", "BSD-3-Clause", "https://chromium.googlesource.com/webm/libwebp",
     ["//third-party/webp"], ["third-party/webp/libwebp/COPYING", "third-party/webp/libwebp/PATENTS"], None),
    ("mozjpeg", "IJG, BSD-3-Clause and zlib", "https://github.com/mozilla/mozjpeg",
     ["//third-party/mozjpeg"], ["third-party/mozjpeg/mozjpeg/LICENSE.md", "third-party/mozjpeg/mozjpeg/README.ijg"], None),
    ("libyuv", "BSD-3-Clause", "https://chromium.googlesource.com/libyuv/libyuv",
     ["//third-party/libyuv", "//third-party/LibYuvBinding"], ["third-party/libyuv/third_party/libyuv/LICENSE"], None),
    ("Opus 1.5.1", "BSD-3-Clause", "https://opus-codec.org",
     ["//third-party/opus"], ["tarball:third-party/opus/opus-1.5.1.tar.gz!/COPYING"], None),
    ("libogg", "BSD-3-Clause", "https://xiph.org/ogg/", ["//third-party/ogg"], [], NOT_IN_TREE),
    ("opusfile", "BSD-3-Clause", "https://opus-codec.org", ["//third-party/opusfile"], [], NOT_IN_TREE),
    ("OpenH264", "BSD-2-Clause", "https://github.com/cisco/openh264",
     ["//third-party/openh264"], [], NOT_IN_TREE),
    ("BoringSSL", "OpenSSL, SSLeay and ISC", "https://boringssl.googlesource.com/boringssl",
     ["//third-party/boringssl"], ["third-party/boringssl/LICENSE"], None),
    ("OpenSSL 1.1.1d", "OpenSSL and SSLeay", "https://www.openssl.org",
     ["//submodules/openssl"], ["tarball:submodules/openssl/openssl-1.1.1d.tar.gz!/LICENSE"], None),
    ("SQLCipher / SQLite", "BSD-3-Clause (SQLCipher); public domain (SQLite)", "https://www.zetetic.net/sqlcipher/",
     ["//submodules/sqlcipher"], ["comment:submodules/sqlcipher/Sources/sqlite3.c!Begin file sqlcipher.c"],
     "SQLite itself is in the public domain (https://sqlite.org/copyright.html)."),
    ("WebRTC", "BSD-3-Clause", "https://webrtc.org",
     ["//third-party/webrtc"], ["third-party/webrtc/webrtc/LICENSE", "third-party/webrtc/webrtc/PATENTS"], None),
    ("Abseil", "Apache-2.0", "https://abseil.io", ["//third-party/webrtc"], ["third-party/webrtc/absl/LICENSE"], None),
    ("libsrtp", "BSD-3-Clause", "https://github.com/cisco/libsrtp",
     ["//third-party/webrtc"], ["third-party/webrtc/libsrtp/third_party/libsrtp/LICENSE"], None),
    ("usrsctp", "BSD-3-Clause", "https://github.com/sctplab/usrsctp",
     ["//third-party/webrtc"], ["third-party/webrtc/dependencies/third_party/usrsctp/LICENSE"], None),
    ("libevent", "BSD-3-Clause", "https://libevent.org",
     ["//third-party/webrtc"], ["third-party/webrtc/dependencies/base/third_party/libevent/LICENSE"], None),
    ("PFFFT", "BSD-like (FFTPACK)", "https://bitbucket.org/jpommier/pffft",
     ["//third-party/webrtc"], ["third-party/webrtc/pffft/third_party/pffft/LICENSE"], None),
    ("fft4g", "Permissive (Ooura)", None, ["//third-party/webrtc"], ["third-party/webrtc/fft4g/LICENSE"], None),
    ("RNNoise", "BSD-3-Clause", "https://github.com/xiph/rnnoise",
     ["//third-party/rnnoise", "//third-party/webrtc"], ["third-party/webrtc/rnnoise/third_party/rnnoise/COPYING"], None),
    ("tgcalls", "LGPL-3.0", "https://github.com/TelegramMessenger/tgcalls",
     ["//submodules/TgVoipWebrtc"], ["submodules/TgVoipWebrtc/tgcalls/LICENSE"], None),
    ("MTProto engine (Rust)", "GPL-2.0", None,
     ["//third-party/mtproto-engine"], ["third-party/mtproto-engine/LICENSE"], None),
    ("WAMR (WebAssembly Micro Runtime)", "Apache-2.0 with LLVM exception", "https://github.com/bytecodealliance/wasm-micro-runtime",
     ["//third-party/wamr"], ["third-party/wamr/LICENSE"], None),
    ("SwiftMath", "MIT", "https://github.com/mgriebling/SwiftMath",
     ["//third-party/SwiftMath"], ["third-party/SwiftMath/LICENSE"], None),
    ("minizip (ZipArchive)", "zlib", "https://github.com/zlib-ng/minizip-ng",
     ["//third-party/ZipArchive"], ["third-party/ZipArchive/Sources/minizip/LICENSE"], None),
    ("XMLCoder", "MIT", "https://github.com/CoreOffice/XMLCoder", ["//third-party/XMLCoder"], [], NOT_IN_TREE),
    ("Boost.Regex", "BSL-1.0", "https://www.boost.org", ["//third-party/boost_regex"], [], NOT_IN_TREE),
    ("FlatBuffers", "Apache-2.0", "https://github.com/google/flatbuffers", ["//third-party/flatc"], [], NOT_IN_TREE),
    ("libprisma", UNDETERMINED, None, ["//third-party/libprisma"], [], "Syntax highlighter (Telegram); grammars from Prism (MIT). No license file in this source tree."),
    ("subcodec", UNDETERMINED, None, ["//third-party/subcodec"], [], "No license file in this source tree."),
    ("Swift2D", UNDETERMINED, None, ["//third-party/Swift2D"], [], "No license file in this source tree."),
    ("Stripe iOS SDK (vendored)", "MIT", "https://github.com/stripe/stripe-ios", ["//submodules/Stripe"], [], NOT_IN_TREE),
    ("libphonenumber (port)", "Apache-2.0", "https://github.com/google/libphonenumber", ["//submodules/libphonenumber"], [], NOT_IN_TREE),
    ("RecaptchaEnterprise (Google, binary)", "Proprietary", "https://cloud.google.com/recaptcha-enterprise",
     ["//third-party/recaptcha"], [], "Closed-source binary framework from Google, as bundled by Telegram-iOS."),
    ("TDLib (end-to-end encryption module)", "BSL-1.0", "https://github.com/tdlib/td",
     ["//third-party/td"], ["third-party/td/td/LICENSE_1_0.txt"], None),
    ("TON wallet engine", "MIT or Apache-2.0", None,
     ["//third-party/wallet-engine"], ["third-party/wallet-engine/wallet-engine/LICENSE-MIT"],
     "Dual-licensed MIT or Apache-2.0; the MIT terms are reproduced here."),
]

# Rust crates: bazel repositories named like rules_rust++crate+<hub>__<crate>-<version>.
CRATE_REPO = re.compile(r"^@rules_rust\+\+crate\+(?P<hub>[a-z_]+?)__(?P<crate>.+)-(?P<version>\d+\.\d+\.\d+[^/]*)$")
SHORT_NOTICE = ("LICENSE-MIT", "LICENSE.MIT", "LICENSE-BSD", "LICENSE-ZLIB", "LICENSE-ISC", "LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING")

# Not bazel packages: data generated into Relay's sources.
EXTRA = [
    ("emoji-datasource 16.0.0", "MIT", "https://github.com/iamcal/emoji-data", None,
     "Emoji names and shortcodes in submodules/MattermostSyncCore (EmojiTableData.swift, generated; attribution in the file).\n\n"
     "The MIT License (MIT)\n\nCopyright (c) 2013 Cal Henderson\n\n"
     "Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated "
     "documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation "
     "the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to "
     "permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\n"
     "The above copyright notice and this permission notice shall be included in all copies or substantial portions of "
     "the Software.\n\n"
     "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO "
     "THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE "
     "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, "
     "TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE "
     "SOFTWARE."),
]


def read_text(spec):
    if spec.startswith("tarball:"):
        path, member_suffix = spec[len("tarball:"):].split("!", 1)
        with tarfile.open(os.path.join(ROOT, path)) as archive:
            for member in archive.getmembers():
                if member.isfile() and member.name.endswith(member_suffix) and member.name.count("/") == 1:
                    return archive.extractfile(member).read().decode("utf-8", "replace")
        raise FileNotFoundError(spec)
    if spec.startswith("comment:"):
        # The first comment block after a marker line of a source file (SQLCipher's license sits after
        # "Begin file sqlcipher.c" in the SQLite amalgamation).
        path, marker = spec[len("comment:"):].split("!", 1)
        with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as file:
            text = file.read()
        start = text.find(marker)
        if start < 0:
            raise FileNotFoundError(spec)
        begin = text.find("/*", start)
        end = text.find("*/", begin)
        return text[begin: end + 2]
    with open(os.path.join(ROOT, spec), encoding="utf-8", errors="replace") as file:
        return file.read()


def cargo_license(cargo_toml):
    """The `license` (or `license-file`) value of a Cargo.toml's [package] table."""
    with open(cargo_toml, encoding="utf-8", errors="replace") as file:
        in_package = False
        for line in file:
            stripped = line.strip()
            if stripped.startswith("["):
                in_package = stripped == "[package]"
                continue
            if in_package:
                match = re.match(r'^license\s*=\s*"(.*)"', stripped)
                if match:
                    return match.group(1)
                match = re.match(r'^license-file\s*=\s*"(.*)"', stripped)
                if match:
                    return "see " + match.group(1)
    return UNDETERMINED


def rust_crates(packages, external_dir):
    """One component listing the Rust crates linked into the app (MTProto engine, TON wallet engine)."""
    crates = {}
    for package in packages:
        match = CRATE_REPO.match(package.split("//")[0])
        if match:
            crates[(match.group("crate"), match.group("version"))] = package.split("//")[0][1:]
    if not crates:
        return None
    lines = ["Rust crates compiled into the app (MTProto engine and TON wallet engine), with the license their "
             "Cargo.toml states. Notices of the crates that ship MIT/BSD/ISC/zlib license files follow; the "
             "Apache-2.0 text is in the \"Abseil\" entry.", ""]
    notices = []
    for (crate, version), repo in sorted(crates.items()):
        license_name = UNDETERMINED
        directory = os.path.join(external_dir, repo) if external_dir else None
        if directory and os.path.isfile(os.path.join(directory, "Cargo.toml")):
            license_name = cargo_license(os.path.join(directory, "Cargo.toml"))
            for name in SHORT_NOTICE:
                path = os.path.join(directory, name)
                if os.path.isfile(path) and os.path.getsize(path) < 4000:
                    with open(path, encoding="utf-8", errors="replace") as file:
                        text = file.read().strip()
                    if "Apache License" not in text[:200]:
                        notices.append("{} {}:\n{}".format(crate, version, text))
                    break
        lines.append("{} {} — {}".format(crate, version, license_name))
    text = "\n".join(lines)
    if notices:
        text += "\n\n" + "\n\n".join(notices)
    return {"name": "Rust crates ({})".format(len(crates)), "license": "MIT, Apache-2.0, BSD and others (per crate)",
            "url": "https://crates.io", "text": text}


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__)
        sys.exit(2)
    with open(sys.argv[1]) as file:
        packages = {line.strip() for line in file if line.strip()}
    external_dir = sys.argv[2] if len(sys.argv) == 3 else None

    def shipped(prefixes):
        for prefix in prefixes:
            bare = prefix[2:]
            for package in packages:
                if package == bare or package.startswith(bare + "/"):
                    return True
        return False

    components = []
    missing = []
    for name, license_name, url, prefixes, files, note in COMPONENTS:
        if not shipped(prefixes):
            continue
        texts = []
        if note:
            texts.append(note)
        for spec in files:
            try:
                texts.append(read_text(spec).strip())
            except (OSError, KeyError, FileNotFoundError):
                missing.append(spec)
        components.append({"name": name, "license": license_name, "url": url, "text": "\n\n".join(texts) or NOT_IN_TREE})
    for name, license_name, url, _, text in EXTRA:
        components.append({"name": name, "license": license_name, "url": url, "text": text})
    crates = rust_crates(packages, external_dir)
    if crates:
        components.append(crates)
    components.sort(key=lambda item: item["name"].lower())

    # Third-party package directories in the graph that no entry covers (for a human to add).
    covered = set()
    for _, _, _, prefixes, _, _ in COMPONENTS:
        covered.update(p[2:] for p in prefixes)
    uncovered = sorted({"/".join(p.split("/")[:2]) for p in packages if p.startswith("third-party/")} - covered)

    with open(OUTPUT, "w", encoding="utf-8") as file:
        json.dump({"generator": "tools/relay-licenses/generate.py", "components": components}, file, indent=1, ensure_ascii=False)
        file.write("\n")
    print("wrote {} components to {}".format(len(components), os.path.relpath(OUTPUT, ROOT)))
    if missing:
        print("license files not found: " + ", ".join(missing))
    if uncovered:
        print("third-party packages in the graph without an entry: " + ", ".join(uncovered))


if __name__ == "__main__":
    main()
