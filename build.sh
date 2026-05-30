#!/usr/bin/env bash
# YAAP build helper script

CLR_RST=$(tput sgr0)
CLR_GRN=$CLR_RST$(tput setaf 2)
CLR_CYA=$CLR_RST$(tput setaf 6)
CLR_BLD=$(tput bold)
CLR_BLD_RED=$CLR_BLD$(tput setaf 1)
CLR_BLD_GRN=$CLR_BLD$(tput setaf 2)
CLR_BLD_BLU=$CLR_BLD$(tput setaf 4)
CLR_BLD_CYA=$CLR_BLD$(tput setaf 6)

BUILD_TYPE="userdebug"
TIME_START=$(date +%s.%N)

die() {
    echo "${CLR_BLD_RED}$*${CLR_RST}" >&2
    exit 1
}

trap 'TIME_END=$(date +%s.%N); ELAPSED=$(echo "$TIME_END - $TIME_START" | bc); MINUTES=$(echo "$ELAPSED / 60" | bc); echo; echo "${CLR_BLD_GRN}Total time elapsed: ${MINUTES} minutes (${ELAPSED} seconds)${CLR_RST}"; echo' EXIT

generate_json() {
    local zip=$1
    [[ -f "$DIR_ROOT/tools/generate_json_build_info.sh" ]] || return 0
    if [[ ! -f "$zip" ]]; then
        echo "${CLR_BLD_RED}Warning: OTA zip not found: $zip${CLR_RST}" >&2
        return 1
    fi
    echo "${CLR_BLD_BLU}Generating JSON build info${CLR_RST}"
    bash "$DIR_ROOT/tools/generate_json_build_info.sh" "$zip" || die "JSON generation failed"
}

run_build() {
    local gapps=$1 gapps_tag zip_base

    if [[ "$gapps" == "y" ]]; then
        export TARGET_BUILD_GAPPS=true
        gapps_tag="GApps"
    else
        export TARGET_BUILD_GAPPS=false
        gapps_tag="Vanilla"
    fi

    zip_base="YAAP-$YAAP_VERSION-$BUILD_TYPE-$gapps_tag"

    echo "${CLR_BLD_GRN}── Building $gapps_tag ($BUILD_TYPE) ──${CLR_RST}"
    echo

    if [[ "$FLAG_INSTALLCLEAN_BUILD" == y ]]; then
        echo "${CLR_BLD_BLU}Running installclean${CLR_RST}"
        m installclean "$CMD" || die "installclean failed"
        echo
    fi

    if (( ${#MODULES[@]} > 0 )); then
        m "${MODULES[@]}" "$CMD" || die "Module build failed"

    elif [[ -n "$KEY_MAPPINGS" ]]; then
        [[ -n "$PWFILE" ]] && export ANDROID_PW_FILE="$PWFILE"

        m otatools target-files-package "$CMD" || die "Build failed"

        echo "${CLR_BLD_BLU}Signing target files${CLR_RST}"
        sign_target_files_apks -o -d "$KEY_MAPPINGS" \
            "$TARGET_FILES_INTERMEDIATES/yaap_$DEVICE-target_files.zip" \
            "$DIR_RELEASE/$zip_base-signed-target_files.zip" \
            || die "Signing failed"

        echo "${CLR_BLD_BLU}Generating signed OTA package${CLR_RST}"
        ota_from_target_files -k "$KEY_MAPPINGS/releasekey" \
            --block ${INCREMENTAL} \
            "$DIR_RELEASE/$zip_base-signed-target_files.zip" \
            "$DIR_RELEASE/$zip_base.zip" \
            || die "OTA generation failed"
        generate_json "$DIR_RELEASE/$zip_base.zip"

        if [[ -n "$DELTA_TARGET_FILES" ]]; then
            [[ -f "$DELTA_TARGET_FILES" ]] || die "Delta base target files not found: $DELTA_TARGET_FILES"
            ota_from_target_files -k "$KEY_MAPPINGS/releasekey" \
                --block --incremental_from "$DELTA_TARGET_FILES" \
                "$DIR_RELEASE/$zip_base-signed-target_files.zip" \
                "$DIR_RELEASE/$zip_base-delta.zip" \
                || die "Delta OTA generation failed"
        fi

        if [[ "$FLAG_IMG_ZIP" == y ]]; then
            echo "${CLR_BLD_BLU}Generating fastboot package${CLR_RST}"
            img_from_target_files \
                "$DIR_RELEASE/$zip_base-signed-target_files.zip" \
                "$DIR_RELEASE/$zip_base-image.zip" \
                || die "Image zip generation failed"
        fi

    elif [[ "$FLAG_IMG_ZIP" == y ]]; then
        m otatools target-files-package "$CMD" || die "Build failed"

        echo "${CLR_BLD_BLU}Generating OTA package${CLR_RST}"
        ota_from_target_files \
            "$TARGET_FILES_INTERMEDIATES/yaap_$DEVICE-target_files.zip" \
            "$DIR_RELEASE/$zip_base.zip" \
            || die "OTA generation failed"
        generate_json "$DIR_RELEASE/$zip_base.zip"

        echo "${CLR_BLD_BLU}Generating fastboot package${CLR_RST}"
        img_from_target_files \
            "$TARGET_FILES_INTERMEDIATES/yaap_$DEVICE-target_files.zip" \
            "$DIR_RELEASE/$zip_base-image.zip" \
            || die "Image zip generation failed"

    else
        m otapackage "$CMD" || die "Build failed"
        cp -f "$OUT/yaap_$DEVICE-ota.zip" "$OUT/$zip_base.zip" || die "Failed to copy OTA package"
        echo "${CLR_BLD_GRN}Package complete: $OUT/$zip_base.zip${CLR_RST}"
        generate_json "$OUT/$zip_base.zip"
    fi

    echo "${CLR_BLD_GRN}── $gapps_tag done ──${CLR_RST}"
    echo
}

showHelpAndExit() {
    echo "${CLR_BLD_BLU}Usage: $0 <device> [options]${CLR_RST}"
    echo
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
        "-g, --gapps,--gms     Build GApps variant"
        "-G, --both            Build both Vanilla and GApps variants"
    )
    printf "  ${CLR_BLD_BLU}%s${CLR_RST}\n" "${opts[@]}"
    exit 1
}

long_opts="help,clean,installclean,repo-sync,build-type:,jobs:,module:,sign-keys:,pwfile:,backup-unsigned,delta:,imgzip,gapps,gms,both"
getopt_cmd=$(getopt -o hcirt:j:m:s:p:bd:zgG --long "$long_opts" \
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
        -G|--both)            FLAG_BOTH=y ;;
        --) shift; break ;;
    esac
    shift
done

(( $# > 0 )) || { echo "${CLR_BLD_RED}Error: No device specified${CLR_RST}" >&2; showHelpAndExit; }
export DEVICE="$1"; shift

[[ "$(uname -m)" == "x86_64" ]] || die "Unsupported arch: $(uname -m)"

cd "$(dirname "$0")"
DIR_ROOT=$(pwd)
[[ -d "$DIR_ROOT/vendor/yaap" ]] || die "error: insane root directory ($DIR_ROOT)"

DIR_RELEASE="$DIR_ROOT/releases/$DEVICE"
mkdir -p "$DIR_RELEASE"
echo "${CLR_BLD_CYA}Release output: $DIR_RELEASE${CLR_RST}"

echo "${CLR_BLD_BLU}Setting up the environment${CLR_RST}"
echo
. build/envsetup.sh
echo

if [[ -z "$JOBS" ]]; then
    [[ "$(uname -s)" == Darwin ]] \
        && JOBS=$(sysctl -n machdep.cpu.core_count) \
        || JOBS=$(nproc --all)
fi
CMD="-j$JOBS"

if [[ "$FLAG_CLEAN_BUILD" == y ]]; then
    echo "${CLR_BLD_BLU}Cleaning output files${CLR_RST}"
    echo
    m clobber "$CMD" || die "clobber failed"
fi

if [[ "$FLAG_SYNC" == y ]]; then
    echo "${CLR_BLD_BLU}Syncing sources${CLR_RST}"
    echo
    repo sync -j"$JOBS" -c --current-branch --no-tags --force-sync || die "repo sync failed"
fi

if [[ -n "$KEY_MAPPINGS" ]]; then
    export YAAP_INLINE_SIGNING=false
    echo "${CLR_BLD_CYA}Inline signing: disabled (external keys provided)${CLR_RST}"
elif [[ "$YAAP_INLINE_SIGNING" == false ]]; then
    echo "${CLR_BLD_CYA}Inline signing: disabled${CLR_RST}"
else
    echo "${CLR_BLD_CYA}Inline signing: enabled${CLR_RST}"
fi

echo "${CLR_BLD_GRN}Building YAAP for $DEVICE${CLR_RST}"
echo "${CLR_GRN}Start time: $(date)${CLR_RST}"
echo

echo "${CLR_BLD_BLU}Lunching $DEVICE${CLR_RST}"
echo
lunch "yaap_$DEVICE-$BUILD_TYPE"
[[ "$(get_build_var TARGET_PRODUCT 2>/dev/null)" == "yaap_$DEVICE" ]] || {
    [[ -f out/error.log ]] && cat out/error.log
    die "Lunch failed for $DEVICE"
}
echo

# Resolve version from build system post-lunch
YAAP_VERSION=$(get_build_var YAAP_VERSION 2>/dev/null)
[[ -n "$YAAP_VERSION" ]] || die "YAAP_VERSION is empty — check vendor/yaap/config/*.mk"
echo "${CLR_BLD_CYA}Version: $YAAP_VERSION${CLR_RST}"
echo

TARGET_FILES_INTERMEDIATES="$OUT/obj/PACKAGING/target_files_intermediates"

echo "${CLR_BLD_BLU}Starting compilation${CLR_RST}"
echo

if [[ "$FLAG_BOTH" == y ]]; then
    run_build n
    run_build y
elif [[ "$FLAG_GAPPS" == y ]]; then
    run_build y
else
    run_build n
fi
