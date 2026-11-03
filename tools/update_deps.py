#!/usr/bin/env python3
"""Move each deps/ submodule to the revision pdfium/DEPS pins.

Usage (from anywhere):

    python3 tools/update_deps.py [--dry-run]

Run it after checking out a new PDFium in pdfium/, the first step in README.md's "Relationship to
upstream". For every submodule under deps/ it finds the same path in pdfium/DEPS and checks the
submodule out at the revision named there, fetching only that commit, as the submodules are shallow.
A bundled copy that is not checked out (they are left out by default) is fetched first, so every pin
moves, whether this machine's builds use it or not.

What it cannot check it leaves alone: a path pdfium/DEPS no longer lists, or one whose repository it
now names at a different address, is reported and not moved. --dry-run reports what is pinned and
what is checked out, and runs no git.

Afterwards: run tools/gn2cmake.py, review its diff, and commit pdfium/, deps/ and cmake/generated/.
"""

import argparse
import ast
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PDFIUM = os.path.join(ROOT, "pdfium")


class Unsupported:
    """A value in DEPS this reader does not evaluate. An error only where one is used."""

    def __init__(self, what):
        self.what = what


def evaluate(node, variables):
    """The value of one expression in DEPS: literals, lists, dicts, '+', and Var() and Str()."""
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.List):
        return [evaluate(item, variables) for item in node.elts]
    if isinstance(node, ast.Dict):
        return {evaluate(k, variables): evaluate(v, variables) for k, v in zip(node.keys, node.values) if k is not None}
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = evaluate(node.left, variables)
        right = evaluate(node.right, variables)
        if isinstance(left, Unsupported):
            return left
        if isinstance(right, Unsupported):
            return right
        return left + right
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and len(node.args) == 1:
        arg = evaluate(node.args[0], variables)
        if node.func.id == "Str":
            return arg
        if node.func.id == "Var" and isinstance(arg, str) and arg in variables:
            return variables[arg]
    return Unsupported(ast.dump(node)[:100])


def read_deps():
    """The deps table of pdfium/DEPS. The file is Python, and is read as data, never run."""
    with open(os.path.join(PDFIUM, "DEPS"), encoding="utf-8") as f:
        tree = ast.parse(f.read(), "pdfium/DEPS")
    variables = {}
    deps = {}
    for node in tree.body:
        if not (isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)):
            continue
        name = node.targets[0].id
        if name == "vars" and isinstance(node.value, ast.Dict):
            # In order, so a variable may use one defined above it.
            for k, v in zip(node.value.keys, node.value.values):
                variables[evaluate(k, variables)] = evaluate(v, variables)
        elif name == "deps" and isinstance(node.value, ast.Dict):
            deps = evaluate(node.value, variables)
    return deps


def read_submodules():
    """(path, url) of each submodule in .gitmodules, in the order listed."""
    modules = []
    current = None
    with open(os.path.join(ROOT, ".gitmodules"), encoding="utf-8") as f:
        for line in f:
            if re.match(r'\s*\[submodule "', line):
                current = {}
                modules.append(current)
            elif current is not None:
                m = re.match(r"\s*(\w+)\s*=\s*(.*?)\s*$", line)
                if m:
                    current[m.group(1)] = m.group(2)
    return [(m["path"], m.get("url", "")) for m in modules if "path" in m]


def pinned(entry):
    """(url, revision) from one deps entry: "url@revision", or a dict holding that as its url."""
    if isinstance(entry, dict):
        entry = entry.get("url")
    if not isinstance(entry, str) or "@" not in entry:
        return None
    url, _, revision = entry.rpartition("@")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        return None
    return url, revision


def same_repository(a, b):
    def bare(url):
        url = url.rstrip("/")
        return url[: -len(".git")] if url.endswith(".git") else url

    return bare(a) == bare(b)


def checked_out(path):
    """The commit checked out at `path`: None when it is not checked out, "" when not on a commit."""
    dot_git = os.path.join(ROOT, path, ".git")
    if os.path.isfile(dot_git):
        with open(dot_git, encoding="utf-8") as f:
            line = f.read().strip()
        if not line.startswith("gitdir: "):
            return ""
        gitdir = os.path.normpath(os.path.join(ROOT, path, line[len("gitdir: "):]))
    elif os.path.isdir(dot_git):
        gitdir = dot_git
    else:
        return None
    try:
        with open(os.path.join(gitdir, "HEAD"), encoding="utf-8") as f:
            head = f.read().strip()
    except OSError:
        return ""
    # A submodule checkout is a detached commit. One on a branch is reported as not on a commit.
    return head if re.fullmatch(r"[0-9a-f]{40}", head) else ""


def git(*args, cwd=ROOT):
    return subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description="Move each deps/ submodule to the revision pdfium/DEPS pins.")
    parser.add_argument("--dry-run", action="store_true", help="report only, and run no git")
    args = parser.parse_args()

    deps = read_deps()
    problems = 0
    moved = 0
    for path, url in read_submodules():
        if not path.startswith("deps/"):
            continue
        key = path[len("deps/"):]
        pin = pinned(deps.get(key)) if key in deps else None
        if key not in deps:
            print(f"{path}: pdfium/DEPS no longer lists {key}. Left as it is.")
            problems += 1
            continue
        if pin is None:
            print(f"{path}: pdfium/DEPS lists {key} in a form this script does not read. Left as it is.")
            problems += 1
            continue
        pin_url, revision = pin
        if not same_repository(pin_url, url):
            print(f"{path}: pdfium/DEPS now names its repository {pin_url}, and .gitmodules {url}. "
                  "Left as it is: change the address in .gitmodules, then run this again.")
            problems += 1
            continue

        now = checked_out(path)
        if args.dry_run:
            if now is None:
                state = "not checked out"
            elif now == revision:
                state = "checked out at the pin"
            elif now == "":
                state = "checked out, not at a commit this script can read"
            else:
                state = f"checked out at {now[:12]}"
            print(f"{path}: pinned at {revision[:12]}, {state}")
            continue

        try:
            if now is None:
                git("submodule", "update", "--init", "--checkout", "--", path)
            here = os.path.join(ROOT, path)
            now = git("rev-parse", "HEAD", cwd=here)
            if now == revision:
                print(f"{path}: already at {revision[:12]}")
                continue
            git("fetch", "--depth", "1", "origin", revision, cwd=here)
            git("checkout", "--quiet", "--detach", revision, cwd=here)
            print(f"{path}: {now[:12]} -> {revision[:12]}")
            moved += 1
        except subprocess.CalledProcessError as e:
            print(f"{path}: git {' '.join(e.cmd[3:])} failed: {(e.stderr or '').strip()}")
            problems += 1

    if not args.dry_run and moved:
        print("Next: python3 tools/gn2cmake.py, review its diff, and commit pdfium/, deps/ and cmake/generated/.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
