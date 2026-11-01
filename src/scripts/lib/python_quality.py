"""The python-quality-orb helper, run as python -I -c "${SCRIPT_PYTHON_QUALITY_PY}".

Commands:

  junit FILE
      Summarizes a pytest JUnit XML report as JSON: the counts, and the
      tests that failed or errored, with their file and line.

  mypy-config [CONFIG]
      Finds the configuration mypy reads, as mypy does (CONFIG, or mypy.ini,
      .mypy.ini, pyproject.toml with [tool.mypy] and setup.cfg with [mypy],
      from the working directory up to a .git or .hg directory, then the
      user's configuration), and prints what the mypy command needs from
      it as JSON: its path, whether it sets python_version and the files to
      check, and the plugins it loads. Needs Python 3.11 (tomllib).

  api-diff --old DIR --new DIR [--package NAME]... [--search-path PATH]...
           [--ignore GLOB]...
      Loads each package's API with Griffe from the old and the new tree,
      statically (nothing is imported), and prints the changes that break
      callers as JSON. Without --package, the package is found from
      pyproject.toml's [project] name. Runs on the Python Griffe is
      installed in.

Exit codes: 0, 1 with an "ERROR:" line for input it refuses, 2 for usage.
Standard library only, and Python 3.11 syntax.
"""

import configparser
import fnmatch
import json
import os
import re
import sys


def fail(message):
    for i, line in enumerate(message.splitlines()):
        print(("ERROR: " if i == 0 else "  ") + line, file=sys.stderr)
    sys.exit(1)


def usage(message):
    print("ERROR: " + message, file=sys.stderr)
    sys.exit(2)


# --- junit ---


def junit(args):
    import xml.etree.ElementTree as ET

    if len(args) != 1:
        usage("junit takes one file.")
    try:
        root = ET.parse(args[0]).getroot()
    except (OSError, ET.ParseError) as error:
        fail("Could not read the JUnit report %s: %s" % (args[0], error))
    suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
    if root.tag not in ("testsuite", "testsuites"):
        fail("%s is not a JUnit report (its root element is <%s>)." % (args[0], root.tag))
    counts = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0}
    failed = []
    for suite in suites:
        for case in suite.iter("testcase"):
            counts["tests"] += 1
            outcome, message, text = None, "", ""
            for child in case:
                if child.tag in ("failure", "error"):
                    outcome = child.tag
                    text = (child.text or "").strip()
                    lines = text.splitlines()
                    message = child.get("message") or (lines[-1] if lines else "")
                    break
                if child.tag == "skipped":
                    outcome = "skipped"
            if outcome == "failure":
                counts["failures"] += 1
            elif outcome == "error":
                counts["errors"] += 1
            elif outcome == "skipped":
                counts["skipped"] += 1
            if outcome in ("failure", "error"):
                line = case.get("line")
                failed.append({
                    "outcome": outcome,
                    "classname": case.get("classname") or "",
                    "name": case.get("name") or "",
                    "file": case.get("file"),
                    # pytest writes the 0-based line of the test's definition.
                    "line": int(line) + 1 if line and line.isdigit() else None,
                    "message": message,
                    "detail": text[-4000:],
                })
    json.dump(dict(counts, failed=failed), sys.stdout)
    print()


# --- mypy-config ---


def toml_load(path):
    import tomllib

    with open(path, "rb") as f:
        return tomllib.load(f)


def mypy_section(path):
    """The [mypy] settings in PATH as a dict, or None when PATH doesn't
    configure mypy (as mypy's _parse_individual_file decides)."""
    if not os.path.isfile(path):
        return None
    shared = os.path.basename(path) in ("pyproject.toml", "setup.cfg")
    try:
        if path.lower().endswith(".toml"):
            data = toml_load(path).get("tool", {})
            if not isinstance(data, dict) or "mypy" not in data:
                return None
            section = data["mypy"]
            return section if isinstance(section, dict) else {}
        parser = configparser.RawConfigParser()
        parser.read(path)
    except Exception as error:  # mypy reports the error and ignores the file
        print("WARN: mypy can't read %s, and ignores it: %s" % (path, error), file=sys.stderr)
        return None
    if "mypy" not in parser:
        return None if shared else {}
    return dict(parser["mypy"])


def mypy_config(args):
    if len(args) > 1:
        usage("mypy-config takes at most one file.")
    found = None
    if args and args[0]:
        found = args[0]
        if not os.path.isfile(found):
            fail("config names %s, which doesn't exist in %s." % (found, os.getcwd()))
        section = mypy_section(found)
    else:
        section = None
        current = os.path.abspath(os.getcwd())
        while found is None:
            for name in ("mypy.ini", ".mypy.ini", "pyproject.toml", "setup.cfg"):
                candidate = os.path.relpath(os.path.join(current, name))
                section = mypy_section(candidate)
                if section is not None:
                    found = candidate
                    break
            if found or any(os.path.exists(os.path.join(current, d)) for d in (".git", ".hg")):
                break
            parent = os.path.dirname(current)
            if parent == current:
                break
            current = parent
        if found is None:
            users = ["~/.config/mypy/config", "~/.mypy.ini"]
            if os.environ.get("XDG_CONFIG_HOME"):
                users.insert(0, os.path.join(os.environ["XDG_CONFIG_HOME"], "mypy/config"))
            for candidate in map(os.path.expanduser, users):
                section = mypy_section(candidate)
                if section is not None:
                    found = candidate
                    break
    section = section or {}
    plugins = section.get("plugins") or []
    if isinstance(plugins, str):
        plugins = [p.strip() for p in plugins.split(",")]
    plugins = [str(p).strip() for p in plugins if str(p).strip()]
    json.dump({
        "config": found,
        "python_version": str(section["python_version"]) if "python_version" in section else None,
        "files": any(section.get(key) for key in ("files", "packages", "modules")),
        "plugins": plugins,
    }, sys.stdout)
    print()


# --- api-diff ---


def project_package(root):
    """The import name of the project in ROOT: pyproject.toml's [project]
    name, normalized, when a package or module of that name is in src/ or
    at the top."""
    path = os.path.join(root, "pyproject.toml")
    try:
        name = toml_load(path).get("project", {}).get("name")
    except FileNotFoundError:
        name = None
    except Exception as error:
        fail("Could not read %s: %s" % (path, error))
    if not isinstance(name, str) or not name:
        fail("package is empty, and %s names no project to take it from.\n"
             "Name the import packages to compare in package." % path)
    module = re.sub(r"[-_.]+", "_", name).lower()
    for base in ("src", "."):
        for candidate in (module, module + ".py"):
            if os.path.exists(os.path.join(root, base, candidate)):
                return module
    fail("package is empty, and there is no package %s (from the project name %s) in src/ or at the top.\n"
         "Name the import packages to compare in package." % (module, name))


def location(obj, root):
    """The file of a Griffe object (or of the module that holds an alias),
    relative to ROOT, and the object's line."""
    try:
        target = obj.parent if obj.is_alias else obj
        path = target.filepath
        if isinstance(path, list):
            path = path[0]
        line = None if obj.is_alias else getattr(obj, "lineno", None)
        return os.path.relpath(str(path), os.path.abspath(root)), line
    except Exception:
        return None, None


ANSI = re.compile(r"\x1b\[[0-9;]*m")


def api_diff(args):
    import argparse

    parser = argparse.ArgumentParser(prog="api-diff")
    parser.add_argument("--old", required=True)
    parser.add_argument("--new", required=True)
    parser.add_argument("--package", action="append", default=[])
    parser.add_argument("--search-path", action="append", default=[])
    parser.add_argument("--ignore", action="append", default=[])
    options = parser.parse_args(args)

    import logging

    import griffe

    # Griffe logs what it can't resolve; the report says what matters.
    logging.getLogger("griffe").setLevel(logging.ERROR)
    packages = options.package or [project_package(options.new)]
    search = options.search_path or None
    results = []
    for package in packages:
        roots = {}
        for side, root in (("old", options.old), ("new", options.new)):
            paths = search or (["src", "."] if os.path.isdir(os.path.join(root, "src")) else ["."])
            paths = [os.path.join(root, p) for p in paths if os.path.isdir(os.path.join(root, p))]
            try:
                roots[side] = griffe.load(
                    package, search_paths=paths, try_relative_path=False, allow_inspection=False,
                    force_inspection=False, resolve_aliases=True, resolve_external=None,
                    docstring_parser=None)
            except ModuleNotFoundError:
                roots[side] = None
            except Exception as error:
                fail("Griffe could not load %s from the %s tree: %s: %s" % (
                    package, side, type(error).__name__, error))
        if roots["new"] is None:
            fail("There is no package %s in %s to compare. Check package and search_paths." % (
                package, os.path.abspath(options.new)))
        entry = {"package": package, "new_in_head": roots["old"] is None, "breakages": [], "ignored": 0}
        if roots["old"] is not None:
            for breakage in griffe.find_breaking_changes(roots["old"], roots["new"]):
                path = breakage.obj.path
                if any(fnmatch.fnmatchcase(path, pattern) for pattern in options.ignore):
                    entry["ignored"] += 1
                    continue
                old_file, old_line = location(breakage.obj, options.old)
                new_obj = None
                try:
                    new_obj = roots["new"].get_member(path.split(".", 1)[1]) if "." in path else roots["new"]
                except Exception:
                    new_obj = None
                new_file, new_line = location(new_obj, options.new) if new_obj is not None else (None, None)
                try:
                    explanation = breakage.explain(style=griffe.ExplanationStyle.ONE_LINE)
                except Exception:
                    explanation = str(breakage)
                entry["breakages"].append({
                    "kind": breakage.kind.name.lower(),
                    "description": breakage.kind.value,
                    "object": path,
                    "old_value": None if breakage.old_value is None else str(breakage.old_value),
                    "new_value": None if breakage.new_value is None else str(breakage.new_value),
                    "file": new_file or old_file,
                    "line": new_line if new_file else old_line,
                    "in_head": bool(new_file),
                    "explanation": ANSI.sub("", explanation).strip(),
                })
        results.append(entry)
    json.dump(results, sys.stdout)
    print()


COMMANDS = {"junit": junit, "mypy-config": mypy_config, "api-diff": api_diff}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        usage("the first argument must be one of: " + ", ".join(COMMANDS) + ".")
    COMMANDS[sys.argv[1]](sys.argv[2:])
