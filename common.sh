#!/usr/bin/env bash
# Copyright (C) 2018 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# shellcheck source=globals.sh
# shellcheck source=logging.sh
# shellcheck source=variables.sh

LIB_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")") # Do not override SCRIPT_DIR

. "${LIB_DIR}/globals.sh"
. "${LIB_DIR}/logging.sh"
. "${LIB_DIR}/variables.sh"

assert_dep () {
    command -v "$1" > /dev/null 2>&1 || { error "command '$1' not found"; exit 1; }
}

assert_dir () {
    [[ -d $1 ]] > /dev/null 2>&1 || { error "directory '$1' not found"; exit 1; }
}

assert_file() {
    [[ -f $1 ]] > /dev/null 2>&1 || { error "file '$1' not found"; exit 1; }
}

function_exists() {
    [[ "$(type -t "${1}")" == 'function' ]]
}

silentkill () {
    if [ -n "$2" ]; then
        kill "$2" "$1" > /dev/null 2>&1 || true
    else
        kill -KILL "$1" > /dev/null 2>&1 || true
    fi
}

fetch_git_repo() {
    local repo="${1}"
    local dir_name="${2}"

    if (( $# != 2 )); then
        error "'fetch_git_repo' requires 2 arguments!"
        return 1
    fi

    if [[ ! -d "${dir_name}" ]]; then
        log_line "Cloning..." 1
        git clone --quiet "${repo}" "${dir_name}"
        log_line "OK!" 2
    else
        log_line "Updating..." 1
        git -C "${dir_name}" fetch --prune -P --quiet origin
        git -C "${dir_name}" reset --hard --quiet origin/master
        log_line "OK!" 2
    fi

    log_line "$(git -C "${dir_name}" remote get-url origin) ($(git -C "${dir_name}" rev-parse --short HEAD))" 1
}

fetch_config_repo() {
    log_line "Config Repository:"

    local REPO_HOST=${CONFIG_REPO_HOST:?"CONFIG_REPO_HOST cannot be Null/Unset"}
    local REPO_NAME=${NAMESPACE:?"NAMESPACE cannot be Null/Unset"}

    fetch_git_repo "${REPO_HOST}${REPO_NAME}" "config"

    pushd ./config > /dev/null
    log_line "Checking for the required file..." 1
    assert_file ./config.sh
    log_line "OK!" 2
    popd > /dev/null

    log_line "Done!" 1
}

get_upstream_version() {
    CLR_LATEST=${CLR_LATEST:-$(curl "${CLR_PUBLIC_DL_URL}/latest")} || true
    if [[ -z "${CLR_LATEST}" ]]; then
        error "Failed to fetch Clear Linux latest version."
        exit 2
    fi

    CLR_FORMAT=$(curl "${CLR_PUBLIC_DL_URL}/update/${CLR_LATEST}/format") || true
    if [[ -z "${CLR_FORMAT}" ]]; then
        error "Failed to fetch Clear Linux latest format."
        exit 2
    fi
}

get_distro_version() {
    DISTRO_LATEST=$(cat "${STAGING_DIR}/latest" 2>/dev/null) || true
    if [[ -z "${DISTRO_LATEST}" ]]; then
        info "Failed to fetch Distribution latest version" "First Mix?"
        DISTRO_FORMAT=${CLR_FORMAT:-1}
        DISTRO_UP_FORMAT=${CLR_FORMAT}
        return
    fi

    DISTRO_FORMAT=$(cat "${STAGING_DIR}/update/${DISTRO_LATEST}/format" 2>/dev/null) || true
    if [[ -z "${DISTRO_FORMAT}" ]]; then
        error "Failed to fetch Distribution latest format."
        exit 2
    fi

    if "${IS_DOWNSTREAM}"; then
        if ((${#DISTRO_LATEST} < 4)); then
            error "Distribution version number seems corrupted."
            exit 2
        fi

        DISTRO_UP_VERSION="${DISTRO_LATEST: : -3}"
        DISTRO_DOWN_VERSION="${DISTRO_LATEST: -3}"

        DISTRO_UP_FORMAT=$(curl "${CLR_PUBLIC_DL_URL}/update/${DISTRO_UP_VERSION}/format") || true
        if [[ -z "${DISTRO_UP_FORMAT}" ]]; then
            error "Failed to fetch Distribution latest base format."
            exit 2
        fi
    fi
}

get_latest_versions() {
    get_upstream_version
    get_distro_version
}

calc_mix_version() {
    if "${IS_DOWNSTREAM}"; then
        if [[ -z "${DISTRO_LATEST}" || "${CLR_LATEST}" -gt "${DISTRO_UP_VERSION}" ]]; then
            MIX_VERSION=$(( CLR_LATEST * 1000 + MIX_INCREMENT ))
            MIX_FORMAT=${CLR_FORMAT}
        elif [[ "${CLR_LATEST}" -eq "${DISTRO_UP_VERSION}" ]]; then
            MIX_VERSION=$(( DISTRO_LATEST + MIX_INCREMENT ))
            if [[ "${MIX_VERSION: -3}" -eq 000 ]]; then
                error "Invalid Mix Version" \
                    "No more Downstream versions available for this Upstream version!"
                exit 1
            fi
        else
            error "Invalid Mix version" \
                "Next Upstream Version is less than the Previous Upstream!"
            exit 1
        fi

        MIX_UP_VERSION="${MIX_VERSION: : -3}"
        MIX_DOWN_VERSION="${MIX_VERSION: -3}"
        MIX_FORMAT="${DISTRO_FORMAT:-1}"
    else
        # format bump if not a new mix
        if [[ -n "${DISTRO_LATEST}" ]] && "${FORMAT_BUMP}"; then
            MIX_VERSION=$(( DISTRO_LATEST + MIX_INCREMENT * 2 ))
            MIX_FORMAT=$(( DISTRO_FORMAT + 1 ))
        else # new mix or regular mix
            MIX_VERSION=$(( DISTRO_LATEST + MIX_INCREMENT ))
            MIX_FORMAT="${DISTRO_FORMAT:-1}"
        fi
    fi
}

# =================
# Command Overrides
# =================

curl() {
    command curl --silent --fail "$@"
}

koji_cmd() {
    # Downloads fail sometime, try harder!
    local result=""
    local ret=1
    for (( i=0; i < 10; i++ )); do
        result=$(koji "${@}" 2> /dev/null) \
            || continue

        ret=0
        break
    done

    [[ -n "${result}" ]] && echo "${result}"
    return ${ret}
}

mixer_cmd() {
    # shellcheck disable=SC2086
    mixer ${MIXER_OPTS} "${@}"
}

sudo_mixer_cmd() {
    # shellcheck disable=SC2086
    sudo -E mixer ${MIXER_OPTS} "${@}"
}
