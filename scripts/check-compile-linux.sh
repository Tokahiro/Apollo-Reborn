#!/bin/sh
#
# check-compile-linux.sh — compile the tweak's sources for iOS on Linux,
# without a Mac, and report C/C++ linkage mismatches between them.
#
# The source list, compiler and Logos flags, SDK version and deployment target
# come from the Makefile itself, evaluated with the Theos commit that CI pins
# (.github/workflows/build-ipa.yml), so they follow the real build. Objects are
# cached and only what changed is rebuilt, so later runs take seconds.
#
# The linkage check reads every object, plus the functions Swift exports with
# @_cdecl, so it also catches a function a header declares without extern "C"
# that a .m, .c or .swift file defines and an .xm calls.
#
# Not covered, so CI stays the final check:
#   - Swift sources, and code behind __has_include("ApolloReborn-Swift.h"),
#     which needs the header the Swift compiler generates.
#   - -fmodules: LLVM's clang can't build the iOS SDK's modules, so a missing
#     import that only module rules reject isn't caught.
#   - Linking the dylib (ld64, FFmpegKit's libraries) and packaging.
#
# Usage: scripts/check-compile-linux.sh
# Needs GNU make, clang (with clang++), perl, git, llvm-nm and llvm-cxxfilt.
# Downloads (about 330 MB, once per pinned commit) go to $APOLLO_IOS_CHECK_DIR,
# default ~/.cache/apollo-ios-check.

set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache=${APOLLO_IOS_CHECK_DIR:-$HOME/.cache/apollo-ios-check}
# One object directory per checkout, so worktrees don't rebuild each other's.
out=$cache/obj/$(printf '%s' "$repo" | cksum | cut -d ' ' -f 1)

for tool in clang clang++ make perl git llvm-nm llvm-cxxfilt; do
    command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done

# fetch <github repo> <dir> <commit> [sparse paths...]: a partial clone at a
# fixed commit into a directory of its own. It is cloned into a temporary
# directory and renamed only when complete; if another run got there first,
# its copy is kept.
fetch() {
    url=https://github.com/$1.git dir=$cache/$2 commit=$3
    shift 3
    # Theos' own checkout has empty placeholders for its submodules, so only
    # the marker shows a finished download.
    [ -f "$dir/.apollo-fetched" ] && return
    mkdir -p "$(dirname "$dir")"
    tmp=$(mktemp -d "$dir.tmp.XXXXXX")
    git clone -q --filter=blob:none --no-checkout "$url" "$tmp"
    if [ $# -gt 0 ]; then
        git -C "$tmp" sparse-checkout set --no-cone "$@"
    fi
    git -C "$tmp" checkout -q "$commit"
    touch "$tmp/.apollo-fetched"
    # Replaces an empty placeholder; keeps another run's finished copy.
    mv -T "$tmp" "$dir" 2>/dev/null || rm -rf "$tmp"
}
# The commit a checked-out repo pins for one of its submodules.
gitlink() { git -C "$1" ls-tree HEAD "$2" | awk '{print $3}'; }

theos_commit=$(grep -A 1 'repository: theos/theos' "$repo/.github/workflows/build-ipa.yml" |
    sed -n 's/.*ref: *\([0-9a-f]\{40\}\).*/\1/p')
[ -n "$theos_commit" ] || { echo "No Theos pin found in build-ipa.yml" >&2; exit 1; }
theos=$cache/theos-$theos_commit
fetch theos/theos "theos-$theos_commit" "$theos_commit"
fetch theos/logos "theos-$theos_commit/vendor/logos" "$(gitlink "$theos" vendor/logos)"
fetch theos/headers "theos-$theos_commit/vendor/include" "$(gitlink "$theos" vendor/include)"
fetch theos/lib "theos-$theos_commit/vendor/lib" "$(gitlink "$theos" vendor/lib)"
[ -d "$repo/modules/KSCrash/Sources" ] || git -C "$repo" submodule update --init --depth 1 modules/KSCrash modules/ZipArchive

# The Makefile generates src/Version.h (ignored by git) before a build.
[ -f "$repo/src/Version.h" ] || printf '#define TWEAK_VERSION "v0"\n#define APOLLO_GIT_COMMIT "local"\n' > "$repo/src/Version.h"

# The build's own inputs, from the Makefile and Theos.
inputs=$(cd "$repo" && make -s -f Makefile THEOS="$theos" --eval 'apollo-check-inputs: ; @printf "FILE %s\n" $(ApolloReborn_FILES); printf "FLAG %s\n" $(_THEOS_INTERNAL_IFLAGS_C) $(_THEOS_INTERNAL_CFLAGS) $(_THEOS_INTERNAL_OBJCFLAGS) $(ApolloReborn_CFLAGS); printf "LOGOSFLAG %s\n" $(_THEOS_INTERNAL_LOGOSFLAGS) $(ApolloReborn_LOGOSFLAGS); printf "SDK %s\nDEPLOY %s\n" "$(APOLLO_DEVICE_SDK)" "$(APOLLO_DEVICE_DEPLOY)"' apollo-check-inputs)
value() { echo "$inputs" | sed -n "s/^$1 //p"; }
sdk_version=$(value SDK)
deploy=$(value DEPLOY)

# A copy of the SDK version the Makefile pins. Third-party; see AGENTS.md.
sdk_repo_commit=4a48e5409f8ea6ac422c44d91b86fa0f8ae010ff
fetch xybp888/iOS-SDKs "sdk-$sdk_repo_commit-$sdk_version" "$sdk_repo_commit" "/iPhoneOS$sdk_version.sdk/"
sdk=$cache/sdk-$sdk_repo_commit-$sdk_version/iPhoneOS$sdk_version.sdk
[ -d "$sdk" ] || { echo "No iPhoneOS$sdk_version.sdk in xybp888/iOS-SDKs at $sdk_repo_commit" >&2; exit 1; }
# Headers only, at the commit the repo pins for its submodule.
ffmpeg_commit=$(gitlink "$repo" modules/ffmpeg-kit)
fetch JeffreyCA/ffmpeg-kit-ios "ffmpeg-$ffmpeg_commit/ffmpeg-kit" "$ffmpeg_commit" '/ffmpeg-kit/include/'

mkdir -p "$out"
# update <file>: replace it with <file>.new only if the content changed, so
# make rebuilds only when something real changed.
update() { cmp -s "$1.new" "$1" && rm -f "$1.new" || mv "$1.new" "$1"; }

# Apple's clang finds SDK sub-frameworks (UIUtilities) by itself; LLVM's needs
# -iframework. Theos also adds -fmodules on macOS (see "Not covered" above).
{
    printf '%s\n' -target "arm64-apple-ios$deploy" -isysroot "$sdk" -iframework "$sdk/System/Library/SubFrameworks" \
        '-DTHEOS_INSTANCE_NAME="ApolloReborn"'
    # FFmpegKit's headers, which the build reads from the populated submodule.
    printf '%s\n' "-I$cache/ffmpeg-$ffmpeg_commit"
    value FLAG
} > "$out/flags.new"
update "$out/flags"
{
    # Theos' default generator for iOS targets.
    printf '%s\n' -c generator=MobileSubstrate
    value LOGOSFLAG
} > "$out/logosflags.new"
update "$out/logosflags"
{
    clang --version | head -n 1
    echo "theos $theos_commit sdk $sdk_repo_commit"
} > "$out/stamp.new"
update "$out/stamp"

files=$(value FILE | sed "s#^$repo/##")
sources=$(echo "$files" | grep -E '\.(m|mm|xm|c|cpp)$' || true)
missing=$(for source in $sources; do if [ ! -f "$repo/$source" ]; then echo "$source"; fi; done)
if [ -n "$missing" ]; then
    echo "$missing" | sed 's/^/MISSING /'
    exit 1
fi
count=$(echo "$sources" | wc -l)
echo "Compiling $count sources from ApolloReborn_FILES for iOS $deploy with the iOS $sdk_version SDK (only changed ones are rebuilt)..."

failed=0
make -k -s -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" -f "$repo/scripts/check-compile-linux.mk" \
    REPO="$repo" OUT="$out" FLAGS_FILE="$out/flags" LOGOS_FLAGS_FILE="$out/logosflags" STAMP_FILE="$out/stamp" \
    LOGOS="$theos/vendor/logos/bin/logos.pl" SOURCES="$(echo $sources)" || failed=1

objects=$(for source in $sources; do if [ -f "$out/$source.o" ]; then echo "$out/$source.o"; fi; done)

# "<symbol> <name> <kind>" for external symbols; kind is c or cxx. A free C++
# function demangles to "name(args)"; other C++ symbols are skipped.
symbols() {
    # shellcheck disable=SC2086
    llvm-nm --extern-only "$@" $objects | awk '$NF ~ /^_/ {print $NF}' | sort -u > "$out/raw"
    llvm-cxxfilt --strip-underscore < "$out/raw" | paste -d '\t' "$out/raw" - | awk -F '\t' '
        $1 !~ /^__Z/ { print $1, substr($1, 2), "c"; next }
        match($2, /^[A-Za-z_][A-Za-z0-9_]*\(/) { print $1, substr($2, 1, RLENGTH - 1), "cxx" }'
}
{
    symbols --defined-only
    # Swift isn't compiled; its @_cdecl functions are C definitions.
    for swift in $(echo "$files" | grep '\.swift$' || true); do
        sed -n 's/.*@_cdecl("\([A-Za-z_][A-Za-z0-9_]*\)").*/_\1 \1 c/p' "$repo/$swift"
    done
} > "$out/defined"
symbols --undefined-only > "$out/undefined"
# A C call with only a C++ definition, or a C++ call whose exact symbol is
# missing while a C definition exists (overloads alone don't count).
awk 'NR == FNR { symbol[$1] = 1; defined[$2, $3] = $1; next }
     $3 == "c" && !(($2, "c") in defined) && (($2, "cxx") in defined) {
         printf "LINKAGE %s: called with C linkage, defined only with C++ linkage (%s)\n", $2, defined[$2, "cxx"]
         found = 1
     }
     $3 == "cxx" && !($1 in symbol) && (($2, "c") in defined) {
         printf "LINKAGE %s: called with C++ linkage (%s), defined with C linkage\n", $2, $1
         found = 1
     }
     END { exit found }' "$out/defined" "$out/undefined" || failed=1

if [ $failed -eq 0 ]; then
    echo "All $count sources compiled; no linkage mismatches."
fi
exit $failed
