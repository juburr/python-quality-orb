#!/bin/bash
#
# Builds a Python project's distributions and checks them, for the package
# command: uv build makes the sdist and then the wheel from it (as PyPI's
# users will build it), or dists names files an earlier step built; twine
# check --strict reads each distribution's metadata and renders its
# description as PyPI would; check-wheel-contents finds the mistakes a wheel
# can hold, such as compiled files, duplicate or missing modules, or files
# at the top level that aren't the project's.
#
# A distribution twine or check-wheel-contents reject is a finding, which
# fails the step unless report_only is true. A build that fails, a check
# that couldn't run, or no distribution to check fails it either way. The
# distributions built are kept in out_dir, or with the reports.
#
# Parameters arrive as PARAM_* variables; the lib as SCRIPT_PYTHON_QUALITY_LIB.

set -euo pipefail

if [[ -z "${SCRIPT_PYTHON_QUALITY_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_PYTHON_QUALITY_LIB is not set; run this script through the orb's package command." >&2
    exit 1
fi
eval "${SCRIPT_PYTHON_QUALITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REPORT_NAME=$(pq_subst "${PARAM_REPORT_NAME}")
pq_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${PQ_BASE}.json"
JUNIT_FILE="${PQ_OUT%/}/junit/${REPORT_NAME}.xml"
RECORD="${PQ_BASE}.run-record.json"
DIST_KEEP="${PQ_BASE}-dist"
rm -f "${REPORT}" "${JUNIT_FILE}" "${RECORD}"

pq_list dists "${PARAM_DISTS}"
DISTS_PARAM=(${PQ_LIST[@]+"${PQ_LIST[@]}"})
OUT_DIR=$(pq_subst "${PARAM_OUT_DIR}")
NO_SOURCES=$(pq_bool no_sources "${PARAM_NO_SOURCES}")
TWINE=$(pq_bool twine "${PARAM_TWINE}")
CHECK_WHEEL_CONTENTS=$(pq_bool check_wheel_contents "${PARAM_CHECK_WHEEL_CONTENTS}")
JUNIT=$(pq_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(pq_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(pq_bool report_only "${PARAM_REPORT_ONLY}")
pq_words check_wheel_contents_args "$(pq_subst "${PARAM_CHECK_WHEEL_CONTENTS_ARGS}")"
CWC_ARGS=(${PQ_WORDS[@]+"${PQ_WORDS[@]}"})
pq_words extra_args "$(pq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${PQ_WORDS[@]+"${PQ_WORDS[@]}"})

# --- Parameters ---
if [[ "${TWINE}" != true && "${CHECK_WHEEL_CONTENTS}" != true ]]; then
    echo "ERROR: twine and check_wheel_contents are both false, so nothing would check the distributions." >&2
    exit 1
fi
if [[ "${#DISTS_PARAM[@]}" -gt 0 && "${#EXTRA_ARGS[@]}" -gt 0 ]]; then
    echo "ERROR: extra_args go to uv build, and dists names distributions built earlier, so they can't be used together." >&2
    exit 1
fi
if [[ -n "${OUT_DIR}" && "${#DISTS_PARAM[@]}" -gt 0 ]]; then
    echo "ERROR: out_dir is where the distributions built are kept, and dists names distributions built earlier." >&2
    exit 1
fi
if [[ "${OUT_DIR}" == -* ]]; then
    echo "ERROR: out_dir can't start with '-': '${OUT_DIR}'. Write ./${OUT_DIR}." >&2
    exit 1
fi
# extra_args (in PQ_WORDS): uv build's own options, such as --python or --config-setting,
# never the ones the command sets itself, nor ones that would build only one
# kind of distribution, elsewhere, or another package.
pq_extra_args extra_args "uv build" \
    "out-dir sdist wheel no-sources package all-packages list help version quiet" \
    "ohq" \
    "python config-setting config-settings-package build-constraints build-constraint index default-index index-url extra-index-url find-links index-strategy keyring-provider resolution prerelease fork-strategy exclude-newer exclude-newer-package link-mode no-build-isolation-package no-binary-package no-build-package refresh-package upgrade-package cache-dir python-preference directory project config-file color allow-insecure-host" \
    "pCbiUPf"
# check_wheel_contents_args: its own options, such as --ignore or --toplevel.
PQ_WORDS=(${CWC_ARGS[@]+"${CWC_ARGS[@]}"})
pq_extra_args check_wheel_contents_args check-wheel-contents "help version" "hV" \
    "config ignore select toplevel package package-omit src-dir" "c"
pq_require_jq
if [[ "${TWINE}" == true ]]; then
    pq_tool twine
    TWINE_TOOL=${PQ_TOOL}
    TWINE_VERSION=$("${TWINE_TOOL}" --no-color --version 2> /dev/null | awk '$2 == "version" { print $3; exit }') || TWINE_VERSION=""
fi
if [[ "${CHECK_WHEEL_CONTENTS}" == true ]]; then
    pq_tool check-wheel-contents
    CWC_TOOL=${PQ_TOOL}
    CWC_VERSION=$("${CWC_TOOL}" --version 2> /dev/null | awk '{ print $NF; exit }') || CWC_VERSION=""
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# --- The distributions ---
DISTS=()
BUILD_ARGS=()
UV_VERSION=""
if [[ "${#DISTS_PARAM[@]}" -gt 0 ]]; then
    PQ_LIST=("${DISTS_PARAM[@]}")
    pq_files dists
    for file in "${PQ_FILES[@]}"; do
        case "${file}" in
            *.whl | *.tar.gz | *.zip) DISTS+=("${file}") ;;
            *)
                echo "ERROR: dists names '${file}', which is neither a wheel (.whl) nor an sdist (.tar.gz)." >&2
                exit 1
                ;;
        esac
    done
else
    pq_tool uv
    UV=${PQ_TOOL}
    UV_VERSION=$("${UV}" --version 2> /dev/null | awk '{ print $2; exit }') || UV_VERSION=""
    BUILD_ARGS=(build --out-dir "${WORK}/dist")
    if [[ "${NO_SOURCES}" == true ]]; then
        BUILD_ARGS+=(--no-sources)
    fi
    BUILD_ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
    # An earlier build's distributions go first, so only this build's are
    # stored with the reports. With dists, that directory is left alone: it
    # can hold the very distributions named.
    rm -rf "${DIST_KEEP:?}"
    echo "Building with uv ${UV_VERSION:-(version unknown)}:"
    pq_show_command uv "${BUILD_ARGS[@]}" | sed 's/^/  /'
    build_code=0
    "${UV}" "${BUILD_ARGS[@]}" > "${WORK}/build.log" 2>&1 || build_code=$?
    sed 's/^/  /' "${WORK}/build.log" | awk 'NR <= 200' || true
    if [[ "${build_code}" -ne 0 ]]; then
        echo "ERROR: uv build failed (exit code ${build_code}), so there is nothing to check." >&2
        exit 1
    fi
    while IFS= read -r file; do
        DISTS+=("${file}")
    done < <(find "${WORK}/dist" -maxdepth 1 -type f \( -name '*.whl' -o -name '*.tar.gz' \) | LC_ALL=C sort)
    if ! printf '%s\n' ${DISTS[@]+"${DISTS[@]}"} | grep -q '\.tar\.gz$' \
        || ! printf '%s\n' ${DISTS[@]+"${DISTS[@]}"} | grep -q '\.whl$'; then
        echo "ERROR: uv build exited 0, but didn't leave an sdist and a wheel in its output directory." >&2
        exit 1
    fi
    if [[ -n "${OUT_DIR}" ]]; then
        KEEP=${OUT_DIR}
    else
        KEEP=${DIST_KEEP}
    fi
    mkdir -p "${KEEP}"
    cp "${DISTS[@]}" "${KEEP}/"
    echo "The distributions are in ${KEEP}."
fi
if [[ "${#DISTS[@]}" -eq 0 ]]; then
    echo "ERROR: There is no distribution to check." >&2
    exit 1
fi
# check-wheel-contents reads wheels only, so without twine an sdist alone
# would be checked by nothing.
if [[ "${TWINE}" != true ]] && ! printf '%s\n' "${DISTS[@]}" | grep -q '\.whl$'; then
    echo "ERROR: twine is false and dists names no wheel, so nothing would check these distributions:" >&2
    printf '  %s\n' "${DISTS[@]}" >&2
    echo "  check-wheel-contents reads wheels only. Set twine to true, or name the wheels in dists." >&2
    exit 1
fi
# Absolute and normalized, as both checkers print the path back.
for i in "${!DISTS[@]}"; do
    DISTS[i]=$(realpath -s -- "${DISTS[i]}")
done

# record OUTCOME: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TOOL=""
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_ARGS=(${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"})
    PQ_INPUTS=()
    for file in "${DISTS[@]}"; do
        PQ_INPUTS+=("distribution:${file}")
    done
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TARGET_JSON=$(jq -cn --arg uv "${UV_VERSION}" --arg twine "${TWINE_VERSION:-}" --arg cwc "${CWC_VERSION:-}" \
        '{uv_version: (if $uv == "" then null else $uv end), twine_version: (if $twine == "" then null else $twine end),
          check_wheel_contents_version: (if $cwc == "" then null else $cwc end)}')
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_REPORTS=("${REPORT}" "${JUNIT_FILE}")
    pq_run_record "${RECORD}" package "$1" 0 "${STARTED}"
}

# --- The checks, one distribution at a time ---
echo '[]' > "${WORK}/findings.json"
# add FILE RULE TOOL MESSAGE: adds a finding about distribution FILE.
add() {
    jq --arg file "$1" --arg rule "$2" --arg tool "$3" --arg message "$4" \
        '. + [{file: $file, line: null, column: null, rule: $rule, tool: $tool, message: $message,
               level: "error", finding: true}]' "${WORK}/findings.json" > "${WORK}/next.json"
    mv "${WORK}/next.json" "${WORK}/findings.json"
}
RESULTS="[]"
for dist in "${DISTS[@]}"; do
    name=${dist##*/}
    twine_status=null
    cwc_status=null
    if [[ "${TWINE}" == true ]]; then
        code=0
        # twine forces a terminal for rich, so --no-color, a wide line, and
        # no escape codes left.
        COLUMNS=1000 "${TWINE_TOOL}" --no-color check --strict "${dist}" > "${WORK}/twine.raw" 2>&1 || code=$?
        sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "${WORK}/twine.raw" > "${WORK}/twine.log"
        if ! grep -q -F "Checking ${dist}:" "${WORK}/twine.log"; then
            pq_tail "${WORK}/twine.log" 20
            record error
            echo "ERROR: twine could not check ${name} (exit code ${code}). This is not a package check result." >&2
            exit 1
        fi
        if [[ "${code}" -eq 0 ]] && grep -q -F -x "Checking ${dist}: PASSED" "${WORK}/twine.log"; then
            twine_status='"passed"'
        elif [[ "${code}" -eq 1 ]]; then
            twine_status='"failed"'
            messages=$(grep -E '^(ERROR|WARNING) ' "${WORK}/twine.log" | sed -E 's/^(ERROR|WARNING) +//' || true)
            add "${dist}" twine-check twine "${messages:-twine check --strict failed}"
        else
            pq_tail "${WORK}/twine.log" 20
            record error
            echo "ERROR: twine check exited ${code} on ${name} without saying it failed. This is not a package check result." >&2
            exit 1
        fi
        sed 's/^/  /' "${WORK}/twine.log"
    fi
    if [[ "${CHECK_WHEEL_CONTENTS}" == true && "${dist}" == *.whl ]]; then
        code=0
        "${CWC_TOOL}" ${CWC_ARGS[@]+"${CWC_ARGS[@]}"} "${dist}" > "${WORK}/cwc.log" 2> "${WORK}/cwc.err" || code=$?
        if [[ "${code}" -eq 0 ]] && grep -q -F -x "${dist}: OK" "${WORK}/cwc.log"; then
            cwc_status='"passed"'
        elif [[ "${code}" -eq 1 ]] && grep -q -F "${dist}: W" "${WORK}/cwc.log"; then
            cwc_status='"failed"'
            # Each failure is "<wheel>: W001: message", with the files it names
            # on the indented lines after it.
            while IFS=$'\t' read -r rule message; do
                add "${dist}" "${rule}" check-wheel-contents "${message}"
            done < <(awk -v prefix="${dist}: " '
                index($0, prefix) == 1 { if (rule != "") print rule "\t" text
                    rest = substr($0, length(prefix) + 1); rule = substr(rest, 1, 4); text = substr(rest, 7); next }
                /^ / && rule != "" { sub(/^ +/, ""); text = text " " $0 }
                END { if (rule != "") print rule "\t" text }' "${WORK}/cwc.log")
        else
            cat "${WORK}/cwc.log" "${WORK}/cwc.err" | sed 's/^/  /' >&2
            record error
            echo "ERROR: check-wheel-contents could not check ${name} (exit code ${code}): an invalid wheel, or a bad" >&2
            echo "  option. This is not a package check result." >&2
            exit 1
        fi
        sed 's/^/  /' "${WORK}/cwc.log"
    fi
    RESULTS=$(jq -c --arg file "${dist}" --argjson twine "${twine_status}" --argjson cwc "${cwc_status}" \
        '. + [{distribution: $file, twine: $twine, check_wheel_contents: $cwc}]' <<< "${RESULTS}")
done
pq_paths "${WORK}/findings.json"
cp "${WORK}/findings.json" "${REPORT}"
FINDINGS=$(jq -r 'length' "${REPORT}")
# shellcheck disable=SC2034 # read by pq_run_record
PQ_RESULTS=${RESULTS}
# shellcheck disable=SC2034 # read by pq_run_record
PQ_COUNTS=$(jq -c --argjson results "${RESULTS}" '{findings: length, distributions: ($results | length),
    wheels: [$results[] | select(.distribution | endswith(".whl"))] | length}' "${REPORT}")

# --- Reports ---
if [[ "${JUNIT}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    pq_junit "${JUNIT_FILE}" "package (${REPORT_NAME})" "$(jq -c --slurpfile f "${REPORT}" '[.[] | .distribution as $d
        | (if .twine then {classname: ($d | split("/") | last), name: "twine check",
             status: (if .twine == "failed" then "failed" else "passed" end),
             message: ([$f[0][] | select(.file == $d and .tool == "twine") | .message] | join("\n"))} else empty end),
          (if .check_wheel_contents then {classname: ($d | split("/") | last), name: "check-wheel-contents",
             status: (if .check_wheel_contents == "failed" then "failed" else "passed" end),
             message: ([$f[0][] | select(.file == $d and .tool == "check-wheel-contents") | "\(.rule): \(.message)"] | join("\n"))}
           else empty end)]' <<< "${RESULTS}")"
fi
SUMMARY="Checked $(pq_plural "${#DISTS[@]}" distribution distributions): $(pq_plural "${FINDINGS}" problem problems)."
if [[ "${FINDINGS}" -gt 0 ]]; then
    pq_print_findings "${REPORT}" 100
    if [[ "${REPORT_ONLY}" == true ]]; then
        record findings-reported
    else
        record findings
    fi
    pq_gate true "${REPORT_ONLY}" "${SUMMARY}"
fi
record passed
pq_gate false "${REPORT_ONLY}" "${SUMMARY}"
