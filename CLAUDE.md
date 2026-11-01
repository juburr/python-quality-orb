# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, that holds Python code to a standard on every commit. It installs Ruff, ty and uv (checksum-verified release binaries) and mypy, Pyright, deptry, Griffe, twine and check-wheel-contents (with that uv, each into an environment of its own, from a lock that pins every wheel by SHA-256), and wraps the checks around them: `fmt` and `lint` (Ruff), `mypy`, `pyright`, `ty`, `test` (pytest and coverage.py in the project's own environment), `deps` (deptry), `api_compat` (Griffe against a git revision) and `package` (uv build, twine check, check-wheel-contents). Security checks (pip-audit, Bandit, licenses, lockfiles) are python-security-orb's.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*.sh src/install/*/*.sh actions/*.sh tests/*.sh

# Tests (offline; git, jq, python3 3.11+, and jsonschema to check run records)
for t in tests/*_test.sh; do bash "$t" || break; done

# Run one command's script with its YAML defaults (what test-deploy.yml uses for steps that must fail)
bash tests/run_command.sh lint working_dir=tests/fixtures/dirty

# Table entries for a new Ruff, ty or uv release, and a lock for a new release of a locked tool
./src/install/ruff/install_hash.sh -v <version>
./src/install/lock.sh -t mypy -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/`
  - `install.yml` - Checks `tools` (`scripts/install_tools.sh`), runs `install_ruff` and `install_ty` when named, `install_uv` once when any tool installed with it (or `uv`, `python`) is named, then `install_python` and the six locked tools' install commands with `install_uv: false`, each picked by a `when: condition: matches:` on `tools` (`^(.*[ ,])?<tool>([ ,].*)?$`).
  - `install_uv.yml`, `install_ruff.yml`, `install_ty.yml` - The family's standard install command shape: cache key from `scripts/cache_key.sh`, `restore_cache`, `install/<tool>/install.sh`, `save_cache`.
  - `install_python.yml`, `install_mypy.yml`, `install_pyright.yml`, `install_deptry.yml`, `install_griffe.yml`, `install_twine.yml`, `install_check_wheel_contents.yml` - python-security-orb's locked-tool install: optionally `install_uv`, the Python cache key (`scripts/python_cache_key.sh`) and restore, `scripts/install_tool.sh` with `PARAM_TOOL` fixed and `SCRIPT_TOOL_LOCKS: << include(install/<tool>/locks.txt) >>` (none for `install_python`), and save. They were generated from one template; keep them in step.
  - `fmt`, `lint`, `mypy`, `pyright`, `ty`, `test`, `deps`, `api_compat`, `package` - One script each in `scripts/`. They were generated from one template too (parameters, then one run step with every `PARAM_*`, then `store_test_results` and `store_artifacts` with `when: always`).
- `install/<tool>/install.sh` and `install_hash.sh` (uv, ruff, ty), `install/lock.sh`, `install/<tool>/locks.txt` - Kept outside `scripts/`, since `tests/shell_conventions_test.sh` exempts only `src/scripts/install.sh`, `install_hash.sh` and `cache_key.sh` by exact path. orb pack ignores the directory; commands include its files.
- `scripts/lib/python_quality.sh` - Shell helpers (`pq_*`), passed to each step as `SCRIPT_PYTHON_QUALITY_LIB: << include(scripts/lib/python_quality.sh) >>` and `eval`ed after a check that it is set. Only defines functions; no `set` line.
- `scripts/lib/python_quality.py` - The Python helper, standard library only and Python 3.11 syntax (`tests/wiring_test.sh` checks), passed to `mypy`, `test` and `api_compat` as `SCRIPT_PYTHON_QUALITY_PY` and run as `python -I -c "${SCRIPT_PYTHON_QUALITY_PY}" COMMAND ...` through `pq_py`, never written to a file.
- `examples/` - Usage examples, pinned to the orb's current version
- `../schemas/run-record.v1.json` - The run record's JSON Schema. Its URL is in every run record, so fields are only ever added within v1.
- `../actions/<command>/action.yml` - The GitHub Action for each command (see below).

### Install

- **uv, Ruff, ty** (`install/<tool>/install.sh`): the layout every juburr orb's install.sh shares: a tool definition, the shared install logic (byte-identical across the orbs; never edit it here alone), and the `sha512sums` table keyed `"<version>/<arch>"`, holding the SHA-512 of the binary in the static musl archive (`<tool>-<x86_64|aarch64>-unknown-linux-musl.tar.gz`, member `<tool>-<triple>/<tool>`). URLs: GitHub, then `releases.astral.sh`, or `download_base_url` alone. Each tool definition holds the `# >>> python-quality-orb install helpers >>>` block, identical in all three (`tests/install_test.sh` checks): `pq_triple`, `pq_asset_urls`, `pq_download_base_url` (an https mirror in place of `https://github.com`, refusing credentials, a query or a fragment) and `pq_install_record`, which writes `.<binary>.install.json` beside the binary, which `pq_tool` checks and the run records include. Each `install_hash.sh` checks the archive against the `.sha256` the release publishes beside it, refuses a release younger than seven days (`<TOOL>_MIN_RELEASE_AGE_DAYS`, from that file's `Last-Modified`; uv's from python-security-orb has no age check), and runs `gh attestation verify --repo astral-sh/<tool> --signer-workflow astral-sh/<tool>/.github/workflows/release.yml` when `gh` is installed (`.github/workflows/actions.yml`'s `install-hash` job runs it with a token). Tables: uv 0.13.0 to 0.13.6, Ruff 0.16.0 to 0.17.2, ty 0.0.84 to 0.0.91.
- **The locked tools** (`scripts/install_tool.sh`, from python-security-orb): `uv python install --managed-python` (`python` 3.11 to 3.14) into `~/.python-quality-orb/python`, or `system`, or a path; then `uv venv` and `uv pip install --require-hashes --only-binary :all: --strict` from the tool's lock (`# >>> <tool> <version> >>>` blocks in `locks.txt`), smoke-tested with `python -I -m <module> --version` (`mypy`, `pyright`, `deptry`, `griffecli`, `twine`, `check_wheel_contents`), swapped into `~/.python-quality-orb/venvs/<tool>`, and run by a script named `<tool>` in `install_path`. Its second line says `installed by python-quality-orb` and its third is `exec '<venv>/bin/python' -I -m <module> "$@"`, which `pq_tool_python` reads to find the tool's Python. Pyright installs as `pyright[nodejs]`, so Node.js comes as a wheel; its smoke test runs without the job's `PYRIGHT_PYTHON_*` variables. `install_python` (`PARAM_TOOL: python`) stops after exporting `PYTHON_QUALITY_ORB_PYTHON`. `install/lock.sh` resolves with uv from wheels uploaded at least seven days earlier and keeps the wheels for CPython 3.11 to 3.14 on x86_64 and aarch64, glibc and musl; for twine, the one with PyPI provenance, it checks the wheel's with `pypi-attestations` when installed.

When a default version changes, change it in `install_<tool>.yml` and `install.yml`'s `<tool>_version`, then regenerate the actions; `tests/wiring_test.sh` requires the defaults to be the newest table entry or lock.

### Command scripts (`src/scripts/`)

Every check takes `working_dir`, `output_dir`, `report_name`, `junit`, `run_record`, `store_artifacts` and, but `test`, `report_only`; all but `api_compat` take `extra_args`. Each first removes the reports an earlier run with the same `report_name` left. The rule every gate follows: findings fail the step unless `report_only` is true; a tool that didn't complete, a file it couldn't parse or read, an exit code that disagrees with its report, or a check of nothing (unless `allow_empty`) always fails it. Each script tells them apart from the tool's report, not its exit code. `extra_args` is split with `split_shell_words` (the parser the juburr orbs share), and `pq_extra_args` refuses the options a script sets itself, those that would change what is checked or how the report reads, and words that aren't options (the tool would read them as a path); an option it doesn't know takes its value as `--option=value`.

Findings share one shape (`pq_paths`, `pq_sarif`, `pq_findings_junit`, `pq_print_findings`): `{file, path, uri, line, column, end_line, end_column, rule, level, message, url, finding}`, where `path` is relative to the working directory, `uri` to the top of the checkout (percent-encoded), and `finding` says whether it counts toward the gate.

- **`fmt.sh`**: `ruff format --no-cache [--config] EXTRA --check --output-format json -- PATHS`, without the job's `RUFF_*` variables. Exit 0, 1 (would reformat) or 2 (couldn't format: a parse or IO error, listed in the same JSON). `pq_ruff_findings` classifies by `.name` (always the diagnostic's kind; preview mode drops `.code` for non-rule diagnostics): `unformatted` is a finding, `invalid-syntax`, `io-error` and anything else an error. "No Python files found under the given path(s)" in the log is a check of nothing. A second `--diff` run writes `<report_name>.diff`.
- **`lint.sh`**: `ruff check --no-fix --no-fix-only --no-cache [--config] EXTRA --output-format json -- PATHS`. Ruff exits 1 for any diagnostic, `invalid-syntax` included, which the orb counts as an error, not a finding; a file it can't read is only a log warning ("Failed to lint", "Encountered error") unless `E902` is on, and also an error. `-q`, `-s`, `--statistics`, `--fix` and the like are refused.
- **`mypy.sh`**: `mypy -O json --no-error-summary --no-color-output --no-pretty [--config-file] --python-executable ENV [--python-version X.Y] EXTRA PATHS`, with `runner: orb` (the script `install_mypy` made) or `runner: project` (`ENV -m mypy`). The helper's `mypy-config` finds the configuration as mypy 2.4's `_find_config_file` does (the file given, else `mypy.ini`, `.mypy.ini`, `pyproject.toml` with `[tool.mypy]`, `setup.cfg` with `[mypy]`, upward to a `.git` or `.hg`, then the user's), and reports `python_version`, whether it names files, and its plugins. `--python-version` is the environment's only when the configuration has none; paths default to `.` only when it names no files and `extra_args` has no `-m`/`-p`. With `runner: orb`, a plugin module the tool environment can't `find_spec` fails the step before mypy runs. Output is one JSON object per line: severity `error` is a finding, `note` is reported; columns become 1-based. Exit 2 (blocking errors, on stderr) is an error.
- **`pyright.sh`**: `pyright --outputjson [--project] --pythonpath ENV EXTRA PATHS`, without `PYRIGHT_PYTHON_*` but `PYRIGHT_PYTHON_IGNORE_WARNINGS=1`. Exit 0/1, or 2 to 4 for an error. Diagnostics at or above `fail_on` (`error`, `warning`, `information`) are findings; `summary.filesAnalyzed` 0 is a check of nothing.
- **`ty.sh`**: `ty check --output-format gitlab [--config-file] --python ENV EXTRA -- PATHS`, without the job's `TY_*` variables (`TY_CONFIG_FILE`, `TY_OUTPUT_FORMAT`) and `CI_PROJECT_DIR` (which changes the report's paths), with `XDG_CONFIG_HOME` pointed at an empty directory so no user-level `ty.toml` adds to the project's. GitLab's severities map to `info`, `minor` (warning), `major` (error) and `critical` (a crash). Exit 1 needs an error or a warning (`error-on-warning`, on by default); exit 0 allows warnings but never errors; 2 and 101 are errors. `fail_on` defaults to `warning`, as ty's own exit code does. "No python files found" in the log is a check of nothing.
- **`test.sh`**: `ENV -m pytest --junitxml=<junit> -o junit_family=legacy -o junit_suite_name=<report_name> EXTRA TARGETS` (legacy for the `file` attribute CircleCI's timings need), or with `coverage` `ENV -m coverage run --parallel-mode [--rcfile] [--source] -m pytest ...` with `COVERAGE_FILE` in the work directory, then `combine`, `json` and `xml` with `--fail-under=0`, and `report` with the project's `fail_under` (exit 2 is "Coverage failure", a finding) unless `coverage_min` replaces it, compared as `covered * 100 * den < min * total` over lines plus branches. pytest exits 0, 1 (failures), 5 (nothing collected), 6 (`--max-warnings`, a finding), or 2 to 4 (an error, such as a module that doesn't import). The helper's `junit` reads the report; exit 1 must have a failure or error in it, and exit 0 none. With `split_tests` and `CIRCLE_NODE_TOTAL` above 1, `pytest --collect-only ... --verbosity=-1` lists the node IDs (`--verbosity` comes after `extra_args`, and pytest applies `addopts` and `PYTEST_ADDOPTS` first, so a project's `-q` can't turn them into file counts; a collection that lists none is an error, and exit 5 is a check of nothing), their files go through `circleci tests split --split-by=timings --timings-type=filename` (read from a file after its exit status), and a node with an empty share passes. No `report_only`: failing tests fail.
- **`deps.sh`**: deptry runs on the environment's Python (3.10+), as `ENV -I -c RUNNER SITE ARGS`, where RUNNER puts the deptry environment's `purelib`/`platlib` (from `pq_tool_python`) in front of `sys.path` and calls `deptry.cli:deptry`: deptry resolves imports with `importlib.metadata`/`find_spec` and the stdlib with `sys.stdlib_module_names` in its own process, so it must be the project's. `--config <pyproject> --no-ansi --json-output <work>`; deptry exits 1 for violations and failures alike, and writes the JSON only when it completes. "Scanning 0 file" in its log is a check of nothing. deptry's short options run letters together (`-pri`, `-ee`), so only long options are taken in `extra_args`.
- **`api_compat.sh`**: resolves the base as openapi-orb's `breaking` does (`base_ref`, or `origin/$GITHUB_BASE_REF`, `origin/HEAD`, `origin/main`, `origin/master`; the merge base unless `merge_base` is false), takes the working directory's tree at the base with `git archive <commit>:<prefix> | tar -x` into the work directory (a tree that didn't exist makes every package new), and runs the helper's `api-diff` on the Griffe environment's Python: `griffe.load(package, search_paths=..., try_relative_path=False, allow_inspection=False, force_inspection=False, resolve_aliases=True)` from both trees (search paths `src` and `.` by default), then `griffe.find_breaking_changes`. A package missing at the base is new; one missing in the working tree, or that Griffe can't load, is an error. Without `package`, the helper takes `pyproject.toml`'s `[project] name`, normalized, when such a package or module is in `src/` or at the top. `ignore` globs match object paths with `fnmatchcase`. Kinds are `BreakageKind` names, lowercased; explanations lose Griffe's escape codes.
- **`package.sh`**: `uv build --out-dir <work>/dist [--no-sources] EXTRA` (both an sdist and a wheel must come out), or `dists`; copies the build to `out_dir` or `output_dir/<report_name>-dist`, which a build empties first and `dists` mode never touches (it can hold the very distributions named); with `twine: false`, `dists` must name a wheel, since check-wheel-contents reads nothing else; normalizes every path with `realpath -s` (both checkers print the path back); then per distribution `twine --no-color check --strict` with `COLUMNS=1000` (twine forces a terminal for rich), escape codes stripped, the `Checking <file>:` line required, `PASSED` or a finding with the `ERROR`/`WARNING` lines, and per wheel `check-wheel-contents [ARGS] <wheel>`: `<wheel>: OK`, or one finding per `<wheel>: W###: ...` with the indented lines after it; anything else (an invalid wheel on stderr) is an error.

### Shared helpers (`scripts/lib/python_quality.sh`)

- From openapi-orb: `pq_subst` (stdin `circleci env subst`, the value as is without the CLI), `pq_bool`, `split_shell_words`/`pq_words`, `pq_match` (C locale), `pq_list`, `pq_files` (globs; no match is an error), `pq_require_jq`, `pq_output`, `pq_uint`, `pq_junit`, `pq_gate`, `pq_plural`, `pq_tail`, `pq_export`, `pq_env_var_name`, `pq_json_is` (never `jq -e` on a tool's output: jq 1.6 exits 0 on an empty file), `pq_sha256`, `pq_url_public`, `pq_ci_json`, `pq_tool_json`, `pq_tool`, `pq_git_top`, `pq_from_top`, `pq_args_json`, `pq_show_command`, `pq_run_record`.
- The orb's own: `pq_py`, `pq_helper_python` (`PYTHON_QUALITY_ORB_PYTHON` or `python3`, 3.11+), `pq_environment` (the `environment` parameter: a directory's `bin/python` or an interpreter, made absolute without following links, with `PQ_ENV_VERSION`), `pq_paths`, `pq_print_findings`, `pq_sarif`, `pq_findings_junit`, `pq_finding_counts`, `pq_extra_args`, `pq_tool_python`, `pq_ruff_findings`, `pq_ruff_env`.
- Keep `schemas/run-record.v1.json` in step with `pq_run_record`; `tests/commands_test.sh` checks every run record it writes against it.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT SCRIPT_PYTHON_QUALITY_LIB=<lib> [SCRIPT_PYTHON_QUALITY_PY=<py>|SCRIPT_TOOL_LOCKS=<locks>]`, with `working-directory: ${{ inputs.working_dir }}`. Inputs never appear inside a `run:` script. The install actions cache with `actions/cache`, keyed as the commands are; `install`'s first step writes the tools named (`list`) and whether uv is needed (`uv`) to its outputs, which the other steps' `if:` read. The checks name their artifact `python-quality-reports-<report_name>-<random>` and upload `output_dir` with `if: always()` and `store_artifacts`. Every `uses:` is pinned to a commit SHA with its version in a comment.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. The actions were generated from the command YAML; keep them in sync by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number. The action descriptions leave out "Environment variables are expanded". `tests/actions_test.sh` checks all of this.

### Tests

- `tests/install_test.sh`: the shared install contract (`tests/install_contract.sh`, with `tests/install_fixtures/release.sh`) for uv, Ruff and ty, and that their shared blocks are identical. The contract needs bash 4.3.
- `tests/install_tool_test.sh`: `install_tool.sh` against a stand-in uv and Python, for every locked tool (its module, its lock, its script) and `install_python`. It hides a real `circleci` on the `PATH` from every run.
- `tests/commands_test.sh`: every check through `tests/run_command.sh` (with its YAML defaults), in a git repository with an origin and a branch, against shell stand-ins for Ruff, ty, Pyright, uv, twine and check-wheel-contents, and Python stand-ins (`tests/fixtures/fake`) for mypy, deptry, Griffe, pytest and coverage.py, run by a stand-in interpreter: the real `python3` with the stand-ins first on its import path (`STUB_HIDE` makes a module unimportable). It is the project's `.venv` and the tool environments, with scripts laid out as `install_tool.sh` writes them. The helper runs for real. Every run record is checked against the schema when jsonschema is installed. It passes with bash 4.0, 4.3 and 5 first on the `PATH`.
- `tests/wiring_test.sh`: every `PARAM_` a script reads is set, every parameter used, reports stored, run steps named, the README documents every command and action, defaults are the newest releases, the helper is Python 3.11 syntax, the schema names every command with a run record.
- `tests/validate_reports.sh` (and `.py`): the CI jobs' reports: SARIF against the OASIS schema pinned by SHA-256, JUnit counts, run records.
- Fixtures: `tests/fixtures/clean` (a src-layout project every check passes, 100% covered), `dirty` (each check finds something: an unformatted file, F401, a wrong return type and an unresolved import, a failing test, DEP001 and DEP002, a README twine rejects and `tests/` at the wheel's top level) and `api-break` (clean's `__init__.py` with a removed parameter and a new required one).

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-install`, `test-env-subst` (env subst and shell conventions), `test-commands` (`cimg/python`, with jsonschema; then the wiring test), `test-actions`, orb-tools lint, pack and review (`orb_name: python-quality`), shellcheck.
- `.circleci/test-deploy.yml` - With the real tools: `install-test` (every tool on `cimg/base`, with Python 3.11 and 3.14, the binaries the tables pin, a second install from the cache), `checksum-test` (unlisted releases fail closed; `known_versions` installs unverified), `arm64-test`, `checks-test` (every check passes on the clean project, and its checkout is unchanged), `findings-test` (report_only reports what the dirty project holds, each check fails by default through `tests/run_command.sh`, and `api_compat` finds the api-break branch's changes). Each ends with `tests/validate_reports.sh`. Publishing runs on `v*` tags.
- `.github/workflows/actions.yml` - The same with the actions on GitHub's runners: `offline-tests`, `install` (amd64 and arm64, Python 3.11, an unlisted Ruff failing), `install-from-cache` (the download hosts blocked), `install-hash` (each binary's `install_hash.sh` with `gh attestation verify`), `checks` (both architectures), `findings` (each check failing, under `continue-on-error`, with its report checked).

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `pq_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them (`tests/run_command.sh` sets them from the YAML).
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, so copy `"$@"` into an array only when `$#` is non-zero.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'` (`pq_export`); `eval` only runs orb code (`"${SCRIPT_PYTHON_QUALITY_LIB}"`). Secrets never go on a command line.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script.
- Variables a script sets for the lib to read carry `# shellcheck disable=SC2034 # read by ...`, since shellcheck can't see into the eval'd lib.
- The scripts must work with jq 1.6: never `jq -e` on a tool's output, and in jq bind a field before piping into another value (`.check_name as $rule | .description | ltrimstr($rule)`).

## Naming

Command names say what they check: the job (`fmt`, `lint`, `test`, `package`), the tool where several check the same thing (`mypy`, `pyright`, `ty`), or the subject (`deps`, `api_compat`). Parameters that map onto one tool option take its name in snake_case (`config`, `project`, `runner`, `fail_on`, `coverage_source`, `no_sources`, `search_paths`); `paths`, `environment` and `extra_args` mean the same in every command that has them. Plumbing matches the other juburr orbs: `working_dir`, `output_dir`, `report_name`, `junit`, `run_record`, `report_only`, `allow_empty`, `store_artifacts`; lists take commas or spaces.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck` over every script and `yamllint .`
- Run every `tests/*_test.sh`, also with bash 4.0 and 4.3 first on the `PATH` (the install contract needs 4.3)
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`, and validate `.circleci/test-deploy.yml` with the packed orb spliced in under `orbs.python-quality-orb`
- Run `actionlint .github/workflows/actions.yml`
- Never run the real tools on a workstation you don't control; CI runs them
