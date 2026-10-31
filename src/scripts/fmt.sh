#!/bin/bash
#
# Checks that Python code is formatted as Ruff's formatter would format it,
# for the fmt command, without changing any file: ruff format --check, with
# its diagnostics as JSON.
#
# Ruff exits 0 when every file is formatted, 1 when it would reformat one, and
# 2 when it couldn't format a file (one it can't parse or read) or couldn't
# run, and lists those failures in the same JSON. The orb reads the JSON: a
# file the formatter would change is a finding, which fails the step unless
# report_only is true; a file Ruff couldn't format, or a run that found no
# Python file to check (unless allow_empty), fails it either way. Ruff's
# configuration (ruff.toml, .ruff.toml or [tool.ruff] in pyproject.toml) is
# the project's own; RUFF_* variables in the job are ignored.
#
# Parameters arrive as PARAM_* variables; the lib as SCRIPT_PYTHON_QUALITY_LIB.

set -euo pipefail

if [[ -z "${SCRIPT_PYTHON_QUALITY_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_PYTHON_QUALITY_LIB is not set; run this script through the orb's fmt command." >&2
    exit 1
fi
eval "${SCRIPT_PYTHON_QUALITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The reports an earlier run with this report_name left go first, so a check
# that stops on its inputs leaves none behind to be stored as its own.
REPORT_NAME=$(pq_subst "${PARAM_REPORT_NAME}")
pq_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${PQ_BASE}.json"
SARIF="${PQ_BASE}.sarif"
DIFF="${PQ_BASE}.diff"
JUNIT_FILE="${PQ_OUT%/}/junit/${REPORT_NAME}.xml"
RECORD="${PQ_BASE}.run-record.json"
rm -f "${REPORT}" "${SARIF}" "${DIFF}" "${JUNIT_FILE}" "${RECORD}"

pq_list paths "${PARAM_PATHS}"
PATHS=(${PQ_LIST[@]+"${PQ_LIST[@]}"})
CONFIG=$(pq_subst "${PARAM_CONFIG}")
ALLOW_EMPTY=$(pq_bool allow_empty "${PARAM_ALLOW_EMPTY}")
JUNIT=$(pq_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(pq_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(pq_bool report_only "${PARAM_REPORT_ONLY}")
pq_words extra_args "$(pq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${PQ_WORDS[@]+"${PQ_WORDS[@]}"})

# --- Parameters ---
for path in ${PATHS[@]+"${PATHS[@]}"}; do
    if [[ ! -e "${path}" ]]; then
        echo "ERROR: paths names '${path}', which doesn't exist in $(pwd)." >&2
        exit 1
    fi
done
if [[ -n "${CONFIG}" && ! -f "${CONFIG}" ]]; then
    echo "ERROR: config names '${CONFIG}', which doesn't exist in $(pwd)." >&2
    exit 1
fi
# extra_args: Ruff's own options, never the ones the command sets itself, nor
# ones that would write files, hide the warnings the orb reads, or report
# elsewhere.
pq_extra_args extra_args "ruff format" \
    "check diff output-format no-cache cache-dir silent quiet exit-non-zero-on-format stdin-filename range watch" \
    "nsqe" "config cache-dir exclude extend-exclude line-length target-version stdin-filename range output-format" ""
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    if [[ "${word}" == @* ]]; then
        echo "ERROR: extra_args can't hold '${word}': Ruff would read more arguments from that file." >&2
        exit 1
    fi
done
pq_require_jq
pq_tool ruff

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

pq_ruff_env
ruff_run() {
    env ${PQ_RUFF_ENV[@]+"${PQ_RUFF_ENV[@]}"} "${PQ_TOOL}" "$@"
}
VERSION=$(ruff_run --version 2> /dev/null | awk '{ print $2; exit }') || VERSION=""

ARGS=(format --no-cache)
if [[ -n "${CONFIG}" ]]; then
    ARGS+=(--config "${CONFIG}")
fi
ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
CHECK_ARGS=("${ARGS[@]}" --check --output-format json -- ${PATHS[@]+"${PATHS[@]}"})

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TOOL_VERSION=${VERSION}
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_ARGS=("${CHECK_ARGS[@]}")
    PQ_INPUTS=()
    if [[ -n "${CONFIG}" ]]; then
        PQ_INPUTS+=("config:${CONFIG}")
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_REPORTS=("${REPORT}" "${SARIF}" "${DIFF}" "${JUNIT_FILE}")
    pq_run_record "${RECORD}" fmt "$1" "$2" "${STARTED}"
}

echo "Checking the formatting with Ruff ${VERSION:-(version unknown)}:"
pq_show_command ruff "${CHECK_ARGS[@]}" | sed 's/^/  /'
code=0
ruff_run "${CHECK_ARGS[@]}" > "${WORK}/ruff.json" 2> "${WORK}/ruff.log" || code=$?
if ! pq_json_is "${WORK}/ruff.json" 'type == "array"'; then
    pq_tail "${WORK}/ruff.log" 30
    record error "${code}"
    echo "ERROR: Ruff did not complete (exit code ${code}) and wrote no report. This is not a formatting result." >&2
    exit 1
fi
pq_ruff_findings "${WORK}/ruff.json" "${WORK}/findings.json"
pq_paths "${WORK}/findings.json"
cp "${WORK}/findings.json" "${REPORT}"
COUNTS=$(jq -c '{files: [.[] | select(.kind == "unformatted")] | length,
    errors: [.[] | select(.finding | not)] | length}' "${REPORT}")
UNFORMATTED=$(jq -r '.files' <<< "${COUNTS}")
ERRORS=$(jq -r '.errors' <<< "${COUNTS}")
# shellcheck disable=SC2034 # read by pq_run_record
PQ_COUNTS=${COUNTS}

# --- A run that checked nothing, or couldn't format a file ---
if [[ "${ERRORS}" -gt 0 || "${code}" -gt 1 || ( "${code}" -eq 1 && "${UNFORMATTED}" -eq 0 ) ]]; then
    jq '[.[] | select(.finding | not)]' "${REPORT}" > "${WORK}/errors.json"
    pq_print_findings "${WORK}/errors.json" 20 >&2
    pq_tail "${WORK}/ruff.log" 20
    record error "${code}"
    if [[ "${ERRORS}" -gt 0 ]]; then
        echo "ERROR: Ruff could not format $(pq_plural "${ERRORS}" file files) (exit code ${code}), so their formatting is" >&2
        echo "  unknown. A file with invalid syntax must be fixed, or left out with extend-exclude in Ruff's configuration." >&2
    else
        echo "ERROR: Ruff exited ${code} without saying what it would reformat. This is not a formatting result." >&2
    fi
    exit 1
fi
if grep -q 'No Python files found' "${WORK}/ruff.log" && [[ "${ALLOW_EMPTY}" != true ]]; then
    pq_tail "${WORK}/ruff.log" 10
    record error "${code}"
    echo "ERROR: Ruff found no Python file to check in ${PATHS[*]:-$(pwd)}, so nothing was checked." >&2
    echo "  Check paths and the include and exclude settings in Ruff's configuration, or set allow_empty to true." >&2
    exit 1
fi

# --- Reports ---
pq_sarif "${REPORT}" "${SARIF}" Ruff "${VERSION}" "https://docs.astral.sh/ruff/formatter/"
if [[ "${JUNIT}" == true ]]; then
    pq_findings_junit "${REPORT}" "${JUNIT_FILE}" "ruff format (${REPORT_NAME})"
fi
if [[ "${UNFORMATTED}" -gt 0 ]]; then
    # The diff is for people; the verdict came from the check.
    ruff_run "${ARGS[@]}" --diff -- ${PATHS[@]+"${PATHS[@]}"} > "${DIFF}" 2> /dev/null || true
    echo "Files Ruff would reformat (the changes are in ${DIFF}):"
    jq -r '.[] | select(.kind == "unformatted") | "  \(.path)"' "${REPORT}" | awk 'NR <= 100' || true
    if [[ "${UNFORMATTED}" -gt 100 ]]; then
        echo "  ... and $((UNFORMATTED - 100)) more, in ${REPORT}."
    fi
fi
awk 'NR <= 5' "${WORK}/ruff.log" | sed 's/^/  /' || true

SUMMARY="Ruff would reformat $(pq_plural "${UNFORMATTED}" file files)."
if [[ "${UNFORMATTED}" -gt 0 ]]; then
    SUMMARY="${SUMMARY} Run ruff format to fix them."
    if [[ "${REPORT_ONLY}" == true ]]; then
        record findings-reported "${code}"
    else
        record findings "${code}"
    fi
    pq_gate true "${REPORT_ONLY}" "${SUMMARY}"
fi
record passed "${code}"
pq_gate false "${REPORT_ONLY}" "${SUMMARY}"
