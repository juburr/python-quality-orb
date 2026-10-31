#!/bin/bash
#
# Type-checks Python code with ty, Astral's type checker (in beta), for the
# ty command, against the packages installed in the project's environment
# (--python), whose Python version is the one checked against unless ty's
# configuration (ty.toml or [tool.ty] in pyproject.toml) sets python-version.
#
# ty writes its diagnostics in GitLab's Code Quality JSON (severities info,
# minor for a warning, major for an error, critical for a crash) and exits 1
# when it reports an error, or a warning with error-on-warning (its
# default), 0 otherwise, 2 for a file it couldn't read or a bad command line,
# and 101 when it crashed. Diagnostics at or above fail_on are findings,
# which fail the step unless report_only is true; a run that couldn't
# complete, or that found no Python file to check (unless allow_empty), fails
# it either way. The job's TY_* variables, which could set another
# configuration file or output format, are ignored, and so is the user-level
# configuration, so the project's configuration alone applies.
#
# Parameters arrive as PARAM_* variables; the lib as SCRIPT_PYTHON_QUALITY_LIB.

set -euo pipefail

if [[ -z "${SCRIPT_PYTHON_QUALITY_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_PYTHON_QUALITY_LIB is not set; run this script through the orb's ty command." >&2
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
    info) FAIL_RANK=1 ;;
    *)
        echo "ERROR: fail_on must be error, warning or info, not '${FAIL_ON}'." >&2
        exit 1
        ;;
esac
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
# extra_args: ty's own options, such as --python-version or --error, never the
# ones the command sets itself, nor ones that change files, the exit code the
# orb checks or the output it reads.
pq_extra_args extra_args ty \
    "output-format config-file python venv fix add-ignore update-baseline error-on-warning exit-zero exit-zero-on-warning watch quiet help version" \
    "qWh" \
    "output-format config-file python venv project typeshed custom-typeshed-dir extra-search-path python-version target-version python-platform platform config error warn ignore exclude baseline color" \
    "c"
if [[ -n "${ENVIRONMENT}" ]]; then
    pq_environment environment "${ENVIRONMENT}"
fi
pq_require_jq
pq_tool ty

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# TY_* variables could set the configuration file or the output format, and
# CI_PROJECT_DIR (GitLab's) the paths in the report; a user-level ty.toml
# would add to the project's configuration.
ENV_ARGS=(-u CI_PROJECT_DIR)
while IFS= read -r name; do
    if [[ "${name}" == TY_* ]]; then
        ENV_ARGS+=(-u "${name}")
    fi
done < <(compgen -e)
mkdir -p "${WORK}/config"
ENV_ARGS+=(XDG_CONFIG_HOME="${WORK}/config")
ty_run() {
    env "${ENV_ARGS[@]}" "${PQ_TOOL}" "$@"
}
VERSION=$(ty_run --version 2> /dev/null | awk '{ print $2; exit }') || VERSION=""

ARGS=(check --output-format gitlab)
if [[ -n "${CONFIG}" ]]; then
    ARGS+=(--config-file "${CONFIG}")
fi
if [[ -n "${ENVIRONMENT}" ]]; then
    ARGS+=(--python "${PQ_ENVIRONMENT}")
fi
ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} -- ${PATHS[@]+"${PATHS[@]}"})

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
    if [[ -n "${CONFIG}" ]]; then
        PQ_INPUTS+=("config:${CONFIG}")
    elif [[ -f ty.toml ]]; then
        PQ_INPUTS+=("config:ty.toml")
    elif [[ -f pyproject.toml ]]; then
        PQ_INPUTS+=("config:pyproject.toml")
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TARGET_JSON=$(jq -cn --arg python "${PQ_ENVIRONMENT:-}" --arg version "${PQ_ENV_VERSION:-}" \
        '{environment: (if $python == "" then null else {python: $python, version: $version} end)}')
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_REPORTS=("${REPORT}" "${SARIF}" "${JUNIT_FILE}")
    pq_run_record "${RECORD}" ty "$1" "$2" "${STARTED}"
}

echo "Type-checking with ty ${VERSION:-(version unknown)}${PQ_ENVIRONMENT:+, against ${PQ_ENVIRONMENT} (Python ${PQ_ENV_VERSION})}:"
pq_show_command ty "${ARGS[@]}" | sed 's/^/  /'
code=0
ty_run "${ARGS[@]}" > "${WORK}/ty.json" 2> "${WORK}/ty.log" || code=$?
if [[ "${code}" -gt 1 ]] || ! pq_json_is "${WORK}/ty.json" 'type == "array"'; then
    pq_tail "${WORK}/ty.log" 20
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r '.[]? | select(.severity == "critical" or .check_name == "io")
        | "  \(.location.path // "-"): \(.description)"' "${WORK}/ty.json" 2> /dev/null | awk 'NR <= 20' >&2 || true
    record error "${code}"
    echo "ERROR: ty did not complete (exit code ${code}): a file it couldn't read, a configuration it can't use, a bad" >&2
    echo "  option, or a crash. This is not a type-checking result." >&2
    exit 1
fi
# shellcheck disable=SC2016 # jq program, not shell
jq --argjson min "${FAIL_RANK}" '[.[] | (.check_name // "") as $rule | {
        file: (.location.path // "-"),
        line: (.location.positions.begin.line // null),
        column: (.location.positions.begin.column // null),
        end_line: (.location.positions.end.line // null),
        end_column: (.location.positions.end.column // null),
        rule: .check_name,
        severity: ({"critical": "error", "major": "error", "minor": "warning"}[.severity] // "info"),
        message: (.description | ltrimstr($rule + ": ")),
        url: (if .check_name then "https://docs.astral.sh/ty/reference/rules/#\(.check_name)" else null end)}
    | . + {level: ({"error": "error", "warning": "warning"}[.severity] // "note"),
           finding: (({"error": 3, "warning": 2, "info": 1}[.severity] // 0) >= $min)}]' \
    "${WORK}/ty.json" > "${WORK}/findings.json"
pq_paths "${WORK}/findings.json"
cp "${WORK}/findings.json" "${REPORT}"
ERRORS=$(jq -r '[.[] | select(.severity == "error")] | length' "${REPORT}")
WARNINGS=$(jq -r '[.[] | select(.severity == "warning")] | length' "${REPORT}")
COUNTS=$(jq -c --arg fail_on "${FAIL_ON}" '. + {fail_on: $fail_on}' <<< "$(pq_finding_counts "${REPORT}")")
FINDINGS=$(jq -r '.findings' <<< "${COUNTS}")
# shellcheck disable=SC2034 # read by pq_run_record
PQ_COUNTS=${COUNTS}
# Exit 1 needs an error or a warning (error-on-warning); 0 allows warnings,
# when the configuration turns error-on-warning off, but never an error.
if [[ ( "${code}" -eq 1 && "$((ERRORS + WARNINGS))" -eq 0 ) || ( "${code}" -eq 0 && "${ERRORS}" -gt 0 ) ]]; then
    pq_tail "${WORK}/ty.log" 20
    record error "${code}"
    echo "ERROR: ty exited ${code}, which doesn't agree with the $(pq_plural "${ERRORS}" error errors) and" >&2
    echo "  $(pq_plural "${WARNINGS}" warning warnings) it reported." >&2
    exit 1
fi
if grep -q 'No python files found' "${WORK}/ty.log" && [[ "${ALLOW_EMPTY}" != true ]]; then
    record error "${code}"
    echo "ERROR: ty found no Python file to check in ${PATHS[*]:-$(pwd)}, so nothing was checked. Check paths and the" >&2
    echo "  include and exclude settings in ty's configuration, or set allow_empty to true." >&2
    exit 1
fi

# --- Reports ---
pq_sarif "${REPORT}" "${SARIF}" ty "${VERSION}" "https://docs.astral.sh/ty/"
if [[ "${JUNIT}" == true ]]; then
    pq_findings_junit "${REPORT}" "${JUNIT_FILE}" "ty (${REPORT_NAME})"
fi
pq_print_findings "${REPORT}" 100
SUMMARY="ty reported $(pq_plural "${ERRORS}" error errors), $(pq_plural "${WARNINGS}" warning warnings) and $(pq_plural "$(jq -r '.note' <<< "${COUNTS}")" info infos); $(pq_plural "${FINDINGS}" finding findings) at or above ${FAIL_ON}."
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
