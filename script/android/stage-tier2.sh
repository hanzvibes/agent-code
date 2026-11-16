#!/usr/bin/env bash
#
# stage-tier2.sh — stage ALL Tier 2 tools for agent-code (Code Harness) as
# Android native libraries, following the proven opencode-android recipe:
#   Termux .deb -> dpkg-deb -x -> pick DT_NEEDED closure -> jniLibs/<abi>/lib*.so
#   patchelf --set-soname + --replace-needed (versioned -> unversioned)
#   ELF gates (e_machine, PT_LOAD p_align >= 0x4000, NEEDED closure)
#   assets: npm tree + corepack + CA bundle -> assets/node/
#         python stdlib + pip -> assets/python/ (PYTHONHOME at runtime)
#         git templates -> assets/git-templates/
#         git-core multicall symlink names -> assets/git-core-links.txt
#         (the Dart backend recreates these symlinks at runtime, pointing
#         at tools/bin/git — except git-remote-{https,ftp,ftps}, which
#         point at tools/bin/git-remote-http)
#
# Provenance (2026-11-16, prep workdir ~/workspace/agent-code-tier2-prep):
# - Pins below are from the FRESH Termux stable index fetched 2026-11-16
#   (Packages-aarch64.gz 3035 pkgs / Packages-x86_64.gz 3030 pkgs).
#   All pins EXCEPT python-pip match the pins in opencode-android main
#   (stage-node.sh / stage-python.sh / stage-ffmpeg.sh, fetched 2026-11-16);
#   python-pip moved 26.3 -> 26.3-1 since 2026-11-12.
# - Stage tables below are the MEASURED DT_NEEDED closures (closure-staged-*.json),
#   verified to match opencode stage-ffmpeg.sh exactly (83 libs + 2 binaries,
#   plus 8 libs shared with the node/python closures).
# - node/python/ffmpeg sections are adapted from opencode stage-node.sh,
#   stage-python.sh and stage-ffmpeg.sh; git/rg/xz/curl/jq/tar sections are NEW
#   (opencode has no stage scripts for git/rg — they predate the pattern).
# - git-core helpers (7 real binaries, ~12.6 MB) are staged by this script
#   per the coordinator decision (desain D5): the git binary hardcodes the
#   dead Termux exec path, so GIT_EXEC_PATH + the helpers are required for
#   clone/fetch/push over HTTPS. All 7 helpers' DT_NEEDED are already in
#   the staged closure (libcurl, libssl, libcrypto, libz, libexpat,
#   libiconv, libpcre2-8). The 152 multicall symlinks are NOT staged as
#   files (aapt2/PackageManager cannot ship symlinks reliably); their
#   names are written to assets/git-core-links.txt and recreated at
#   runtime by BundledRuntimeBackend.
#
# Notes (see PREP-REPORT.md §6):
#  1. libx264/libx265 are GPL — bundling triggers GPL obligations for the APK
#     (opencode notes this in THIRD_PARTY_NOTICES.md).
#  2. git-shell / git-cvsserver / scalar are real binaries in the git .deb
#     that are NOT staged (SSH serving / CVS / scalar maintenance — not
#     needed by the agent). Their git-core symlinks are recreated pointing
#     at tools/bin/git like the other multicall names; behaviour may
#     differ from Termux for those three only.
#  3. Flutter pubspec directory entries are NOT recursive (flutter_tools
#     asset.dart _parseAssetsFromFolder uses a non-recursive listSync):
#     listing only assets/node/ bundles NONE of the npm tree. This script
#     therefore regenerates the whole `assets:` list in pubspec.yaml with
#     every subdirectory listed explicitly (608 dirs + 2 files).
#     Verified 2026-11-16: `flutter build bundle` before the fix bundled
#     only 3 files (git-templates/description + the 2 .txt files); after
#     the fix it bundles exactly the 2928 files in tier2-manifest.txt.
#
# Usage:
#   ./stage-tier2.sh --abi arm64-v8a --jni-out <agent-code>/android/app/src/main/jniLibs/arm64-v8a \
#       --assets-out <agent-code>/assets
#   ./stage-tier2.sh --abi x86_64 --jni-out <...>/jniLibs/x86_64 --no-assets
#   ./stage-tier2.sh --abi arm64-v8a ... --debs-dir <dir-with-already-downloaded-.debs>
#       (reuses .deb files from that dir when present and sha256-verified,
#       downloads the rest from packages.termux.dev)
#   NOTE: --work-dir defaults to a mktemp dir (often /tmp, which on this VM
#   is a 512 MB tmpfs — too small: extraction needs ~1.2 GB per ABI).
#   Always pass --work-dir on a real disk with >= 2 GB free.
#
# Requirements: curl, dpkg-deb, patchelf (>= 0.18), readelf.
#   (patchelf 0.19.3 verified on the prep VM: renames + SONAME + gates hold.)
set -euo pipefail
ABI="" JNI_OUT="" ASSETS_OUT="" WITH_ASSETS=1 WORK_DIR="" PATCHELF="${PATCHELF:-patchelf}" DEBS_DIR_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --abi) ABI="$2"; shift 2 ;;
    --jni-out) JNI_OUT="$2"; shift 2 ;;
    --assets-out) ASSETS_OUT="$2"; shift 2 ;;
    --no-assets) WITH_ASSETS=0; shift ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --patchelf) PATCHELF="$2"; shift 2 ;;
    --debs-dir) DEBS_DIR_OVERRIDE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ "$ABI" = "arm64-v8a" ] || [ "$ABI" = "x86_64" ] || { echo "--abi must be arm64-v8a or x86_64" >&2; exit 2; }
[ -n "$JNI_OUT" ] || { echo "--jni-out is required" >&2; exit 2; }
if [ "$WITH_ASSETS" = "1" ] && [ -z "$ASSETS_OUT" ]; then echo "--assets-out is required unless --no-assets" >&2; exit 2; fi

# --- Pinned packages (Termux stable index, 2026-11-16) --------------------
# Format per package: "<pool-path>" "<sha256-aarch64>" "<sha256-x86_64>".
# Only the 98 packages that contribute a staged file or an asset are listed;
# the full apt closure is 124 packages (the other 26 — libllvm, mesa,
# ttf-dejavu, libx11, ... — are apt-only deps no staged file DT_NEEDEs).
BASE_URL="https://packages.termux.dev/apt/termux-main"
# Format per package: "<pool-aarch64>|<sha256-aarch64>|<pool-x86_64>|<sha256-x86_64>".
declare -A DEBS=(
  [brotli]="pool/main/b/brotli/brotli_1.2.1_aarch64.deb|4fba29438b2b44f8470d52173b4548e938542dc2fc632f8699be5a284cbb9485|pool/main/b/brotli/brotli_1.2.1_x86_64.deb|de652571f92e74c7f0cfe71e16cfc6ead340b184dda024614e6cab3048234142"
  [c-ares]="pool/main/c/c-ares/c-ares_1.34.9_aarch64.deb|623d84855e176f3f2a415d24c0e1d2f529356f4b5439bb3313e6d7ff0da4585c|pool/main/c/c-ares/c-ares_1.34.9_x86_64.deb|ac96c37fcc9181d1a7095f60485457fe6c3d784a83b0e8e6e7af9b3bfceda237"
  [ca-certificates]="pool/main/c/ca-certificates/ca-certificates_1:2026.11.05-1_all.deb|12fc350fc5ad638338b06b04835bce897615f8c93f96d30ac396cdb39b850c6b|pool/main/c/ca-certificates/ca-certificates_1:2026.11.05-1_all.deb|12fc350fc5ad638338b06b04835bce897615f8c93f96d30ac396cdb39b850c6b"
  [curl]="pool/main/c/curl/curl_8.23.0_aarch64.deb|e57a9975a828eb48790bec0da950795af165aa714f6a33d266c45a4e2898aa85|pool/main/c/curl/curl_8.23.0_x86_64.deb|03a68c5393759f6802a2b256891c2bca93d633d4915cdcb50e6d643c12f84fff"
  [ffmpeg]="pool/main/f/ffmpeg/ffmpeg_9.0.2-2_aarch64.deb|7a785ef62993ed8e0181fb0dcedae39ba7f62827c1150aa1bf805926d9bdf0da|pool/main/f/ffmpeg/ffmpeg_9.0.2-2_x86_64.deb|bbcd5b3ae003476aaa4c8db6a27ea5be268277d546667daa57c29e9ed8275415"
  [fftw]="pool/main/f/fftw/fftw_3.3.11_aarch64.deb|0a5140986bbfc69dbfa8f939f78521fb3dc02a193b6c822b7218dae44d99ffd5|pool/main/f/fftw/fftw_3.3.11_x86_64.deb|1caa8697eacaf3369f911fc29e228ca2419311917762e923795d0ae9e5b8b3f8"
  [fontconfig]="pool/main/f/fontconfig/fontconfig_2.18.3_aarch64.deb|7f8b70dd7ca85b1e7cbb14a11e9e6bd4ce3189ab985aa7af51145484d85f2c61|pool/main/f/fontconfig/fontconfig_2.18.3_x86_64.deb|5c40bc38f24e22eb7d6654748aaf8d6a33a5a69ff53cf02a249e8aa3ecefc2e5"
  [freetype]="pool/main/f/freetype/freetype_2.15.0_aarch64.deb|fe217807b22aa40029874eb1d9e01b89a01b5f1e4f0556c4de9c8e83c4db4256|pool/main/f/freetype/freetype_2.15.0_x86_64.deb|c82adef4b84b9ef502c64c23857e3d2cac611c7bfa6943f7d4c9d0fcfec733e3"
  [fribidi]="pool/main/f/fribidi/fribidi_1.0.18_aarch64.deb|6d9a4f6403a1450d22514dc7dc4de2b2358bec28afbce4576e37a3b224beae4b|pool/main/f/fribidi/fribidi_1.0.18_x86_64.deb|97ff239b52e7f348bc4597ed3987ee5a3e8b057234ab034c51da0ad147a54370"
  [game-music-emu]="pool/main/g/game-music-emu/game-music-emu_0.6.5_aarch64.deb|ffe1c43919d485409b2459d462b2dc6389492afeea869aef701b391a4ed29c67|pool/main/g/game-music-emu/game-music-emu_0.6.5_x86_64.deb|1eaae861eee36635fcce3d8605e0e37c929c563ea9dd4267c1a920f09c2fc62b"
  [gdbm]="pool/main/g/gdbm/gdbm_1.26-1_aarch64.deb|c378de833aae3cf41f3028491ea11836479d9833ab653edc27d0c0e0e691d5c5|pool/main/g/gdbm/gdbm_1.26-1_x86_64.deb|af6c89b403d42a98898c665fc2c48da59a7d20e6e26f651a654790661844001f"
  [git]="pool/main/g/git/git_2.56.1_aarch64.deb|3343f56fc99e2f0631a553a39789769495435cb07b6ffb3c71a7fcb7bd561e95|pool/main/g/git/git_2.56.1_x86_64.deb|c2b2e63b090c979ebedfb8610a06b87f052a9ce0477dd0a3a9d5bb9171c4550b"
  [glib]="pool/main/g/glib/glib_2.90.1_aarch64.deb|132d8ce961d96a7252fd4bc2228bddd385b1b17b706a46caae6d541ae0e4b2c0|pool/main/g/glib/glib_2.90.1_x86_64.deb|fb663e2222c3f7c7fb5c98b4694426665a719160adff0a6aec509b8285b63de4"
  [glslang]="pool/main/g/glslang/glslang_16.6.0_aarch64.deb|c5b5d6cb57d5841966c4b07033d319ebf6a3df61347a484b9dc5e332d29cd721|pool/main/g/glslang/glslang_16.6.0_x86_64.deb|66651725abea231a6a7207123767906e39d29d0d89393cf1b1afec9b3e386c85"
  [harfbuzz]="pool/main/h/harfbuzz/harfbuzz_15.1.0-1_aarch64.deb|0ad02ed6650599800fb60c06f1a358c9666795fc371940278b7b69ef4c925d88|pool/main/h/harfbuzz/harfbuzz_15.1.0-1_x86_64.deb|de5518bb7c13b6423635280e2e5df6d025a96a8400f200183475843d7fe51d3a"
  [highway]="pool/main/h/highway/highway_1.4.0-1_aarch64.deb|71b8e0c231ab6b66827374543d55997a5cb02d8882f5d53e059ba78cd2511da1|pool/main/h/highway/highway_1.4.0-1_x86_64.deb|00c3ed53c3d9697e4ec3bca3758fa2ea39b38ee753cf284e08cc839d51fd04e9"
  [jq]="pool/main/j/jq/jq_1.8.2_aarch64.deb|0eac323797c5d70c35f5fb935c58b5fd7528937584a1aebbd5c5b965d1663afa|pool/main/j/jq/jq_1.8.2_x86_64.deb|b0a35244083a79ff4263b85e9219361d06988d63317eaa52afee92448ae10e1b"
  [libacl]="pool/main/liba/libacl/libacl_2.4.0_aarch64.deb|cb620e33405e74b566cb05740dca488705cf0c475ec7f795fa333412211b6d92|pool/main/liba/libacl/libacl_2.4.0_x86_64.deb|cfb92789ab1b1aad89d0918cd406e755918f2331276854a2c8a57748fb6c4049"
  [libandroid-execinfo]="pool/main/liba/libandroid-execinfo/libandroid-execinfo_0.1-3_aarch64.deb|725dd2c6da7fc96e860fcc928e18aa9fb0e85e0bdcaf4f8ce0f0654ca6860fc2|pool/main/liba/libandroid-execinfo/libandroid-execinfo_0.1-3_x86_64.deb|348582b47b4b6dec8c13147437d8bd93d029239bc95f30635074cad08efb6220"
  [libandroid-glob]="pool/main/liba/libandroid-glob/libandroid-glob_0.6-3_aarch64.deb|2276ae8adedf0db76c2f4ffc94cc4cceb2f4f5d78e021b54e2e046d1233e7826|pool/main/liba/libandroid-glob/libandroid-glob_0.6-3_x86_64.deb|33b5d2ce934e89d50363e7ea267cea697da937d14de9fcea78cc7271956ef86e"
  [libandroid-posix-semaphore]="pool/main/liba/libandroid-posix-semaphore/libandroid-posix-semaphore_0.1-4_aarch64.deb|0efa8677a0166315ba4e685863712eba0ca0a1732827492f38226e2723730c7a|pool/main/liba/libandroid-posix-semaphore/libandroid-posix-semaphore_0.1-4_x86_64.deb|4bde3f8bc00fa59761544593f0606a05e4b449801f1c79038c42ce66988d0eb0"
  [libandroid-selinux]="pool/main/liba/libandroid-selinux/libandroid-selinux_14.0.0.11-1_aarch64.deb|00afd8c34087c2864737b51fd9d104dc5e955f6ec3c0f50c0c7ef5b4a56866b9|pool/main/liba/libandroid-selinux/libandroid-selinux_14.0.0.11-1_x86_64.deb|99cf96556683ddb53f7d645ca1720e10523c4796ce5b41c583da9f89a47679ce"
  [libandroid-shmem]="pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb|0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6|pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_x86_64.deb|ffa9e4c87467b158b148d0ff92dda796aa038276c2075af3269cdcdb06f25797"
  [libandroid-support]="pool/main/liba/libandroid-support/libandroid-support_29-1_aarch64.deb|f2f145d6135ad4843ac9670153be3e3944dc1e6f1736d46d2306c28f2b86f517|pool/main/liba/libandroid-support/libandroid-support_29-1_x86_64.deb|665900760c05959ec076082a0941f05bd452f301e5a70bdfa7383fd3404d44d5"
  [libaom]="pool/main/liba/libaom/libaom_3.15.3_aarch64.deb|942fa9a844e77a5a0bd73da4928261538f08cf79109c0608d28f0243eaeba1a2|pool/main/liba/libaom/libaom_3.15.3_x86_64.deb|157b5b66e7bed4dd93bc9ba389dfb2bbe6974b923fb147062e1efdcec6ee4748"
  [libass]="pool/main/liba/libass/libass_0.17.5_aarch64.deb|4f94205285ea2062be4f60e695723a6f3350339ec89720943b0dce5ae30db01d|pool/main/liba/libass/libass_0.17.5_x86_64.deb|404eabbea13cb89b29ec79f9a822f60481f0fa4c102d01b41d9b705eb1ce8414"
  [libbluray]="pool/main/libb/libbluray/libbluray_1.5.1_aarch64.deb|fbe931e6a7d9604fe865bd24b8012ad3b7f04c6bbb6cf9b277760db1b4a8df7e|pool/main/libb/libbluray/libbluray_1.5.1_x86_64.deb|8bc30b6112f4863a586627ded81de017b3d594f529d57cf0303876b38f19ef48"
  [libbs2b]="pool/main/libb/libbs2b/libbs2b_3.1.0-2_aarch64.deb|c71660d99e4baa064ba93f0ef750b6b2ea0d1d494a754cf1c67b550bb4baa91d|pool/main/libb/libbs2b/libbs2b_3.1.0-2_x86_64.deb|048022121af8f3ad3ae7a23bd91f3e1a1e76541b5cf8c57cd77928e35d6ba3ea"
  [libbz2]="pool/main/libb/libbz2/libbz2_1.0.8-8_aarch64.deb|4335d7f060650b0aabef545d1334c2f9f280223d5962e13c24a00ec934b794ba|pool/main/libb/libbz2/libbz2_1.0.8-8_x86_64.deb|f6f81d38a40c1626202da1e87727e5a3e6de296b1c0eb252af8948646b164ca0"
  [libc++]="pool/main/libc/libc++/libc++_30_aarch64.deb|53d0b84a7ba7459024257cb94d5b136fe13ef858567f65a8064b35950799f2ca|pool/main/libc/libc++/libc++_30_x86_64.deb|c9bcd9a8067a19c9c0e4893a72d314a2e37d6b67ce8dd05c67b9bbacad044b4f"
  [libcurl]="pool/main/libc/libcurl/libcurl_8.23.0_aarch64.deb|2011bb9709261bb3d5ecaa6672faa333be14cf48ad4af37031e3e365309557ac|pool/main/libc/libcurl/libcurl_8.23.0_x86_64.deb|fa71ce8eca3d0aa48a748fc60e4519351fc9c4d51b20cac5722190cb002cfd1c"
  [libdav1d]="pool/main/libd/libdav1d/libdav1d_1.5.4_aarch64.deb|4c2ffdcbbb805727caaa2e91b56917830dbacf4245dd439cf2e1c0d61a541613|pool/main/libd/libdav1d/libdav1d_1.5.4_x86_64.deb|93f0c7fd4c7706cf89783243c3a1e9676b25a9a78976caa6524f1cad73f4a38c"
  [libdvdnav]="pool/main/libd/libdvdnav/libdvdnav_7.0.0_aarch64.deb|fd8509a88b5966cdadf9925b2687e50c31d796e773cb326e651e76c0a3b16958|pool/main/libd/libdvdnav/libdvdnav_7.0.0_x86_64.deb|686ba8a5bd1530963b5b8a5df3d1aa15bce40c973fb83f268e56337527e93136"
  [libdvdread]="pool/main/libd/libdvdread/libdvdread_7.1.1_aarch64.deb|8e1606f7d2aec40c9e8f748ab595cf0f684c998b4642bc59fa6b18b5fe1d2fb0|pool/main/libd/libdvdread/libdvdread_7.1.1_x86_64.deb|8f74f292de2fbcb9953ac3c04e674b58fe45851b5a4a4a65bf418e9c09dedb29"
  [libexpat]="pool/main/libe/libexpat/libexpat_2.10.0_aarch64.deb|0e4411f01f6fb664f3f04f9420289472f9afc30db01ea1c5d1e57fd9fa2354be|pool/main/libe/libexpat/libexpat_2.10.0_x86_64.deb|2e0f6f7d54ef7d8a732148f0a2ff53594b1a8d410a707f480f143861313a0ecd"
  [libffi]="pool/main/libf/libffi/libffi_3.8.0_aarch64.deb|4f255badf74cd31f6a2801c17fa1444199c84c834b517b7c843e2fe9ebe91d77|pool/main/libf/libffi/libffi_3.8.0_x86_64.deb|59121ca4bc5f5735d7bb603bd99548983064e8fde97d236e97122cb87d3452a3"
  [libgraphite]="pool/main/libg/libgraphite/libgraphite_1.3.15_aarch64.deb|15ac85737a35150cecb9e46ecb32567ae2a4fc28071cdf58fb95e1b77d7889d9|pool/main/libg/libgraphite/libgraphite_1.3.15_x86_64.deb|c82bd46d191d4cbf08547f3537200c5c459ec1dcbb82fcd05b3704f05f47bc21"
  [libiconv]="pool/main/libi/libiconv/libiconv_1.19.1_aarch64.deb|a1c6323eff4f660e16ae6f5832356444b3269c19a4f61146355a49e7c4be5ed1|pool/main/libi/libiconv/libiconv_1.19.1_x86_64.deb|3eb0c454676ad24d26c79601721b2eb3f9485c611ad0179fb86b17229344f46d"
  [libicu]="pool/main/libi/libicu/libicu_79.1_aarch64.deb|83c980a010e957738e3567127801d66a1b9bd7e404a4fda98788048ee57d606c|pool/main/libi/libicu/libicu_79.1_x86_64.deb|541410d7b425ebde5d4027c86218081925b15dc1e5cffaa45449bdc4b2256251"
  [libjxl]="pool/main/libj/libjxl/libjxl_0.13.0_aarch64.deb|7ccbe06a6c0d22a8934729e580397bb405c30ea5f25ccf18365c1c79c7103f5c|pool/main/libj/libjxl/libjxl_0.13.0_x86_64.deb|8800e9126cc92c3aae146b16d85a7dc8526a334fdd3971cdbca9b3842c5ab31e"
  [liblzma]="pool/main/libl/liblzma/liblzma_5.8.4_aarch64.deb|44e95e6e60dddb3705e60a344a4f009a1085a210797342b721eaff41b44033c0|pool/main/libl/liblzma/liblzma_5.8.4_x86_64.deb|100ea7503a0b9ecffa45e1f168d035651f2eb7aedbebe71dd21fc0da4a84ef16"
  [libmp3lame]="pool/main/libm/libmp3lame/libmp3lame_4.0-1_aarch64.deb|59f70ad8885578063bcbea3b11e74fb69e2416ca036b47aa255c1fa4f074565e|pool/main/libm/libmp3lame/libmp3lame_4.0-1_x86_64.deb|1599ab4003ae944c648d5bd7a9b00001bf4ef34a2dde6cf8c23b7ea58a2174a5"
  [libmpg123]="pool/main/libm/libmpg123/libmpg123_1.33.7_aarch64.deb|883b104faae53820b2e758363300ccf99e28f627a263d766af61ae07b73b07b3|pool/main/libm/libmpg123/libmpg123_1.33.7_x86_64.deb|d39a982b5080b1a01f3d21707d4de72ea6ce13ab795548fa307bafdb4c4c0323"
  [libmysofa]="pool/main/libm/libmysofa/libmysofa_1.3.5_aarch64.deb|b083050d4bc0bd11db0f73382ae3db8c5dc352520b78aaa44f150d87cff80215|pool/main/libm/libmysofa/libmysofa_1.3.5_x86_64.deb|f81064e2cf5ed2b6d73301b1f594a525f3d699b201fffc3c7c9cb1eb3c156b6d"
  [libnghttp2]="pool/main/libn/libnghttp2/libnghttp2_1.71.0_aarch64.deb|ae33e7b21e0636be8686b9b13a20e31267f047f69cb26b4befd70c9a9bae221e|pool/main/libn/libnghttp2/libnghttp2_1.71.0_x86_64.deb|9bc1791438de6380038835cbd10c9cede716212cc32e37eb54407cd24f6605d6"
  [libnghttp3]="pool/main/libn/libnghttp3/libnghttp3_1.19.0_aarch64.deb|8bb6fa31f9281cd48047ec9a571cadf153538f5b38f0203ad7a4e221344b14a6|pool/main/libn/libnghttp3/libnghttp3_1.19.0_x86_64.deb|b3fa3f6117a8d2c1e5c6535f733282c077d39760b79bd08eac4ffba8da7bc0e6"
  [libngtcp2]="pool/main/libn/libngtcp2/libngtcp2_1.26.0_aarch64.deb|8225ecde58104ef5aa234fa54a1bea5051a8a9ef2937e5ba996b3e8dda68c8eb|pool/main/libn/libngtcp2/libngtcp2_1.26.0_x86_64.deb|9a4ba347834cf4593cd80df9c9ad4caaf0486946ac0e1a812d10f0d712b5eae2"
  [libogg]="pool/main/libo/libogg/libogg_1.3.6-1_aarch64.deb|4f1700a532f251ad3600f44f88cd764f1f6b0542d3343391117944b47a92802d|pool/main/libo/libogg/libogg_1.3.6-1_x86_64.deb|55dd0908feb56bec69fdf1c0aaeedb73f6c74cc28495c0d640172845863c9eed"
  [libopencore-amr]="pool/main/libo/libopencore-amr/libopencore-amr_0.1.6-1_aarch64.deb|8ad25c12b892d56e85a21517d814146109fea7865b2548b8637743d7d6e0fee2|pool/main/libo/libopencore-amr/libopencore-amr_0.1.6-1_x86_64.deb|820cb0c2be317bea917e3ae5a083c4d2bfa095367ad4b623b4696f258c032db4"
  [libopenmpt]="pool/main/libo/libopenmpt/libopenmpt_0.8.10_aarch64.deb|ffbd8d03f0f4ca21aefdd5777d133a0b2ddafb44697f1c386e977fb048362235|pool/main/libo/libopenmpt/libopenmpt_0.8.10_x86_64.deb|a8937113c514b161961b544ce230125f67b73ce0b08885a33b4c8b551d0034ff"
  [libopus]="pool/main/libo/libopus/libopus_1.6.1_aarch64.deb|005a9335ce0ec0f510bbe6e0229c901d6f920cc375fcda56461e96cef70f8ff0|pool/main/libo/libopus/libopus_1.6.1_x86_64.deb|724f0215e78a21a02f8dd01dd6c78d6cea71457c8080be99f984f5d8c8f5e4d9"
  [libplacebo]="pool/main/libp/libplacebo/libplacebo_7.387.0_aarch64.deb|925a54773e29aefc790fd1a6d7759ea3b893d0482db878299c8b885233655f82|pool/main/libp/libplacebo/libplacebo_7.387.0_x86_64.deb|8a306edec39eef00c9feaadc5799ad41287786e4aeda8900c649cd01dc4950ba"
  [libpng]="pool/main/libp/libpng/libpng_1.6.59_aarch64.deb|32d61f0b1a60cf7283aa3a80e288737493df2c6b84c8c749606b77c94a10f2b2|pool/main/libp/libpng/libpng_1.6.59_x86_64.deb|b5bbc3c552255d072ac5e53ec7641128f373d09e404abd01a8285b1a4a7f324c"
  [librav1e]="pool/main/libr/librav1e/librav1e_0.8.1_aarch64.deb|ac7842a5896bdff1b4d4974d9c02e60f7d4a587b8618df691118a8591f8dbccf|pool/main/libr/librav1e/librav1e_0.8.1_x86_64.deb|6a40a0e0633d49f3eb222ad345dcb579aacdccf211645017ad95c83a15a6f0dc"
  [libsamplerate]="pool/main/libs/libsamplerate/libsamplerate_0.2.2-4_aarch64.deb|521d46cc49557c00b2d5c107da1f86f0cdda8a3a3b84bd9958bd7fc52bec2dae|pool/main/libs/libsamplerate/libsamplerate_0.2.2-4_x86_64.deb|ab641f508e9846952edbd452c9661810c723787c40dc309e582c7a27a4333fb3"
  [libsodium]="pool/main/libs/libsodium/libsodium_1.0.22-1_aarch64.deb|a9fbbc3a7a5a2a0f514474ee706d49b576ac09268b87142a3690edb9f5f3643d|pool/main/libs/libsodium/libsodium_1.0.22-1_x86_64.deb|4eb2e0b3b8b1693020505b8e445bfd0e2010c130d6ed3a67b34d0fed35657094"
  [libsoxr]="pool/main/libs/libsoxr/libsoxr_0.1.3-8_aarch64.deb|a1c5f66aae3b9900e9a492b43901b2b98586870c7905feb9f3c835cc9af464be|pool/main/libs/libsoxr/libsoxr_0.1.3-8_x86_64.deb|3cd66761119a4f4cb621a701279c2b2edc9a6c4e9f1872dbfc8058fb76c6a66f"
  [libsqlite]="pool/main/libs/libsqlite/libsqlite_3.54.1-1_aarch64.deb|661fb995f7215845007b222a85266ae99d9443e87e0604f8677edfd738e6b81a|pool/main/libs/libsqlite/libsqlite_3.54.1-1_x86_64.deb|497471806378934fec8a6f3b5db70cf52a3652828786a241e2e37eebc19112b0"
  [libsrt]="pool/main/libs/libsrt/libsrt_1.5.7_aarch64.deb|6199d01dd9d1630a32c220f7fdb9bca958adbd7062f90e9bfc010cf75fdef07a|pool/main/libs/libsrt/libsrt_1.5.7_x86_64.deb|a69c915f0c5f8375ae557651d1514c7ea6a0085a04a67501971078030c5fc063"
  [libssh]="pool/main/libs/libssh/libssh_0.12.2_aarch64.deb|05cfb1d6f70e9b316f1eac7a5ec9139f884e644d6d91e668e9ca49716aad8ff0|pool/main/libs/libssh/libssh_0.12.2_x86_64.deb|9090c7d8dcc794f42087f41b15b7f2b4f7ab695db3c90373c366dff3532d98cb"
  [libssh2]="pool/main/libs/libssh2/libssh2_1.11.1-2_aarch64.deb|1add4e0a926b848814e7e2f1817ea28b123c54cabd5bbc4e5cfd65291cbad84e|pool/main/libs/libssh2/libssh2_1.11.1-2_x86_64.deb|00db1c1497e8703281efded7f1f2a63824b145c980d9ec309ae0ab7ccb9ce1c5"
  [libtheora]="pool/main/libt/libtheora/libtheora_1.2.0-1_aarch64.deb|9d4582f14f71df7a48101ee05297a57a898654ead55ef10ca4d73e254151b1e8|pool/main/libt/libtheora/libtheora_1.2.0-1_x86_64.deb|b1903d622483976402e2554df61845c7b789b36a7b86fda087307e19802d2d7c"
  [libudfread]="pool/main/libu/libudfread/libudfread_1.2.0_aarch64.deb|61a7e02c30ae61f9cbe46bf8cefa8e361a16b29010a07cacb43513ff533df81c|pool/main/libu/libudfread/libudfread_1.2.0_x86_64.deb|b5ce605b0476947c7c9ed64bbb16af18fdbfe1a5fd81060984671507f312e2d9"
  [libvidstab]="pool/main/libv/libvidstab/libvidstab_1.1.2_aarch64.deb|598d1c5ea7de4e4c76aa2198602e3dc35684671d9690e69d665058d55a89ab75|pool/main/libv/libvidstab/libvidstab_1.1.2_x86_64.deb|447b6ec815f7240f7900df6b98e2803594d3a2b392437bc6fefd4bbd4841b926"
  [libvmaf]="pool/main/libv/libvmaf/libvmaf_3.2.1_aarch64.deb|8c65e85997426c00ce6a419343eb820e164d725e4b267e268a9e8e351e2f9001|pool/main/libv/libvmaf/libvmaf_3.2.1_x86_64.deb|f789d61e510dc6da7c19ef3912b8f2f09365d2a40c68f73550ce4d7b66233ead"
  [libvo-amrwbenc]="pool/main/libv/libvo-amrwbenc/libvo-amrwbenc_0.1.3-2_aarch64.deb|aa913ca492246ed1e6ce57a3c52fe856c323cbb6e8dbdb6904b80214551f6e00|pool/main/libv/libvo-amrwbenc/libvo-amrwbenc_0.1.3-2_x86_64.deb|c66b14c24adc1f26436dbe4e5703c039f87c2d0a3dafce360af083ca071e7022"
  [libvorbis]="pool/main/libv/libvorbis/libvorbis_1.3.7-4_aarch64.deb|6bfd70c4b570b85594bd06116b75a6f8109ec58cbc123e938b630a6eefdedf4e|pool/main/libv/libvorbis/libvorbis_1.3.7-4_x86_64.deb|9515c03de58faa17e2e19deb78da09289c90b939c17fcbaf4b171aebfefb65bf"
  [libvpx]="pool/main/libv/libvpx/libvpx_1:1.17.0_aarch64.deb|1dbc5be0610c9da58732f480c7a27dbb32cf72a472e88c6c0993bdc0feeae00a|pool/main/libv/libvpx/libvpx_1:1.17.0_x86_64.deb|f7716a1eaad1d727a0eca42f3761188f1539186260f8deca248eef77e0d238d1"
  [libwebp]="pool/main/libw/libwebp/libwebp_1.6.0.0.0.1+really1.6.0_aarch64.deb|8ba7fcfadd1a9957a7632c6407d6ef3e41d34dbd96a41769b245592ed4559045|pool/main/libw/libwebp/libwebp_1.6.0.0.0.1+really1.6.0_x86_64.deb|3274f3b6b3b765ed5cfb3d33cf309a2222de7766ad53f0eaefcbe89563f2f7a3"
  [libx264]="pool/main/libx/libx264/libx264_1:0.164.3191-1_aarch64.deb|fe98852cb06ce1c963a54284179d8cda42af2fa82afcac09f7d81e6de4d9bbc1|pool/main/libx/libx264/libx264_1:0.164.3191-1_x86_64.deb|b71ce302a81561c0e30ae65980b541b508dbe804fadc3eb402ba90085d0c1024"
  [libx265]="pool/main/libx/libx265/libx265_4.3_aarch64.deb|8dbfd50ad2ceea5ffa2384f0f4cc16a87cbf56ac83b4861fa4f640d1beb352cd|pool/main/libx/libx265/libx265_4.3_x86_64.deb|2289658fba654b3e56c22f30f8baef0b8fa1b39ef92887c5744b3063ba997288"
  [libxau]="pool/main/libx/libxau/libxau_1.0.12-2_aarch64.deb|2d86bed61ce89dd8fdb55e565aede10155f2ce3adaccb61d5f1375aec3314083|pool/main/libx/libxau/libxau_1.0.12-2_x86_64.deb|b964143f84f11270ba14baf9a747b9732f5a9b84d2ca0e70ca26ba0364e0ce0b"
  [libxcb]="pool/main/libx/libxcb/libxcb_1.17.0-1_aarch64.deb|191c3642b6a8c754bc75b69b94a81858ecb5f18766dc085aff55559b8087ad34|pool/main/libx/libxcb/libxcb_1.17.0-1_x86_64.deb|38da04c89e95026282c1277ca475fe02aca78735e0af48e3aada6b5aed78b894"
  [libxdmcp]="pool/main/libx/libxdmcp/libxdmcp_1.1.5-2_aarch64.deb|caea0cf5c0028af0840774094b8900ef7afffd8f9bbd7b1abfbe66851f0d6077|pool/main/libx/libxdmcp/libxdmcp_1.1.5-2_x86_64.deb|814a80d52fdfd193286f3a2e50215a10f03f6e64579cbdef3886cf499adf896d"
  [libxml2]="pool/main/libx/libxml2/libxml2_2.15.4-1_aarch64.deb|d315861bbcf716cfb088f53cddab9fb6a96430cc66769f79774cc69c2f53bcff|pool/main/libx/libxml2/libxml2_2.15.4-1_x86_64.deb|b25b5b18185b4d9f61fc63d2d8ec11fadb5755b42e01c6afef9f5ad2abd6fb78"
  [libzimg]="pool/main/libz/libzimg/libzimg_3.0.6_aarch64.deb|a776d30cdb5734fa8feb17fb89fe8a67d14d64e491777d9b62b0fd714a9b59e8|pool/main/libz/libzimg/libzimg_3.0.6_x86_64.deb|a77720138851bd3f517e0a5f1507461f1dfe9152cc38c3763f3478c0a8cec443"
  [libzmq]="pool/main/libz/libzmq/libzmq_4.3.5-2_aarch64.deb|1d59efb56905e79159808c6b656cc768ffcc210012bc2d9b63f23162f65480d2|pool/main/libz/libzmq/libzmq_4.3.5-2_x86_64.deb|124f76f0a8b275cdfe15122311aede2fb78483151f105090f9f6dc8a86bf59c9"
  [littlecms]="pool/main/l/littlecms/littlecms_2.20_aarch64.deb|20be10d39b67e50366e172d11e7f3895fa2a71b5a86139713a101fa1d3b8d015|pool/main/l/littlecms/littlecms_2.20_x86_64.deb|bfc8c267668667787c7b1397bc57473cf25370c104ef5519527df83f6cf21d1b"
  [ncurses]="pool/main/n/ncurses/ncurses_6.6.20260307+really6.5.20250830_aarch64.deb|f44bbfdc3d42ec0217bffa978309390e59cea5a48a9a83226d4a496c42ad0b99|pool/main/n/ncurses/ncurses_6.6.20260307+really6.5.20250830_x86_64.deb|3f30f53c6a41c8450d146d4d42611a44be6ba0a8de1e8bb4dc903109a5fc3ff1"
  [ncurses-ui-libs]="pool/main/n/ncurses-ui-libs/ncurses-ui-libs_6.6.20260307+really6.5.20250830_aarch64.deb|7393f369009be189b3d4ec1f9b16ebd57621d6a1b22949ae07685573950d1f37|pool/main/n/ncurses-ui-libs/ncurses-ui-libs_6.6.20260307+really6.5.20250830_x86_64.deb|1193618e18f579eb86064e00648d80648eaec5da70c0a5b944ac1315d209d16e"
  [nodejs-lts]="pool/main/n/nodejs-lts/nodejs-lts_24.22.3_aarch64.deb|80edcc73db025db0baa09be27e3d65a16e6f2a72ab925f1873a1b808ab857c28|pool/main/n/nodejs-lts/nodejs-lts_24.22.3_x86_64.deb|d73ab1303aa1a8ecca188795f536279c7ef196c4e3f72b645e443501b03247e4"
  [npm]="pool/main/n/npm/npm_12.2.2_all.deb|edb4a1dc3a6967f1e65872c7cb7588bd3672152beab6ae633ba848931371e9e1|pool/main/n/npm/npm_12.2.2_all.deb|edb4a1dc3a6967f1e65872c7cb7588bd3672152beab6ae633ba848931371e9e1"
  [ocl-icd]="pool/main/o/ocl-icd/ocl-icd_2.3.5_aarch64.deb|2d76ddf09069ad599a4d5b2aee374c58411e1a3b0618b1ca5412467c9fd7b26a|pool/main/o/ocl-icd/ocl-icd_2.3.5_x86_64.deb|453a41d9c6dfac297f3a01101d9b3f32e37b88a93562027fba292a1bdcdd664b"
  [oniguruma]="pool/main/o/oniguruma/oniguruma_6.9.10-1_aarch64.deb|93675574c560cd2f75b32f0bd2fdaa693419dd6ac0e6c71c26ce5fd928cae1c5|pool/main/o/oniguruma/oniguruma_6.9.10-1_x86_64.deb|af74e1e83551d0a24f24f37f5462e3ec3db12a15588788cb1f54b7628ed8239c"
  [openssl]="pool/main/o/openssl/openssl_1:3.6.5_aarch64.deb|a2fb7856875e63ef6b90442752e05974813372c3ca86d2513a78ea43c67a0f8b|pool/main/o/openssl/openssl_1:3.6.5_x86_64.deb|540f144592d23d35672976e175ede1b5d8cf464f153f646df5d4e6dcd8491a15"
  [pcre2]="pool/main/p/pcre2/pcre2_10.49_aarch64.deb|c27995e5f52b8ecc9b8b3e662eb08e49f82a18bfd3f34343936acc7b23964724|pool/main/p/pcre2/pcre2_10.49_x86_64.deb|4a6f66ac12565342897ce9b5cd11ba8ce6fce1fd1a91ae679c3468d7fc2ee541"
  [python]="pool/main/p/python/python_3.14.10_aarch64.deb|1a5a300c8d844f2c18a3bb61cafbffb2e93fba9a7106ebe967f06c9628d1e434|pool/main/p/python/python_3.14.10_x86_64.deb|61e29ea9fb1b2e2f8eed7f9e7f86e4d0c16ec2941242f895ed9983fde8e1d11c"
  [python-pip]="pool/main/p/python-pip/python-pip_26.3-1_all.deb|c4ab1dd91a08ea7c9180be530bda56c57cfdf1ac17f6576c948224a5dc8806dc|pool/main/p/python-pip/python-pip_26.3-1_all.deb|c4ab1dd91a08ea7c9180be530bda56c57cfdf1ac17f6576c948224a5dc8806dc"
  [readline]="pool/main/r/readline/readline_8.3.6_aarch64.deb|616cc73009bc0223f61caed8dd09455714455aa5ea5e180126e2f69c4c775136|pool/main/r/readline/readline_8.3.6_x86_64.deb|e9684798d13ede05f785315f68d3ff739563db2abef0e73db4dc9b8e17ded368"
  [ripgrep]="pool/main/r/ripgrep/ripgrep_15.2.0_aarch64.deb|38e28bc297000517b24702568a483eca7dc3323eb6bdccc9033f031776bdcc6c|pool/main/r/ripgrep/ripgrep_15.2.0_x86_64.deb|2eb50ab2e378436767975b072ce7118decf6444d6d6ed178bc89979b5f150f2a"
  [rubberband]="pool/main/r/rubberband/rubberband_4.0.0-1_aarch64.deb|1172030a1e3ed70976114c8ca3eb4da0b82c1714825bd751ac1ada606dbc685a|pool/main/r/rubberband/rubberband_4.0.0-1_x86_64.deb|e730332f93c558c207c26b024bf5a50985bdbe0531361fbc86feab9d7cce7633"
  [svt-av1]="pool/main/s/svt-av1/svt-av1_4.3.0_aarch64.deb|3a9459c012dbe3bf9484ee200ff962a49499c05d3cf2829ac278d37973d03cc0|pool/main/s/svt-av1/svt-av1_4.3.0_x86_64.deb|1113fe77be4c29e5492a22c3f3b7d23c8cbbe9d29f4dd02bc64470ead0531a6f"
  [tar]="pool/main/t/tar/tar_1.35-3_aarch64.deb|a3847bc259b8654f621d36fa6345b1d6e93932e60e315e526eac2e3ecc5549ec|pool/main/t/tar/tar_1.35-3_x86_64.deb|7e8c311c04dd4ce66d053a5f55faaf4914cfc34c4c53589c55c162f504788a7f"
  [vulkan-loader-generic]="pool/main/v/vulkan-loader-generic/vulkan-loader-generic_1.4.368_aarch64.deb|8043459b6d4efd4834b756c6eeb539e8ae184d71046ffddff3ca75e85b1fcb27|pool/main/v/vulkan-loader-generic/vulkan-loader-generic_1.4.368_x86_64.deb|5fc1d27b9872253ac08d38dedf4314077fe2a6a547184cba550919a5f1a70a8e"
  [xvidcore]="pool/main/x/xvidcore/xvidcore_1.3.7-1_aarch64.deb|2f358b11fd750935b43ac19f09bb7c4228e007079426e0b73ee8bae1ddf26fc1|pool/main/x/xvidcore/xvidcore_1.3.7-1_x86_64.deb|fb523353406710cbe9fbaac4fc4ba0048da4fb1be06e89f0be1369abf75b63ed"
  [xz-utils]="pool/main/x/xz-utils/xz-utils_5.8.4_aarch64.deb|c26e35d5393d4ad59d7bfbac93570d418996e69bc160458bee0e165844ae56e8|pool/main/x/xz-utils/xz-utils_5.8.4_x86_64.deb|66c8f91dfbced4357a519381313a6a766d0938b70fc0cf965a82e2f05d8386ef"
  [zlib]="pool/main/z/zlib/zlib_1.4_aarch64.deb|e3027565ae50bcd8ba5113c988b589754ae192c9cc3e6afbe3e4ed7c06b2598e|pool/main/z/zlib/zlib_1.4_x86_64.deb|55ab8f16e492d6ed03c2e2bf701af52cf54a313442dd7adedd3d6f3e3eba2e4f"
  [zstd]="pool/main/z/zstd/zstd_1.5.7-1_aarch64.deb|e1b4a5113648da8de189620ba1fce74c48b2d0833d9043391b9a1c91fb606fd3|pool/main/z/zstd/zstd_1.5.7-1_x86_64.deb|a76ba6c3d8742819bf4fff7780eb2e022269412700fc8f4471f530cc0d81833f"
)

if [ "$ABI" = "arm64-v8a" ]; then
  DEB_ARCH="aarch64"; EXPECTED_MACHINE="b700"; SHA_COL=2
else
  DEB_ARCH="x86_64"; EXPECTED_MACHINE="3e00"; SHA_COL=3
fi

# --- Setup ------------------------------------------------------------------
if [ -z "$WORK_DIR" ]; then WORK_DIR="$(mktemp -d)"; trap 'rm -rf "$WORK_DIR"' EXIT; fi
DEBS_DIR="$WORK_DIR/debs"; EXTRACT_DIR="$WORK_DIR/extract"
PREFIX="$EXTRACT_DIR/data/data/com.termux/files/usr"
mkdir -p "$DEBS_DIR" "$EXTRACT_DIR" "$JNI_OUT"
if [ "$WITH_ASSETS" = "1" ]; then mkdir -p "$ASSETS_OUT"; fi
command -v "$PATCHELF" >/dev/null || { echo "patchelf not found (set --patchelf or install it)" >&2; exit 1; }
"$PATCHELF" --version

download() { # $1=package
  local entry="${DEBS[$1]}" pool_a sha_a pool_x sha_x pool sha file path rest
  pool_a="${entry%%|*}"; rest="${entry#*|}"; sha_a="${rest%%|*}"; rest="${rest#*|}"
  pool_x="${rest%%|*}"; sha_x="${rest#*|}"
  if [ "$DEB_ARCH" = "aarch64" ]; then pool="$pool_a"; sha="$sha_a"; else pool="$pool_x"; sha="$sha_x"; fi
  file="$(basename "$pool")"; path="$DEBS_DIR/$file"
  if [ ! -f "$path" ] && [ -n "$DEBS_DIR_OVERRIDE" ] && [ -f "$DEBS_DIR_OVERRIDE/$file" ]; then
    echo "Reusing $file from $DEBS_DIR_OVERRIDE"
    cp "$DEBS_DIR_OVERRIDE/$file" "$path"
  fi
  if [ ! -f "$path" ]; then echo "Downloading $file..."; curl -f -sL --retry 3 --retry-delay 2 -4 "$BASE_URL/$pool" -o "$path"; fi
  echo "$sha $path" | sha256sum --check --strict -
}

for pkg in "${!DEBS[@]}"; do download "$pkg"; done
# dpkg-deb -x fails chown on non-root hosts for some packages (resolv-conf,
# ttf-dejavu in prep); the file contents still extract, but the tar pipeline
# below is clean either way.
for deb in "$DEBS_DIR"/*.deb; do echo "Extracting $(basename "$deb")..."; dpkg-deb --fsys-tarfile "$deb" | tar --no-same-owner -x -C "$EXTRACT_DIR"; done

# --- Pick the trimmed closure ------------------------------------------------
# stage_lib <glob-under-$PREFIX/lib-or-bin> <staged-name>. Versioned names are
# renamed by patchelf below; the file on disk already carries the final name.
stage_lib() { # $1=path under $PREFIX (lib/... or bin/...) $2=staged name
  local src="$PREFIX/$1"
  [ -f "$src" ] || { echo "stage_lib: missing $src" >&2; exit 1; }
  cp "$src" "$JNI_OUT/$2"
}

# --- git (5 files, 10465640 B, measured) ---
stage_lib "bin/git" "libgit.so"
stage_lib "lib/libcrypto.so.3" "libcrypto.so"
stage_lib "lib/libiconv.so" "libiconv.so"
stage_lib "lib/libpcre2-8.so" "libpcre2-8.so"
stage_lib "lib/libz.so.1" "libz.so"

# --- git-core helpers (7 real binaries, ~12.6 MB) ---
# Coordinator decision (desain D5): stage the helpers + set GIT_EXEC_PATH
# so clone/fetch/push over HTTPS work. Their DT_NEEDED are all already in
# the staged closure (libcurl/libssl/libcrypto/libz/libexpat/libiconv/
# libpcre2-8). git-remote-https/-ftp/-ftps are symlinks to git-remote-http
# in the .deb; the runtime recreates them pointing at tools/bin/git-remote-http.
stage_lib "libexec/git-core/git-remote-http" "libgit-remote-http.so"
stage_lib "libexec/git-core/git-http-fetch" "libgit-http-fetch.so"
stage_lib "libexec/git-core/git-http-push" "libgit-http-push.so"
stage_lib "libexec/git-core/git-daemon" "libgit-daemon.so"
stage_lib "libexec/git-core/git-http-backend" "libgit-http-backend.so"
stage_lib "libexec/git-core/git-imap-send" "libgit-imap-send.so"
stage_lib "libexec/git-core/git-sh-i18n--envsubst" "libgit-sh-i18n--envsubst.so"

# --- rg (2 files, 5348904 B, measured) ---
stage_lib "bin/rg" "librg.so"
stage_lib "lib/libpcre2-8.so" "libpcre2-8.so"

# --- node (10 files, 94351704 B, measured) ---
stage_lib "bin/node" "libnode.so"
stage_lib "lib/libc++_shared.so" "libc++_shared.so"
stage_lib "lib/libcares.so" "libcares.so"
stage_lib "lib/libcrypto.so.3" "libcrypto.so"
stage_lib "lib/libicudata.so.79" "libicudata.so"
stage_lib "lib/libicui18n.so.79" "libicui18n.so"
stage_lib "lib/libicuuc.so.79" "libicuuc.so"
stage_lib "lib/libsqlite3.so" "libsqlite3.so"
stage_lib "lib/libssl.so.3" "libssl.so"
stage_lib "lib/libz.so.1" "libz.so"

# --- python3 (93 files, 21005960 B, measured) ---
stage_lib "bin/python3.14" "libpython3.so"
stage_lib "lib/libandroid-posix-semaphore.so" "libandroid-posix-semaphore.so"
stage_lib "lib/libandroid-support.so" "libandroid-support.so"
stage_lib "lib/libbz2.so.1.0" "libbz2.so"
stage_lib "lib/libcrypto.so.3" "libcrypto.so"
stage_lib "lib/libexpat.so.1" "libexpat.so"
stage_lib "lib/libffi.so" "libffi.so"
stage_lib "lib/libgdbm.so" "libgdbm.so"
stage_lib "lib/libgdbm_compat.so" "libgdbm_compat.so"
stage_lib "lib/liblzma.so.5" "liblzma.so"
stage_lib "lib/libncursesw.so.6" "libncursesw.so"
stage_lib "lib/libpanelw.so.6" "libpanelw.so"
stage_lib "lib/libpython3.14.so" "libpython3.14.so"
stage_lib "lib/libreadline.so.8" "libreadline.so"
stage_lib "lib/libsqlite3.so" "libsqlite3.so"
stage_lib "lib/libssl.so.3" "libssl.so"
stage_lib "lib/libz.so.1" "libz.so"
stage_lib "lib/libzstd.so.1" "libzstd.so"

# --- jq (3 files, 930088 B, measured) ---
stage_lib "bin/jq" "libjq-cli.so"
stage_lib "lib/libjq.so" "libjq.so"
stage_lib "lib/libonig.so" "libonig.so"

# --- curl (10 files, 8422840 B, measured) ---
stage_lib "bin/curl" "libcurl-cli.so"
stage_lib "lib/libcrypto.so.3" "libcrypto.so"
stage_lib "lib/libcurl.so" "libcurl.so"
stage_lib "lib/libnghttp2.so" "libnghttp2.so"
stage_lib "lib/libnghttp3.so" "libnghttp3.so"
stage_lib "lib/libngtcp2.so" "libngtcp2.so"
stage_lib "lib/libngtcp2_crypto_ossl.so" "libngtcp2_crypto_ossl.so"
stage_lib "lib/libssh2.so" "libssh2.so"
stage_lib "lib/libssl.so.3" "libssl.so"
stage_lib "lib/libz.so.1" "libz.so"

# --- xz (2 files, 237424 B, measured) ---
stage_lib "bin/xz" "libxz.so"
stage_lib "lib/liblzma.so.5" "liblzma.so"

# --- tar (6 files, 2255504 B, measured) ---
stage_lib "bin/tar" "libtar.so"
stage_lib "lib/libacl.so" "libacl.so"
stage_lib "lib/libandroid-glob.so" "libandroid-glob.so"
stage_lib "lib/libandroid-selinux.so" "libandroid-selinux.so"
stage_lib "lib/libiconv.so" "libiconv.so"
stage_lib "lib/libpcre2-8.so" "libpcre2-8.so"

# --- ffmpeg (93 files, 96020072 B, measured) ---
stage_lib "bin/ffmpeg" "libffmpeg.so"
stage_lib "bin/ffprobe" "libffprobe.so"
stage_lib "lib/libOpenCL.so" "libOpenCL.so"
stage_lib "lib/libSvtAv1Enc.so" "libSvtAv1Enc.so"
stage_lib "lib/libXau.so" "libXau.so"
stage_lib "lib/libXdmcp.so" "libXdmcp.so"
stage_lib "lib/libandroid-execinfo.so" "libandroid-execinfo.so"
stage_lib "lib/libandroid-glob.so" "libandroid-glob.so"
stage_lib "lib/libandroid-posix-semaphore.so" "libandroid-posix-semaphore.so"
stage_lib "lib/libandroid-shmem.so" "libandroid-shmem.so"
stage_lib "lib/libandroid-support.so" "libandroid-support.so"
stage_lib "lib/libaom.so" "libaom.so"
stage_lib "lib/libass.so" "libass.so"
stage_lib "lib/libavcodec.so.63" "libavcodec.so"
stage_lib "lib/libavdevice.so.63" "libavdevice.so"
stage_lib "lib/libavfilter.so.12" "libavfilter.so"
stage_lib "lib/libavformat.so.63" "libavformat.so"
stage_lib "lib/libavutil.so.61" "libavutil.so"
stage_lib "lib/libbluray.so.4" "libbluray.so"
stage_lib "lib/libbrotlicommon.so" "libbrotlicommon.so"
stage_lib "lib/libbrotlidec.so" "libbrotlidec.so"
stage_lib "lib/libbrotlienc.so" "libbrotlienc.so"
stage_lib "lib/libbs2b.so" "libbs2b.so"
stage_lib "lib/libbz2.so.1.0" "libbz2.so"
stage_lib "lib/libc++_shared.so" "libc++_shared.so"
stage_lib "lib/libcrypto.so.3" "libcrypto.so"
stage_lib "lib/libdav1d.so" "libdav1d.so"
stage_lib "lib/libdvdnav.so.4" "libdvdnav.so"
stage_lib "lib/libdvdread.so.8" "libdvdread.so"
stage_lib "lib/libexpat.so.1" "libexpat.so"
stage_lib "lib/libfftw3.so" "libfftw3.so"
stage_lib "lib/libfontconfig.so" "libfontconfig.so"
stage_lib "lib/libfreetype.so" "libfreetype.so"
stage_lib "lib/libfribidi.so" "libfribidi.so"
stage_lib "lib/libglib-2.0.so.0" "libglib-2.0.so"
stage_lib "lib/libglslang-default-resource-limits.so" "libglslang-default-resource-limits.so"
stage_lib "lib/libglslang.so" "libglslang.so"
stage_lib "lib/libgme.so" "libgme.so"
stage_lib "lib/libgraphite2.so" "libgraphite2.so"
stage_lib "lib/libharfbuzz.so" "libharfbuzz.so"
stage_lib "lib/libhwy.so" "libhwy.so"
stage_lib "lib/libiconv.so" "libiconv.so"
stage_lib "lib/libjxl.so" "libjxl.so"
stage_lib "lib/libjxl_cms.so" "libjxl_cms.so"
stage_lib "lib/libjxl_threads.so" "libjxl_threads.so"
stage_lib "lib/liblcms2.so" "liblcms2.so"
stage_lib "lib/liblzma.so.5" "liblzma.so"
stage_lib "lib/libmp3lame.so" "libmp3lame.so"
stage_lib "lib/libmpg123.so" "libmpg123.so"
stage_lib "lib/libmysofa.so" "libmysofa.so"
stage_lib "lib/libogg.so" "libogg.so"
stage_lib "lib/libopencore-amrnb.so" "libopencore-amrnb.so"
stage_lib "lib/libopencore-amrwb.so" "libopencore-amrwb.so"
stage_lib "lib/libopenmpt.so" "libopenmpt.so"
stage_lib "lib/libopus.so" "libopus.so"
stage_lib "lib/libpcre2-8.so" "libpcre2-8.so"
stage_lib "lib/libplacebo.so.387" "libplacebo.so"
stage_lib "lib/libpng16.so" "libpng16.so"
stage_lib "lib/librav1e.so" "librav1e.so"
stage_lib "lib/librubberband.so" "librubberband.so"
stage_lib "lib/libsamplerate.so" "libsamplerate.so"
stage_lib "lib/libsharpyuv.so" "libsharpyuv.so"
stage_lib "lib/libsodium.so" "libsodium.so"
stage_lib "lib/libsoxr.so" "libsoxr.so"
stage_lib "lib/libsrt.so" "libsrt.so"
stage_lib "lib/libssh.so" "libssh.so"
stage_lib "lib/libssl.so.3" "libssl.so"
stage_lib "lib/libswresample.so.7" "libswresample.so"
stage_lib "lib/libswscale.so.10" "libswscale.so"
stage_lib "lib/libtheoradec.so" "libtheoradec.so"
stage_lib "lib/libtheoraenc.so" "libtheoraenc.so"
stage_lib "lib/libudfread.so.3" "libudfread.so"
stage_lib "lib/libvidstab.so" "libvidstab.so"
stage_lib "lib/libvmaf.so" "libvmaf.so"
stage_lib "lib/libvo-amrwbenc.so.0" "libvo-amrwbenc.so"
stage_lib "lib/libvorbis.so" "libvorbis.so"
stage_lib "lib/libvorbisenc.so" "libvorbisenc.so"
stage_lib "lib/libvorbisfile.so" "libvorbisfile.so"
stage_lib "lib/libvpx.so.12" "libvpx.so"
stage_lib "lib/libvulkan.so" "libvulkan.so"
stage_lib "lib/libwebp.so" "libwebp.so"
stage_lib "lib/libwebpmux.so" "libwebpmux.so"
stage_lib "lib/libx264.so.164" "libx264.so"
stage_lib "lib/libx265.so" "libx265.so"
stage_lib "lib/libxcb-shape.so" "libxcb-shape.so"
stage_lib "lib/libxcb-shm.so" "libxcb-shm.so"
stage_lib "lib/libxcb-xfixes.so" "libxcb-xfixes.so"
stage_lib "lib/libxcb.so" "libxcb.so"
stage_lib "lib/libxml2.so.16" "libxml2.so"
stage_lib "lib/libxvidcore.so.4" "libxvidcore.so"
stage_lib "lib/libz.so.1" "libz.so"
stage_lib "lib/libzimg.so" "libzimg.so"
stage_lib "lib/libzmq.so" "libzmq.so"

# --- patchelf: versioned DT_NEEDED -> unversioned ---------------------------
# One invocation per file (batched args): each invocation rewrites the whole
# ELF and pads sections, so one edit per call grew libnode.so by ~2 MB per
# --replace-needed in opencode; one call for all edits keeps it to ~2 MB/file.
# Verified on the prep VM with patchelf 0.19.3 on libcurl(-cli).so: renames
# applied, SONAME set, LOAD aligns stay >= 0x4000, growth +19/+75 KiB.
declare -A RENAME=(
  [libavcodec.so.63]=libavcodec.so
  [libavdevice.so.63]=libavdevice.so
  [libavfilter.so.12]=libavfilter.so
  [libavformat.so.63]=libavformat.so
  [libavutil.so.61]=libavutil.so
  [libbluray.so.4]=libbluray.so
  [libbz2.so.1.0]=libbz2.so
  [libcrypto.so.3]=libcrypto.so
  [libdvdnav.so.4]=libdvdnav.so
  [libdvdread.so.8]=libdvdread.so
  [libexpat.so.1]=libexpat.so
  [libglib-2.0.so.0]=libglib-2.0.so
  [libicudata.so.79]=libicudata.so
  [libicui18n.so.79]=libicui18n.so
  [libicuuc.so.79]=libicuuc.so
  [liblzma.so.5]=liblzma.so
  [libncursesw.so.6]=libncursesw.so
  [libpanelw.so.6]=libpanelw.so
  [libplacebo.so.387]=libplacebo.so
  [libreadline.so.8]=libreadline.so
  [libssl.so.3]=libssl.so
  [libswresample.so.7]=libswresample.so
  [libswscale.so.10]=libswscale.so
  [libudfread.so.3]=libudfread.so
  [libvo-amrwbenc.so.0]=libvo-amrwbenc.so
  [libvpx.so.12]=libvpx.so
  [libx264.so.164]=libx264.so
  [libxml2.so.16]=libxml2.so
  [libxvidcore.so.4]=libxvidcore.so
  [libz.so.1]=libz.so
  [libzstd.so.1]=libzstd.so
  [libcurl.so.3]=libcurl.so  # already covered via libcurl NEEDED walk
)
for lib in "$JNI_OUT"/lib*.so; do
  name="$(basename "$lib")"; args=()
  case "$name" in libgit.so|librg.so|libnode.so|libpython3.so|libjq-cli.so|libcurl-cli.so|libxz.so|libtar.so|libffmpeg.so|libffprobe.so|libgit-remote-http.so|libgit-http-fetch.so|libgit-http-push.so|libgit-daemon.so|libgit-http-backend.so|libgit-imap-send.so|libgit-sh-i18n--envsubst.so) ;;
    *) current_soname="$("$PATCHELF" --print-soname "$lib" 2>/dev/null || true)"
       if [ "$current_soname" != "$name" ]; then args+=(--set-soname "$name"); fi ;;
  esac
  needed="$("$PATCHELF" --print-needed "$lib" || true)"
  for old in "${!RENAME[@]}"; do
    if printf '%s\n' "$needed" | grep -qx "$old"; then args+=(--replace-needed "$old" "${RENAME[$old]}"); fi
  done
  if [ "${#args[@]}" -gt 0 ]; then "$PATCHELF" "${args[@]}" "$lib"; fi
done

# --- ELF gates (same as opencode stage-node.sh / stage-engine.ps1) -----------
check_elf() { # $1=file
  local file="$1" magic machine
  magic="$(od -An -tx1 -N4 "$file" | tr -d ' \n')"
  machine="$(od -An -tx1 -j18 -N2 "$file" | tr -d ' \n')"
  [ "$magic" = "7f454c46" ] || { echo "not an ELF file: $file" >&2; exit 1; }
  [ "$machine" = "$EXPECTED_MACHINE" ] || { echo "architecture mismatch: $file reports e_machine=0x$machine, expected 0x$EXPECTED_MACHINE" >&2; exit 1; }
  local align
  while IFS= read -r align; do
    [ "$((align))" -ge 16384 ] || { echo "$file has a PT_LOAD segment with p_align=$align; needs 0x4000 for 16 KB page sizes" >&2; exit 1; }
  done < <(readelf -lW "$file" | awk '$1 == "LOAD" { print $NF }')
  local n
  while IFS= read -r n; do
    case "$n" in
      libc.so|libm.so|libdl.so|liblog.so|libandroid.so|libmediandk.so) ;;
      lib*.so) [ -f "$JNI_OUT/$n" ] || { echo "$file still needs $n, which is not staged" >&2; exit 1; } ;;
      lib*.so.*) base="${n%%.so.*}.so"; [ -f "$JNI_OUT/$base" ] || { echo "$file still needs $n (versioned; staged as $base), which is not staged" >&2; exit 1; } ;;
      *) ;;
    esac
  done < <("$PATCHELF" --print-needed "$file")
}
total=0
for lib in "$JNI_OUT"/lib*.so; do check_elf "$lib"; size="$(wc -c < "$lib")"; total=$((total + size)); echo "$ABI staged: $(basename "$lib") ($size B)"; done
echo "$ABI tier2 closure: $total B (131 files incl. 7 git-core helpers; raw, before APK compression)"

# --- Assets: npm tree + corepack + CA bundle; python stdlib + pip ------------
if [ "$WITH_ASSETS" = "1" ]; then
  # Node assets (opencode stage-node.sh pattern).
  rm -rf "$ASSETS_OUT/node"
  mkdir -p "$ASSETS_OUT/node/lib/node_modules" "$ASSETS_OUT/node/etc/tls"
  cp -r "$PREFIX/lib/node_modules/npm" "$ASSETS_OUT/node/lib/node_modules/npm"
  cp -r "$PREFIX/lib/node_modules/corepack" "$ASSETS_OUT/node/lib/node_modules/corepack"
  rm -rf "$ASSETS_OUT/node/lib/node_modules/npm/man" "$ASSETS_OUT/node/lib/node_modules/npm/docs"
  cp "$PREFIX/etc/tls/cert.pem" "$ASSETS_OUT/node/etc/tls/cert.pem"
  echo "node assets staged: $(du -sb "$ASSETS_OUT/node" | cut -f1) B (target ~10.5 MiB raw; npm man/docs pruned like opencode)"
  # Python assets (opencode stage-python.sh pattern).
  rm -rf "$ASSETS_OUT/python"
  mkdir -p "$ASSETS_OUT/python/lib"
  cp -r "$PREFIX/lib/python3.14" "$ASSETS_OUT/python/lib/python3.14"
  # lib-dynload modules are dlopen'd at import time: same unversioned renames.
  for mod in "$ASSETS_OUT"/python/lib/python3.14/lib-dynload/*.so; do
    args=(); needed="$("$PATCHELF" --print-needed "$mod" || true)"
    for old in "${!RENAME[@]}"; do
      if printf '%s\n' "$needed" | grep -qx "$old"; then args+=(--replace-needed "$old" "${RENAME[$old]}"); fi
    done
    if [ "${#args[@]}" -gt 0 ]; then "$PATCHELF" "${args[@]}" "$mod"; fi
    check_elf "$mod"
  done
  # pip's vendored certifi ships as a symlink to the dead Termux CA path.
  rm -f "$ASSETS_OUT/python/lib/python3.14/site-packages/pip/_vendor/certifi/cacert.pem"
  cp "$PREFIX/etc/tls/cert.pem" "$ASSETS_OUT/python/lib/python3.14/site-packages/pip/_vendor/certifi/cacert.pem"
  echo "python assets staged: $(du -sb "$ASSETS_OUT/python" | cut -f1) B (target ~23.1 MiB raw incl. patchelf growth on lib-dynload)"
  # Git templates (needed by `git init`; 27 KiB, 16 files).
  rm -rf "$ASSETS_OUT/git-templates"
  cp -r "$PREFIX/share/git-core/templates" "$ASSETS_OUT/git-templates"
  # git-core multicall symlink names (152 entries): the .deb ships them as
  # symlinks to ../../bin/git (except git-remote-{https,ftp,ftps}, which
  # point at git-remote-http). A symlink to a path that does not exist at
  # build time cannot be packaged by aapt2, so only the NAMES are shipped;
  # BundledRuntimeBackend recreates them at runtime in files/engine/git-core.
  find "$PREFIX/libexec/git-core" -maxdepth 1 -type l -printf '%f\n' | LC_ALL=C sort > "$ASSETS_OUT/git-core-links.txt"
  echo "git-core links listed: $(wc -l < "$ASSETS_OUT/git-core-links.txt") names (target 152)"
  # Asset manifest: every staged asset file, one relative path per line.
  # BundledRuntimeBackend reads this via rootBundle and copies each file
  # to files/engine/ on first launch (avoids relying on AssetManifest.json).
  (cd "$ASSETS_OUT" && find node python git-templates -type f | LC_ALL=C sort > "$ASSETS_OUT/tier2-manifest.txt")
  echo "asset manifest: $(wc -l < "$ASSETS_OUT/tier2-manifest.txt") files"
  # Regenerate the pubspec.yaml assets section: Flutter pubspec directory
  # entries are NOT recursive (flutter_tools asset.dart
  # _parseAssetsFromFolder uses a non-recursive listSync, so only the
  # top-level FILES of a listed directory are bundled). Listing just
  # assets/node/ + assets/python/ + assets/git-templates/ silently drops
  # the whole node/python trees (only git-templates/description made it
  # into the APK — verified 2026-11-16 via `flutter build bundle`).
  # Every subdirectory must be listed explicitly. This step rewrites the
  # whole `assets:` list in <repo>/pubspec.yaml from the staged trees
  # (the section contains only Tier 2 entries).
  command -v python3 >/dev/null || { echo "python3 is required (pubspec regeneration)" >&2; exit 2; }
  (cd "$ASSETS_OUT" && find node python git-templates -type d | LC_ALL=C sort | sed 's|$|/|' > "$WORK_DIR/tier2-asset-dirs.txt")
  ASSETS_DIR_LIST="$WORK_DIR/tier2-asset-dirs.txt" REPO_PUBSPEC="$(dirname "$ASSETS_OUT")/pubspec.yaml" python3 - <<'PYEOF'
import os
dirs = [l.strip() for l in open(os.environ["ASSETS_DIR_LIST"]) if l.strip()]
pubspec_path = os.environ["REPO_PUBSPEC"]
lines = open(pubspec_path).read().splitlines(keepends=True)
block = [
    "    # Tier 2 bundled runtime (script/android/stage-tier2.sh):\n",
    "    # node tree + CA bundle, python stdlib + pip, git templates,\n",
    "    # git-core multicall names, and the asset manifest the backend\n",
    "    # uses to extract them on first launch.\n",
    "    # GENERATED by script/android/stage-tier2.sh -- do not edit by hand.\n",
    "    # Flutter pubspec directory entries are NOT recursive (flutter_tools\n",
    "    # asset.dart _parseAssetsFromFolder uses a non-recursive listSync),\n",
    "    # so every subdirectory of the node/python/git-templates trees must\n",
    "    # be listed explicitly. Re-run the staging script to regenerate.\n",
]
block += [f"    - assets/{d}\n" for d in dirs]
block += ["    - assets/git-core-links.txt\n", "    - assets/tier2-manifest.txt\n"]
idx = [i for i, l in enumerate(lines) if l.rstrip() == "  assets:"]
if idx:
    start = idx[0]
    end = start + 1
    while end < len(lines) and lines[end].startswith("    "):
        end += 1
    lines[start + 1:end] = block
else:
    # Fresh checkout: no assets section yet — insert one after
    # `uses-material-design: true` (last line of the flutter section).
    anchor = [i for i, l in enumerate(lines) if l.rstrip() == "  uses-material-design: true"]
    at = anchor[0] + 1 if anchor else len(lines)
    lines[at:at] = ["  assets:\n"] + block
open(pubspec_path, "w").write("".join(lines))
print(f"pubspec assets regenerated: {len(dirs)} directories + 2 files")
PYEOF
  # Gate: pubspec must list every staged directory + the 2 text files.
  [ "$(grep -c '    - assets/' "$(dirname "$ASSETS_OUT")/pubspec.yaml")" = "$(( $(wc -l < "$WORK_DIR/tier2-asset-dirs.txt") + 2 ))" ] \
    || { echo "pubspec asset count mismatch" >&2; exit 1; }
fi

echo "stage-tier2 done for $ABI (git-core helpers staged, GIT_EXEC_PATH is set by BundledRuntimeBackend)"
