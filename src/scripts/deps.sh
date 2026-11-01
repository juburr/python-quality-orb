#!/bin/bash
#
# Checks a Python project's declared dependencies against its imports with
# deptry, for the deps command: imports no dependency provides (DEP001),
# dependencies nothing imports (DEP002), imports of packages only installed
# through another dependency (DEP003), development dependencies imported by
# the project's code (DEP004), and standard library modules declared as
# dependencies (DEP005).
#
# deptry decides what an import resolves to from the packages installed
# where it runs, and which modules are the standard library from the Python
# it runs on, so it runs on the project environment's Python, with the
# packages of this orb's deptry environment in front of the project's: the
# project's installed packages and Python version decide the result, and
# deptry's own dependencies stay the versions its lock pins.
#
# deptry exits 1 for violations and for a failure alike, so the orb reads the
# JSON report it writes only when it completes: violations are findings,
# which fail the step unless report_only is true; a run that wrote no report
# fails it either way. deptry's configuration is [tool.deptry] in
# pyproject.toml.
#
# Parameters arrive as PARAM_* variables; the lib as SCRIPT_PYTHON_QUALITY_LIB.

set -euo pipefail

if [[ -z "${SCRIPT_PYTHON_QUALITY_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_PYTHON_QUALITY_LIB is not set; run this script through the orb's deps command." >&2
    exit 1
fi
eval "${SCRIPT_PYTHON_QUALITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REPORT_NAME=$(pq_subst "${PARAM_REPORT_NAME}")
pq_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${PQ_BASE}.json"
SARIF="${PQ_BASE}.sarif"
JUNIT_FILE="${PQ_OUT%/}/junit/${REPORT_NAME}.xml"
RECORD="${PQ_BASE}.run-record.json"
rm -f "${REPORT}" "${SARIF}" "${JUNIT_FILE}" "${RECORD}"

pq_list paths "${PARAM_PATHS}"
PATHS=(${PQ_LIST[@]+"${PQ_LIST[@]}"})
ENVIRONMENT=$(pq_subst "${PARAM_ENVIRONMENT}")
CONFIG=$(pq_subst "${PARAM_CONFIG}")
ALLOW_EMPTY=$(pq_bool allow_empty "${PARAM_ALLOW_EMPTY}")
JUNIT=$(pq_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(pq_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(pq_bool report_only "${PARAM_REPORT_ONLY}")
pq_words extra_args "$(pq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${PQ_WORDS[@]+"${PQ_WORDS[@]}"})

# --- Parameters ---
if [[ "${#PATHS[@]}" -eq 0 ]]; then
    PATHS=(.)
fi
for path in "${PATHS[@]}"; do
    if [[ ! -d "${path}" ]]; then
        echo "ERROR: paths names '${path}', which is not a directory in $(pwd)." >&2
        exit 1
    fi
done
CONFIG=${CONFIG:-pyproject.toml}
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: deptry reads the project's dependencies from ${CONFIG}, which doesn't exist in $(pwd)." >&2
    exit 1
fi
# extra_args: deptry's own long options, such as --known-first-party or
# --per-rule-ignores, never the ones the command sets itself or ones that
# report elsewhere. Its short options run letters together (-pri, -ee), so
# only their long forms are taken.
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    if [[ "${word}" == -[!-]* && "${word}" != -v ]]; then
        echo "ERROR: extra_args can't hold '${word}': give deptry's options in their long form, such as --ignore." >&2
        exit 1
    fi
done
pq_extra_args extra_args deptry \
    "json-output github-output github-warning-errors config version help" "" \
    "ignore per-rule-ignores exclude extend-exclude requirements-files requirements-files-dev known-first-party package-module-name-map optional-dependencies-dev-groups pep621-dev-dependency-groups non-dev-dependency-groups" ""
if [[ -z "${ENVIRONMENT}" ]]; then
    echo "ERROR: environment must name the project's environment, with the project's dependencies installed." >&2
    exit 1
fi
pq_environment environment "${ENVIRONMENT}"
if ! pq_match "${PQ_ENV_VERSION}" '^3\.([1-9][0-9])$'; then
    echo "ERROR: deptry runs on the project's Python, and needs 3.10 or newer; ${PQ_ENVIRONMENT} is ${PQ_ENV_VERSION}." >&2
    exit 1
fi
pq_require_jq
pq_tool deptry
pq_tool_python deptry

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# deptry's packages, put in front of the project environment's.
if ! SITE=$("${PQ_TOOL_PYTHON}" -I -c 'import sysconfig
paths = sysconfig.get_paths()
print(":".join(dict.fromkeys([paths["purelib"], paths["platlib"]])))' 2> /dev/null) || [[ -z "${SITE}" ]]; then
    echo "ERROR: Could not find the packages of deptry's environment (${PQ_TOOL_PYTHON})." >&2
    exit 1
fi
# shellcheck disable=SC2016 # Python program, not shell
RUNNER='import sys
sys.path[0:0] = sys.argv[1].split(":")
sys.argv = ["deptry"] + sys.argv[2:]
from deptry.cli import deptry
deptry()'
deptry_run() {
    env -u PYTHONPATH -u PYTHONHOME "${PQ_ENVIRONMENT}" -I -c "${RUNNER}" "${SITE}" "$@"
}
if ! VERSION=$(deptry_run --version 2> "${WORK}/version.log" | awk '{ print $NF; exit }') || [[ -z "${VERSION}" ]]; then
    pq_tail "${WORK}/version.log" 20
    echo "ERROR: deptry doesn't run on ${PQ_ENVIRONMENT} (Python ${PQ_ENV_VERSION}) with its own packages in front." >&2
    exit 1
fi

ARGS=(--config "${CONFIG}" --no-ansi --json-output "${WORK}/deptry.json"
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "${PATHS[@]}")

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TOOL_VERSION=${VERSION}
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_ARGS=(--config "${CONFIG}" --no-ansi --json-output "<report>" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "${PATHS[@]}")
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_INPUTS=("config:${CONFIG}")
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TARGET_JSON=$(jq -cn --arg python "${PQ_ENVIRONMENT}" --arg version "${PQ_ENV_VERSION}" \
        '{environment: {python: $python, version: $version}}')
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_REPORTS=("${REPORT}" "${SARIF}" "${JUNIT_FILE}")
    pq_run_record "${RECORD}" deps "$1" "$2" "${STARTED}"
}

echo "Checking the dependencies with deptry ${VERSION}, on ${PQ_ENVIRONMENT} (Python ${PQ_ENV_VERSION}):"
pq_show_command deptry "${ARGS[@]}" | sed 's/^/  /'
code=0
deptry_run "${ARGS[@]}" > "${WORK}/deptry.log" 2>&1 || code=$?
if [[ "${code}" -gt 1 ]] || ! pq_json_is "${WORK}/deptry.json" 'type == "array"'; then
    pq_tail "${WORK}/deptry.log" 30
    record error "${code}"
    echo "ERROR: deptry did not complete (exit code ${code}) and wrote no report. This is not a dependency check result." >&2
    exit 1
fi
# shellcheck disable=SC2016 # jq program, not shell
jq '[.[] | {file: (.location.file // "-"), line: .location.line, column: .location.column,
        rule: .error.code, module: .module, message: .error.message, level: "error", finding: true,
        url: "https://deptry.com/rules-violations/"}]' "${WORK}/deptry.json" > "${WORK}/findings.json"
pq_paths "${WORK}/findings.json"
cp "${WORK}/findings.json" "${REPORT}"
FINDINGS=$(jq -r 'length' "${REPORT}")
# shellcheck disable=SC2034 # read by pq_run_record
PQ_COUNTS=$(jq -c '{findings: length} + ([.[].rule] | group_by(.) | map({key: .[0], value: length}) | from_entries)' "${REPORT}")
if [[ ( "${code}" -eq 1 && "${FINDINGS}" -eq 0 ) || ( "${code}" -eq 0 && "${FINDINGS}" -gt 0 ) ]]; then
    pq_tail "${WORK}/deptry.log" 30
    record error "${code}"
    echo "ERROR: deptry exited ${code}, which doesn't agree with the $(pq_plural "${FINDINGS}" violation violations) it reported." >&2
    exit 1
fi
# deptry logs "Scanning N files..." before it looks at the imports.
if grep -q '^Scanning 0 file' "${WORK}/deptry.log" && [[ "${ALLOW_EMPTY}" != true ]]; then
    record error "${code}"
    echo "ERROR: deptry found no Python file in ${PATHS[*]}, so no import was checked. Check paths and deptry's" >&2
    echo "  exclude settings, or set allow_empty to true." >&2
    exit 1
fi
grep -m 1 '^Scanning [0-9]' "${WORK}/deptry.log" | sed 's/^/  /' || true

# --- Reports ---
pq_sarif "${REPORT}" "${SARIF}" deptry "${VERSION}" "https://deptry.com/"
if [[ "${JUNIT}" == true ]]; then
    pq_findings_junit "${REPORT}" "${JUNIT_FILE}" "deptry (${REPORT_NAME})"
fi
pq_print_findings "${REPORT}" 100
SUMMARY="deptry reported $(pq_plural "${FINDINGS}" violation violations)."
if [[ "${FINDINGS}" -gt 0 ]]; then
    if [[ "${REPORT_ONLY}" == true ]]; then
        record findings-reported "${code}"
    else
        record findings "${code}"
    fi
    pq_gate true "${REPORT_ONLY}" "${SUMMARY}"
fi
record passed "${code}"
pq_gate false "${REPORT_ONLY}" "${SUMMARY}"
