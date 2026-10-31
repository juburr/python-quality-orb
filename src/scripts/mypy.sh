#!/bin/bash
#
# Type-checks Python code with mypy, for the mypy command, against the
# packages installed in the project's environment.
#
# mypy runs either from this orb's install (runner: orb), told where the
# project's environment is with --python-executable, or from the project's
# environment itself (runner: project), which a configuration that loads
# plugins needs, since plugins are imported into mypy's process. Without
# python_version in mypy's configuration, the environment's Python version is
# the version checked against, not the version mypy runs on.
#
# mypy writes one JSON object per message (-O json) and exits 1 for type
# errors, 0 without, and 2 for an error that stopped it (a syntax error, a
# configuration it can't use, no files to check), which it writes to stderr.
# Errors are findings, which fail the step unless report_only is true; notes
# are reported; a run that stopped fails the step either way.
#
# Parameters arrive as PARAM_* variables; the lib as SCRIPT_PYTHON_QUALITY_LIB
# and the helper as SCRIPT_PYTHON_QUALITY_PY.

set -euo pipefail

if [[ -z "${SCRIPT_PYTHON_QUALITY_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_PYTHON_QUALITY_LIB is not set; run this script through the orb's mypy command." >&2
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
RUNNER=$(pq_subst "${PARAM_RUNNER}")
JUNIT=$(pq_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(pq_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(pq_bool report_only "${PARAM_REPORT_ONLY}")
pq_words extra_args "$(pq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${PQ_WORDS[@]+"${PQ_WORDS[@]}"})

# --- Parameters ---
case "${RUNNER}" in
    orb | project) ;;
    *)
        echo "ERROR: runner must be orb or project, not '${RUNNER}'." >&2
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
# extra_args: mypy's own options, never the ones the command sets itself, nor
# ones that change the output the orb reads, check code given as text, or
# install packages.
pq_extra_args extra_args mypy \
    "output error-summary no-error-summary python-executable config-file python-version install-types command version help" \
    "OcVh" \
    "config-file python-version python-executable cache-dir exclude module package custom-typeshed-dir custom-typing-module always-true always-false enable-error-code disable-error-code junit-xml junit-format any-exprs-report cobertura-xml-report html-report linecount-report linecoverage-report lineprecision-report txt-report xml-report xslt-html-report xslt-txt-report platform shadow-file enable-incomplete-feature find-occurrences soft-error-limit untyped-calls-exclude deprecated-calls-exclude perf-stats-file output" \
    "mpO"
TARGET_OPTION=false
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    case "${word}" in
        -m | -p | --module | --package | --module=* | --package=* | -m?* | -p?*) TARGET_OPTION=true ;;
    esac
done
if [[ -z "${ENVIRONMENT}" && "${RUNNER}" == project ]]; then
    echo "ERROR: runner: project runs mypy from the project's environment, so environment must name it." >&2
    exit 1
fi
if [[ -n "${ENVIRONMENT}" ]]; then
    pq_environment environment "${ENVIRONMENT}"
fi
pq_require_jq
pq_helper_python

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# --- mypy, and the configuration it reads ---
if [[ "${RUNNER}" == orb ]]; then
    pq_tool mypy
    MYPY=("${PQ_TOOL}")
else
    if ! "${PQ_ENVIRONMENT}" -I -c 'import mypy' 2> /dev/null; then
        echo "ERROR: runner is project, but mypy is not installed in ${PQ_ENVIRONMENT}. Add it to the project's" >&2
        echo "  development dependencies, or use runner: orb with this orb's install (tools: mypy)." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TOOL=""
    MYPY=("${PQ_ENVIRONMENT}" -m mypy)
fi
mypy_run() {
    env -u MYPY_FORCE_COLOR -u MYPY_FORCE_TERMINAL_WIDTH "${MYPY[@]}" "$@"
}
VERSION=$(mypy_run --version 2> /dev/null | awk '{ print $2; exit }') || VERSION=""
if ! pq_py "${PQ_PYTHON}" mypy-config "${CONFIG}" > "${WORK}/config.json"; then
    exit 1
fi
CONFIG_FOUND=$(jq -r '.config // ""' "${WORK}/config.json")
if [[ -n "${CONFIG_FOUND}" ]]; then
    echo "mypy's configuration: ${CONFIG_FOUND}"
else
    echo "mypy finds no configuration, so its defaults apply."
fi
# Plugins are imported into mypy's own process, and this orb's environment
# holds mypy alone.
if [[ "${RUNNER}" == orb ]]; then
    pq_tool_python mypy
    missing=()
    while IFS= read -r plugin; do
        [[ -n "${plugin}" ]] || continue
        if [[ "${plugin}" != */* && "${plugin}" != *.py ]] && ! "${PQ_TOOL_PYTHON}" -I -c \
            'import importlib.util, sys; sys.exit(importlib.util.find_spec(sys.argv[1].split(":")[0]) is None)' \
            "${plugin}" 2> /dev/null; then
            missing+=("${plugin}")
        fi
    done < <(jq -r '.plugins[]' "${WORK}/config.json")
    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: mypy's configuration loads the plugin(s) ${missing[*]}, which mypy imports into its own process," >&2
        echo "  and this orb's mypy environment doesn't have them. Set runner to project, with mypy and the plugins'" >&2
        echo "  packages in the project's environment." >&2
        exit 1
    fi
fi

ARGS=(-O json --no-error-summary --no-color-output --no-pretty)
if [[ -n "${CONFIG}" ]]; then
    ARGS+=(--config-file "${CONFIG}")
fi
if [[ -n "${ENVIRONMENT}" ]]; then
    ARGS+=(--python-executable "${PQ_ENVIRONMENT}")
    if [[ "$(jq -r '.python_version // ""' "${WORK}/config.json")" == "" ]]; then
        ARGS+=(--python-version "${PQ_ENV_VERSION}")
    fi
else
    ARGS+=(--no-site-packages)
fi
ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
if [[ "${#PATHS[@]}" -eq 0 && "${TARGET_OPTION}" == false && "$(jq -r '.files' "${WORK}/config.json")" != true ]]; then
    PATHS=(.)
fi
ARGS+=(${PATHS[@]+"${PATHS[@]}"})

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
    if [[ -n "${CONFIG_FOUND}" ]]; then
        PQ_INPUTS+=("config:${CONFIG_FOUND}")
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TARGET_JSON=$(jq -cn --arg python "${PQ_ENVIRONMENT:-}" --arg version "${PQ_ENV_VERSION:-}" --arg runner "${RUNNER}" \
        --arg mypy "${VERSION}" '{runner: $runner, mypy_version: $mypy,
            environment: (if $python == "" then null else {python: $python, version: $version} end)}')
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_REPORTS=("${REPORT}" "${SARIF}" "${JUNIT_FILE}")
    pq_run_record "${RECORD}" mypy "$1" "$2" "${STARTED}"
}

echo "Type-checking with mypy ${VERSION:-(version unknown)}${PQ_ENVIRONMENT:+, against ${PQ_ENVIRONMENT} (Python ${PQ_ENV_VERSION})}:"
pq_show_command mypy "${ARGS[@]}" | sed 's/^/  /'
code=0
mypy_run "${ARGS[@]}" > "${WORK}/mypy.jsonl" 2> "${WORK}/mypy.log" || code=$?
# shellcheck disable=SC2016 # jq program, not shell
if [[ "${code}" -gt 1 ]] || ! jq -R -s '
        [split("\n")[] | select(length > 0) | fromjson
         | {file, line: (if (.line // 0) > 0 then .line else null end),
            column: (if .line > 0 and .column != null and .column >= 0 then .column + 1 else null end),
            end_line: (if (.end_line // 0) > 0 then .end_line else null end),
            end_column: (if (.end_column // 0) > 0 then .end_column else null end),
            rule: .code, severity,
            level: (if .severity == "error" then "error" else "note" end),
            message: (.message + (if (.hint // "") != "" then "\n" + .hint else "" end)),
            url: (if .code then "https://mypy.readthedocs.io/en/stable/error_code_list.html" else null end),
            finding: (.severity == "error")}]' "${WORK}/mypy.jsonl" > "${WORK}/findings.json" 2> /dev/null; then
    pq_tail "${WORK}/mypy.log" 30
    awk 'NR <= 10' "${WORK}/mypy.jsonl" | sed 's/^/  /' >&2 || true
    record error "${code}"
    echo "ERROR: mypy stopped (exit code ${code}) before it could check the code: a syntax error, a configuration it" >&2
    echo "  can't use, a plugin it can't load, or no files to check. This is not a type-checking result." >&2
    exit 1
fi
pq_paths "${WORK}/findings.json"
cp "${WORK}/findings.json" "${REPORT}"
COUNTS=$(pq_finding_counts "${REPORT}")
FINDINGS=$(jq -r '.findings' <<< "${COUNTS}")
# shellcheck disable=SC2034 # read by pq_run_record
PQ_COUNTS=${COUNTS}
if [[ ( "${code}" -eq 1 && "${FINDINGS}" -eq 0 ) || ( "${code}" -eq 0 && "${FINDINGS}" -gt 0 ) ]]; then
    pq_tail "${WORK}/mypy.log" 20
    record error "${code}"
    echo "ERROR: mypy exited ${code}, which doesn't agree with the $(pq_plural "${FINDINGS}" error errors) it reported." >&2
    exit 1
fi
if [[ -s "${WORK}/mypy.log" ]]; then
    awk 'NR <= 10' "${WORK}/mypy.log" | sed 's/^/  /' || true
fi

# --- Reports ---
pq_sarif "${REPORT}" "${SARIF}" mypy "${VERSION}" "https://mypy.readthedocs.io/"
if [[ "${JUNIT}" == true ]]; then
    pq_findings_junit "${REPORT}" "${JUNIT_FILE}" "mypy (${REPORT_NAME})"
fi
pq_print_findings "${REPORT}" 100
SUMMARY="mypy reported $(pq_plural "${FINDINGS}" error errors) and $(pq_plural "$(jq -r '.note' <<< "${COUNTS}")" note notes)."
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
