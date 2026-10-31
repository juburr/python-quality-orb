#!/usr/bin/env bash
#
# Tests the command scripts offline, each run by tests/run_command.sh with its
# parameters' defaults from the command's YAML, against stand-ins that record
# every call (arguments, working directory, and the environment that
# matters) and answer from the fixtures in tests/fixtures/stubs:
#
#   - shell stand-ins for Ruff, ty, Pyright, uv, twine and
#     check-wheel-contents, as the orb's install puts them on the PATH;
#   - Python stand-ins (tests/fixtures/fake) for mypy, deptry, Griffe, pytest
#     and coverage.py, run by stand-in interpreters (the real python3 with
#     the stand-ins first on its import path): the project's environment
#     (.venv) and the environments the orb's install makes for mypy, deptry
#     and Griffe, with the scripts that run them.
#
# It checks each command's arguments, the configuration and environment
# variables the tools may not read, the gate (findings, report_only, fail_on),
# every way a run can end without a verdict, the reports (JSON, SARIF, JUnit)
# and the extra_args each refuses. The helper (src/scripts/lib/python_quality.py)
# runs for real, on the python3 on the PATH (3.11 or newer). api_compat runs
# in a real git repository with an origin. Every run record is checked against
# schemas/run-record.v1.json. The scripts run with the bash first on the PATH,
# so putting an older bash there checks it. A stand-in circleci CLI expands
# $ORB_TEST_VAR.
#
# Run from a checkout:
#   bash <this file>

# The checks run small scripts in single quotes, which expand their own
# arguments.
# shellcheck disable=SC2016

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
FIX="${ROOT}/tests/fixtures"
STUBS="${FIX}/stubs"
FAKE="${FIX}/fake"

if ! python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2> /dev/null; then
    echo "FAIL: these tests need python3 3.11 or newer on the PATH, which the orb's helper runs on."
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUB="${WORK}/stub"
HOME_DIR="${WORK}/home"
JOB="${WORK}/job"
OUT="${WORK}/reports"
mkdir -p "${WORK}/bin" "${STUB}/calls" "${HOME_DIR}"

# The PATH without a real circleci CLI, which CircleCI's images have, or a
# real tool: a directory that holds one is replaced by one with links to
# everything else in it.
TOOL_NAMES=" circleci ruff ty mypy pyright deptry griffe twine check-wheel-contents uv "
CLEAN_PATH=""
IFS=: read -ra PATH_DIRS <<< "${PATH}"
for dir in "${PATH_DIRS[@]}"; do
    [[ -d "${dir}" ]] || continue
    found=false
    for file in "${dir}"/*; do
        if [[ "${TOOL_NAMES}" == *" ${file##*/} "* ]]; then
            found=true
            break
        fi
    done
    if [[ "${found}" == true ]]; then
        shadow=$(mktemp -d "${WORK}/path.XXXXXX")
        for file in "${dir}"/*; do
            [[ "${TOOL_NAMES}" == *" ${file##*/} "* ]] || ln -s "${file}" "${shadow}/"
        done
        dir=${shadow}
    fi
    CLEAN_PATH+="${CLEAN_PATH:+:}${dir}"
done

# Like `circleci env subst`, expands $NAME and ${NAME} references, from stdin.
cat > "${WORK}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "tests split" ]]; then
    # The share of node CIRCLE_NODE_INDEX: every other file.
    awk -v n="${CIRCLE_NODE_INDEX:-0}" -v total="${CIRCLE_NODE_TOTAL:-1}" '(NR - 1) % total == n'
    printf '%s\n' "$*" >> "${STUB_DIR}/split.log"
    exit 0
fi
if [[ "$*" != "env subst" ]]; then
    echo "circleci stub: expected 'env subst' with the value on stdin, got: $*" >&2
    exit 1
fi
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s' "${output}${input}"
EOF

# The common part of every shell stand-in: records the call.
cat > "${WORK}/record.sh" << 'EOF'
set +o errexit +o nounset +o pipefail +o xtrace
calls="${STUB_DIR}/calls"
n=$(($(find "${calls}" -name '*.args' | wc -l) + 1))
printf '%s\n' "${0##*/}" "$@" > "${calls}/${n}.args"
{
    printf 'cwd=%s\n' "${PWD}"
    env | grep -E '^(RUFF_|TY_|PYRIGHT_|XDG_CONFIG_HOME=|CI_PROJECT_DIR=|COLUMNS=|NO_COLOR=)' | sort
} > "${calls}/${n}.meta"
args=("$@")
# opt NAME: the value of --NAME VALUE or --NAME=VALUE.
opt() {
    local i
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            "--$1") printf '%s\n' "${args[i + 1]}"; return 0 ;;
            "--$1="*) printf '%s\n' "${args[i]#*=}"; return 0 ;;
        esac
    done
    return 1
}
# fixture FILE: FILE with @JOB@ replaced by the working directory, as the
# tools write absolute paths.
fixture() {
    sed "s|@JOB@|${PWD}|g" "$1"
}
EOF

# The stand-in Ruff. Settings:
#   STUB_RUFF_JSON   what check or format --check prints (default [])
#   STUB_RUFF_EXIT   its exit code (default 1 when it prints a diagnostic)
#   STUB_RUFF_LOG    what it prints on stderr
cat > "${WORK}/bin/ruff" << 'EOF'
#!/usr/bin/env bash
source "${STUB_RECORD}"
if [[ "$1" == --version ]]; then
    echo "ruff 0.17.2"
    exit 0
fi
[[ -n "${STUB_RUFF_LOG:-}" ]] && printf '%s\n' "${STUB_RUFF_LOG}" >&2
if [[ " $* " == *" --diff "* ]]; then
    printf -- '--- src/demo/__init__.py\n+++ src/demo/__init__.py\n@@ -3 +3 @@\n-x  =  1\n+x = 1\n'
    exit 1
fi
if [[ -n "${STUB_RUFF_JSON:-}" ]]; then
    fixture "${STUB_RUFF_JSON}"
    exit "${STUB_RUFF_EXIT:-1}"
fi
echo '[]'
exit "${STUB_RUFF_EXIT:-0}"
EOF

# The stand-in ty. STUB_TY_JSON, STUB_TY_EXIT and STUB_TY_LOG as for Ruff.
cat > "${WORK}/bin/ty" << 'EOF'
#!/usr/bin/env bash
source "${STUB_RECORD}"
if [[ "$1" == --version ]]; then
    echo "ty 0.0.91"
    exit 0
fi
[[ -n "${STUB_TY_LOG:-}" ]] && printf '%s\n' "${STUB_TY_LOG}" >&2
if [[ -n "${STUB_TY_JSON:-}" ]]; then
    fixture "${STUB_TY_JSON}"
    exit "${STUB_TY_EXIT:-1}"
fi
echo '[]'
exit "${STUB_TY_EXIT:-0}"
EOF

# The stand-in Pyright. STUB_PYRIGHT_JSON (default nothing found in 3 files)
# and STUB_PYRIGHT_EXIT (default 1 when the JSON counts an error).
cat > "${WORK}/bin/pyright" << 'EOF'
#!/usr/bin/env bash
source "${STUB_RECORD}"
if [[ "$1" == --version ]]; then
    echo "pyright 1.1.414"
    exit 0
fi
if [[ -n "${STUB_PYRIGHT_JSON:-}" ]]; then
    fixture "${STUB_PYRIGHT_JSON}"
    errors=$(fixture "${STUB_PYRIGHT_JSON}" | jq '.summary.errorCount')
else
    printf '{"version":"1.1.414","generalDiagnostics":[],"summary":{"filesAnalyzed":%s,"errorCount":0,"warningCount":0,"informationCount":0}}\n' "${STUB_PYRIGHT_FILES:-3}"
    errors=0
fi
if [[ -n "${STUB_PYRIGHT_EXIT:-}" ]]; then
    exit "${STUB_PYRIGHT_EXIT}"
fi
[[ "${errors}" -gt 0 ]] && exit 1
exit 0
EOF

# The stand-in uv: --version, and build, which writes an sdist and a wheel
# (STUB_UV_NO_WHEEL leaves the wheel out; STUB_UV_EXIT fails the build).
cat > "${WORK}/bin/uv" << 'EOF'
#!/usr/bin/env bash
source "${STUB_RECORD}"
if [[ "$1" == --version ]]; then
    echo "uv 0.13.6"
    exit 0
fi
if [[ "$1" == build ]]; then
    if [[ -n "${STUB_UV_EXIT:-}" ]]; then
        echo "error: Failed to build \`demo @ ${PWD}\`" >&2
        exit "${STUB_UV_EXIT}"
    fi
    out=$(opt out-dir)
    mkdir -p "${out}"
    echo "Building source distribution..." >&2
    printf 'sdist\n' > "${out}/demo-1.0.tar.gz"
    if [[ -z "${STUB_UV_NO_WHEEL:-}" ]]; then
        printf 'wheel\n' > "${out}/demo-1.0-py3-none-any.whl"
    fi
    echo "Successfully built ${out}/demo-1.0.tar.gz" >&2
    exit 0
fi
echo "uv stub: unexpected $*" >&2
exit 2
EOF

# The stand-in twine, which prints rich's escape codes as it does with its
# terminal forced. STUB_TWINE_FAIL: a glob of the distributions it fails;
# STUB_TWINE_CRASH: it fails before checking.
cat > "${WORK}/bin/twine" << 'EOF'
#!/usr/bin/env bash
source "${STUB_RECORD}"
[[ "$1" == --no-color ]] && shift
if [[ "$1" == --version ]]; then
    echo "twine version 7.0.0 (keyring: 25.6.0, packaging: 25.0, requests: 2.32.5)"
    exit 0
fi
file=${!#}
if [[ -n "${STUB_TWINE_CRASH:-}" ]]; then
    echo "InvalidDistribution: Unknown distribution format: '${file##*/}'"
    exit 1
fi
printf 'Checking %s: ' "${file}"
# shellcheck disable=SC2053 # a glob
if [[ -n "${STUB_TWINE_FAIL:-}" && "${file##*/}" == ${STUB_TWINE_FAIL} ]]; then
    printf '\033[31mFAILED\033[0m\n'
    printf '\033[31mERROR   \033[0m `long_description` has syntax errors in markup and would not be rendered on PyPI.\n'
    printf '         line 3: Error: Unexpected indentation.\n'
    exit 1
fi
printf '\033[32mPASSED\033[0m\n'
exit 0
EOF

# The stand-in check-wheel-contents. STUB_CWC_FAIL: a glob of the wheels it
# fails; STUB_CWC_INVALID: it can't read the wheel.
cat > "${WORK}/bin/check-wheel-contents" << 'EOF'
#!/usr/bin/env bash
source "${STUB_RECORD}"
if [[ "$1" == --version ]]; then
    echo "check-wheel-contents 0.6.3"
    exit 0
fi
file=${!#}
if [[ -n "${STUB_CWC_INVALID:-}" ]]; then
    echo "${file}: invalid wheel: File is not a zip file" >&2
    exit 1
fi
# shellcheck disable=SC2053 # a glob
if [[ -n "${STUB_CWC_FAIL:-}" && "${file##*/}" == ${STUB_CWC_FAIL} ]]; then
    printf '%s: W002: Wheel contains duplicate files:\n  demo/a.py\n  demo/b.py\n' "${file}"
    printf '%s: W009: Wheel contains multiple toplevel library entries:\n  demo/\n  tests/\n' "${file}"
    exit 1
fi
echo "${file}: OK"
exit 0
EOF

# The stand-in interpreter: the real python3, with tests/fixtures/fake first
# on its import path, and the modules STUB_HIDE names made unimportable.
# Asked for its packages' directory (sysconfig), it names the stand-ins'.
cat > "${WORK}/python" << EOF
#!/usr/bin/env bash
export STUB_FAKE='${FAKE}'
EOF
cat >> "${WORK}/python" << 'EOF'
BOOT='import os, sys
sys.path.insert(0, os.environ["STUB_FAKE"])
for name in os.environ.get("STUB_HIDE", "").split():
    sys.modules[name] = None
'
if [[ "$1" == -I && "$2" == -c ]]; then
    if [[ "$3" == *sysconfig* ]]; then
        echo "${STUB_FAKE}"
        exit 0
    fi
    code=$3
    shift 3
    exec python3 -I -B -c "${BOOT}"'
code = sys.argv.pop(1)
exec(compile(code, "<string>", "exec"), {"__name__": "__main__"})' "${code}" "$@"
fi
[[ "$1" == -I ]] && shift
if [[ "$1" == -m ]]; then
    module=$2
    shift 2
    exec python3 -I -B -c "${BOOT}"'
import runpy
module = sys.argv.pop(1)
sys.argv[0] = module
runpy.run_module(module, run_name="__main__", alter_sys=True)' "${module}" "$@"
fi
exec python3 -B "$@"
EOF
chmod +x "${WORK}/bin/"* "${WORK}/python"
# The environments the orb's install makes, and the scripts that run them.
for entry in mypy:mypy deptry:deptry griffe:griffecli; do
    tool=${entry%%:*}
    mkdir -p "${WORK}/venvs/${tool}/bin"
    cp "${WORK}/python" "${WORK}/venvs/${tool}/bin/python"
    printf "#!/bin/sh\n# %s, installed by python-quality-orb in %s.\nexec '%s' -I -m %s \"\$@\"\n" \
        "${tool}" "${WORK}/venvs/${tool}" "${WORK}/venvs/${tool}/bin/python" "${entry#*:}" > "${WORK}/bin/${tool}"
    chmod +x "${WORK}/bin/${tool}"
done

# --- The job: a project in a git checkout with an origin, on a branch ---
git_q() { git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main "$@" > /dev/null 2>&1; }
git_q init --bare "${WORK}/origin.git"
git_q init "${JOB}"
mkdir -p "${JOB}/src/demo" "${JOB}/tests" "${JOB}/src/demo/_compat"
cat > "${JOB}/pyproject.toml" << 'EOF'
[project]
name = "demo"
version = "1.0"
dependencies = ["requests"]
EOF
printf 'def greet(name, punctuation="!"):\n    return name + punctuation\n\n\ndef farewell():\n    return "bye"\n' > "${JOB}/src/demo/__init__.py"
printf 'def shim():\n    return ""\n' > "${JOB}/src/demo/_compat/__init__.py"
printf 'def test_one():\n    assert True\n' > "${JOB}/tests/test_demo.py"
printf '.venv/\n' > "${JOB}/.gitignore"
git_q -C "${JOB}" add -A
git_q -C "${JOB}" commit -m base
git_q -C "${JOB}" remote add origin "${WORK}/origin.git"
git_q -C "${JOB}" push origin main
git_q -C "${JOB}" remote set-head origin main
git_q -C "${JOB}" checkout -b feature
printf 'def greet(name):\n    return name\n' > "${JOB}/src/demo/__init__.py"
mkdir -p "${JOB}/src/newpkg"
printf 'VALUE = 1\n' > "${JOB}/src/newpkg/__init__.py"
git_q -C "${JOB}" add -A
git_q -C "${JOB}" commit -m feature
# The project's environment.
mkdir -p "${JOB}/.venv/bin"
cp "${WORK}/python" "${JOB}/.venv/bin/python"

FAILURES=0
RC=0
OUTPUT=""

# run COMMAND [NAME=VALUE ...] [-- VAR=value ...]: runs COMMAND's script in
# the job directory through tests/run_command.sh, with the parameters given
# and the environment settings after --. Recorded calls and BASH_ENV start
# empty, and output_dir is OUT unless given.
RECORDS=0
mkdir -p "${WORK}/records"
run() {
    local command=$1 params=() envs=() record
    shift
    while [[ $# -gt 0 && "$1" != -- ]]; do
        params+=("$1")
        shift
    done
    if [[ $# -gt 0 ]]; then
        shift
        envs=("$@")
    fi
    if [[ " ${params[*]-} " != *" output_dir="* ]]; then
        params=("output_dir=${OUT}" ${params[@]+"${params[@]}"})
    fi
    rm -rf "${STUB}/calls" "${STUB}/split.log" "${OUT}"
    mkdir -p "${STUB}/calls"
    : > "${WORK}/bash_env"
    OUTPUT=$(cd "${JOB}" && env -u GITHUB_BASE_REF -u GITHUB_ACTIONS -u CIRCLE_BUILD_URL -u CIRCLE_NODE_TOTAL \
        -u CIRCLE_NODE_INDEX -u PYTHON_QUALITY_ORB_PYTHON -u VIRTUAL_ENV HOME="${HOME_DIR}" \
        PATH="${WORK}/bin:${CLEAN_PATH}" BASH_ENV="${WORK}/bash_env" STUB_DIR="${STUB}" STUB_FIXTURES="${STUBS}" \
        STUB_RECORD="${WORK}/record.sh" ${envs[@]+"${envs[@]}"} \
        bash "${ROOT}/tests/run_command.sh" "${command}" ${params[@]+"${params[@]}"} 2>&1)
    RC=$?
    for record in "${OUT}"/*.run-record.json; do
        [[ -f "${record}" ]] || continue
        RECORDS=$((RECORDS + 1))
        cp "${record}" "${WORK}/records/${RECORDS}.json"
    done
}

check() {
    local description=$1 call
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        while IFS= read -r line; do
            printf '    | %s\n' "${line}"
        done <<< "${OUTPUT}"
        for call in "${STUB}/calls/"*.args; do
            [[ -f "${call}" ]] || continue
            printf '    call %s: %s\n' "$(basename "${call}" .args)" "$(tr '\n' ' ' < "${call}")"
        done
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is() { [[ "${RC}" -eq "$1" ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
script_lacks() { ! grep -v '^Running scripts/' <<< "${OUTPUT}" | grep -qF -- "$1"; }
no_call() { ! call "$1" "$2" > /dev/null; }
# any_call TOOL ARG...: some call of TOOL got these arguments, in this order,
# next to each other.
any_call() {
    local file tool=$1
    shift
    for file in "${STUB}/calls/"*.args; do
        [[ -f "${file}" && "$(sed -n 1p "${file}")" == "${tool}" ]] || continue
        if WANT=$(printf '%s\n' "$@") awk '
            BEGIN { n = split(ENVIRON["WANT"], want, "\n") }
            NR > 1 { line[NR] = $0 }
            END {
                for (i = 2; i + n - 1 <= NR; i++) {
                    found = 1
                    for (j = 1; j <= n; j++) if (line[i + j - 1] != want[j]) { found = 0; break }
                    if (found) exit 0
                }
                exit 1
            }' "${file}"; then
            return 0
        fi
    done
    return 1
}
no_calls() { [[ -z "$(find "${STUB}/calls" -name '*.args')" ]]; }
call_count() { [[ "$(find "${STUB}/calls" -name '*.args' | wc -l)" -eq "$1" ]]; }
# call TOOL WORD: the arguments file of the first call of TOOL with WORD as
# its first argument.
call() {
    local file
    for file in $(find "${STUB}/calls" -name '*.args' | sort -t/ -k1 -V); do
        if [[ "$(sed -n 1p "${file}")" == "$1" && "$(sed -n 2p "${file}")" == "$2" ]]; then
            printf '%s\n' "${file}"
            return 0
        fi
    done
    return 1
}
# calls_of TOOL WORD: how many calls of TOOL with WORD as their first argument.
calls_of() {
    local file n=0
    for file in "${STUB}/calls/"*.args; do
        [[ -f "${file}" ]] || continue
        if [[ "$(sed -n 1p "${file}")" == "$1" && "$(sed -n 2p "${file}")" == "$2" ]]; then
            n=$((n + 1))
        fi
    done
    printf '%s\n' "${n}"
}
# has TOOL WORD ARG...: the first such call got these arguments, in this
# order, next to each other.
has() {
    local file
    file=$(call "$1" "$2") || return 1
    shift 2
    # One argument per line; the arguments wanted, one per line too, must be
    # consecutive lines. (grep -F would take each line as another pattern.)
    WANT=$(printf '%s\n' "$@") awk '
        BEGIN { n = split(ENVIRON["WANT"], want, "\n") }
        { line[NR] = $0 }
        END {
            for (i = 1; i + n - 1 <= NR; i++) {
                found = 1
                for (j = 1; j <= n; j++) if (line[i + j - 1] != want[j]) { found = 0; break }
                if (found) exit 0
            }
            exit 1
        }' "${file}"
}
lacks() {
    local file
    file=$(call "$1" "$2") || return 1
    ! grep -qxF -- "$3" "${file}"
}
# meta TOOL WORD LINE: the first such call's recorded working directory or
# environment has LINE.
meta() {
    local file
    file=$(call "$1" "$2") || return 1
    grep -qxF -- "$3" "${file%.args}.meta"
}
no_meta() {
    local file
    file=$(call "$1" "$2") || return 1
    ! grep -q -- "$3" "${file%.args}.meta"
}
report() { [[ -s "${OUT}/$1" ]]; }
no_report() { [[ ! -e "${OUT}/$1" ]]; }
json_is() { [[ "$(jq -c "$2" "$1" 2> /dev/null)" == "$3" ]]; }
report_is() { json_is "${OUT}/$1" "$2" "$3"; }
junit_has() { grep -qF -- "$1" "${OUT}/junit/$2.xml"; }

echo "=== fmt"
run fmt -- RUFF_OUTPUT_FORMAT=text RUFF_CACHE_DIR=/elsewhere
check "formatted code passes" rc_is 0
check "Ruff checks without writing, as JSON, without a cache" has ruff format --no-cache --check --output-format json --
check "the job's RUFF_* variables never reach Ruff" no_meta ruff format "^RUFF_"
check "the findings report is written" report_is fmt.json 'length' '0'
check "and SARIF" report_is fmt.sarif '.runs[0].tool.driver.name' '"Ruff"'
run fmt paths="src tests" config=pyproject.toml -- STUB_RUFF_JSON="${STUBS}/ruff-format.json"
check "an unformatted file fails the step" rc_is 1
check "naming it, relative to the working directory" said "  src/demo/__init__.py"
check "and how to fix it" said "Run ruff format to fix them."
check "with the configuration and paths given" has ruff format --no-cache --config pyproject.toml --check --output-format json -- src tests
check "the report holds it" report_is fmt.json '[.[] | .path, .kind, .finding]' '["src/demo/__init__.py","unformatted",true]'
check "SARIF locates it from the top of the checkout" report_is fmt.sarif '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' '"src/demo/__init__.py"'
check "the diff is written for people" report fmt.diff
check "JUnit has a failed case" junit_has '<failure message="File would be reformatted"' fmt
run fmt report_only=true -- STUB_RUFF_JSON="${STUBS}/ruff-format.json"
check "report_only passes with findings" rc_is 0
check "saying so" said "report_only is true, so this step passes"
run fmt report_only=true -- STUB_RUFF_JSON="${STUBS}/ruff-syntax.json" STUB_RUFF_EXIT=2
check "a file Ruff can't parse fails the step, report_only or not" rc_is 1
check "saying how to leave it out" said "extend-exclude"
check "and which file" said "src/demo/broken.py"
run fmt -- STUB_RUFF_LOG="warning: No Python files found under the given path(s)"
check "no Python file to check fails the step" rc_is 1
check "saying nothing was checked" said "Ruff found no Python file to check"
run fmt allow_empty=true -- STUB_RUFF_LOG="warning: No Python files found under the given path(s)"
check "unless allow_empty" rc_is 0
run fmt -- STUB_RUFF_EXIT=2 STUB_RUFF_JSON=/dev/null
check "a run with no report fails" rc_is 1
check "saying it isn't a result" said "This is not a formatting result."
run fmt paths=missing
check "a path that doesn't exist is refused" rc_is 1
check "before Ruff runs" no_calls
for value in --check --diff "--output-format=text" -s -q --quiet --no-cache "--cache-dir=/x" @args.txt "src" "--line-length 100 extra"; do
    run fmt extra_args="${value}"
    check "fmt refuses extra_args '${value}'" rc_is 1
    check "fmt: before Ruff runs (${value})" no_calls
done
run fmt extra_args="--line-length 100 --preview"
check "fmt takes Ruff's own options with their values" has ruff format --no-cache --line-length 100 --preview --check

echo "=== lint"
run lint -- RUFF_OUTPUT_FILE=/tmp/elsewhere.json
check "clean code passes" rc_is 0
check "Ruff never fixes a file" has ruff check --no-fix --no-fix-only --no-cache
check "and writes JSON to the orb" has ruff check --output-format json --
check "the job's RUFF_* variables never reach Ruff" no_meta ruff check "^RUFF_"
run lint run_record=true -- STUB_RUFF_JSON="${STUBS}/ruff-check.json"
check "a diagnostic fails the step" rc_is 1
check "each is printed with its rule" said "  src/demo/__init__.py:1:8: error F401: \`os\` imported but unused"
check "with what --fix can do" said "1 of them can be fixed with ruff check --fix."
check "the report keeps the rule's URL" report_is lint.json '.[0].url' '"https://docs.astral.sh/ruff/rules/unused-import"'
check "SARIF names the rules" report_is lint.sarif '[.runs[0].tool.driver.rules[].id] | sort' '["E711","F401"]'
check "with their documentation" report_is lint.sarif '.runs[0].tool.driver.rules[] | select(.id == "F401") | .helpUri' '"https://docs.astral.sh/ruff/rules/unused-import"'
check "and regions" report_is lint.sarif '.runs[0].results[1].locations[0].physicalLocation.region' '{"startLine":4,"startColumn":16,"endLine":4,"endColumn":20}'
check "the run record counts them by rule" report_is lint.run-record.json '.counts.rules' '{"E711":1,"F401":1}'
check "and names Ruff" report_is lint.run-record.json '.tool.name + " " + .tool.version' '"ruff 0.17.2"'
run lint -- STUB_RUFF_JSON="${STUBS}/ruff-syntax.json"
check "a file Ruff can't parse fails the step" rc_is 1
check "as unchecked code" said "Ruff could not read or parse 1 file, so they went unchecked"
run lint report_only=true -- STUB_RUFF_LOG="warning: Failed to lint src/demo/secret.py: Permission denied (os error 13)"
check "a file Ruff can't read, which it only warns about, fails the step, report_only or not" rc_is 1
run lint -- STUB_RUFF_EXIT=1
check "exit 1 without a diagnostic fails" rc_is 1
check "as a disagreement" said "doesn't agree with the 0 findings"
run lint -- STUB_RUFF_LOG="warning: No Python files found under the given path(s)"
check "no Python file to check fails the step" rc_is 1
for value in --fix --diff --watch --exit-zero "--output-file=x" -o --statistics --add-noqa --unsafe-fixes -e -n -q -s; do
    run lint extra_args="${value}"
    check "lint refuses extra_args '${value}'" rc_is 1
done
run lint extra_args="--select E,F --target-version py311"
check "lint takes Ruff's own options with their values" has ruff check --no-fix --no-fix-only --no-cache --select E,F --target-version py311 --output-format json --
run lint paths='$ORB_TEST_VAR' -- ORB_TEST_VAR=src
check "paths expand environment variables" has ruff check --output-format json -- src

echo "=== mypy"
run mypy -- MYPY_FORCE_COLOR=1
check "clean code passes" rc_is 0
check "mypy writes JSON lines without a summary" has mypy -O json --no-error-summary
check "against the project's environment" has mypy -O --python-executable "${JOB}/.venv/bin/python"
check "at its Python version, when the configuration names none" has mypy -O --python-version "$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
check "checking the working directory when nothing names files" bash -c 'tail -n 1 "$1" | grep -qx .' _ "$(call mypy -O)"
check "without MYPY_FORCE_COLOR" no_meta mypy -O "MYPY_FORCE_COLOR"
check "saying it finds no configuration" said "mypy finds no configuration"
run mypy -- STUB_MYPY_OUTPUT="${STUBS}/mypy.jsonl"
check "type errors fail the step" rc_is 1
check "with mypy's columns, 1-based" said "  src/demo/__init__.py:5:12: error return-value: Incompatible return value type"
check "notes are reported" report_is mypy.json '[.[] | select(.level == "note") | .finding]' '[false]'
check "with the hint in the message" report_is mypy.json '.[1].message | contains("types-PyYAML")' 'true'
check "SARIF holds every message, at its level" report_is mypy.sarif '[.runs[0].results[].level]' '["error","error","note"]'
check "the summary counts both" said "mypy reported 2 errors and 1 note."
check "JUnit skips the notes" junit_has '<skipped message="Revealed type' mypy
run mypy -- STUB_MYPY_OUTPUT="${STUBS}/mypy-notes.jsonl"
check "notes alone pass" rc_is 0
run mypy -- STUB_MYPY_EXIT=2 STUB_MYPY_STDERR="src/demo/broken.py:2: error: Invalid syntax  [syntax]"
check "a run mypy stopped fails the step" rc_is 1
check "with mypy's error" said "Invalid syntax"
check "as no result" said "This is not a type-checking result."
run mypy -- STUB_MYPY_EXIT=1
check "exit 1 without an error fails" rc_is 1
mkdir -p "${JOB}/cfg-version" "${JOB}/cfg-plugins" "${JOB}/cfg-files/pkg"
printf '[mypy]\npython_version = 3.11\n' > "${JOB}/cfg-version/mypy.ini"
printf '[tool.mypy]\nplugins = ["goodplugin", "pq_missing_plugin.mypy"]\n' > "${JOB}/cfg-plugins/pyproject.toml"
printf '[tool.mypy]\nfiles = ["pkg"]\n' > "${JOB}/cfg-files/pyproject.toml"
run mypy working_dir=cfg-version environment=../.venv
check "a configured python_version is left alone" lacks mypy -O --python-version
check "naming the configuration it found" said "mypy's configuration: mypy.ini"
run mypy working_dir=cfg-files environment=../.venv
check "files in the configuration are what mypy checks" bash -c '[[ "$(tail -n 1 "$1")" != . ]]' _ "$(call mypy -O)"
run mypy working_dir=cfg-plugins environment=../.venv
check "a plugin the orb's mypy environment lacks fails the step" rc_is 1
check "naming it, and runner: project" said "loads the plugin(s) pq_missing_plugin.mypy"
check "but not one it has" not_said "goodplugin,"
check "before mypy checks anything" no_call mypy -O
run mypy working_dir=cfg-plugins environment=../.venv runner=project
check "runner: project runs the environment's own mypy" rc_is 0
check "as python -m mypy" said "Type-checking with mypy 2.4.0"
run mypy runner=project -- STUB_HIDE=mypy
check "runner: project needs mypy in the environment" rc_is 1
check "saying so" said "mypy is not installed in ${JOB}/.venv/bin/python"
run mypy environment=""
check "with no environment, mypy checks without site-packages" has mypy -O --no-site-packages
run mypy environment=missing
check "an environment that doesn't exist is refused" rc_is 1
check "saying how to make one" said "uv sync, poetry install"
run mypy config=missing.ini
check "a config that doesn't exist is refused" rc_is 1
for value in "-O text" --output=text --error-summary --install-types "-c x=1" "--python-version=3.9" "--python-executable=/x" src; do
    run mypy extra_args="${value}"
    check "mypy refuses extra_args '${value}'" rc_is 1
done
run mypy extra_args="--strict -p demo"
check "mypy takes its own options, and -p instead of a path" has mypy -O --strict -p demo
check "with no path added" bash -c '[[ "$(tail -n 1 "$1")" == demo ]]' _ "$(call mypy -O)"

echo "=== pyright"
run pyright -- PYRIGHT_PYTHON_FORCE_VERSION=1.1.999 PYRIGHT_PYTHON_GLOBAL_NODE=1
check "clean code passes" rc_is 0
check "Pyright writes JSON, against the project's environment" has pyright --outputjson --pythonpath "${JOB}/.venv/bin/python"
check "never told to fetch another Pyright" no_meta pyright --outputjson "PYRIGHT_PYTHON_FORCE_VERSION"
check "or use another Node.js" no_meta pyright --outputjson "PYRIGHT_PYTHON_GLOBAL_NODE"
check "nor to warn about newer releases" meta pyright --outputjson "PYRIGHT_PYTHON_IGNORE_WARNINGS=1"
run pyright run_record=true -- STUB_PYRIGHT_JSON="${STUBS}/pyright.json"
check "an error fails the step" rc_is 1
check "at fail_on error, the warning is no finding" report_is pyright.json '[.[] | .finding]' '[true,false,false]'
check "paths are relative to the working directory" report_is pyright.json '[.[].path] | unique' '["src/demo/__init__.py","src/demo/util.py"]'
check "lines and columns 1-based" report_is pyright.json '.[0] | [.line, .column]' '[5,12]'
check "the summary counts each severity" said "Pyright analyzed 3 files and reported 1 errors, 1 warnings and 1 informations; 1 finding at or above error."
check "the run record counts the files" report_is pyright.run-record.json '.counts.files_analyzed' '3'
run pyright fail_on=warning report_only=true -- STUB_PYRIGHT_JSON="${STUBS}/pyright.json"
check "fail_on warning counts the warning too" report_is pyright.json '[.[] | .finding]' '[true,true,false]'
check "report_only passes" rc_is 0
run pyright -- STUB_PYRIGHT_FILES=0
check "no file analyzed fails the step" rc_is 1
check "saying nothing was checked" said "Pyright analyzed no file"
run pyright allow_empty=true -- STUB_PYRIGHT_FILES=0
check "unless allow_empty" rc_is 0
run pyright -- STUB_PYRIGHT_EXIT=3
check "a configuration Pyright can't use fails the step" rc_is 1
run pyright -- STUB_PYRIGHT_EXIT=1
check "exit 1 without an error fails" rc_is 1
run pyright project=missing.json
check "a project that doesn't exist is refused" rc_is 1
for value in --outputjson "--level=error" --warnings --watch -w "-p x" --verifytypes=demo --writebaseline --verbose src; do
    run pyright extra_args="${value}"
    check "pyright refuses extra_args '${value}'" rc_is 1
done

echo "=== ty"
run ty -- TY_OUTPUT_FORMAT=full TY_CONFIG_FILE=/tmp/other.toml CI_PROJECT_DIR=/builds/x
check "clean code passes" rc_is 0
check "ty writes GitLab's JSON, against the project's environment" has ty check --output-format gitlab --python "${JOB}/.venv/bin/python" --
check "without the job's TY_* variables" no_meta ty check "^TY_"
check "or GitLab's project directory" no_meta ty check "CI_PROJECT_DIR"
check "or the user's configuration" bash -c 'grep -q "^XDG_CONFIG_HOME=/tmp" "$1"' _ "$(call ty check | sed 's/args$/meta/')"
run ty -- STUB_TY_JSON="${STUBS}/ty.json"
check "an error fails the step" rc_is 1
check "at fail_on warning (ty's own default), the warning is a finding too" report_is ty.json '[.[] | .finding]' '[true,true,false]'
check "the rule leaves the message" report_is ty.json '.[0].message' '"Return type does not match returned value"'
check "with the rule's documentation" report_is ty.json '.[0].url' '"https://docs.astral.sh/ty/reference/rules/#invalid-return-type"'
check "SARIF has every level" report_is ty.sarif '[.runs[0].results[].level]' '["error","warning","note"]'
run ty fail_on=error -- STUB_TY_JSON="${STUBS}/ty.json"
check "fail_on error leaves the warning out" report_is ty.json '[.[] | .finding]' '[true,false,false]'
jq 'map(select(.severity != "major"))' "${STUBS}/ty.json" > "${WORK}/ty-warnings.json"
run ty fail_on=error -- STUB_TY_JSON="${WORK}/ty-warnings.json"
check "warnings alone pass at fail_on error" rc_is 0
run ty -- STUB_TY_JSON="${WORK}/ty-warnings.json" STUB_TY_EXIT=0
check "a configuration with error-on-warning off may exit 0 with warnings, which still count" rc_is 1
check "as findings" said "1 finding at or above warning"
run ty -- STUB_TY_EXIT=2 STUB_TY_LOG="ty failed: Invalid value for --python"
check "a run ty couldn't complete fails" rc_is 1
check "with its error" said "Invalid value for --python"
run ty -- STUB_TY_EXIT=101
check "a crash fails" rc_is 1
run ty -- STUB_TY_LOG=" WARN No python files found under the given path(s)"
check "no Python file to check fails" rc_is 1
for value in --fix --add-ignore --exit-zero --error-on-warning --watch -W -q "--output-format=full" "--python=/x" src; do
    run ty extra_args="${value}"
    check "ty refuses extra_args '${value}'" rc_is 1
done
run ty extra_args="--python-version 3.12 --error possibly-unresolved-reference"
check "ty takes its own options with their values" has ty check --output-format gitlab --python "${JOB}/.venv/bin/python" --python-version 3.12 --error possibly-unresolved-reference --

echo "=== test"
run test run_record=true
check "passing tests pass" rc_is 0
check "pytest runs in the project's environment" said "in ${JOB}/.venv/bin/python"
check "writing legacy JUnit, which CircleCI's timings read" has pytest "--junitxml=${OUT}/junit/test.xml" -o junit_family=legacy -o junit_suite_name=test
check "the summary" said "Passed: 3 tests: 3 passed, 0 failed, 0 errors, 0 skipped."
check "the report counts them" report_is test.json '[.tests, .failures, .errors, .skipped]' '[3,0,0,0]'
check "the run record names pytest's version" report_is test.run-record.json '.target.pytest_version' '"9.2.0"'
run test -- STUB_PYTEST_JUNIT="${STUBS}/pytest-failed.xml"
check "a failed test fails the step" rc_is 1
check "naming it, with its file and line" said "failure: tests/test_demo.py:7 tests.test_demo.test_two: AssertionError: assert 2 == 3"
check "and an erroring one" said "error: tests/test_other.py:3 tests.test_other.test_three"
check "the summary counts them" said "4 tests: 1 passed, 1 failed, 1 errors, 1 skipped. 2 tests failed or errored."
run test -- STUB_PYTEST_EXIT=2
check "an interrupted run fails" rc_is 1
check "as no result" said "This is not a test result."
run test -- STUB_PYTEST_EXIT=5
check "no test collected fails" rc_is 1
check "saying nothing was tested" said "pytest collected no test"
run test allow_empty=true -- STUB_PYTEST_EXIT=5
check "unless allow_empty" rc_is 0
run test -- STUB_PYTEST_EXIT=6
check "too many warnings fail the step" rc_is 1
check "saying so" said "more warnings than --max-warnings allows"
run test -- STUB_PYTEST_EXIT=1
check "exit 1 without a failure in the report fails" rc_is 1
run test -- STUB_HIDE=pytest
check "pytest must be in the environment" rc_is 1
check "saying so" said "pytest is not installed in ${JOB}/.venv/bin/python"
run test coverage=true coverage_source=demo
check "coverage runs pytest under coverage.py" has coverage run --parallel-mode --source=demo -m pytest
check "and passes" rc_is 0
check "the data stays in a temporary directory" meta coverage run "COVERAGE_FILE=$(sed -n 's/^COVERAGE_FILE=//p' "$(call coverage run | sed 's/args$/meta/')")"
check "combined" bash -c '[[ -n "$1" ]]' _ "$(call coverage combine)"
check "the JSON report, never failing on fail_under" has coverage json -o "${OUT}/test.coverage.json" --fail-under=0
check "and XML" report test.coverage.xml
check "the summary has the percentage" said "coverage 90%"
check "the report has the totals" report_is test.json '.coverage | [.covered, .total]' '[90,100]'
run test coverage=true -- STUB_COVERAGE_FAIL_UNDER=95
check "below the project's own fail_under fails the step" rc_is 1
check "with coverage.py's message" said "Coverage failure: total of 90 is less than fail-under=95"
run test coverage=true coverage_min=90 -- STUB_COVERAGE_FAIL_UNDER=95
check "coverage_min replaces fail_under" rc_is 0
run test coverage=true coverage_min=90.5
check "coverage_min with a fraction fails below it" rc_is 1
check "saying by how much" said "coverage is 90% (90 of 100), below coverage_min 90.5%"
run test coverage=true coverage_min=100 -- STUB_COVERAGE_TOTALS='{"covered_lines": 1999, "num_statements": 2000, "percent_covered": 99.95}'
check "1999 of 2000 is not 100%" rc_is 1
run test coverage=true -- STUB_COVERAGE_NODATA=1
check "coverage that measured nothing fails" rc_is 1
run test coverage=true -- STUB_HIDE=coverage
check "coverage.py must be in the environment" rc_is 1
for value in 101 -1 abc 50.1234567; do
    run test coverage=true coverage_min="${value}"
    check "coverage_min ${value} is refused" rc_is 1
done
run test coverage_min=80
check "coverage_min needs coverage" rc_is 1
run test split_tests=true -- CIRCLE_NODE_TOTAL=2 CIRCLE_NODE_INDEX=1
check "split_tests runs this node's share" rc_is 0
check "collecting the tests first" has pytest --collect-only -q -p no:cacheprovider
check "split by file name timings" grep -q -- "tests split --split-by=timings --timings-type=filename" "${STUB}/split.log"
check "running the files that fell to it" bash -c '[[ "$(tail -n 1 "$1")" == tests/test_other.py ]]' _ "$(call pytest "--junitxml=${OUT}/junit/test.xml")"
run test split_tests=true coverage=true coverage_min=80 -- CIRCLE_NODE_TOTAL=2
check "coverage_min can't be checked across nodes" rc_is 1
run test split_tests=true -- CIRCLE_NODE_TOTAL=4 CIRCLE_NODE_INDEX=3
check "a node whose share is empty passes without running pytest" rc_is 0
check "saying so" said "no test file fell to node 3 of 4"
run test split_tests=true
check "without parallelism, split_tests runs every test" no_call pytest --collect-only
for value in --junitxml=x --collect-only --co --pdb --trace --fixtures tests; do
    run test extra_args="${value}"
    check "test refuses extra_args '${value}'" rc_is 1
done
run test extra_args='-x -k "not slow" -n=4'
check "test takes pytest's options, a plugin's as --option=value" has pytest "--junitxml=${OUT}/junit/test.xml" -x -k "not slow" -n=4

echo "=== deps"
run deps run_record=true
check "a project without violations passes" rc_is 0
check "deptry runs on the project's Python" said "on ${JOB}/.venv/bin/python"
check "reading pyproject.toml, writing JSON" has deptry --config pyproject.toml --no-ansi --json-output
check "over the working directory" bash -c '[[ "$(tail -n 1 "$1")" == . ]]' _ "$(call deptry --config)"
check "the run record names deptry and the environment" report_is deps.run-record.json '[.tool.version, (.target.environment.python | endswith("/.venv/bin/python"))]' '["0.25.1",true]'
run deps -- STUB_DEPTRY_JSON="${STUBS}/deptry.json"
check "violations fail the step" rc_is 1
check "each with its rule" said "src/demo/util.py:1:8: error DEP001: 'yaml' imported but missing"
check "the report counts them by rule" report_is deps.json '[.[].rule]' '["DEP002","DEP001"]'
check "SARIF places a pyproject.toml violation in the file" report_is deps.sarif '.runs[0].results[0].locations[0].physicalLocation' '{"artifactLocation":{"uri":"pyproject.toml"}}'
run deps -- STUB_DEPTRY_CRASH=1
check "a run with no report fails" rc_is 1
check "with deptry's error" said "no [project] table"
run deps -- STUB_DEPTRY_FILES=0
check "no Python file read fails" rc_is 1
run deps allow_empty=true -- STUB_DEPTRY_FILES=0
check "unless allow_empty" rc_is 0
run deps paths=src config=missing.toml
check "a config that doesn't exist is refused" rc_is 1
for value in -kf=demo "--json-output=x" --github-output=x "--config=x" src; do
    run deps extra_args="${value}"
    check "deps refuses extra_args '${value}'" rc_is 1
done
run deps extra_args="--per-rule-ignores DEP002=requests --known-first-party=demo"
check "deps takes deptry's long options" has deptry --config --per-rule-ignores DEP002=requests --known-first-party=demo

echo "=== api_compat"
run api_compat run_record=true
check "no breaking change passes" rc_is 0
check "comparing with the merge base of origin/main" said "Comparing the API with origin/main (merge base"
check "the package from pyproject.toml's project name, in src" has griffe load demo
check "read from the base without the checkout's git worktree" bash -c 'grep -q "/base/src$" "$1"' _ "$(call griffe load)"
check "never importing anything" bash -c 'grep -qx "allow_inspection=False" "$1" && grep -qx "try_relative_path=False" "$1"' _ "$(call griffe load)"
check "the record names the base" report_is api_compat.run-record.json '.target.base.ref' '"origin/main"'
run api_compat -- STUB_GRIFFE_BREAKAGES="${STUBS}/griffe-breakages.json"
check "a breaking change fails the step" rc_is 1
check "each is printed" said "src/demo/__init__.py:3: error parameter_removed:"
check "without Griffe's escape codes" not_said $'\x1b'
check "a removed object is placed in the file it was in" report_is api_compat.json '.[1] | [.path, .line, .in_head]' '["src/demo/__init__.py",7,false]'
check "the report has the old and new values" report_is api_compat.json '.[2] | [.old_value, .new_value]' '["str","bytes"]'
check "SARIF names the kinds" report_is api_compat.sarif '[.runs[0].tool.driver.rules[].id]' '["object_removed","parameter_removed","return_changed_type"]'
run api_compat ignore="demo._compat.*" report_only=true -- STUB_GRIFFE_BREAKAGES="${STUBS}/griffe-breakages.json"
check "ignored objects are counted, not reported" said "2 breaking changes, and 1 ignored."
check "report_only passes" rc_is 0
run api_compat package=newpkg -- STUB_GRIFFE_BREAKAGES="${STUBS}/griffe-breakages.json"
check "a package new since the base passes" rc_is 0
check "saying so" said "newpkg: new since the base"
run api_compat package=gone
check "a package that isn't in the working tree fails" rc_is 1
check "saying where it looked" said "There is no package gone"
run api_compat -- STUB_GRIFFE_FAIL=1
check "a package Griffe can't load fails" rc_is 1
check "with the error" said "invalid syntax"
run api_compat base_ref=main merge_base=false
check "base_ref and merge_base: false compare with the branch itself" said "Comparing the API with main ("
run api_compat -- GITHUB_BASE_REF=main
check "on GitHub Actions, the pull request's base" said "Comparing the API with origin/main"
run api_compat base_ref=nonexistent
check "a base_ref that isn't a commit fails" rc_is 1
check "saying how to fetch it" said "fetch-depth: 0"
for value in "-x" "a b" "a:b"; do
    run api_compat base_ref="${value}"
    check "base_ref '${value}' is refused" rc_is 1
done
run api_compat package="not-a-module"
check "a package that isn't an import name is refused" rc_is 1
run api_compat search_paths=../elsewhere
check "a search path outside the working directory is refused" rc_is 1

echo "=== package"
run package run_record=true
check "a sound sdist and wheel pass" rc_is 0
check "uv builds both, without uv's sources" has uv build --out-dir
check "with --no-sources" bash -c 'grep -qx -- --no-sources "$1"' _ "$(call uv build)"
check "twine checks each strictly, without colors" any_call twine --no-color check --strict
check "check-wheel-contents checks the wheel" test "$(calls_of check-wheel-contents --version)" -eq 1 -a "$(find "${STUB}/calls" -name '*.args' -exec sed -n '1{/^check-wheel-contents$/!q};$p' {} \; | grep -c '\.whl$')" -eq 1
check "the distributions are kept with the reports" test -f "${OUT}/package-dist/demo-1.0.tar.gz"
check "the summary" said "Checked 2 distributions: 0 problems."
check "the run record lists them" report_is package.run-record.json '[.inputs[].role] | unique' '["distribution"]'
run package out_dir=dist -- STUB_TWINE_FAIL='*.tar.gz' STUB_CWC_FAIL='*.whl'
check "problems fail the step" rc_is 1
check "twine's, read through rich's escape codes" report_is package.json '[.[] | select(.tool == "twine") | .message | contains("syntax errors in markup")]' '[true]'
check "and check-wheel-contents', one per check" report_is package.json '[.[] | select(.tool == "check-wheel-contents") | .rule]' '["W002","W009"]'
check "with the files it names" report_is package.json '[.[] | select(.rule == "W002") | .message]' '["Wheel contains duplicate files: demo/a.py demo/b.py"]'
check "out_dir keeps the distributions" test -f "${JOB}/dist/demo-1.0-py3-none-any.whl"
check "JUnit has a case per check" junit_has 'name="check-wheel-contents"><failure' package
run package -- STUB_UV_EXIT=2
check "a build that fails fails the step" rc_is 1
check "with uv's error" said "Failed to build"
run package -- STUB_UV_NO_WHEEL=1
check "a build without a wheel fails" rc_is 1
run package report_only=true -- STUB_TWINE_CRASH=1
check "twine failing before it checks fails, report_only or not" rc_is 1
run package -- STUB_CWC_INVALID=1
check "a wheel check-wheel-contents can't read fails" rc_is 1
mkdir -p "${JOB}/prebuilt"
printf 'wheel\n' > "${JOB}/prebuilt/demo-2.0-py3-none-any.whl"
run package dists="./prebuilt/*.whl"
check "dists checks distributions built earlier" rc_is 0
check "without building" no_call uv build
check "matching the paths the checkers print back" said "${JOB}/prebuilt/demo-2.0-py3-none-any.whl: OK"
run package dists="prebuilt/*.zip"
check "a dists pattern that matches nothing fails" rc_is 1
run package dists="pyproject.toml"
check "a file that isn't a distribution is refused" rc_is 1
run package twine=false check_wheel_contents=false
check "turning both checks off is refused" rc_is 1
run package twine=false -- STUB_TWINE_FAIL='*'
check "twine: false skips twine" rc_is 0
for value in --out-dir=x --sdist --wheel --no-sources --package=x --all-packages -o x; do
    run package extra_args="${value}"
    check "package refuses extra_args '${value}'" rc_is 1
done
run package check_wheel_contents_args="--ignore=W002 --toplevel=demo" -- STUB_CWC_FAIL=''
check "check_wheel_contents_args reach it" has check-wheel-contents --ignore=W002 --toplevel=demo

echo "=== shared parameters"
for command in fmt lint mypy pyright ty test deps api_compat package; do
    run "${command}" report_name="../escape"
    check "${command}: a report_name that isn't a file name is refused" rc_is 1
    run "${command}" output_dir=relative
    check "${command}: a relative output_dir is refused" rc_is 1
done
mv "${WORK}/bin/circleci" "${WORK}/bin/circleci.off"
run lint paths='$ORB_TEST_VAR' -- ORB_TEST_VAR=src
check "without the CircleCI CLI (GitHub Actions), values are used as they are" rc_is 1
check "naming it" said "paths names '\$ORB_TEST_VAR'"
mv "${WORK}/bin/circleci.off" "${WORK}/bin/circleci"

echo "=== run records against the schema"
problems=""
for record in "${WORK}/records/"*.json; do
    [[ -f "${record}" ]] || continue
    problem=$(jq -r --slurpfile schema "${ROOT}/schemas/run-record.v1.json" '$schema[0] as $schema
        | ($schema.required - keys | map("missing \(.)")[]),
          (select(.schema != $schema.properties.schema.const) | "schema is \(.schema)"),
          (select(.outcome as $o | $schema.properties.outcome.enum | index($o) | not) | "outcome \(.outcome)")' "${record}" 2>&1)
    if [[ -n "${problem}" ]]; then
        problems+="${record##*/}: ${problem}"$'\n'
    fi
done
OUTPUT=${problems}
check "every record (${RECORDS}) has the fields the schema requires" test -z "${problems}"
if command -v python3 > /dev/null 2>&1 && python3 -c 'import jsonschema' 2> /dev/null; then
    OUTPUT=$(python3 - "${ROOT}/schemas/run-record.v1.json" "${WORK}/records/"*.json 2>&1 << 'EOF'
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
validator = jsonschema.Draft202012Validator(schema)
bad = 0
for path in sys.argv[2:]:
    for error in validator.iter_errors(json.load(open(path))):
        print("%s: %s at %s" % (path.rsplit("/", 1)[-1], error.message, "/".join(map(str, error.path))))
        bad += 1
sys.exit(1 if bad else 0)
EOF
    )
    check "every record validates against schemas/run-record.v1.json" test $? -eq 0
else
    echo "skip: python3 with jsonschema is not installed, so the records were not validated against the schema"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} command check(s) failed."
    exit 1
fi
echo "All command checks passed."
