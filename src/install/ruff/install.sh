#!/bin/bash
#
# Installs Ruff for the install_ruff command (the fmt and lint commands run
# it): the Linux amd64 or arm64 build that matches this machine, verified
# against the checksum table in this file before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (ruff only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# python-quality-orb installs several tools, so it has one such script per
# tool, in src/install/<tool>/.
#
# Add the checksums for a new release with:
#   src/install/ruff/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing ruff needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="python-quality-orb-ruff"
TOOL_NAME="ruff"
TOOL_BINARY="ruff"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME, shared by every install command of
# the orb: no image puts it on the PATH, so the install puts it first, ahead
# of a ruff the image or the project's environment ships.
TOOL_DEFAULT_INSTALL_DIR=".python-quality-orb/bin"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    printf 'ruff-%s.tar.gz\n' "$(pq_triple "$2")"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line.
tool_asset_urls() {
    pq_asset_urls ruff "$1" "$3"
}

# tool_archive_member VERSION ARCH: the binary's path inside the asset. The
# checksum table holds the SHA-512 of that file.
tool_archive_member() {
    printf 'ruff-%s/ruff\n' "$(pq_triple "$2")"
}

# tool_version BINARY: prints the installed version (ruff X.Y.Z) without
# using the network or reading a configuration file.
tool_version() {
    "$1" --version
}

# >>> python-quality-orb install helpers >>>
# Identical in every tool definition of python-quality-orb (uv, ruff, ty), so
# change them in all of them together. They run inside the shared install
# logic, through tool_install, and only after orb_init has read the
# parameters.

# pq_triple ARCH: the target triple of an Astral release for ARCH. The musl
# builds are static, so they run on any Linux, glibc or musl, of any age.
pq_triple() {
    case "$1" in
        amd64) printf 'x86_64-unknown-linux-musl\n' ;;
        arm64) printf 'aarch64-unknown-linux-musl\n' ;;
        *) printf '%s-unknown-linux-musl\n' "$1" ;;
    esac
}

# pq_asset_urls REPO VERSION ASSET: where to download an Astral release
# asset, one URL per line, tried in order: GitHub Releases, then Astral's own
# copy of them, or the download_base_url mirror alone.
pq_asset_urls() {
    if [[ -n "${PQ_DOWNLOAD_BASE_URL:-}" ]]; then
        printf '%s/astral-sh/%s/releases/download/%s/%s\n' "${PQ_DOWNLOAD_BASE_URL}" "$1" "$2" "$3"
        return 0
    fi
    printf 'https://github.com/astral-sh/%s/releases/download/%s/%s\n' "$1" "$2" "$3"
    printf 'https://releases.astral.sh/github/%s/releases/download/%s/%s\n' "$1" "$2" "$3"
}

# pq_download_base_url DEFAULT: sets PQ_DOWNLOAD_BASE_URL from the
# download_base_url parameter, which replaces DEFAULT (https://github.com) in
# the download URL, so the same file comes from an internal mirror such as
# Artifactory, Nexus or S3. The checksum table, not the mirror, decides what
# is installed.
pq_download_base_url() {
    local authority
    PQ_DOWNLOAD_BASE_URL=$(orb_subst "${PARAM_DOWNLOAD_BASE_URL:-}")
    PQ_DOWNLOAD_BASE_URL=${PQ_DOWNLOAD_BASE_URL%/}
    if [[ -z "${PQ_DOWNLOAD_BASE_URL}" ]]; then
        return 0
    fi
    # Credentials in the URL would show in the log and on curl's command
    # line, so they are refused before the URL is printed anywhere.
    authority=${PQ_DOWNLOAD_BASE_URL#*://}
    if [[ "${authority%%/*}" == *@* ]]; then
        orb_die "download_base_url must not hold credentials (user:password@ before the host): they would show in the log and on curl's command line."
    fi
    # Nor can a query or fragment, which can hold a token too, and would end
    # up in the middle of every download URL.
    if [[ "${PQ_DOWNLOAD_BASE_URL}" == *[?#]* ]]; then
        orb_die "download_base_url must not have a query or fragment (? or #): it could hold a token, which would show in the log."
    fi
    if [[ ! "${PQ_DOWNLOAD_BASE_URL}" =~ ^https://[^[:space:]\"\'\<\>\\]+$ ]]; then
        orb_die "download_base_url must be an https:// URL, not '${PQ_DOWNLOAD_BASE_URL}'."
    fi
    orb_info "  download mirror:  ${PQ_DOWNLOAD_BASE_URL} (in place of $1)"
}

# pq_install_record: writes what was installed, and how, beside the binary
# (.<binary>.install.json), which the commands' run records include when it
# describes the binary they ran: the release, the asset and its checksum, the
# verify_checksums mode, whether the checksum table listed the release, and
# the binary's SHA-512.
pq_install_record() {
    local file="${ORB_BIN_DIR}/.${TOOL_BINARY}.install.json" sha512="" verified=false
    if command -v sha512sum > /dev/null 2>&1; then
        sha512=$(sha512sum "${ORB_BIN_DIR}/${TOOL_BINARY}" | awk '{ print $1 }')
    fi
    if [[ -n "${ORB_EXPECTED_SHA512:-}" && "${ORB_VERIFY_CHECKSUMS}" != false ]]; then
        verified=true
    fi
    if ! orb_temp_beside "${file}" || ! printf '{"tool":"%s","version":"%s","arch":"%s","asset":"%s","asset_sha512":"%s","verify_checksums":"%s","verified":%s,"binary_sha512":"%s"}\n' \
        "${TOOL_NAME}" "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}" "${ORB_EXPECTED_SHA512:-}" \
        "${ORB_VERIFY_CHECKSUMS}" "${verified}" "${sha512}" > "${ORB_TEMP}" || ! mv -f "${ORB_TEMP}" "${file}"; then
        orb_warn "Could not write ${file}; run records will not say how ${TOOL_NAME} was installed."
    fi
}
# <<< python-quality-orb install helpers <<<

# tool_install: the shared single-binary install, from the mirror when one is
# given.
tool_install() {
    pq_download_base_url https://github.com
    orb_install_binary
    pq_install_record
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            # Like saving it, removing it is best-effort: a read-only cache
            # directory only means the download isn't cached.
            rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers: the ruff binary in
# the static musl build.
#
# The table starts at 0.16.0, the first release whose format --check writes
# JSON and whose JSON names every diagnostic (name, severity), which the fmt
# and lint commands read. Ruff 0.16.0 and 0.17.0 changed the default rules;
# a project's own configuration decides them otherwise.
declare -A sha512sums=(
    ["0.17.2/amd64"]="d9f8a87da1a076f57c1ba297a07dd6f91680349a629c1a20a80cc0e32e1cf2af749a75ec231f8e44b2dd941ce78a949052e1f38f70ac40f6e6f075b895516420"
    ["0.17.2/arm64"]="9dcc1d0809b8fea4df6a475ad7bc70872beae11e9df9c8a60b0829c7f806c80cefc9a853f89b88994180a15e049b30347cff4713d10cf6c890a90d7101a3a527"
    ["0.17.1/amd64"]="56d9bf34b82a017e8dc72aaab0d6939626d0a937755d88c74c6b9eab46a64ea09e9a4e0f29898576d4fe1a8872534ce64e93a77b7333faac8a3c9bde8c23569c"
    ["0.17.1/arm64"]="c018733dbc6cc08f6c01762c7fad98c485d37373d2354fbcf4592ac26ef3b52869c17705f65880ea5842e24f984a81e62cb44caa73cd73388bdfb2e1413f3ee1"
    ["0.17.0/amd64"]="5dc36b63f413d877953b5f1e4ff568cc701f91900b92efacde15b3e042287a6b62e1550d9c7468efb9d82756d8104b4352c2d50756d157285cd8326f81eb0614"
    ["0.17.0/arm64"]="f2017e8d19cd8734ada864da42e827ec84bbb10a0bb26c69e37873a024d3eb1b02338f8f5f163f2987f4488510084ec5dad3747833e32506947b81c19e923b38"
    ["0.16.10/amd64"]="d5bf953e423ad7218cdac0fc55c19995f75f6694937a2f152f38c3ee0d7d9450dab8b8900d2adae42fb950d5fc5055f30ea490f16d46b236e108773df30a400f"
    ["0.16.10/arm64"]="8c103d5b547e1b4e0dce45a39212730e8f2003f13ba875e4cbf6aaade64d054c8097aa3357d8bc5769056b9e0766e0017ed736903af21aaef8ead5fa9198cca0"
    ["0.16.9/amd64"]="b9d5a0bd4a0a0077dcfcd70bdc38c95ffb2faf538c43b2390950a476f9862a706f16ce2af7ec5e2ec48ac557e1dfc6196fb66c6df5c81b8295a20fe8e1d6503e"
    ["0.16.9/arm64"]="d3358004ad29aaa1eb5d02352577b89eabcbb2b9dad69018a3c74b5ed67c556628c7525bd126117d27f0400536aa855622809d879d915851ea29fd3cdc2ae63e"
    ["0.16.8/amd64"]="64cf52b2679920c2b3332c6c71c5162f86a48862166d3adf7abb4d4969a7c8475194ddd9668386c9c206efea1ad12f295cabf84b6e489f41c7f483777a8f2d92"
    ["0.16.8/arm64"]="b9097fec39f35e54b751783f5c135fb417e0b2a4fe82430700d175918b057d75f1370c69a5b07fa0b87d40fd54b174e0e163cb907a87ba9532b3b4ebfb26788b"
    ["0.16.7/amd64"]="cb7e36c03e773b8bd4ef7841a7c73ca9d536b2f8c34be1218e71a4938d2ffba414a47c5cc836d1f49306ea88aa3b93d72b09cd48b2f93042dfb4f5b6f5faede9"
    ["0.16.7/arm64"]="5407d0098dd9f040d628941f661c49e369ada4df9f95c316ec78acf4713ae3e367f5f135b4c94bbbe59048f2e7a96b8bf26d0ea166ce2a46b8df3a41fdb48c97"
    ["0.16.6/amd64"]="d898fbbea47ba3101da114e1661f900d3d6a35594dfd9a911cb818aa064a15fbb50f436e054d5b8a3b3d270b80a55823697933b56809992da21b45656ac37a1a"
    ["0.16.6/arm64"]="3acec5eee65032ca4386493650ef819ce28ba93e339d3666975fd389a3b094f399b03b738856f75c61bafb6764a10f262b470c06cb46a760ad3ddd833f9aa8ff"
    ["0.16.5/amd64"]="d1fa016f33d5287f93c9e5b9f4421fadf1a1127a6b07b0da101a4b0f88155223eaa584457d8c29881d333fe34fb5f45f8040621cf14eba267c99e5eb696f867c"
    ["0.16.5/arm64"]="c7715cbbfd24e68f5c47b6a956b98de98eeface325659cfc96292ac0bea0eda7d9ab8149e4556315ec62167bac3e8ba6add828448f3898d724f1c0656ef66a91"
    ["0.16.4/amd64"]="ab894e62963f4e5708dd11e3de111bc44280693d4167b86153ff77e5e258309df0b35fd518ea894e5c258bc2a48df297cb1904730eda4190852e659624441a79"
    ["0.16.4/arm64"]="8f2c66c93662bcefa9a46644ab540ebde6bdbe97d7814233130fcf0bc246dc7c53e968d42060b6e7fa31595bcb9075bdf182ec07ab301c0e68ed38d2d336df4d"
    ["0.16.3/amd64"]="7d54cfc7e8f8e00d1e5df886093ab609d6ade04b3736df8d4c4871c48dea8da41838adc8db16852f8341c993cb3a6482af9657b1c4608ff5631aa76e792201c8"
    ["0.16.3/arm64"]="58be10b71422f3f164597ecf2fec457a078c96eaf5dbf572f57effb3746f1ba6e3f1602a9057db0659faeecaaddf3054424b302a12b16f694ca6578d1d4c3111"
    ["0.16.2/amd64"]="d6dc18003dc2962913a97ced6260b6b760974d9ce2ae9c9b08bde1cc86bd3d17c58cde341e2e69ed10ad53c964b97c645029a83fad18854113bfbeff5ae06115"
    ["0.16.2/arm64"]="e2e85cad1a5e8a98b1ed1e5916720f51196cd440f840c1959e408aa9d2a31bb3eace98e373c5b908e3aa3e8463349ce92c5c1ac418d11d5f88db3278d39c29c0"
    ["0.16.1/amd64"]="eae5088c82c96fc10184ee5585de8cbd275cf379de74869dca1d94f079e4cda9df6c68a51462942bd9e42e1fefbd0b5d23e0b83e75f5dffbac0d88e8d7c3fc7f"
    ["0.16.1/arm64"]="9b1c4cd6df5681d180d075df9f003c50fe8565e497226d1ec0d2bcde7fdbb65f09b770b62c686669f7b9cf79d0f9ccd5b28f8f5bbf5aefec6287913a8baa8cb6"
    ["0.16.0/amd64"]="f34fbd68de33737cc967941d0ad8d4a31ded6975b8f2aa051696d2177036b9323a51e4039b4970fb0b1d85b402af3822cb6315977098a7e7c2756642f912b222"
    ["0.16.0/arm64"]="cf428940a8a5ca8db965f923af088f21a288db2fb429e42fd3e0897f0bdb7eb3510c741046377a6f39e9f4891913d50f7625b89f6dd5ae4dd6c6e61d6a375516"
)
# <<< checksum table <<<

orb_install_main
