#!/usr/bin/env bash
# YAAP build helper script

set -o pipefail

# red = errors, cyan = warnings, green = confirmations, blue = informational
# plain for generic text, bold for titles, reset flag at each end of line
# plain blue should not be used for readability reasons - use plain cyan instead
if [ -t 1 ]; then
    CLR_RST=$(tput sgr0)                         ## reset flag
    CLR_RED=$CLR_RST$(tput setaf 1)              #  red, plain
    CLR_GRN=$CLR_RST$(tput setaf 2)              #  green, plain
    CLR_CYA=$CLR_RST$(tput setaf 6)              #  cyan, plain
    CLR_BLD=$(tput bold)                         ## bold flag
    CLR_BLD_RED=$CLR_RST$CLR_BLD$(tput setaf 1) #  red, bold
    CLR_BLD_GRN=$CLR_RST$CLR_BLD$(tput setaf 2) #  green, bold
    CLR_BLD_BLU=$CLR_RST$CLR_BLD$(tput setaf 4) #  blue, bold
    CLR_BLD_CYA=$CLR_RST$CLR_BLD$(tput setaf 6) #  cyan, bold
else
    CLR_RST="" CLR_RED="" CLR_GRN="" CLR_CYA=""
    CLR_BLD="" CLR_BLD_RED="" CLR_BLD_GRN="" CLR_BLD_BLU="" CLR_BLD_CYA=""
fi

# Set defaults
BUILD_TYPE="userdebug"
MODULES=()
CMD=()

function checkExit() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "${CLR_BLD_RED}Build failed!${CLR_RST}"
        echo ""
        exit "$exit_code"
    fi
}

# Output usage help
function showHelpAndExit() {
    echo "${CLR_BLD_BLU}Usage: $0 <device> [options]${CLR_RST}"
    echo ""
    echo "${CLR_BLD_BLU}Options:${CLR_RST}"
    echo "${CLR_BLD_BLU}  -h, --help            Display this help message${CLR_RST}"
    echo "${CLR_BLD_BLU}  -c, --clean           Wipe the tree before building${CLR_RST}"
    echo "${CLR_BLD_BLU}  -i, --installclean    Dirty build - Use 'installclean'${CLR_RST}"
    echo "${CLR_BLD_BLU}  -r, --repo-sync       Sync before building${CLR_RST}"
    echo "${CLR_BLD_BLU}  -t, --build-type      Specify build type (default: userdebug)${CLR_RST}"
    echo "${CLR_BLD_BLU}  -j, --jobs            Specify jobs/threads to use${CLR_RST}"
    echo "${CLR_BLD_BLU}  -m, --module          Build a specific module${CLR_RST}"
    echo "${CLR_BLD_BLU}  -s, --sign-keys       Specify path to sign key mappings${CLR_RST}"
    echo "${CLR_BLD_BLU}  -p, --pwfile          Specify path to sign key password file${CLR_RST}"
    echo "${CLR_BLD_BLU}  -b, --backup-unsigned Store a copy of unsigned package along with signed${CLR_RST}"
    echo "${CLR_BLD_BLU}  -d, --delta           Generate a delta OTA from the specified target_files zip${CLR_RST}"
    echo "${CLR_BLD_BLU}  -z, --imgzip          Generate fastboot flashable image zip from signed target_files${CLR_RST}"
    echo "${CLR_BLD_BLU}  -g, --gapps           Build with GApps (TARGET_BUILD_GAPPS=true)${CLR_RST}"
    exit 1
}

# Setup getopt
long_opts="help,clean,installclean,repo-sync,build-type:,jobs:,module:,sign-keys:,pwfile:,backup-unsigned,delta:,imgzip,gapps,gms"
getopt_cmd=$(getopt -o hcirt:j:m:s:p:bd:zg --long "$long_opts" \
    -n "$(basename "$0")" -- "$@") || {
    echo "${CLR_BLD_RED}Error: Getopt failed. Extra args${CLR_RST}"
    showHelpAndExit
}

eval set -- "$getopt_cmd"

while true; do
    case "$1" in
        -h|--help)            showHelpAndExit ;;
        -c|--clean)           FLAG_CLEAN_BUILD=y ;;
        -i|--installclean)    FLAG_INSTALLCLEAN_BUILD=y ;;
        -r|--repo-sync)       FLAG_SYNC=y ;;
        -t|--build-type)      BUILD_TYPE="$2"; shift ;;
        -j|--jobs)            JOBS="$2"; shift ;;
        -m|--module)          MODULES+=("$2"); shift ;;
        -s|--sign-keys)       KEY_MAPPINGS="$2"; shift ;;
        -p|--pwfile)          PWFILE="$2"; shift ;;
        -b|--backup-unsigned) FLAG_BACKUP_UNSIGNED=y ;;
        -d|--delta)           DELTA_TARGET_FILES="$2"; shift ;;
        -z|--imgzip)          FLAG_IMG_ZIP=y ;;
        -g|--gapps|--gms)     FLAG_GAPPS=y ;;
        --)                   shift; break ;;
    esac
    shift
done

# Mandatory argument
if [ $# -eq 0 ]; then
    echo "${CLR_BLD_RED}Error: No device specified${CLR_RST}"
    showHelpAndExit
fi
export DEVICE="$1"; shift

# Make sure we are running on 64-bit before carrying on with anything
ARCH=$(uname -m | sed 's/x86_//;s/i[3-6]86/32/')
if [ "$ARCH" != "64" ]; then
    echo "${CLR_BLD_RED}error: unsupported arch (expected: 64, found: $ARCH)${CLR_RST}"
    exit 1
fi

# Set up paths
cd "$(dirname "$0")" || { echo "${CLR_BLD_RED}error: cannot cd to script directory${CLR_RST}"; exit 1; }
DIR_ROOT=$(pwd)

# Make sure everything looks sane so far
if [ ! -d "$DIR_ROOT/vendor/yaap" ]; then
    echo "${CLR_BLD_RED}error: insane root directory ($DIR_ROOT)${CLR_RST}"
    exit 1
fi

# Pick the default thread count (allow overrides from the environment)
if [ -z "$JOBS" ]; then
    if [ "$(uname -s)" = 'Darwin' ]; then
        JOBS=$(sysctl -n machdep.cpu.core_count)
    else
        JOBS=$(grep -c '^processor' /proc/cpuinfo)
    fi
fi
CMD+=(-j"$JOBS")

# Output directory for release zips
DIR_RELEASE="$DIR_ROOT/releases/$DEVICE"
mkdir -p "$DIR_RELEASE"
echo "${CLR_BLD_CYA}Release output: $DIR_RELEASE${CLR_RST}"

# Initializationizing!
echo "${CLR_BLD_BLU}Setting up the environment${CLR_RST}"
echo ""
. build/envsetup.sh
echo ""

# Prep for a clean build, if requested so
if [ "$FLAG_CLEAN_BUILD" = 'y' ]; then
    echo "${CLR_BLD_BLU}Cleaning output files left from old builds${CLR_RST}"
    echo ""
    m clobber "${CMD[@]}"
    checkExit
    [ -d "$DIR_ROOT/kernel_platform/out/" ] && rm -rf "$DIR_ROOT/kernel_platform/out/"
fi

# Sync up, if asked to
if [ "$FLAG_SYNC" = 'y' ]; then
    echo "${CLR_BLD_BLU}Downloading the latest source files${CLR_RST}"
    echo ""
    repo sync -j"$JOBS" -c --current-branch --no-tags --no-clone-bundle --force-sync
    checkExit
fi

# GApps or not
if [ "$FLAG_GAPPS" = 'y' ]; then
    export TARGET_BUILD_GAPPS=true
    echo "${CLR_BLD_CYA}GApps: enabled${CLR_RST}"
else
    export TARGET_BUILD_GAPPS=false
    echo "${CLR_BLD_CYA}GApps: disabled${CLR_RST}"
fi

# If external sign keys specified, disable inline signing
if [ -n "${KEY_MAPPINGS}" ]; then
    export YAAP_INLINE_SIGNING=false
    echo "${CLR_BLD_CYA}Inline signing: disabled (external keys provided)${CLR_RST}"
elif [ "${YAAP_INLINE_SIGNING}" = 'false' ]; then
    echo "${CLR_BLD_CYA}Inline signing: disabled${CLR_RST}"
else
    echo "${CLR_BLD_CYA}Inline signing: enabled${CLR_RST}"
fi

echo ""

# Pre-build summary
echo "${CLR_BLD_BLU}=== Build Configuration ===${CLR_RST}"
echo "${CLR_CYA}  Device    : $DEVICE${CLR_RST}"
echo "${CLR_CYA}  Type      : $BUILD_TYPE${CLR_RST}"
echo "${CLR_CYA}  Jobs      : $JOBS${CLR_RST}"
echo "${CLR_CYA}  GApps     : ${FLAG_GAPPS:-n}${CLR_RST}"
echo "${CLR_CYA}  Clean     : ${FLAG_CLEAN_BUILD:-n}${CLR_RST}"
echo "${CLR_CYA}  Sync      : ${FLAG_SYNC:-n}${CLR_RST}"
[ -n "${KEY_MAPPINGS}" ] && echo "${CLR_CYA}  Sign keys : $KEY_MAPPINGS${CLR_RST}"
[ -n "${MODULES[*]}" ]   && echo "${CLR_CYA}  Modules   : ${MODULES[*]}${CLR_RST}"
echo ""

# Check the starting time (of the real build process)
TIME_START=$(date +%s)

# Friendly logging to tell the user everything is working fine is always nice
echo "${CLR_BLD_GRN}Building YAAP for $DEVICE${CLR_RST}"
echo "${CLR_GRN}Start time: $(date)${CLR_RST}"
echo ""

# Lunch-time!
echo "${CLR_BLD_BLU}Lunching $DEVICE${CLR_RST} ${CLR_CYA}(Including dependencies sync)${CLR_RST}"
echo ""
lunch "yaap_$DEVICE-$BUILD_TYPE"
checkExit

YAAP_VERSION="$(get_build_var YAAP_VERSION)"
TARGET_KERNEL_OUT="$DIR_ROOT/$(get_build_var KERNEL_PREBUILT_DIR)"
TARGET_KERNEL_VERSION="$(get_build_var TARGET_KERNEL_VERSION)"
echo ""

# Perform installclean, if requested so
if [ "$FLAG_INSTALLCLEAN_BUILD" = 'y' ]; then
    echo "${CLR_BLD_BLU}Cleaning compiled image files left from old builds${CLR_RST}"
    echo ""
    m installclean "${CMD[@]}"
    checkExit
fi

# Build away!
echo "${CLR_BLD_BLU}Starting compilation${CLR_RST}"
echo ""

# Build kernel platform if it exists and the kernel version is not a legacy one
LEGACY_KERNELS=("4.4" "4.9" "4.14" "4.19" "5.4")
KERNEL_IS_LEGACY=false
for kv in "${LEGACY_KERNELS[@]}"; do
    [ "${TARGET_KERNEL_VERSION}" = "$kv" ] && KERNEL_IS_LEGACY=true && break
done

if [ -d "$DIR_ROOT/kernel_platform/" ] && [ "$KERNEL_IS_LEGACY" = false ] && [ -n "${TARGET_KERNEL_VERSION}" ]; then
    EXTRA_KERNEL_ENV=()
    if [ "${BUILD_TYPE}" = "user" ]; then
        EXTRA_KERNEL_ENV+=(LTO=full)
    else
        EXTRA_KERNEL_ENV+=(LZ4_RAMDISK_COMPRESS_ARGS=--fast LTO=thin)
    fi
    if [ "${FLAG_CLEAN_BUILD}" = 'y' ] || [ "${FLAG_INSTALLCLEAN_BUILD}" = 'y' ]; then
        EXTRA_KERNEL_ENV+=(RECOMPILE_KERNEL=1)
        [ -d "${TARGET_KERNEL_OUT}" ] && rm -rf "${TARGET_KERNEL_OUT}"
    fi
    env "${EXTRA_KERNEL_ENV[@]}" \
        ANDROID_KERNEL_OUT="${TARGET_KERNEL_OUT}" \
        KERNEL_VARIANT=gki \
        ./kernel_platform/build/android/prepare_vendor.sh
    checkExit
fi

# Intermediates path shorthand
TARGET_FILES_INTERMEDIATES="$OUT/obj/PACKAGING/target_files_intermediates"

# Build a specific module(s)
if [ "${#MODULES[@]}" -gt 0 ]; then
    m "${MODULES[@]}" "${CMD[@]}"
    checkExit

# Build signed ROM package if key mappings specified
elif [ -n "${KEY_MAPPINGS}" ]; then
    [ -n "${PWFILE}" ] && export ANDROID_PW_FILE="$PWFILE"

    echo "${CLR_BLD_BLU}Building target-files-package${CLR_RST}"
    m otatools target-files-package "${CMD[@]}"
    checkExit

    echo "${CLR_BLD_BLU}Signing target files APKs${CLR_RST}"
    sign_target_files_apks -o -d "$KEY_MAPPINGS" \
        "$TARGET_FILES_INTERMEDIATES/yaap_${DEVICE}-target_files.zip" \
        "$DIR_RELEASE/YAAP-${YAAP_VERSION}-signed-target_files.zip"
    checkExit

    if [ "$FLAG_BACKUP_UNSIGNED" = 'y' ]; then
        cp -f "$TARGET_FILES_INTERMEDIATES/yaap_${DEVICE}-target_files.zip" \
              "$DIR_RELEASE/YAAP-${YAAP_VERSION}-unsigned-target_files.zip"
    fi

    echo "${CLR_BLD_BLU}Generating signed install package${CLR_RST}"
    ota_from_target_files -k "$KEY_MAPPINGS/releasekey" \
        --block \
        "$DIR_RELEASE/YAAP-${YAAP_VERSION}-signed-target_files.zip" \
        "$DIR_RELEASE/YAAP-${YAAP_VERSION}.zip"
    checkExit

    if [ -n "$DELTA_TARGET_FILES" ]; then
        if [ ! -f "$DELTA_TARGET_FILES" ]; then
            echo "${CLR_BLD_RED}Delta error: base target files don't exist ($DELTA_TARGET_FILES)${CLR_RST}"
            exit 1
        fi
        echo "${CLR_BLD_BLU}Generating delta OTA${CLR_RST}"
        ota_from_target_files -k "$KEY_MAPPINGS/releasekey" \
            --block --incremental_from "$DELTA_TARGET_FILES" \
            "$DIR_RELEASE/YAAP-${YAAP_VERSION}-signed-target_files.zip" \
            "$DIR_RELEASE/YAAP-${YAAP_VERSION}-delta.zip"
        checkExit
    fi

    if [ "$FLAG_IMG_ZIP" = 'y' ]; then
        echo "${CLR_BLD_BLU}Generating signed fastboot package${CLR_RST}"
        img_from_target_files \
            "$DIR_RELEASE/YAAP-${YAAP_VERSION}-signed-target_files.zip" \
            "$DIR_RELEASE/YAAP-${YAAP_VERSION}-image.zip"
        checkExit
    fi

# Build ROM package with fastboot zip
elif [ "$FLAG_IMG_ZIP" = 'y' ]; then
    m otatools target-files-package "${CMD[@]}"
    checkExit

    echo "${CLR_BLD_BLU}Generating install package${CLR_RST}"
    ota_from_target_files \
        "$TARGET_FILES_INTERMEDIATES/yaap_${DEVICE}-target_files.zip" \
        "$DIR_RELEASE/YAAP-${YAAP_VERSION}.zip"
    checkExit

    echo "${CLR_BLD_BLU}Generating fastboot package${CLR_RST}"
    img_from_target_files \
        "$TARGET_FILES_INTERMEDIATES/yaap_${DEVICE}-target_files.zip" \
        "$DIR_RELEASE/YAAP-${YAAP_VERSION}-image.zip"
    checkExit

else
    m otapackage "${CMD[@]}"
    checkExit

    cp -f "$OUT/yaap_${DEVICE}-ota.zip" "$DIR_RELEASE/YAAP-${YAAP_VERSION}.zip"
    checkExit
    echo "${CLR_BLD_GRN}Package complete: $DIR_RELEASE/YAAP-${YAAP_VERSION}.zip${CLR_RST}"
fi

echo ""

# Check the finishing time
TIME_END=$(date +%s)
ELAPSED=$(( TIME_END - TIME_START ))

echo "${CLR_BLD_GRN}Total time elapsed:${CLR_RST} ${CLR_GRN}$(( ELAPSED / 60 )) minutes (${ELAPSED} seconds)${CLR_RST}"
echo ""

exit 0
