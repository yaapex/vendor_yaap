#!/usr/bin/env bash
# AOSPA build helper script

# red = errors, cyan = warnings, green = confirmations, blue = informational
CLR_RST=$(tput sgr0)
CLR_RED=$CLR_RST$(tput setaf 1)
CLR_GRN=$CLR_RST$(tput setaf 2)
CLR_CYA=$CLR_RST$(tput setaf 6)
CLR_BLD=$(tput bold)
CLR_BLD_RED=$CLR_BLD$(tput setaf 1)
CLR_BLD_GRN=$CLR_BLD$(tput setaf 2)
CLR_BLD_BLU=$CLR_BLD$(tput setaf 4)
CLR_BLD_CYA=$CLR_BLD$(tput setaf 6)

BUILD_TYPE="userdebug"

die() { echo "${CLR_BLD_RED}$*${CLR_RST}" >&2; exit 1; }

checkExit() {
    local code=$?
    (( code != 0 )) && die "Build failed!"
}

showHelpAndExit() {
    echo "${CLR_BLD_BLU}Usage: $0 <device> [options]${CLR_RST}"
    echo
    echo "${CLR_BLD_BLU}Options:${CLR_RST}"
    local -a opts=(
        "-h, --help            Display this help message"
        "-c, --clean           Wipe the tree before building"
        "-i, --installclean    Dirty build - Use 'installclean'"
        "-r, --repo-sync       Sync before building"
        "-t, --build-type      Specify build type"
        "-j, --jobs            Specify jobs/threads to use"
        "-m, --module          Build a specific module"
        "-s, --sign-keys       Specify path to sign key mappings"
        "-p, --pwfile          Specify path to sign key password file"
        "-b, --backup-unsigned Store a copy of unsigned package along with signed"
        "-d, --delta           Generate a delta OTA from the specified target_files zip"
        "-z, --imgzip          Generate fastboot flashable image zip from signed target_files"
        "-g, --gapps,--gms     Build with GApps (TARGET_BUILD_GAPPS=true)"
    )
    printf "  ${CLR_BLD_BLU}%s${CLR_RST}\n" "${opts[@]}"
    exit 1
}

# Parse options
long_opts="help,clean,installclean,repo-sync,build-type:,jobs:,module:,sign-keys:,pwfile:,backup-unsigned,delta:,imgzip,gapps,gms"
getopt_cmd=$(getopt -o hcirt:j:m:s:p:bd:zg --long "$long_opts" \
    -n "$(basename "$0")" -- "$@") \
    || { echo "${CLR_BLD_RED}Error: Getopt failed${CLR_RST}" >&2; showHelpAndExit; }

eval set -- "$getopt_cmd"

while true; do
    case "$1" in
        -h|--help)            showHelpAndExit ;;
        -c|--clean)           FLAG_CLEAN_BUILD=y ;;
        -i|--installclean)    FLAG_INSTALLCLEAN_BUILD=y ;;
        -r|--repo-sync)       FLAG_SYNC=y ;;
        -t|--build-type)      BUILD_TYPE="$2";         shift ;;
        -j|--jobs)            JOBS="$2";               shift ;;
        -m|--module)          MODULES+=("$2");         shift ;;
        -s|--sign-keys)       KEY_MAPPINGS="$2";       shift ;;
        -p|--pwfile)          PWFILE="$2";             shift ;;
        -b|--backup-unsigned) FLAG_BACKUP_UNSIGNED=y ;;
        -d|--delta)           DELTA_TARGET_FILES="$2"; shift ;;
        -z|--imgzip)          FLAG_IMG_ZIP=y ;;
        -g|--gapps|--gms)     FLAG_GAPPS=y ;;
        --) shift; break ;;
    esac
    shift
done

(( $# > 0 )) || { echo "${CLR_BLD_RED}Error: No device specified${CLR_RST}" >&2; showHelpAndExit; }
export DEVICE="$1"; shift

# Require 64-bit host
[[ "$(uname -m)" == "x86_64" ]] \
    || die "error: unsupported arch (expected: x86_64, found: $(uname -m))"

# Resolve root and validate
cd "$(dirname "$0")"
DIR_ROOT=$(pwd)
[[ -d "$DIR_ROOT/vendor/yaap" ]] || die "error: insane root directory ($DIR_ROOT)"

DIR_RELEASE="$DIR_ROOT/releases/$DEVICE"
mkdir -p "$DIR_RELEASE"
echo "${CLR_BLD_CYA}Release output: $DIR_RELEASE${CLR_RST}"

# Set up build environment
echo "${CLR_BLD_BLU}Setting up the environment${CLR_RST}"
echo
. build/envsetup.sh
echo

# Resolve thread count
if [[ -z "$JOBS" ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then
        JOBS=$(sysctl -n machdep.cpu.core_count)
    else
        JOBS=$(nproc --all)
    fi
fi
CMD="-j$JOBS"

# Clean
if [[ "$FLAG_CLEAN_BUILD" == y ]]; then
    echo "${CLR_BLD_BLU}Cleaning output files left from old builds${CLR_RST}"
    echo
    m clobber "$CMD"
fi

# Repo sync
if [[ "$FLAG_SYNC" == y ]]; then
    echo "${CLR_BLD_BLU}Downloading the latest source files${CLR_RST}"
    echo
    repo sync -j"$JOBS" -c --current-branch --no-tags --force-sync
fi

# GApps
if [[ "$FLAG_GAPPS" == y ]]; then
    export TARGET_BUILD_GAPPS=true
    echo "${CLR_BLD_CYA}GApps: enabled${CLR_RST}"
else
    export TARGET_BUILD_GAPPS=false
    echo "${CLR_BLD_CYA}GApps: disabled${CLR_RST}"
fi

# Signing mode
if [[ -n "$KEY_MAPPINGS" ]]; then
    export YAAP_INLINE_SIGNING=false
    echo "${CLR_BLD_CYA}Inline signing: disabled (external keys provided)${CLR_RST}"
elif [[ "$YAAP_INLINE_SIGNING" == false ]]; then
    echo "${CLR_BLD_CYA}Inline signing: disabled${CLR_RST}"
else
    echo "${CLR_BLD_CYA}Inline signing: enabled${CLR_RST}"
fi

TIME_START=$(date +%s.%N)
echo "${CLR_BLD_GRN}Building YAAP for $DEVICE${CLR_RST}"
echo "${CLR_GRN}Start time: $(date)${CLR_RST}"
echo

# Lunch
echo "${CLR_BLD_BLU}Lunching $DEVICE${CLR_RST} ${CLR_CYA}(Including dependencies sync)${CLR_RST}"
echo
lunch "yaap_$DEVICE-$BUILD_TYPE"
[[ "$(get_build_var TARGET_PRODUCT 2>/dev/null)" == "yaap_$DEVICE" ]] || {
    [[ -f out/error.log ]] && cat out/error.log
    die "Lunch failed for $DEVICE"
}
echo

# Resolve YAAP_VERSION from build system after lunch
YAAP_VERSION=$(get_build_var YAAP_VERSION 2>/dev/null)
[[ -n "$YAAP_VERSION" ]] || die "YAAP_VERSION is empty — check vendor/yaap/config/*.mk"
echo "${CLR_BLD_CYA}Version: $YAAP_VERSION${CLR_RST}"
echo

# Install-clean
if [[ "$FLAG_INSTALLCLEAN_BUILD" == y ]]; then
    echo "${CLR_BLD_BLU}Cleaning compiled image files left from old builds${CLR_RST}"
    echo
    m installclean "$CMD" || die "installclean failed!"
fi

echo "${CLR_BLD_BLU}Starting compilation${CLR_RST}"
echo

TARGET_FILES_INTERMEDIATES="$OUT/obj/PACKAGING/target_files_intermediates"

# ── Build dispatch ────────────────────────────────────────────────────────────

if (( ${#MODULES[@]} > 0 )); then
    m "${MODULES[@]}" "$CMD"
    checkExit

elif [[ -n "$KEY_MAPPINGS" ]]; then
    [[ -n "$PWFILE" ]] && export ANDROID_PW_FILE="$PWFILE"

    m otatools target-files-package "$CMD"; checkExit

    echo "${CLR_BLD_BLU}Signing target files APKs${CLR_RST}"
    sign_target_files_apks -o -d "$KEY_MAPPINGS" \
        "$TARGET_FILES_INTERMEDIATES/yaap_$DEVICE-target_files.zip" \
        "$DIR_RELEASE/YAAP-$YAAP_VERSION-signed-target_files.zip"
    checkExit

    echo "${CLR_BLD_BLU}Generating signed install package${CLR_RST}"
    ota_from_target_files -k "$KEY_MAPPINGS/releasekey" \
        --block ${INCREMENTAL} \
        "$DIR_RELEASE/YAAP-$YAAP_VERSION-signed-target_files.zip" \
        "$DIR_RELEASE/YAAP-$YAAP_VERSION.zip"
    checkExit

    if [[ -n "$DELTA_TARGET_FILES" ]]; then
        [[ -f "$DELTA_TARGET_FILES" ]] \
            || die "Delta error: base target files don't exist ($DELTA_TARGET_FILES)"
        ota_from_target_files -k "$KEY_MAPPINGS/releasekey" \
            --block --incremental_from "$DELTA_TARGET_FILES" \
            "$DIR_RELEASE/YAAP-$YAAP_VERSION-signed-target_files.zip" \
            "$DIR_RELEASE/YAAP-$YAAP_VERSION-delta.zip"
        checkExit
    fi

    if [[ "$FLAG_IMG_ZIP" == y ]]; then
        echo "${CLR_BLD_BLU}Generating signed fastboot package${CLR_RST}"
        img_from_target_files \
            "$DIR_RELEASE/YAAP-$YAAP_VERSION-signed-target_files.zip" \
            "$DIR_RELEASE/YAAP-$YAAP_VERSION-image.zip"
        checkExit
    fi

elif [[ "$FLAG_IMG_ZIP" == y ]]; then
    m otatools target-files-package "$CMD"; checkExit

    echo "${CLR_BLD_BLU}Generating install package${CLR_RST}"
    ota_from_target_files \
        "$TARGET_FILES_INTERMEDIATES/yaap_$DEVICE-target_files.zip" \
        "$DIR_RELEASE/YAAP-$YAAP_VERSION.zip"
    checkExit

    echo "${CLR_BLD_BLU}Generating fastboot package${CLR_RST}"
    img_from_target_files \
        "$TARGET_FILES_INTERMEDIATES/yaap_$DEVICE-target_files.zip" \
        "$DIR_RELEASE/YAAP-$YAAP_VERSION-image.zip"
    checkExit

else
    m otapackage "$CMD"; checkExit
    cp -f "$OUT/yaap_$DEVICE-ota.zip" "$OUT/YAAP-$YAAP_VERSION.zip"
    echo "${CLR_BLD_GRN}Package complete: $OUT/YAAP-$YAAP_VERSION.zip${CLR_RST}"
fi

echo

TIME_END=$(date +%s.%N)
ELAPSED=$(echo "$TIME_END - $TIME_START" | bc)
MINUTES=$(echo "$ELAPSED / 60" | bc)
echo "${CLR_BLD_GRN}Total time elapsed:${CLR_RST} ${CLR_GRN}${MINUTES} minutes (${ELAPSED} seconds)${CLR_RST}"
echo

exit 0
