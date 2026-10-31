#!/bin/bash
#
# Installs ty, Astral's type checker, for the install_ty command (the ty
# command runs it): the Linux amd64 or arm64 build that matches this machine,
# verified against the checksum table in this file before it is installed.
# ty is in beta: its diagnostics can change between any two releases, so pin
# the version a project checks with.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (ty only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# python-quality-orb installs several tools, so it has one such script per
# tool, in src/install/<tool>/.
#
# Add the checksums for a new release with:
#   src/install/ty/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing ty needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="python-quality-orb-ty"
TOOL_NAME="ty"
TOOL_BINARY="ty"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME, shared by every install command of
# the orb: no image puts it on the PATH, so the install puts it first, ahead
# of a ty the image or the project's environment ships.
TOOL_DEFAULT_INSTALL_DIR=".python-quality-orb/bin"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    printf 'ty-%s.tar.gz\n' "$(pq_triple "$2")"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line.
tool_asset_urls() {
    pq_asset_urls ty "$1" "$3"
}

# tool_archive_member VERSION ARCH: the binary's path inside the asset. The
# checksum table holds the SHA-512 of that file.
tool_archive_member() {
    printf 'ty-%s/ty\n' "$(pq_triple "$2")"
}

# tool_version BINARY: prints the installed version (ty X.Y.Z (commit date))
# without using the network or reading a configuration file.
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
# tool_archive_member says which file each checksum covers: the ty binary in
# the static musl build.
#
# The table starts at 0.0.84, which fixed GHSA-vxvm-j4xq-q7m4 (a crafted
# project could run code in ty through a use-after-free in Salsa).
declare -A sha512sums=(
    ["0.0.91/amd64"]="808dc78e4063c1a5f4d6f3ceee626fffcc025ca9151d123fad0ebb7a890b9d517cc81d3a5027217d30e3e18dc2f88a001c565fbdc83ef0902d0c0690e31fe3b0"
    ["0.0.91/arm64"]="7be56d836f2334d7b6958f536701a0977aac8d888c64130e244440dbd2d906ef2f6057d50d1d3e8433bfcf8c59fd1dc9e821d70d9318b1ac18508bcd05f850b2"
    ["0.0.90/amd64"]="07c076240fadf7e1efa222c5998f5d5fcc805cd6a2f5940cee0c14763c4487411539f1295f6ca31f6bd31bd2f278709caeca9ec515e3284d818fbb2ca24294db"
    ["0.0.90/arm64"]="90d20e9c8a43c1dfc6ce919a07f885e6b68db5196676573c76e74c36d7bb1682210e55fbd0de19709b5f21e6ccb123418504ba171f1a24b86f9fb7f1f58429a5"
    ["0.0.89/amd64"]="29f91b4d0484a0272602c88a6f3ba9d17382c4dff7af79600c58d3ddcdcc3ec0d3e9293093ea189a1c13c33f4d93a3aba6d273152e81aa0a3bf2665845228a3f"
    ["0.0.89/arm64"]="730b50e774009436b84214372a4cc7cfbc7e9ba7eeb10dc80bdd8d1c0f67aeab5eb35ff70bc0122835dbdb34f2453dda9b8dff8edcd21c83b855a915286f606b"
    ["0.0.88/amd64"]="1612a7d18986162bfa70d13efe090d3e25e984e0f2cc172795ba76fd794f61662b6c2119589581ce0ee12aa301098677cbf57df37dfb99f701850d8a627443d7"
    ["0.0.88/arm64"]="0042c1026ae09aa7b88d177691a3988a68ae51b77a4f418ce48ba62edab146cd3d73a0f49021cf904091270736bb6f15a9cf008f4d43e1c36f9749f5b64590f4"
    ["0.0.87/amd64"]="c290bd05a482d6bef84a452eb3dba147c4f0bf5cd0b4fe496aaaab479851bd6b09be598fcaa9df8c0d87fa6f7857d6499c4113d06ea6a9a0881b8615d0ac1980"
    ["0.0.87/arm64"]="eb734b0a34f65811f4b7872cc56a04913476f0e3bc48808a4f6db9a432b72e8a0ee1ad9cce76d21700485f907b7869aeecc96521fecbe4f4ff00065053db749d"
    ["0.0.86/amd64"]="10bf91bf383ef892c075779c804d3e92a122651d647a7ce42964fc957a76229ddc5e4ec4c2bdce1a409ca66ef4d3e8d1d179849d6f8b16916c421c07575ac74c"
    ["0.0.86/arm64"]="7ab4a5895261c6622372c8b58e241815dc19a150101e00acdfe8fd0419971a064a2c89cde196c16a9c6d512632bdd3355e486373770a023204ba4a6dbf5d2fc6"
    ["0.0.85/amd64"]="3b59a8956cd6ef5eeba7c0ab3b61356b125e587158bede8c3b51de58a5526e7d0787806f99bdb144e239af69c420e431d2bff18ed6d1c8be7ff852a0fe36f0bf"
    ["0.0.85/arm64"]="4530e4048736ed500f6a893a428ce4d1c827c66eeee8adea87c3fc82fc259ac82ff02c19f76fa25e92e3261c2c1d84d6ed1f197daf49d22f0fd7016aa9e3bcb8"
    ["0.0.84/amd64"]="362961e2208b873e68ec009a74dd829d858fe8082c2285bd2b86400597f1f9986de6f68d94363f2ffd1c3d95b7a9f3d6edf4e0b4266a53ed406beb6f114fecc6"
    ["0.0.84/arm64"]="81005d7ce6a11f3f6d9a32579a9495f9226f9c5fcff6c01b7eaf7effd5e0782c55416f50904fa515efbb5d8a648464f2c70225c9def93606efa9ce5b6ddcee96"
)
# <<< checksum table <<<

orb_install_main
