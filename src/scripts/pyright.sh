#!/bin/bash
#
# Type-checks Python code with Pyright, for the pyright command, against the
# packages installed in the project's environment (--pythonpath), whose
# Python version is the one checked against unless Pyright's configuration
# (pyrightconfig.json or [tool.pyright] in pyproject.toml) sets pythonVersion.
#
# Pyright writes its results as JSON (--outputjson) and exits 1 when it
# reports an error, 0 without, and 2, 3 or 4 when it couldn't run (a fatal
# error, a configuration it can't use, a bad command line). Diagnostics at or
# above fail_on are findings, which fail the step unless report_only is true;
# a run that couldn't complete, or that analyzed no file (unless allow_empty),
# fails it either way. Pyright runs with the Node.js the lock installs beside
# it, and without the job's PYRIGHT_PYTHON_* variables, which could make it
# download another Pyright or Node.js.
#
# Parameters arrive as PARAM_* variables; the lib as SCRIPT_PYTHON_QUALITY_LIB.

set -euo pipefail

if [[ -z "${SCRIPT_PYTHON_QUALITY_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_PYTHON_QUALITY_LIB is not set; run this script through the orb's pyright command." >&2
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
PROJECT=$(pq_subst "${PARAM_PROJECT}")
FAIL_ON=$(pq_subst "${PARAM_FAIL_ON}")
ALLOW_EMPTY=$(pq_bool allow_empty "${PARAM_ALLOW_EMPTY}")
JUNIT=$(pq_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(pq_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(pq_bool report_only "${PARAM_REPORT_ONLY}")
pq_words extra_args "$(pq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${PQ_WORDS[@]+"${PQ_WORDS[@]}"})

# --- Parameters ---
case "${FAIL_ON}" in
    error) FAIL_RANK=3 ;;
    warning) FAIL_RANK=2 ;;
    information) FAIL_RANK=1 ;;
    *)
        echo "ERROR: fail_on must be error, warning or information, not '${FAIL_ON}'." >&2
        exit 1
        ;;
esac
for path in ${PATHS[@]+"${PATHS[@]}"}; do
    if [[ ! -e "${path}" ]]; then
        echo "ERROR: paths names '${path}', which doesn't exist in $(pwd)." >&2
        exit 1
    fi
done
if [[ -n "${PROJECT}" && ! -e "${PROJECT}" ]]; then
    echo "ERROR: project names '${PROJECT}', which doesn't exist in $(pwd)." >&2
    exit 1
fi
# extra_args: Pyright's own options, never the ones the command sets itself,
# nor ones that filter what is reported, change the exit code the orb checks,
# print more than the JSON, write files or switch to another mode.
pq_extra_args extra_args pyright \
    "outputjson project pythonpath venvpath level warnings watch createstub verifytypes writebaseline verbose stats dependencies version help" \
    "pwvh" \
    "project pythonpath pythonplatform pythonversion venvpath typeshedpath threads level createstub verifytypes baselinefile" \
    "t"
if [[ -n "${ENVIRONMENT}" ]]; then
    pq_environment environment "${ENVIRONMENT}"
fi
pq_require_jq
pq_tool pyright

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

ENV_ARGS=(-u PYRIGHT_PYTHON_FORCE_VERSION -u PYRIGHT_PYTHON_PYLANCE_VERSION -u PYRIGHT_PYTHON_USE_BUNDLED_PYRIGHT
    -u PYRIGHT_PYTHON_NODEJS_WHEEL -u PYRIGHT_PYTHON_GLOBAL_NODE -u PYRIGHT_PYTHON_ENV_DIR -u PYRIGHT_PYTHON_CACHE_DIR
    PYRIGHT_PYTHON_IGNORE_WARNINGS=1)
pyright_run() {
    env "${ENV_ARGS[@]}" "${PQ_TOOL}" "$@"
}
VERSION=$(pyright_run --version 2> /dev/null | awk '/^pyright /{ print $2; exit }') || VERSION=""

ARGS=(--outputjson)
if [[ -n "${PROJECT}" ]]; then
    ARGS+=(--project "${PROJECT}")
fi
if [[ -n "${ENVIRONMENT}" ]]; then
    ARGS+=(--pythonpath "${PQ_ENVIRONMENT}")
fi
ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ${PATHS[@]+"${PATHS[@]}"})

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TOOL_VERSION=${VERSION}
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_ARGS=("${ARGS[@]}")
    PQ_INPUTS=()
    if [[ -f "${PROJECT}" ]]; then
        PQ_INPUTS+=("config:${PROJECT}")
    elif [[ -z "${PROJECT}" && -f pyrightconfig.json ]]; then
        PQ_INPUTS+=("config:pyrightconfig.json")
    elif [[ -z "${PROJECT}" && -f pyproject.toml ]]; then
        PQ_INPUTS+=("config:pyproject.toml")
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TARGET_JSON=$(jq -cn --arg python "${PQ_ENVIRONMENT:-}" --arg version "${PQ_ENV_VERSION:-}" \
        '{environment: (if $python == "" then null else {python: $python, version: $version} end)}')
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_REPORTS=("${REPORT}" "${SARIF}" "${JUNIT_FILE}")
    pq_run_record "${RECORD}" pyright "$1" "$2" "${STARTED}"
}

echo "Type-checking with Pyright ${VERSION:-(version unknown)}${PQ_ENVIRONMENT:+, against ${PQ_ENVIRONMENT} (Python ${PQ_ENV_VERSION})}:"
pq_show_command pyright "${ARGS[@]}" | sed 's/^/  /'
code=0
pyright_run "${ARGS[@]}" > "${WORK}/pyright.json" 2> "${WORK}/pyright.log" || code=$?
if [[ "${code}" -gt 1 ]] || ! pq_json_is "${WORK}/pyright.json" \
    '(.generalDiagnostics | type == "array") and (.summary.filesAnalyzed | type == "number")'; then
    pq_tail "${WORK}/pyright.log" 20
    awk 'NR <= 30' "${WORK}/pyright.json" | sed 's/^/  /' >&2 || true
    record error "${code}"
    echo "ERROR: Pyright did not complete (exit code ${code}): a fatal error, a configuration it can't use, or a bad" >&2
    echo "  option. This is not a type-checking result." >&2
    exit 1
fi
# shellcheck disable=SC2016 # jq program, not shell
jq --argjson min "${FAIL_RANK}" '[.generalDiagnostics[] | {
        file: (.file // "-"),
        line: (if .range then .range.start.line + 1 else null end),
        column: (if .range then .range.start.character + 1 else null end),
        end_line: (if .range then .range.end.line + 1 else null end),
        end_column: (if .range then .range.end.character + 1 else null end),
        rule: (.rule // null), severity,
        level: ({"error": "error", "warning": "warning"}[.severity] // "note"),
        message: .message,
        url: "https://microsoft.github.io/pyright/#/configuration",
        finding: (({"error": 3, "warning": 2, "information": 1}[.severity] // 0) >= $min)}]' \
    "${WORK}/pyright.json" > "${WORK}/findings.json"
pq_paths "${WORK}/findings.json"
cp "${WORK}/findings.json" "${REPORT}"
ANALYZED=$(jq -r '.summary.filesAnalyzed' "${WORK}/pyright.json")
ERRORS=$(jq -r '[.[] | select(.severity == "error")] | length' "${REPORT}")
COUNTS=$(jq -c --argjson analyzed "${ANALYZED}" --arg fail_on "${FAIL_ON}" \
    '. + {files_analyzed: $analyzed, fail_on: $fail_on}' <<< "$(pq_finding_counts "${REPORT}")")
FINDINGS=$(jq -r '.findings' <<< "${COUNTS}")
# shellcheck disable=SC2034 # read by pq_run_record
PQ_COUNTS=${COUNTS}
if [[ ( "${code}" -eq 1 && "${ERRORS}" -eq 0 ) || ( "${code}" -eq 0 && "${ERRORS}" -gt 0 ) ]]; then
    pq_tail "${WORK}/pyright.log" 20
    record error "${code}"
    echo "ERROR: Pyright exited ${code}, which doesn't agree with the $(pq_plural "${ERRORS}" error errors) it reported." >&2
    exit 1
fi
if [[ "${ANALYZED}" -eq 0 && "${ALLOW_EMPTY}" != true ]]; then
    record error "${code}"
    echo "ERROR: Pyright analyzed no file in ${PATHS[*]:-$(pwd)}, so nothing was checked. Check paths and the include" >&2
    echo "  and exclude settings in Pyright's configuration, or set allow_empty to true." >&2
    exit 1
fi

# --- Reports ---
pq_sarif "${REPORT}" "${SARIF}" Pyright "${VERSION}" "https://microsoft.github.io/pyright/"
if [[ "${JUNIT}" == true ]]; then
    pq_findings_junit "${REPORT}" "${JUNIT_FILE}" "pyright (${REPORT_NAME})"
fi
pq_print_findings "${REPORT}" 100
SUMMARY="Pyright analyzed $(pq_plural "${ANALYZED}" file files) and reported $(jq -r '"\(.error) errors, \(.warning) warnings and \(.note) informations"' <<< "${COUNTS}"); $(pq_plural "${FINDINGS}" finding findings) at or above ${FAIL_ON}."
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
