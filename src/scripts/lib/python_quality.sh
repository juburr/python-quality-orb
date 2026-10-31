#!/bin/bash

# Shared helpers for the python-quality-orb commands. Each command passes this
# file to its step as SCRIPT_PYTHON_QUALITY_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions and variables.

# pq_subst VALUE: prints VALUE with environment variables expanded. The value
# is piped in on stdin: passed as an argument, a value starting with "-" would
# be parsed as a flag. Without the CircleCI CLI (GitHub Actions and local
# runs), the value is used as is.
pq_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# pq_bool NAME VALUE: prints true or false. CircleCI passes boolean parameters
# as 1 or 0; GitHub Actions and local callers use true or false.
pq_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# pq_words PARAMETER VALUE: sets PQ_WORDS to VALUE split like shell words
# (see split_shell_words), naming PARAMETER in any error. Nothing in it is
# expanded or executed: a $(...) or backtick that reached a parameter through
# an environment variable (a branch name, a commit message) reaches the tool as
# text inside quotes, and fails the step outside them.
pq_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    PQ_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# pq_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, setting
# BASH_REMATCH. In other locales a range such as [a-z] can match letters such
# as é (cimg images set LC_ALL=en_US.UTF-8), so checks with ranges use this.
pq_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# pq_list PARAMETER VALUE: sets PQ_LIST to VALUE, with environment variables
# expanded, split on commas and spaces.
pq_list() {
    local value
    PQ_LIST=()
    value=$(pq_subst "$2")
    if [[ "${value}" == *$'\n'* ]]; then
        echo "ERROR: ${1} must be separated by commas or spaces, not newlines." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    read -r -a PQ_LIST <<< "${value//,/ }"
}

# pq_require_jq: stops the step unless jq, which the reports are built with,
# is on the PATH.
pq_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "ERROR: jq is not on the PATH, and this command needs it to write its reports." >&2
        echo "  CircleCI's cimg images and GitHub's hosted runners have it; elsewhere, install jq in an earlier step." >&2
        exit 1
    fi
}

# pq_output DIR NAME: checks output_dir and report_name, creates DIR, and sets
# PQ_OUT to DIR and PQ_BASE to the path every report of this run starts with.
pq_output() {
    if [[ "$1" != /* || "$1" == *$'\n'* ]]; then
        echo "ERROR: output_dir must be an absolute path, not '$1'." >&2
        exit 1
    fi
    if ! pq_match "$2" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        echo "ERROR: report_name must be letters, digits, '.', '_' and '-', not '$2'." >&2
        exit 1
    fi
    if ! mkdir -p "$1"; then
        echo "ERROR: Could not create output_dir $1." >&2
        exit 1
    fi
    PQ_OUT=${1%/}
    PQ_OUT=${PQ_OUT:-/}
    # shellcheck disable=SC2034 # read by the script that evals this file
    PQ_BASE="${PQ_OUT%/}/$2"
}

# pq_uint PARAMETER VALUE [MIN]: stops the step unless VALUE is a whole number
# of at least MIN (default 0).
pq_uint() {
    if ! pq_match "$2" '^[0-9]{1,9}$' || ((10#$2 < ${3:-0})); then
        echo "ERROR: ${1} must be a whole number of at least ${3:-0}, not '$2'." >&2
        exit 1
    fi
}

# pq_junit FILE SUITE CASES: writes JUnit XML to FILE, for CircleCI's Tests
# tab or any other JUnit reader, from CASES, a JSON array of test cases:
#   {"classname": ..., "name": ..., "status": "failed" | "skipped" | "passed",
#    "message": ..., "detail": ...}
# A run with no cases gets one passing case, so the tab shows it ran.
pq_junit() {
    local dir=${1%/*}
    mkdir -p "${dir}"
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --arg suite "$2" '
        (if length == 0 then [{classname: $suite, name: "no findings", status: "passed"}] else . end) as $cases
        | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<testsuites>",
          "  <testsuite name=\"\($suite | @html)\" tests=\"\($cases | length)\" failures=\"\([$cases[] | select(.status == "failed")] | length)\" skipped=\"\([$cases[] | select(.status == "skipped")] | length)\">",
          ($cases[] |
            "    <testcase classname=\"\(.classname | @html)\" name=\"\(.name | @html)\">"
            + (if .status == "failed" then "<failure message=\"\((.message // "") | @html)\">\((.detail // "") | @html)</failure>"
               elif .status == "skipped" then "<skipped message=\"\((.message // "") | @html)\"/>"
               else "" end)
            + "</testcase>"),
          "  </testsuite>",
          "</testsuites>"
    ' <<< "$3" > "$1"
}

# pq_gate FINDINGS REPORT_ONLY SUMMARY: ends a check. Without findings it
# succeeds. With findings it fails with SUMMARY, unless REPORT_ONLY is true,
# when it only warns: the reports are written either way.
pq_gate() {
    if [[ "$1" == false ]]; then
        echo "Passed: $3"
        exit 0
    fi
    if [[ "$2" == true ]]; then
        echo "WARN: $3" >&2
        echo "WARN: report_only is true, so this step passes. The reports are in ${PQ_OUT}." >&2
        exit 0
    fi
    echo "ERROR: $3" >&2
    echo "  The reports are in ${PQ_OUT}. Set report_only to true to report findings without failing." >&2
    exit 1
}

# pq_plural COUNT SINGULAR PLURAL: prints COUNT and the word that goes with
# it, such as "1 file" or "2 files".
pq_plural() {
    if [[ "$1" -eq 1 ]]; then
        printf '%s %s\n' "$1" "$2"
    else
        printf '%s %s\n' "$1" "$3"
    fi
}

# pq_tail FILE [LINES]: prints the last LINES (default 40) lines of FILE to
# stderr, indented, to show why a tool failed. A Python traceback ends with
# the exception, so the tail holds it.
pq_tail() {
    tail -n "${2:-40}" "$1" | sed 's/^/  /' >&2
}

# pq_export NAME VALUE: exports NAME=VALUE, shell-quoted, to later steps
# through BASH_ENV (on GitHub Actions, the action passes it on through
# GITHUB_ENV).
pq_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}

# pq_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
pq_env_var_name() {
    if ! pq_match "$2" '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

# pq_json_is FILE FILTER [JQ_OPTION...]: whether FILE holds one JSON value for
# which FILTER is true. It compares jq's output instead of using -e, since jq
# 1.6 (as on Ubuntu 22.04 and some cimg images) exits 0 with -e when the file
# is empty, as a tool that failed before writing its report leaves it.
pq_json_is() {
    local file=$1 filter=$2 options=()
    if [[ $# -gt 2 ]]; then
        options=("${@:3}")
    fi
    [[ "$(jq -c ${options[@]+"${options[@]}"} "(${filter}) | if . then true else false end" "${file}" 2> /dev/null)" == true ]]
}

# pq_sha256 FILE: prints FILE's SHA-256.
pq_sha256() {
    sha256sum -- "$1" | awk '{ print $1 }'
}

# pq_url_public URL: prints URL without the userinfo, query and fragment,
# which can hold credentials, so it can go in a log or an artifact.
pq_url_public() {
    local url=$1
    if [[ "${url}" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*@)?([^?#]*) ]]; then
        printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${url%%[?#]*}"
    fi
}

# pq_ci_json: describes the CI job this runs in, for run records: a CircleCI
# job or a GitHub Actions run, or null elsewhere.
pq_ci_json() {
    if [[ -n "${CIRCLE_BUILD_URL:-}" ]]; then
        jq -cn --arg url "${CIRCLE_BUILD_URL}" --arg sha "${CIRCLE_SHA1:-}" --arg job "${CIRCLE_JOB:-}" \
            --arg repo "${CIRCLE_PROJECT_USERNAME:-}${CIRCLE_PROJECT_REPONAME:+/${CIRCLE_PROJECT_REPONAME}}" \
            '{provider: "circleci", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    elif [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        jq -cn --arg url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}/attempts/${GITHUB_RUN_ATTEMPT:-1}" \
            --arg sha "${GITHUB_SHA:-}" --arg job "${GITHUB_JOB:-}" --arg repo "${GITHUB_REPOSITORY:-}" \
            '{provider: "github-actions", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    else
        echo null
    fi
}

# pq_tool_json PATH VERSION: describes a tool that ran for the run record:
# its SHA-512, and how the orb installed it, from the install record beside
# it when that record describes this very file.
pq_tool_json() {
    local sha="" install="null" entry
    if [[ -n "$1" && -f "$1" ]]; then
        # Without sha512sum the record says so with a null SHA-512, as pq_tool
        # only warns.
        sha=$(sha512sum -- "$1" 2> /dev/null | awk '{ print $1 }') || sha=""
        entry="$(dirname "$1")/.${1##*/}.install.json"
        # shellcheck disable=SC2016 # jq program, not shell
        if [[ -f "${entry}" ]] && pq_json_is "${entry}" '.binary_sha512 == $sha' --arg sha "${sha}"; then
            install=$(jq -c 'del(.binary_sha512)' "${entry}")
        fi
    fi
    jq -cn --arg name "${1##*/}" --arg path "$1" --arg version "$2" --arg sha "${sha}" --argjson install "${install}" \
        '{name: $name, path: $path, version: $version, sha512: (if $sha == "" then null else $sha end), install: $install}'
}

# pq_tool NAME: sets PQ_TOOL to NAME's path on the PATH, or stops the step
# saying how to install it. Warns when it is not the binary this orb's install
# verified, as the install record beside it says, such as a copy that came
# with the image.
pq_tool() {
    local record sha
    if ! PQ_TOOL=$(command -v "$1"); then
        echo "ERROR: $1 is not on the PATH. Install it in an earlier step with this orb's install (tools: $1)," >&2
        echo "  or with install_$1." >&2
        exit 1
    fi
    record="$(dirname "${PQ_TOOL}")/.$1.install.json"
    sha=$(sha512sum -- "${PQ_TOOL}" 2> /dev/null | awk '{ print $1 }') || sha=""
    # shellcheck disable=SC2016 # jq program, not shell
    if [[ -n "${sha}" && -f "${record}" ]] && pq_json_is "${record}" '.binary_sha512 == $sha' --arg sha "${sha}"; then
        if [[ "$(jq -r '.verified' "${record}")" != true ]]; then
            echo "WARN: ${PQ_TOOL} was installed without verifying it against this orb's checksums (verify_checksums)." >&2
        fi
        return 0
    fi
    echo "WARN: ${PQ_TOOL} is not the $1 this orb's install verified." >&2
    echo "WARN: Install $1 with this orb's install, and put its install_path first on the PATH, to run a verified one." >&2
}

# pq_git_top: sets PQ_TOP to the top of the git checkout the working
# directory is in, and PQ_PREFIX to the working directory's path below it
# (empty, or ending in /), or stops the step.
pq_git_top() {
    if ! PQ_TOP=$(git rev-parse --show-toplevel 2> /dev/null) || [[ -z "${PQ_TOP}" ]]; then
        echo "ERROR: This command compares git revisions, and $(pwd) is not in a git checkout." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    PQ_PREFIX=$(git rev-parse --show-prefix)
}

# pq_from_top PATH: prints PATH, absolute or relative to the working
# directory, as a path relative to PQ_TOP, without following the symbolic
# links in PATH. The working directory is taken by its physical path, as git
# takes the top's. Stops the step when PATH is outside the checkout.
pq_from_top() {
    local path=$1
    if [[ "${path}" != /* ]]; then
        path="$(pwd -P)/${path}"
    fi
    path=$(realpath -ms --relative-to="${PQ_TOP}" -- "${path}")
    if [[ "${path}" == .. || "${path}" == ../* || "${path}" == /* ]]; then
        echo "ERROR: $1 is outside the git checkout ${PQ_TOP}." >&2
        exit 1
    fi
    printf '%s\n' "${path}"
}

# pq_args_json ARG...: the arguments as a JSON array. They pass through jq
# NUL-separated, so arguments that start with "-" never reach jq's own option
# parsing, and a URL among them loses its userinfo, query and fragment.
pq_args_json() {
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    # Ended by a word rather than a NUL, which jq 1.6 drops from the end of
    # raw input.
    { printf '%s\0' "$@"; printf 'end'; } | jq -Rsc 'split("\u0000") | .[:-1]
        | map(gsub("(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/?#\\s]*@"; "\(.scheme)")
            | gsub("(?<url>[A-Za-z][A-Za-z0-9+.-]*://[^?#\\s]*)[?#]\\S*"; "\(.url)"))'
}

# pq_show_command ARG...: the arguments as one line to log, each quoted for
# the shell only when it needs it, and URLs stripped as pq_args_json strips
# them.
pq_show_command() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi
    pq_args_json "$@" | jq -r 'map(if test("^[A-Za-z0-9_./:=@%+,-]+$") then . else @sh end) | join(" ")'
}

# pq_files PARAMETER: sets PQ_FILES to the files PQ_LIST names, each a path
# or a glob relative to the working directory. A pattern that matches no
# file fails the step: a typo would otherwise check nothing.
pq_files() {
    local pattern match matches
    PQ_FILES=()
    for pattern in ${PQ_LIST[@]+"${PQ_LIST[@]}"}; do
        matches=0
        while IFS= read -r match; do
            [[ -n "${match}" ]] || continue
            PQ_FILES+=("${match}")
            matches=$((matches + 1))
        done < <(compgen -G "${pattern}" | LC_ALL=C sort || true)
        if [[ "${matches}" -eq 0 || ( "${pattern}" != *[*?[]* && ! -f "${pattern}" ) ]]; then
            echo "ERROR: $1 names '${pattern}', but there is no such file in $(pwd)." >&2
            exit 1
        fi
    done
}

# pq_run_record FILE COMMAND OUTCOME EXIT_CODE STARTED: writes a run record,
# the JSON document schemas/run-record.v1.json describes, saying what exactly
# this command checked, so a reviewer can tell without running it again. It
# reads what the command set:
#   PQ_TOOL          the tool that ran, if any (the script install put on the PATH)
#   PQ_TOOL_VERSION  what it reports as its version
#   PQ_ARGS          the arguments it ran with, as an array
#   PQ_INPUTS        "role:path" entries, such as "lockfile:uv.lock"
#   PQ_REPORTS       the report files written
#   PQ_COUNTS        a JSON object of the command's counts
#   PQ_RESULTS       a JSON array of per-item results, such as one per input
#   PQ_TARGET_JSON   the environment checked, as JSON, if any
# OUTCOME is passed, findings, findings-reported (findings with report_only)
# or error.
pq_run_record() {
    local file=$1 entry path role sha inputs="[]" reports="[]" args
    for entry in ${PQ_INPUTS[@]+"${PQ_INPUTS[@]}"}; do
        role=${entry%%:*}
        path=${entry#*:}
        sha=""
        if [[ -f "${path}" ]]; then
            sha=$(pq_sha256 "${path}")
        fi
        if [[ -d "$(dirname "${path}")" ]]; then
            path=$(cd "$(dirname "${path}")" && pwd)/${path##*/}
        fi
        inputs=$(jq -c --arg role "${role}" --arg path "${path}" --arg sha "${sha}" \
            '. + [{role: $role, path: $path, sha256: (if $sha == "" then null else $sha end)}]' <<< "${inputs}")
    done
    for path in ${PQ_REPORTS[@]+"${PQ_REPORTS[@]}"}; do
        if [[ -f "${path}" ]]; then
            reports=$(jq -c --arg path "${path}" --arg sha "$(pq_sha256 "${path}")" '. + [{path: $path, sha256: $sha}]' <<< "${reports}")
        fi
    done
    args=$(pq_args_json ${PQ_ARGS[@]+"${PQ_ARGS[@]}"})
    if ! jq -n --arg command "$2" --arg outcome "$3" --argjson code "$4" --arg started "$5" \
        --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$(pwd)" --argjson ci "$(pq_ci_json)" \
        --argjson tool "$(if [[ -n "${PQ_TOOL:-}" ]]; then pq_tool_json "${PQ_TOOL}" "${PQ_TOOL_VERSION:-}"; else echo null; fi)" \
        --argjson target "${PQ_TARGET_JSON:-null}" \
        --argjson inputs "${inputs}" --argjson reports "${reports}" --argjson counts "${PQ_COUNTS:-null}" \
        --argjson results "${PQ_RESULTS:-null}" --argjson args "${args}" '{
            schema: "https://github.com/juburr/python-quality-orb/blob/main/schemas/run-record.v1.json",
            command: $command, outcome: $outcome, exit_code: $code,
            started_at: $started, finished_at: $finished, ci: $ci, working_directory: $cwd,
            tool: $tool, arguments: $args, target: $target,
            inputs: $inputs, counts: $counts, results: $results, reports: $reports
        }' > "${file}"; then
        echo "WARN: Could not write the run record ${file}." >&2
        return 0
    fi
    echo "Run record: ${file}"
}

# pq_py PYTHON COMMAND ARG...: runs the orb's Python helper
# (SCRIPT_PYTHON_QUALITY_PY, src/scripts/lib/python_quality.py) with PYTHON in
# isolated mode, so the job's PYTHONPATH and the working directory's modules
# stay out of it.
pq_py() {
    local python=$1
    shift
    "${python}" -I -c "${SCRIPT_PYTHON_QUALITY_PY}" "$@"
}

# pq_helper_python: sets PQ_PYTHON to the Python the helper runs on: the one
# the orb's install exported in PYTHON_QUALITY_ORB_PYTHON, or else python3 on
# the PATH. Stops the step if neither is Python 3.11 or newer, which reads
# TOML.
pq_helper_python() {
    PQ_PYTHON=${PYTHON_QUALITY_ORB_PYTHON:-}
    if [[ -z "${PQ_PYTHON}" || ! -x "${PQ_PYTHON}" ]]; then
        PQ_PYTHON=$(command -v python3 || true)
    fi
    if [[ -z "${PQ_PYTHON}" ]] || ! "${PQ_PYTHON}" -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2> /dev/null; then
        echo "ERROR: This command needs Python 3.11 or newer: install it in an earlier step with this orb's install" >&2
        echo "  (tools: python, or any Python tool), or use an image with python3." >&2
        exit 1
    fi
}

# pq_environment PARAMETER VALUE: sets PQ_ENVIRONMENT to the interpreter of
# the project's environment, which VALUE names: the interpreter itself, or
# the environment's directory (VALUE/bin/python), made absolute without
# following links, since a virtual environment's python is a link to the
# interpreter it was made with. Sets PQ_ENV_VERSION to its X.Y. Stops the
# step when it doesn't run.
pq_environment() {
    local python=$2
    if [[ -d "${python}" && -x "${python%/}/bin/python" ]]; then
        python=${python%/}/bin/python
    fi
    if [[ -z "${python}" || -d "${python}" || ! -x "${python}" ]]; then
        echo "ERROR: ${1} must be the project's environment, with its dependencies installed: a directory such as" >&2
        echo "  .venv, or an interpreter such as .venv/bin/python. '$2' is neither in $(pwd). Create it in an" >&2
        echo "  earlier step, such as with uv sync, poetry install, or python -m venv and pip install." >&2
        exit 1
    fi
    if [[ "${python}" != /* ]]; then
        python="$(cd "$(dirname "${python}")" && pwd)/${python##*/}"
    fi
    if ! PQ_ENV_VERSION=$("${python}" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2> /dev/null) \
        || ! pq_match "${PQ_ENV_VERSION}" '^3\.[0-9]+$'; then
        echo "ERROR: ${python} (${1}) does not run as a Python 3 interpreter." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    PQ_ENVIRONMENT=${python}
}

# pq_paths FILE: adds to each finding in FILE, a JSON array whose findings
# carry the "file" the tool named, a "path" relative to the working directory
# (when the file is below it) to show, and a "uri" relative to the top of the
# git checkout (or a file:// URI outside one) for SARIF, percent-encoded.
pq_paths() {
    local top prefix=""
    if top=$(git rev-parse --show-toplevel 2> /dev/null); then
        prefix=$(git rev-parse --show-prefix)
    else
        top=""
    fi
    # shellcheck disable=SC2016 # jq program, not shell
    jq --arg cwd "$(pwd -P)" --arg cwdl "$(pwd)" --arg top "${top}" --arg prefix "${prefix}" '
        def under($base): if $base != "" and startswith($base + "/") then .[($base | length) + 1:] else null end;
        def encode: split("/") | map(@uri) | join("/");
        map(.file as $f
            | ($f | if startswith("/") then (under($cwd) // under($cwdl) // .) else sub("^(\\./)+"; "") end) as $path
            | . + {path: $path,
                   uri: (if ($path | startswith("/")) then ($path | (under($top) | if . then encode else null end) // ("file://" + encode))
                         else ($prefix + $path | encode) end)})' "$1" > "$1.paths"
    mv -f "$1.paths" "$1"
}

# pq_print_findings FILE [MAX]: prints the findings in FILE (pq_paths' form,
# with "line", "column", "level", "rule" and "message"), one per line, at most
# MAX (default 50) of them.
pq_print_findings() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --argjson max "${2:-50}" '
        .[:$max][] | "  \(.path)\(if .line then ":\(.line)" + (if .column then ":\(.column)" else "" end) else "" end):"
            + " \(.level) \(.rule // "-"): \(.message | split("\n")[0])"' "$1"
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --argjson max "${2:-50}" 'if length > $max then "  ... and \(length - $max) more, in the reports." else empty end' "$1"
}

# pq_sarif FILE OUT TOOL VERSION URI: writes SARIF 2.1.0 to OUT from the
# findings in FILE (pq_paths' form, with "level" error, warning or note,
# "rule", "message", "line" and "column" 1-based or null, "end_line",
# "end_column" and "url" optional). Every finding is a result, at its level.
pq_sarif() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq --arg tool "$3" --arg version "$4" --arg uri "$5" '
        . as $all
        | ([.[].rule | select(. != null)] | unique) as $rules
        | {"$schema": "https://json.schemastore.org/sarif-2.1.0.json", version: "2.1.0",
           runs: [{
             tool: {driver: ({name: $tool, informationUri: $uri,
                              rules: [$rules[] as $r
                                  | {id: $r, name: $r, shortDescription: {text: $r}}
                                    + (first($all[] | select(.rule == $r and (.url // "") != "") | {helpUri: .url}) // {})]}
                             + (if $version != "" then {version: $version} else {} end))},
             results: [.[] | {
                 ruleId: (.rule // "unknown"),
                 level: (if .level == "error" or .level == "warning" or .level == "note" then .level else "warning" end),
                 message: {text: .message},
                 locations: [{physicalLocation: ({artifactLocation: {uri: .uri}}
                     + (if (.line // 0) > 0 then {region: ({startLine: .line}
                         + (if (.column // 0) > 0 then {startColumn: .column} else {} end)
                         + (if (.end_line // 0) >= .line then {endLine: .end_line} else {} end)
                         + (if (.end_line // 0) >= .line and (.end_column // 0) > 0
                               and (.end_line > .line or .end_column > (.column // 0)) then {endColumn: .end_column} else {} end))}
                        else {} end))}]}]
           }]}' "$1" > "$2"
}

# pq_findings_junit FILE OUT SUITE: writes JUnit to OUT from the findings in
# FILE: a failed case for each finding that counts ("finding": true), a
# skipped one for the others.
pq_findings_junit() {
    # shellcheck disable=SC2016 # jq program, not shell
    pq_junit "$2" "$3" "$(jq -c 'map({classname: .path,
        name: "\(.rule // "-") at \(.line // 1):\(.column // 1)",
        status: (if .finding then "failed" else "skipped" end),
        message: (.message | split("\n")[0]), detail: .message})' "$1")"
}

# pq_extra_args PARAMETER TOOL REFUSED_LONG REFUSED_SHORT VALUE_LONG VALUE_SHORT:
# checks the words pq_words put in PQ_WORDS, the options a command passes on to
# TOOL. It stops the step on:
#   - a long option named in REFUSED_LONG (space-separated names without the
#     dashes), or a short one whose letter is in REFUSED_SHORT, also inside a
#     group such as -qv: the command sets them itself, or they would change
#     what is checked or how the report reads;
#   - a word that isn't an option, which the tool would read as another path
#     to check (the command has a parameter for those), and "--" or "@file",
#     after which it would;
#   - an option that ends extra_args without the value it takes.
# VALUE_LONG and VALUE_SHORT name the options that take a value as the next
# word, which is skipped. An option the command doesn't know takes its value
# as --option=value.
pq_extra_args() {
    local word name letters letter i expect=false
    for word in ${PQ_WORDS[@]+"${PQ_WORDS[@]}"}; do
        if [[ "${expect}" == true ]]; then
            expect=false
            continue
        fi
        case "${word}" in
            --)
                echo "ERROR: ${1} can't hold '--': ${2} would read every word after it as a path to check." >&2
                exit 1
                ;;
            --*)
                name=${word#--}
                name=${name%%=*}
                if [[ " ${3} " == *" ${name} "* ]]; then
                    echo "ERROR: ${1} can't hold '${word}': the command sets it, or it would change what is checked" >&2
                    echo "  or how the report reads." >&2
                    exit 1
                fi
                if [[ " ${5} " == *" ${name} "* && "${word}" != *=* ]]; then
                    expect=true
                fi
                ;;
            -?*)
                letters=${word#-}
                for ((i = 0; i < ${#letters}; i++)); do
                    letter=${letters:i:1}
                    if [[ -n "${4}" && "${4}" == *"${letter}"* ]]; then
                        echo "ERROR: ${1} can't hold '${word}': the command sets -${letter}, or it would change what is" >&2
                        echo "  checked or how the report reads." >&2
                        exit 1
                    fi
                    if [[ -n "${6}" && "${6}" == *"${letter}"* ]]; then
                        if ((i == ${#letters} - 1)); then
                            expect=true
                        fi
                        break
                    fi
                done
                ;;
            *)
                echo "ERROR: ${1} can't hold '${word}', which ${2} would read as a path to check. Name what to check" >&2
                echo "  in the command's parameters, and give an option's value as --option=value." >&2
                exit 1
                ;;
        esac
    done
    if [[ "${expect}" == true ]]; then
        echo "ERROR: ${1} ends in an option without its value." >&2
        exit 1
    fi
}

# pq_tool_python NAME: sets PQ_TOOL_PYTHON to the Python of the environment
# this orb's install made for NAME, which the script PQ_TOOL (pq_tool NAME)
# runs, read from that script's exec line. Stops the step when PQ_TOOL isn't
# such a script.
pq_tool_python() {
    local line
    line=$(awk 'NR == 3' "${PQ_TOOL}" 2> /dev/null || true)
    if [[ "$(awk 'NR == 2' "${PQ_TOOL}" 2> /dev/null || true)" != *"installed by python-quality-orb"* ]] \
        || ! pq_match "${line}" "^exec '(/[^']+/bin/python)' -I -m [A-Za-z_]+ \"\\\$@\"\$" \
        || [[ ! -x "${BASH_REMATCH[1]}" ]]; then
        echo "ERROR: ${PQ_TOOL} is not the $1 this orb's install_${1//-/_} installs, and this command needs that one:" >&2
        echo "  it runs code in $1's own environment. Install it with this orb's install (tools: $1)." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    PQ_TOOL_PYTHON=${BASH_REMATCH[1]}
}

# pq_finding_counts FILE: prints the counts of the findings in FILE (pq_paths'
# form) as JSON: by level, and how many count ("finding": true).
pq_finding_counts() {
    jq -c '{total: length, findings: [.[] | select(.finding)] | length,
        error: [.[] | select(.level == "error")] | length,
        warning: [.[] | select(.level == "warning")] | length,
        note: [.[] | select(.level == "note")] | length}' "$1"
}

# pq_ruff_findings IN OUT: turns Ruff's JSON diagnostics (ruff check or ruff
# format --check, --output-format json) into findings, adding "kind": "lint"
# for a rule's diagnostic (its code is a rule code such as E501),
# "unformatted" for a file the formatter would change, "syntax" for a file
# Ruff couldn't parse, and "error" for anything else (an unreadable file, a
# panic). Ruff's preview mode writes no code for diagnostics that aren't a
# rule's, and its "name" is always the diagnostic's kind.
pq_ruff_findings() {
    jq '[.[] | {
        file: (.filename // "-"), line: .location.row, column: .location.column,
        end_line: .end_location.row, end_column: .end_location.column,
        rule: (.code // .name), name: .name, message: (.message // ""), url: .url,
        fixable: (.fix != null),
        kind: (if .name == "unformatted" then "unformatted"
               elif .name == "invalid-syntax" then "syntax"
               elif .name == "io-error" then "error"
               elif ((.code // "") | test("^[A-Z]+[0-9]+$")) then "lint"
               else "error" end),
        level: "error"}
        | . + {finding: (.kind == "lint" or .kind == "unformatted")}]' "$1" > "$2"
}

# pq_ruff_env: sets PQ_RUFF_ENV to the env arguments that run Ruff without the
# job's RUFF_* variables, which could send its report elsewhere, change its
# format, or point its cache at files the job doesn't own. Its configuration
# files still apply: they are the project's policy.
pq_ruff_env() {
    local name
    PQ_RUFF_ENV=()
    while IFS= read -r name; do
        if [[ "${name}" == RUFF_* ]]; then
            PQ_RUFF_ENV+=(-u "${name}")
        fi
    done < <(compgen -e)
}
