#!/bin/bash
#
# Runs a project's tests with pytest, for the test command, in the project's
# own environment (python -m pytest), optionally measured by coverage.py
# (python -m coverage run -m pytest), which must be installed there too:
# tests import the project and its dependencies, so they run where those
# are installed. On CircleCI with parallelism, split_tests gives each node
# its share of the test files, by the timings of earlier runs.
#
# pytest exits 0 when every test passed, 1 when one failed, 5 when it
# collected no test, 6 when the tests passed with more warnings than
# --max-warnings allows, and 2, 3 or 4 when it was interrupted (a test
# module that doesn't import), failed inside, or was misused. The orb reads
# pytest's JUnit report: failed and erroring tests, too many warnings, and
# coverage below coverage_min (or the project's own fail_under) are
# findings, which fail the step; a run that couldn't complete, or that
# collected no test (unless allow_empty), fails it too.
#
# Parameters arrive as PARAM_* variables; the lib as SCRIPT_PYTHON_QUALITY_LIB
# and the helper as SCRIPT_PYTHON_QUALITY_PY.

set -euo pipefail

if [[ -z "${SCRIPT_PYTHON_QUALITY_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_PYTHON_QUALITY_LIB is not set; run this script through the orb's test command." >&2
    exit 1
fi
eval "${SCRIPT_PYTHON_QUALITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REPORT_NAME=$(pq_subst "${PARAM_REPORT_NAME}")
pq_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${PQ_BASE}.json"
COVERAGE_JSON="${PQ_BASE}.coverage.json"
COVERAGE_XML="${PQ_BASE}.coverage.xml"
COVERAGE_TXT="${PQ_BASE}.coverage.txt"
JUNIT_FILE="${PQ_OUT%/}/junit/${REPORT_NAME}.xml"
RECORD="${PQ_BASE}.run-record.json"
rm -f "${REPORT}" "${COVERAGE_JSON}" "${COVERAGE_XML}" "${COVERAGE_TXT}" "${JUNIT_FILE}" "${RECORD}"

pq_list paths "${PARAM_PATHS}"
PATHS=(${PQ_LIST[@]+"${PQ_LIST[@]}"})
ENVIRONMENT=$(pq_subst "${PARAM_ENVIRONMENT}")
COVERAGE=$(pq_bool coverage "${PARAM_COVERAGE}")
pq_list coverage_source "${PARAM_COVERAGE_SOURCE}"
COVERAGE_SOURCE=(${PQ_LIST[@]+"${PQ_LIST[@]}"})
COVERAGE_MIN=$(pq_subst "${PARAM_COVERAGE_MIN}")
COVERAGE_CONFIG=$(pq_subst "${PARAM_COVERAGE_CONFIG}")
SPLIT_TESTS=$(pq_bool split_tests "${PARAM_SPLIT_TESTS}")
ALLOW_EMPTY=$(pq_bool allow_empty "${PARAM_ALLOW_EMPTY}")
JUNIT=$(pq_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(pq_bool run_record "${PARAM_RUN_RECORD}")
pq_words extra_args "$(pq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${PQ_WORDS[@]+"${PQ_WORDS[@]}"})

# --- Parameters ---
for path in ${PATHS[@]+"${PATHS[@]}"}; do
    if [[ ! -e "${path}" ]]; then
        echo "ERROR: paths names '${path}', which doesn't exist in $(pwd)." >&2
        exit 1
    fi
done
MIN_NUM=""
MIN_DEN=1
if [[ -n "${COVERAGE_MIN}" ]]; then
    if ! pq_match "${COVERAGE_MIN}" '^(100(\.0+)?|[0-9]{1,2}(\.[0-9]{1,6})?)$'; then
        echo "ERROR: coverage_min must be a percentage from 0 to 100, such as 80 or 92.5, not '${COVERAGE_MIN}'." >&2
        exit 1
    fi
    if [[ "${COVERAGE}" != true ]]; then
        echo "ERROR: coverage_min needs coverage: true, which measures it." >&2
        exit 1
    fi
    fraction=""
    if [[ "${COVERAGE_MIN}" == *.* ]]; then
        fraction=${COVERAGE_MIN#*.}
    fi
    MIN_NUM=$((10#${COVERAGE_MIN%%.*}${fraction}))
    for ((i = 0; i < ${#fraction}; i++)); do
        MIN_DEN=$((MIN_DEN * 10))
    done
fi
if [[ -n "${COVERAGE_CONFIG}" && ! -f "${COVERAGE_CONFIG}" ]]; then
    echo "ERROR: coverage_config names '${COVERAGE_CONFIG}', which doesn't exist in $(pwd)." >&2
    exit 1
fi
if [[ "${COVERAGE}" != true && ( -n "${COVERAGE_CONFIG}" || "${#COVERAGE_SOURCE[@]}" -gt 0 ) ]]; then
    echo "ERROR: coverage_config and coverage_source need coverage: true." >&2
    exit 1
fi
# extra_args: pytest's own options and its plugins', such as -k, -m or -x,
# never the ones the command sets itself, nor ones that would collect
# without running, stop for a debugger, or write the JUnit report elsewhere.
pq_extra_args extra_args pytest \
    "junitxml junit-xml collect-only co setup-plan setup-only setup-show fixtures fixtures-per-test markers pdb trace help version" \
    "h" \
    "maxfail deselect ignore ignore-glob rootdir basetemp durations durations-min tb color code-highlight import-mode log-level log-format log-date-format log-cli-level log-file log-file-level confcutdir override-ini config-file junit-prefix capture show-capture pythonwarnings max-warnings" \
    "kmpcoWrn"
if [[ -z "${ENVIRONMENT}" ]]; then
    echo "ERROR: environment must name the project's environment, with pytest and the project installed." >&2
    exit 1
fi
pq_environment environment "${ENVIRONMENT}"
PY=${PQ_ENVIRONMENT}
if ! PYTEST_VERSION=$("${PY}" -I -c 'import pytest; print(pytest.__version__)' 2> /dev/null); then
    echo "ERROR: pytest is not installed in ${PY}. Add it to the project's development dependencies." >&2
    exit 1
fi
COVERAGE_VERSION=""
if [[ "${COVERAGE}" == true ]] && ! COVERAGE_VERSION=$("${PY}" -I -c 'import coverage; print(coverage.__version__)' 2> /dev/null); then
    echo "ERROR: coverage is true, but coverage.py is not installed in ${PY}. Add coverage to the project's" >&2
    echo "  development dependencies." >&2
    exit 1
fi
NODES=${CIRCLE_NODE_TOTAL:-1}
if [[ "${SPLIT_TESTS}" == true && "${NODES}" -gt 1 && -n "${COVERAGE_MIN}" ]]; then
    echo "ERROR: coverage_min can't be checked with split_tests across ${NODES} nodes: each node measures its own share." >&2
    exit 1
fi
pq_require_jq
pq_helper_python

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
JUNIT_OUT=${JUNIT_FILE}
if [[ "${JUNIT}" != true ]]; then
    JUNIT_OUT="${WORK}/junit.xml"
fi
mkdir -p "$(dirname "${JUNIT_OUT}")"

# --- This node's share of the test files ---
TARGETS=(${PATHS[@]+"${PATHS[@]}"})
SPLIT=false
if [[ "${SPLIT_TESTS}" == true && "${NODES}" -gt 1 ]]; then
    if ! command -v circleci > /dev/null 2>&1; then
        echo "ERROR: split_tests needs the CircleCI CLI (circleci tests split), which is not on the PATH." >&2
        exit 1
    fi
    echo "Collecting the tests to split them across ${NODES} nodes:"
    code=0
    "${PY}" -m pytest --collect-only -q -p no:cacheprovider ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
        ${PATHS[@]+"${PATHS[@]}"} > "${WORK}/collect.log" 2>&1 || code=$?
    if [[ "${code}" -ne 0 && "${code}" -ne 5 ]]; then
        pq_tail "${WORK}/collect.log" 30
        echo "ERROR: pytest could not collect the tests (exit code ${code}), so they can't be split." >&2
        exit 1
    fi
    awk -F'::' '/::/ { print $1 }' "${WORK}/collect.log" | LC_ALL=C sort -u > "${WORK}/files.txt"
    split_code=0
    circleci tests split --split-by=timings --timings-type=filename < "${WORK}/files.txt" > "${WORK}/share.txt" \
        2> "${WORK}/split.log" || split_code=$?
    if [[ "${split_code}" -ne 0 ]]; then
        pq_tail "${WORK}/split.log" 10
        echo "ERROR: circleci tests split failed (exit code ${split_code})." >&2
        exit 1
    fi
    TARGETS=()
    while IFS= read -r file; do
        [[ -n "${file}" ]] && TARGETS+=("${file}")
    done < "${WORK}/share.txt"
    SPLIT=true
    echo "  $(pq_plural "$(wc -l < "${WORK}/files.txt" | tr -d ' ')" file files) with tests; node ${CIRCLE_NODE_INDEX:-0} runs $(pq_plural "${#TARGETS[@]}" file files)."
    if [[ "${#TARGETS[@]}" -eq 0 ]]; then
        echo "Passed: no test file fell to node ${CIRCLE_NODE_INDEX:-0} of ${NODES}."
        exit 0
    fi
fi

PYTEST_ARGS=(-m pytest "--junitxml=${JUNIT_OUT}" -o junit_family=legacy -o "junit_suite_name=${REPORT_NAME}"
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ${TARGETS[@]+"${TARGETS[@]}"})
COVERAGE_ARGS=()
if [[ -n "${COVERAGE_CONFIG}" ]]; then
    COVERAGE_ARGS+=("--rcfile=${COVERAGE_CONFIG}")
fi
if [[ "${COVERAGE}" == true ]]; then
    RUN=("${PY}" -m coverage run --parallel-mode ${COVERAGE_ARGS[@]+"${COVERAGE_ARGS[@]}"})
    if [[ "${#COVERAGE_SOURCE[@]}" -gt 0 ]]; then
        RUN+=("--source=$(IFS=,; echo "${COVERAGE_SOURCE[*]}")")
    fi
    RUN+=("${PYTEST_ARGS[@]}")
    # Every process writes its data in the work directory, which combine reads.
    mkdir -p "${WORK}/coverage"
    export COVERAGE_FILE="${WORK}/coverage/.coverage"
else
    RUN=("${PY}" "${PYTEST_ARGS[@]}")
fi

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TOOL=""
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_ARGS=("${RUN[@]:1}")
    PQ_INPUTS=()
    if [[ -n "${COVERAGE_CONFIG}" ]]; then
        PQ_INPUTS+=("coverage_config:${COVERAGE_CONFIG}")
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TARGET_JSON=$(jq -cn --arg python "${PY}" --arg version "${PQ_ENV_VERSION}" --arg pytest "${PYTEST_VERSION}" \
        --arg coverage "${COVERAGE_VERSION}" --argjson split "${SPLIT}" --arg node "${CIRCLE_NODE_INDEX:-0}" \
        --arg nodes "${NODES}" '{environment: {python: $python, version: $version}, pytest_version: $pytest,
            coverage_version: (if $coverage == "" then null else $coverage end),
            split: (if $split then {node: ($node | tonumber), nodes: ($nodes | tonumber)} else null end)}')
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_REPORTS=("${REPORT}" "${JUNIT_FILE}" "${COVERAGE_JSON}" "${COVERAGE_XML}" "${COVERAGE_TXT}")
    pq_run_record "${RECORD}" test "$1" "$2" "${STARTED}"
}

echo "Running the tests with pytest ${PYTEST_VERSION}${COVERAGE_VERSION:+ and coverage.py ${COVERAGE_VERSION}}, in ${PY} (Python ${PQ_ENV_VERSION}):"
pq_show_command python "${RUN[@]:1}" | sed 's/^/  /'
code=0
"${RUN[@]}" || code=$?
echo "pytest exited ${code}."

# --- What pytest reported ---
case "${code}" in
    0 | 1 | 5 | 6) ;;
    *)
        record error "${code}"
        echo "ERROR: pytest did not complete (exit code ${code}: interrupted, an internal error, or a usage error). A" >&2
        echo "  test module that fails to import stops the run; see pytest's output above. This is not a test result." >&2
        exit 1
        ;;
esac
if [[ ! -s "${JUNIT_OUT}" ]] || ! pq_py "${PQ_PYTHON}" junit "${JUNIT_OUT}" > "${WORK}/summary.json"; then
    record error "${code}"
    echo "ERROR: pytest exited ${code} but wrote no readable JUnit report to ${JUNIT_OUT}." >&2
    exit 1
fi
TESTS=$(jq -r '.tests' "${WORK}/summary.json")
FAILED=$(jq -r '.failures + .errors' "${WORK}/summary.json")
if [[ ( "${code}" -eq 1 && "${FAILED}" -eq 0 ) || ( "${code}" -eq 0 && "${FAILED}" -gt 0 ) ]]; then
    record error "${code}"
    echo "ERROR: pytest exited ${code}, which doesn't agree with the $(pq_plural "${FAILED}" failure failures) in its JUnit report." >&2
    exit 1
fi
if [[ "${code}" -eq 5 || "${TESTS}" -eq 0 ]]; then
    if [[ "${ALLOW_EMPTY}" == true ]]; then
        jq '. + {coverage: null}' "${WORK}/summary.json" > "${REPORT}"
        record passed "${code}"
        echo "Passed: pytest collected no test, which allow_empty allows."
        exit 0
    fi
    record error "${code}"
    echo "ERROR: pytest collected no test in ${TARGETS[*]:-$(pwd)}, so nothing was tested. Check paths and pytest's" >&2
    echo "  testpaths and python_files settings, or set allow_empty to true." >&2
    exit 1
fi

# --- Coverage ---
COVERAGE_JSON_VALUE=null
COVERAGE_LOW=false
COVERAGE_MESSAGE=""
if [[ "${COVERAGE}" == true ]]; then
    cov() {
        "${PY}" -m coverage "$@" ${COVERAGE_ARGS[@]+"${COVERAGE_ARGS[@]}"}
    }
    cov_code=0
    if ! cov combine --quiet > "${WORK}/combine.log" 2>&1 \
        || ! cov json -o "${COVERAGE_JSON}" --fail-under=0 > "${WORK}/json.log" 2>&1; then
        cat "${WORK}/combine.log" "${WORK}/json.log" 2> /dev/null | sed 's/^/  /' >&2 || true
        record error "${code}"
        echo "ERROR: coverage.py measured nothing it could report: check coverage_source and the project's coverage" >&2
        echo "  configuration ([run] source, include and omit)." >&2
        exit 1
    fi
    cov xml -o "${COVERAGE_XML}" --fail-under=0 > /dev/null 2>&1 || true
    # The table, with the project's own fail_under unless coverage_min replaces it.
    if [[ -n "${COVERAGE_MIN}" ]]; then
        cov report --fail-under=0 > "${COVERAGE_TXT}" 2>&1 || cov_code=$?
    else
        cov report > "${COVERAGE_TXT}" 2>&1 || cov_code=$?
    fi
    awk 'NR <= 200' "${COVERAGE_TXT}" | sed 's/^/  /' || true
    # shellcheck disable=SC2016 # jq program, not shell
    COVERAGE_JSON_VALUE=$(jq -c '.totals | {covered: (.covered_lines + (.covered_branches // 0)),
        total: (.num_statements + (.num_branches // 0)), lines_covered: .covered_lines, lines: .num_statements,
        branches_covered: (.covered_branches // null), branches: (.num_branches // null), percent: .percent_covered}' \
        "${COVERAGE_JSON}")
    covered=$(jq -r '.covered' <<< "${COVERAGE_JSON_VALUE}")
    total=$(jq -r '.total' <<< "${COVERAGE_JSON_VALUE}")
    if [[ -n "${COVERAGE_MIN}" ]]; then
        # Whole numbers, never a rounded percentage: 1999 of 2000 is not 100%.
        if ((covered * 100 * MIN_DEN < MIN_NUM * total)); then
            COVERAGE_LOW=true
            COVERAGE_MESSAGE="coverage is $(jq -r '.percent * 100 | floor / 100' <<< "${COVERAGE_JSON_VALUE}")% (${covered} of ${total}), below coverage_min ${COVERAGE_MIN}%"
        fi
    elif [[ "${cov_code}" -eq 2 ]]; then
        COVERAGE_LOW=true
        COVERAGE_MESSAGE=$(grep -m 1 'Coverage failure' "${COVERAGE_TXT}" || echo "coverage is below the project's fail_under")
    elif [[ "${cov_code}" -ne 0 ]]; then
        record error "${code}"
        echo "ERROR: coverage report failed (exit code ${cov_code})." >&2
        exit 1
    fi
fi

# --- Reports ---
# shellcheck disable=SC2016 # jq program, not shell
jq --argjson coverage "${COVERAGE_JSON_VALUE}" --argjson low "${COVERAGE_LOW}" --arg message "${COVERAGE_MESSAGE}" \
    --argjson code "${code}" '. + {exit_code: $code, max_warnings_exceeded: ($code == 6),
        coverage: (if $coverage then $coverage + {below_minimum: $low, message: (if $message == "" then null else $message end)} else null end)}' \
    "${WORK}/summary.json" > "${REPORT}"
# shellcheck disable=SC2034 # read by pq_run_record
PQ_COUNTS=$(jq -c '{tests, failures, errors, skipped,
    coverage_percent: (.coverage.percent // null), coverage_below_minimum: (.coverage.below_minimum // false)}' "${REPORT}")
# shellcheck disable=SC2016 # jq program, not shell
jq -r '.failed[:50][] | "  \(.outcome): \(if .file then .file + (if .line then ":\(.line)" else "" end) + " " else "" end)\(.classname).\(.name): \(.message | split("\n")[0])"' "${REPORT}"
SUMMARY="$(pq_plural "${TESTS}" test tests): $(jq -r '"\(.tests - .failures - .errors - .skipped) passed, \(.failures) failed, \(.errors) errors, \(.skipped) skipped"' "${REPORT}")"
if [[ -n "${COVERAGE_JSON_VALUE}" && "${COVERAGE_JSON_VALUE}" != null ]]; then
    SUMMARY="${SUMMARY}; coverage $(jq -r '.percent * 100 | floor / 100' <<< "${COVERAGE_JSON_VALUE}")%"
fi
SUMMARY="${SUMMARY}."
PROBLEMS=()
if [[ "${FAILED}" -gt 0 ]]; then
    PROBLEMS+=("$(pq_plural "${FAILED}" test tests) failed or errored")
fi
if [[ "${code}" -eq 6 ]]; then
    PROBLEMS+=("the tests raised more warnings than --max-warnings allows")
fi
if [[ "${COVERAGE_LOW}" == true ]]; then
    PROBLEMS+=("${COVERAGE_MESSAGE}")
fi
if [[ "${#PROBLEMS[@]}" -gt 0 ]]; then
    record findings "${code}"
    joined=${PROBLEMS[0]}
    for problem in "${PROBLEMS[@]:1}"; do
        joined="${joined}; ${problem}"
    done
    echo "ERROR: ${SUMMARY} ${joined}." >&2
    echo "  The reports are in ${PQ_OUT}." >&2
    exit 1
fi
record passed "${code}"
echo "Passed: ${SUMMARY}"
