#!/bin/bash
#
# Lints Python code with Ruff, for the lint command, without changing any
# file: ruff check --no-fix, with its diagnostics as JSON.
#
# Ruff exits 1 for any diagnostic, including a file it can't parse
# (invalid-syntax), and 2 when it couldn't run; a file it can't read is only
# a warning in its log unless the E902 rule is on. The orb reads the JSON and
# the log: a rule's diagnostic is a finding, which fails the step unless
# report_only is true; a file Ruff couldn't parse or read, or a run that
# found no Python file to check (unless allow_empty), fails it either way,
# since that code went unchecked. Ruff's configuration (ruff.toml, .ruff.toml
# or [tool.ruff] in pyproject.toml) decides the rules; RUFF_* variables in
# the job are ignored, and a configured fix = true never applies.
#
# Parameters arrive as PARAM_* variables; the lib as SCRIPT_PYTHON_QUALITY_LIB.

set -euo pipefail

if [[ -z "${SCRIPT_PYTHON_QUALITY_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_PYTHON_QUALITY_LIB is not set; run this script through the orb's lint command." >&2
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
JUNIT_FILE="${PQ_OUT%/}/junit/${REPORT_NAME}.xml"
RECORD="${PQ_BASE}.run-record.json"
rm -f "${REPORT}" "${SARIF}" "${JUNIT_FILE}" "${RECORD}"

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
# extra_args: Ruff's own options, such as --select or --target-version,
# never the ones the command sets itself, nor ones that would change files,
# hide the warnings the orb reads, or report elsewhere.
pq_extra_args extra_args "ruff check" \
    "fix no-fix fix-only no-fix-only unsafe-fixes diff watch exit-zero exit-non-zero-on-fix output-format output-file statistics add-noqa show-files show-settings no-cache cache-dir silent quiet stdin-filename" \
    "eownsq" \
    "config select extend-select ignore extend-ignore per-file-ignores extend-per-file-ignores exclude extend-exclude fixable unfixable extend-fixable extend-unfixable target-version line-length dummy-variable-rgx cache-dir output-file output-format stdin-filename add-noqa" ""
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

# --no-fix overrides fix = true in the configuration, so no file changes.
ARGS=(check --no-fix --no-fix-only --no-cache)
if [[ -n "${CONFIG}" ]]; then
    ARGS+=(--config "${CONFIG}")
fi
ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
CHECK_ARGS=("${ARGS[@]}" --output-format json -- ${PATHS[@]+"${PATHS[@]}"})

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
    PQ_REPORTS=("${REPORT}" "${SARIF}" "${JUNIT_FILE}")
    pq_run_record "${RECORD}" lint "$1" "$2" "${STARTED}"
}

echo "Linting with Ruff ${VERSION:-(version unknown)}:"
pq_show_command ruff "${CHECK_ARGS[@]}" | sed 's/^/  /'
code=0
ruff_run "${CHECK_ARGS[@]}" > "${WORK}/ruff.json" 2> "${WORK}/ruff.log" || code=$?
if ! pq_json_is "${WORK}/ruff.json" 'type == "array"'; then
    pq_tail "${WORK}/ruff.log" 30
    record error "${code}"
    echo "ERROR: Ruff did not complete (exit code ${code}) and wrote no report. This is not a lint result." >&2
    exit 1
fi
pq_ruff_findings "${WORK}/ruff.json" "${WORK}/findings.json"
pq_paths "${WORK}/findings.json"
cp "${WORK}/findings.json" "${REPORT}"
COUNTS=$(jq -c '{findings: [.[] | select(.finding)] | length,
    fixable: [.[] | select(.finding and .fixable)] | length,
    files: [.[] | select(.finding) | .file] | unique | length,
    errors: [.[] | select(.finding | not)] | length,
    rules: ([.[] | select(.finding) | .rule] | group_by(.) | map({key: .[0], value: length}) | from_entries)}' "${REPORT}")
FINDINGS=$(jq -r '.findings' <<< "${COUNTS}")
ERRORS=$(jq -r '.errors' <<< "${COUNTS}")
# shellcheck disable=SC2034 # read by pq_run_record
PQ_COUNTS=${COUNTS}
# A file Ruff can't read is only a warning in its log unless E902 is on.
UNREAD=$(grep -c -E 'Failed to lint|Encountered error' "${WORK}/ruff.log" || true)

# --- A run that checked nothing, or couldn't read or parse a file ---
if [[ "${ERRORS}" -gt 0 || "${UNREAD}" -gt 0 || "${code}" -gt 1 \
    || ( "${code}" -eq 1 && "${FINDINGS}" -eq 0 ) || ( "${code}" -eq 0 && "${FINDINGS}" -gt 0 ) ]]; then
    jq '[.[] | select(.finding | not)]' "${REPORT}" > "${WORK}/errors.json"
    pq_print_findings "${WORK}/errors.json" 20 >&2
    pq_tail "${WORK}/ruff.log" 20
    record error "${code}"
    if [[ "${ERRORS}" -gt 0 || "${UNREAD}" -gt 0 ]]; then
        echo "ERROR: Ruff could not read or parse $(pq_plural "$((ERRORS + UNREAD))" file files), so they went unchecked" >&2
        echo "  (exit code ${code}). A file with invalid syntax must be fixed, or left out with extend-exclude in Ruff's" >&2
        echo "  configuration." >&2
    else
        echo "ERROR: Ruff exited ${code}, which doesn't agree with the $(pq_plural "${FINDINGS}" finding findings) it reported." >&2
        echo "  This is not a lint result." >&2
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
pq_sarif "${REPORT}" "${SARIF}" Ruff "${VERSION}" "https://docs.astral.sh/ruff/"
if [[ "${JUNIT}" == true ]]; then
    pq_findings_junit "${REPORT}" "${JUNIT_FILE}" "ruff check (${REPORT_NAME})"
fi
pq_print_findings "${REPORT}" 100
awk 'NR <= 5' "${WORK}/ruff.log" | sed 's/^/  /' || true

FIXABLE=$(jq -r '.fixable' <<< "${COUNTS}")
SUMMARY="Ruff reported $(pq_plural "${FINDINGS}" finding findings) in $(pq_plural "$(jq -r '.files' <<< "${COUNTS}")" file files)."
if [[ "${FINDINGS}" -gt 0 ]]; then
    if [[ "${FIXABLE}" -gt 0 ]]; then
        SUMMARY="${SUMMARY} ${FIXABLE} of them can be fixed with ruff check --fix."
    fi
    if [[ "${REPORT_ONLY}" == true ]]; then
        record findings-reported "${code}"
    else
        record findings "${code}"
    fi
    pq_gate true "${REPORT_ONLY}" "${SUMMARY}"
fi
record passed "${code}"
pq_gate false "${REPORT_ONLY}" "${SUMMARY}"
