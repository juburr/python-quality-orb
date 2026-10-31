#!/bin/bash
#
# Finds changes to a Python package's public API that break its callers, for
# the api_compat command: Griffe reads the package's API from the working
# tree and from a base revision (by default the merge base with the pull
# request's base branch, or with the remote's default branch), and compares
# them: removed objects, parameters removed, moved, made required or given
# another kind or default, changed return and attribute types, removed base
# classes.
#
# Griffe reads the code without importing it, so nothing of the project runs
# and its dependencies need not be installed. The base revision comes out of
# git with git archive into a temporary directory; the checkout and its git
# metadata are left alone. Each breaking change is a finding, which fails the
# step unless report_only is true; a package that isn't at the base yet is
# new, and passes. A package Griffe can't load fails the step either way.
#
# Parameters arrive as PARAM_* variables; the lib as SCRIPT_PYTHON_QUALITY_LIB
# and the helper as SCRIPT_PYTHON_QUALITY_PY.

set -euo pipefail

if [[ -z "${SCRIPT_PYTHON_QUALITY_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_PYTHON_QUALITY_LIB is not set; run this script through the orb's api_compat command." >&2
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

pq_list package "${PARAM_PACKAGE}"
PACKAGES=(${PQ_LIST[@]+"${PQ_LIST[@]}"})
pq_list search_paths "${PARAM_SEARCH_PATHS}"
SEARCH_PATHS=(${PQ_LIST[@]+"${PQ_LIST[@]}"})
pq_list ignore "${PARAM_IGNORE}"
IGNORE=(${PQ_LIST[@]+"${PQ_LIST[@]}"})
BASE_REF=$(pq_subst "${PARAM_BASE_REF}")
MERGE_BASE=$(pq_bool merge_base "${PARAM_MERGE_BASE}")
JUNIT=$(pq_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(pq_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(pq_bool report_only "${PARAM_REPORT_ONLY}")

# --- Parameters ---
for package in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
    if ! pq_match "${package}" '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$'; then
        echo "ERROR: package must name import packages, such as mypackage, not '${package}'." >&2
        exit 1
    fi
done
for path in ${SEARCH_PATHS[@]+"${SEARCH_PATHS[@]}"}; do
    if [[ "${path}" == /* || "${path}" == ..* || "${path}" == */../* || ! -d "${path}" ]]; then
        echo "ERROR: search_paths must be directories below the working directory, such as src; '${path}' is not." >&2
        exit 1
    fi
done
if [[ "${BASE_REF}" == -* || "${BASE_REF}" == *[[:space:]:]* ]]; then
    echo "ERROR: base_ref must name a commit, such as origin/main, not '${BASE_REF}'." >&2
    exit 1
fi
pq_require_jq
pq_tool griffe
pq_tool_python griffe
VERSION=$("${PQ_TOOL_PYTHON}" -I -c 'import importlib.metadata as m; print(m.version("griffe"))' 2> /dev/null) || VERSION=""

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# --- The base ---
pq_git_top
if [[ -z "${BASE_REF}" ]]; then
    # A pull request's base branch on GitHub Actions; elsewhere the remote's
    # default branch.
    if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
        BASE_REF="origin/${GITHUB_BASE_REF}"
    elif head=$(git symbolic-ref -q refs/remotes/origin/HEAD 2> /dev/null); then
        BASE_REF=${head#refs/remotes/}
    else
        for candidate in origin/main origin/master; do
            if git rev-parse --verify --quiet "${candidate}^{commit}" > /dev/null; then
                BASE_REF=${candidate}
                break
            fi
        done
    fi
    if [[ -z "${BASE_REF}" ]]; then
        echo "ERROR: base_ref is empty, and this checkout has no origin/HEAD, origin/main or origin/master to" >&2
        echo "  compare with. Set base_ref to the branch, tag or commit whose API callers use." >&2
        exit 1
    fi
fi
if ! tip=$(git rev-parse --verify --quiet "${BASE_REF}^{commit}"); then
    echo "ERROR: base_ref ${BASE_REF} is not a commit in this checkout. Fetch it in an earlier step, such as" >&2
    echo "  git fetch origin ${BASE_REF#origin/}, or check out with all history (actions/checkout: fetch-depth: 0)." >&2
    exit 1
fi
if [[ "${MERGE_BASE}" == true ]]; then
    if ! BASE_COMMIT=$(git merge-base "${tip}" HEAD 2> /dev/null); then
        echo "ERROR: ${BASE_REF} and HEAD have no common ancestor in this checkout, which is usually a shallow" >&2
        echo "  clone. Fetch more history (actions/checkout: fetch-depth: 0), or set merge_base to false to" >&2
        echo "  compare with ${BASE_REF} itself." >&2
        exit 1
    fi
    BASE_LABEL="${BASE_REF} (merge base ${BASE_COMMIT:0:12})"
else
    BASE_COMMIT=${tip}
    BASE_LABEL="${BASE_REF} (${BASE_COMMIT:0:12})"
fi
echo "Comparing the API with ${BASE_LABEL}."
if [[ "${BASE_COMMIT}" == "$(git rev-parse HEAD)" ]]; then
    echo "The base is this commit, so only uncommitted changes can show."
fi
# The working directory's tree at the base, from git's objects only.
mkdir -p "${WORK}/base"
TREE="${BASE_COMMIT}:${PQ_PREFIX%/}"
if git cat-file -e "${TREE}" 2> /dev/null; then
    if ! git archive --format=tar "${TREE}" 2> "${WORK}/archive.log" | tar -x -C "${WORK}/base" 2>> "${WORK}/archive.log"; then
        pq_tail "${WORK}/archive.log" 10
        echo "ERROR: Could not take $(pwd) at ${BASE_COMMIT:0:12} out of git." >&2
        exit 1
    fi
else
    echo "$(pwd) didn't exist at ${BASE_COMMIT:0:12}, so every package in it is new."
fi

ARGS=(api-diff --old "${WORK}/base" --new .)
for package in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
    ARGS+=(--package "${package}")
done
for path in ${SEARCH_PATHS[@]+"${SEARCH_PATHS[@]}"}; do
    ARGS+=(--search-path "${path}")
done
for pattern in ${IGNORE[@]+"${IGNORE[@]}"}; do
    ARGS+=(--ignore "${pattern}")
done

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TOOL_VERSION=${VERSION}
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_ARGS=("${ARGS[@]:3}")
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_TARGET_JSON=$(jq -cn --arg ref "${BASE_REF}" --arg commit "${BASE_COMMIT}" --argjson merge "${MERGE_BASE}" \
        --arg head "$(git rev-parse HEAD)" '{base: {ref: $ref, commit: $commit, merge_base: $merge}, head: $head}')
    # shellcheck disable=SC2034 # read by pq_run_record
    PQ_REPORTS=("${REPORT}" "${SARIF}" "${JUNIT_FILE}")
    pq_run_record "${RECORD}" api_compat "$1" "$2" "${STARTED}"
}

echo "Reading the API with Griffe ${VERSION:-(version unknown)}, without importing the code."
code=0
pq_py "${PQ_TOOL_PYTHON}" "${ARGS[@]}" > "${WORK}/diff.json" 2> "${WORK}/diff.log" || code=$?
if [[ "${code}" -ne 0 ]] || ! pq_json_is "${WORK}/diff.json" 'type == "array" and length > 0'; then
    pq_tail "${WORK}/diff.log" 30
    record error "${code}"
    echo "ERROR: Griffe could not compare the API (exit code ${code}). This is not an API compatibility result." >&2
    exit 1
fi
# shellcheck disable=SC2016 # jq program, not shell
jq '[.[] | .package as $pkg | .breakages[] | {
        file: (.file // "-"), line: .line, column: null, rule: .kind, package: $pkg, object: .object,
        old_value, new_value, in_head,
        message: (if .explanation != "" then .explanation else "\(.object): \(.description)" end),
        level: "error", finding: true,
        url: "https://mkdocstrings.github.io/griffe/guide/users/checking/"}]' "${WORK}/diff.json" > "${WORK}/findings.json"
pq_paths "${WORK}/findings.json"
cp "${WORK}/findings.json" "${REPORT}"
FINDINGS=$(jq -r 'length' "${REPORT}")
# shellcheck disable=SC2034 # read by pq_run_record
PQ_RESULTS=$(jq -c 'map({package, new_in_head, breakages: (.breakages | length), ignored})' "${WORK}/diff.json")
# shellcheck disable=SC2034 # read by pq_run_record
PQ_COUNTS=$(jq -c '{findings: length} + ([.[].rule] | group_by(.) | map({key: .[0], value: length}) | from_entries)' "${REPORT}")
jq -r '.[] | if .new_in_head then "  \(.package): new since the base, so there is nothing to compare."
    else "  \(.package): \(.breakages | length) breaking \(if (.breakages | length) == 1 then "change" else "changes" end)"
        + (if .ignored > 0 then ", and \(.ignored) ignored" else "" end) + "." end' "${WORK}/diff.json"

# --- Reports ---
pq_sarif "${REPORT}" "${SARIF}" Griffe "${VERSION}" "https://mkdocstrings.github.io/griffe/"
if [[ "${JUNIT}" == true ]]; then
    pq_findings_junit "${REPORT}" "${JUNIT_FILE}" "griffe (${REPORT_NAME})"
fi
pq_print_findings "${REPORT}" 100
SUMMARY="Griffe found $(pq_plural "${FINDINGS}" "breaking change" "breaking changes") since ${BASE_LABEL}."
if [[ "${FINDINGS}" -gt 0 ]]; then
    if [[ "${REPORT_ONLY}" == true ]]; then
        record findings-reported 0
    else
        record findings 0
    fi
    pq_gate true "${REPORT_ONLY}" "${SUMMARY}"
fi
record passed 0
pq_gate false "${REPORT_ONLY}" "${SUMMARY}"
