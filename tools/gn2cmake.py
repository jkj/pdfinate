#!/usr/bin/env python3
"""Translate PDFium's BUILD.gn files into CMake data.

Usage (from the top of the PDFinate tree):

    python3 tools/gn2cmake.py

Reads pdfium/BUILD.gn and every BUILD.gn inside pdfium/ that the `//:pdfium` target reaches, and
writes cmake/generated/pdfium_gn.cmake. That file only records data: for each GN target and config,
its sources, deps, configs, defines, include directories and libraries, each guarded by the CMake
condition that GN would have evaluated. cmake/gn.cmake turns the data into targets.

Settings PDFinate fixes are folded away here (no XFA, no V8, no Skia, no Rust, no PartitionAlloc).
Settings that differ per platform or per PDFinate option stay as CMake conditions on PDFINATE_*
variables, so the one generated file serves every platform.

Run it again after moving the pdfium submodule, and review the diff. The generated file records a
checksum of every BUILD.gn it read, and the CMake build refuses to configure when they no longer
match, so a stale file cannot go unnoticed.
"""

import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PDFIUM = os.path.join(ROOT, "pdfium")
OUTPUT = os.path.join(ROOT, "cmake", "generated", "pdfium_gn.cmake")

# Paths that gclient fetches from pdfium/DEPS rather than holding in the PDFium repository. PDFinate
# keeps them under deps/ at the same relative paths, so a source or include path starting with one of
# these lives under ${PDFINATE_DEPS_DIR}, and anything else under ${PDFINATE_PDFIUM_DIR}.
DEPS_PATHS = [
    "build",
    "third_party/abseil-cpp",
    "third_party/dragonbox/src",
    "third_party/fast_float/src",
    "third_party/freetype/src",
    "third_party/harfbuzz/src",
    "third_party/highway/src",
    "third_party/icu",
    "third_party/libjpeg_turbo",
    "third_party/libpng",
    "third_party/libyuv",
    "third_party/brotli",
    "third_party/zlib",
]


class Sym(str):
    """A condition GN cannot decide here: a CMake expression, evaluated at configure time."""


class SymStr(str):
    """A string-valued variable GN cannot decide here: the name of a CMake variable."""


# Platform variables become CMake variables, which cmake/platform.cmake sets.
SCOPE_SYMBOLIC = {
    "is_win": Sym("PDFINATE_IS_WIN"),
    "is_mac": Sym("PDFINATE_IS_MAC"),
    "is_ios": Sym("PDFINATE_IS_IOS"),
    "is_apple": Sym("PDFINATE_IS_APPLE"),
    "is_linux": Sym("PDFINATE_IS_LINUX"),
    "is_android": Sym("PDFINATE_IS_ANDROID"),
    "is_posix": Sym("PDFINATE_IS_POSIX"),
    "current_cpu": SymStr("PDFINATE_CPU"),
    "target_cpu": SymStr("PDFINATE_CPU"),
    # Dependencies the embedding project may supply instead of the bundled copy.
    "use_system_freetype": Sym("PDFINATE_USE_SYSTEM_FREETYPE"),
    "pdf_bundle_freetype": Sym("(NOT PDFINATE_USE_SYSTEM_FREETYPE)"),
    "use_system_harfbuzz": Sym("PDFINATE_USE_SYSTEM_HARFBUZZ"),
    "use_system_lcms2": Sym("PDFINATE_USE_SYSTEM_LCMS2"),
    "use_system_libjpeg": Sym("PDFINATE_USE_SYSTEM_JPEG"),
    "use_system_libopenjpeg2": Sym("PDFINATE_USE_SYSTEM_OPENJPEG"),
    "use_system_libpng": Sym("PDFINATE_USE_SYSTEM_PNG"),
    "use_system_libtiff": Sym("PDFINATE_USE_SYSTEM_TIFF"),
    "use_system_zlib": Sym("PDFINATE_USE_SYSTEM_ZLIB"),
    # Optional speed-ups.
    "pdf_use_libyuv": Sym("PDFINATE_USE_LIBYUV"),
    "pdf_enable_brotli": Sym("PDFINATE_ENABLE_BROTLI"),
}

# Settings PDFinate fixes. Each is the value upstream would see in a standalone, non-Chromium build
# without XFA, V8, Skia or Rust.
SCOPE_FIXED = {
    "is_chromeos": False,
    "is_fuchsia": False,
    "is_nacl": False,
    "is_castos": False,
    "is_clang": True,
    "is_debug": False,
    "is_official_build": False,
    "is_component_build": False,
    "is_asan": False,
    "is_msan": False,
    "is_ubsan": False,
    "build_with_chromium": False,
    "use_glib": False,
    "use_custom_libcxx": False,
    "use_libjpeg_turbo": True,
    "enable_paint_preview": False,
    "checkout_skia": False,
    "clang_use_chrome_plugins": False,
    "current_toolchain": "//build/toolchain:default",
    "default_toolchain": "//build/toolchain:default",
    "pdf_enable_xfa": False,
    "pdf_enable_v8": False,
    "pdf_use_skia": False,
    "pdf_use_agg": True,
    "pdf_enable_freetype": True,
    "pdf_enable_click_logging": False,
    "pdf_enable_fontations": False,
    "pdf_enable_rust_bmp": False,
    "pdf_enable_rust_jpeg": False,
    "pdf_enable_rust_png": False,
    "pdf_use_partition_alloc": False,
    "pdf_is_standalone": False,
    "pdf_is_complete_lib": False,
    "enable_callgrind": False,
    "build_gn_logs": [],
    "enable_rust": False,
    "enable_rust_cxx": False,
    "use_libfuzzer": False,
    "use_clang_coverage": False,
}

TARGET_TYPES = {"source_set", "static_library", "component", "group", "config", "pkg_config"}
# Templates for tests, fuzzers and Rust: nothing the library needs.
SKIPPED_TEMPLATES = {
    "pdfium_unittest_source_set", "pdfium_embeddertest_source_set", "test", "fuzzer_test",
    "rust_static_library", "executable", "write_file",
}
IGNORED_CALLS = {"import", "assert", "declare_args", "error", "print"}
LIST_FIELDS = {
    "sources", "public", "deps", "public_deps", "configs", "public_configs",
    "all_dependent_configs", "defines", "include_dirs", "libs", "frameworks",
}
LABEL_FIELDS = {"deps", "public_deps", "configs", "public_configs", "all_dependent_configs"}
PATH_FIELDS = {"sources", "public", "include_dirs"}


class GNError(Exception):
    pass


# --- Lexer ---------------------------------------------------------------------------------------

TOKEN_RE = re.compile(r"""
    (?P<ws>[ \t\r\n]+)
  | (?P<comment>\#[^\n]*)
  | (?P<string>"(?:\\.|[^"\\])*")
  | (?P<number>-?[0-9]+)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>\+=|-=|==|!=|<=|>=|&&|\|\||[-+=<>!{}\[\](),.])
""", re.VERBOSE)


def tokenize(text, path):
    pos = 0
    tokens = []
    while pos < len(text):
        m = TOKEN_RE.match(text, pos)
        if not m:
            line = text.count("\n", 0, pos) + 1
            raise GNError(f"{path}:{line}: cannot read {text[pos:pos + 20]!r}")
        kind = m.lastgroup
        if kind not in ("ws", "comment"):
            tokens.append((kind, m.group(kind), text.count("\n", 0, pos) + 1))
        pos = m.end()
    tokens.append(("eof", "", text.count("\n") + 1))
    return tokens


# --- Parser --------------------------------------------------------------------------------------

class Parser:
    def __init__(self, tokens, path):
        self.t = tokens
        self.i = 0
        self.path = path

    def peek(self, value=None):
        kind, text, _ = self.t[self.i]
        return text == value if value is not None else (kind, text)

    def take(self, value=None):
        kind, text, line = self.t[self.i]
        if value is not None and text != value:
            raise GNError(f"{self.path}:{line}: expected {value!r}, found {text!r}")
        self.i += 1
        return kind, text, line

    def statements(self, until):
        out = []
        while not self.peek(until):
            out.append(self.statement())
        return out

    def statement(self):
        kind, text, line = self.take()
        if kind == "ident" and text == "if":
            return self.if_statement(line)
        if kind != "ident":
            raise GNError(f"{self.path}:{line}: unexpected {text!r}")
        if self.peek("("):
            self.take("(")
            args = []
            while not self.peek(")"):
                args.append(self.expr())
                if self.peek(","):
                    self.take(",")
            self.take(")")
            block = None
            if self.peek("{"):
                self.take("{")
                block = self.statements("}")
                self.take("}")
            return ("call", text, args, block, line)
        lhs = text
        while self.peek("."):
            self.take(".")
            lhs += "." + self.take()[1]
        _, op, _ = self.take()
        if op not in ("=", "+=", "-="):
            raise GNError(f"{self.path}:{line}: expected an assignment after {lhs!r}")
        return ("assign", lhs, op, self.expr(), line)

    def if_statement(self, line):
        self.take("(")
        cond = self.expr()
        self.take(")")
        self.take("{")
        then = self.statements("}")
        self.take("}")
        other = []
        if self.peek("else"):
            self.take("else")
            if self.peek("if"):
                kind, text, l2 = self.take("if")
                other = [self.if_statement(l2)]
            else:
                self.take("{")
                other = self.statements("}")
                self.take("}")
        return ("if", cond, then, other, line)

    # Precedence, loosest first, as GN has it.
    BINARY = [("||",), ("&&",), ("==", "!="), ("<", "<=", ">", ">="), ("+", "-")]

    def expr(self, level=0):
        if level == len(self.BINARY):
            return self.unary()
        left = self.expr(level + 1)
        while self.peek()[1] in self.BINARY[level]:
            op = self.take()[1]
            left = ("binary", op, left, self.expr(level + 1))
        return left

    def unary(self):
        if self.peek("!"):
            self.take("!")
            return ("not", self.unary())
        return self.primary()

    def primary(self):
        kind, text, line = self.take()
        if kind == "string":
            return ("rawstr", text[1:-1])
        if kind == "number":
            return ("num", int(text))
        if text == "[":
            items = []
            while not self.peek("]"):
                items.append(self.expr())
                if self.peek(","):
                    self.take(",")
            self.take("]")
            return ("list", items)
        if text == "(":
            e = self.expr()
            self.take(")")
            return e
        if kind == "ident":
            if text in ("true", "false"):
                return ("bool", text == "true")
            if self.peek("("):
                self.take("(")
                args = []
                while not self.peek(")"):
                    args.append(self.expr())
                    if self.peek(","):
                        self.take(",")
                self.take(")")
                return ("fcall", text, args, line)
            node = ("ident", text, line)
            while self.peek(".") or self.peek("["):
                if self.peek("."):
                    self.take(".")
                    node = ("member", node, self.take()[1], line)
                else:
                    self.take("[")
                    node = ("index", node, self.expr(), line)
                    self.take("]")
            return node
        raise GNError(f"{self.path}:{line}: unexpected {text!r}")


def decode_string(s):
    if "$" in s:
        raise GNError(f"string interpolation is not supported: {s!r}")
    return re.sub(r"\\(.)", r"\1", s)


# --- Conditions ----------------------------------------------------------------------------------

def c_not(a):
    if isinstance(a, bool):
        return not a
    m = re.fullmatch(r"\(NOT (.*)\)", a)
    if m and balanced(m.group(1)):
        return Sym(m.group(1))
    return Sym(f"(NOT {a})")


def balanced(s):
    depth = 0
    for ch in s:
        depth += {"(": 1, ")": -1}.get(ch, 0)
        if depth < 0:
            return False
    return depth == 0


def c_and(a, b):
    if a is False or b is False:
        return False
    if a is True:
        return b
    if b is True:
        return a
    return Sym(f"({a} AND {b})")


def c_or(a, b):
    if a is True or b is True:
        return True
    if a is False:
        return b
    if b is False:
        return a
    if a == c_not(b):
        return True
    return Sym(f"({a} OR {b})")


def cmake_quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace(";", "\\;") + '"'


# --- Evaluation ----------------------------------------------------------------------------------

class Target:
    def __init__(self, label, kind):
        self.label = label
        self.kind = kind
        self.ops = []  # (condition, field, op, [items])
        self.condition = False  # OR of the conditions it is defined under


class Evaluator:
    def __init__(self):
        self.targets = {}
        self.files = {}  # dir -> sha256 of its BUILD.gn
        self.pending = ["//:pdfium"]
        self.external = set()
        self.skipped = set()

    # Labels and paths --------------------------------------------------------

    @staticmethod
    def normalize_dir(base, rel):
        if rel.startswith("//"):
            path = rel[2:]
        else:
            path = os.path.normpath(os.path.join(base, rel)) if base else os.path.normpath(rel)
        path = path.replace(os.sep, "/").strip("/")
        return "" if path == "." else path

    def label(self, base, text):
        if ":" in text:
            d, name = text.split(":", 1)
            d = self.normalize_dir(base, d) if d else base
        else:
            d = self.normalize_dir(base, text)
            name = os.path.basename(d)
        return f"//{d}:{name}"

    def path(self, base, text):
        p = self.normalize_dir(base, text)
        for dep in DEPS_PATHS:
            if p == dep or p.startswith(dep + "/"):
                return "${PDFINATE_DEPS_DIR}/" + p if p else "${PDFINATE_DEPS_DIR}"
        return "${PDFINATE_PDFIUM_DIR}/" + p if p else "${PDFINATE_PDFIUM_DIR}"

    @staticmethod
    def is_internal_dir(d):
        if any(d == dep or d.startswith(dep + "/") for dep in DEPS_PATHS):
            return False
        return os.path.isfile(os.path.join(PDFIUM, d, "BUILD.gn"))

    # Files -------------------------------------------------------------------

    def run(self):
        # Follows every label a reached target names, whatever its condition, so the output holds
        # each target any platform or option can reach. CMake walks the graph again at configure
        # time, with the conditions decided, to pick the ones this build compiles.
        self.reached = set()
        self.missing = set()
        while self.pending:
            label = self.pending.pop()
            if label in self.reached:
                continue
            self.reached.add(label)
            d = label[2:].split(":")[0]
            if not self.is_internal_dir(d):
                self.external.add(label)
                continue
            if d not in self.files:
                self.load(d)
            t = self.targets.get(label)
            if t is None:
                self.missing.add(label)
                continue
            for cond, field, op, items in t.ops:
                if field in LABEL_FIELDS and op != "-=" and cond is not False:
                    self.pending.extend(items)

    def load(self, d):
        path = os.path.join(PDFIUM, d, "BUILD.gn")
        with open(path, "rb") as f:
            data = f.read()
        self.files[d] = hashlib.sha256(data).hexdigest()
        rel = os.path.relpath(path, ROOT)
        tree = Parser(tokenize(data.decode("utf-8"), rel), rel).statements("")
        scope = dict(SCOPE_FIXED)
        scope.update(SCOPE_SYMBOLIC)
        self.block(tree, scope, True, d, None, rel)

    # Statements --------------------------------------------------------------

    def block(self, stmts, scope, cond, d, target, rel):
        for s in stmts:
            kind = s[0]
            if kind == "if":
                _, test, then, other, line = s
                c = self.value(test, scope, d, rel)
                if isinstance(c, bool):
                    self.block(then if c else other, scope, cond, d, target, rel)
                elif isinstance(c, Sym):
                    self.block(then, scope, c_and(cond, c), d, target, rel)
                    self.block(other, scope, c_and(cond, c_not(c)), d, target, rel)
                else:
                    raise GNError(f"{rel}:{line}: condition is not a boolean")
            elif kind == "assign":
                _, lhs, op, rhs, line = s
                if target is not None and lhs in LIST_FIELDS:
                    items = self.value(rhs, scope, d, rel)
                    if not isinstance(items, list) or not all(isinstance(x, str) and not isinstance(x, (Sym, SymStr)) for x in items):
                        raise GNError(f"{rel}:{line}: {lhs} is not a list of plain strings")
                    target.ops.append((cond, lhs, op, [self.item(lhs, x, d) for x in items]))
                    continue
                if cond is not True and target is None:
                    raise GNError(f"{rel}:{line}: conditional file-level assignment to {lhs} is not supported")
                v = self.value(rhs, scope, d, rel)
                if op == "=":
                    scope[lhs] = v
                elif op == "+=":
                    scope[lhs] = scope.get(lhs, []) + v
                else:
                    scope[lhs] = [x for x in scope.get(lhs, []) if x not in v]
            elif kind == "call":
                _, name, args, body, line = s
                if name in IGNORED_CALLS or name in SKIPPED_TEMPLATES:
                    continue
                if name not in TARGET_TYPES:
                    # A template this script does not expand. Harmless unless the library needs a
                    # target it defines, which then shows up as a missing label.
                    self.skipped.add(name)
                    continue
                if target is not None:
                    raise GNError(f"{rel}:{line}: nested target")
                tname = self.value(args[0], scope, d, rel)
                label = f"//{d}:{tname}"
                kind_name = "config" if name in ("config", "pkg_config") else name
                t = self.targets.get(label)
                if t is None:
                    t = self.targets[label] = Target(label, kind_name)
                elif t.kind != kind_name:
                    raise GNError(f"{rel}:{line}: {label} is defined as both {t.kind} and {kind_name}")
                t.condition = c_or(t.condition, cond)
                self.block(body or [], dict(scope), cond, d, t, rel)

    def item(self, field, value, d):
        if field in LABEL_FIELDS:
            return self.label(d, value)
        if field in PATH_FIELDS:
            return self.path(d, value)
        return value

    # Expressions -------------------------------------------------------------

    def value(self, e, scope, d, rel):
        kind = e[0]
        if kind == "rawstr":
            return decode_string(e[1])
        if kind in ("num", "bool"):
            return e[1]
        if kind == "list":
            return [self.value(x, scope, d, rel) for x in e[1]]
        if kind == "ident":
            if e[1] not in scope:
                raise GNError(f"{rel}:{e[2]}: unknown variable {e[1]} (add it to SCOPE_FIXED or SCOPE_SYMBOLIC)")
            return scope[e[1]]
        if kind == "not":
            v = self.value(e[1], scope, d, rel)
            return c_not(v)
        if kind == "fcall":
            _, name, args, line = e
            if name == "defined":
                return args[0][0] == "ident" and args[0][1] in scope
            raise GNError(f"{rel}:{line}: unsupported function {name}()")
        if kind == "binary":
            _, op, a, b = e
            if op in ("&&", "||"):
                va = self.value(a, scope, d, rel)
                vb = self.value(b, scope, d, rel)
                return c_and(va, vb) if op == "&&" else c_or(va, vb)
            va = self.value(a, scope, d, rel)
            vb = self.value(b, scope, d, rel)
            if op in ("==", "!="):
                if isinstance(va, SymStr) or isinstance(vb, SymStr):
                    var, lit = (va, vb) if isinstance(va, SymStr) else (vb, va)
                    r = Sym(f"({var} STREQUAL {cmake_quote(lit)})")
                    return r if op == "==" else c_not(r)
                return (va == vb) if op == "==" else (va != vb)
            if op == "+":
                return va + vb
            raise GNError(f"{rel}: unsupported operator {op}")
        raise GNError(f"{rel}: unsupported expression {kind}")


# --- Includes of dependencies --------------------------------------------------------------------

# PDFium includes the headers of these dependencies by their path in Chromium's tree, not as each
# library installs them. When one comes from the embedding project instead, cmake/deps.cmake writes a
# forwarding header at each such path, so this records which paths PDFium uses.
SHIMMABLE = re.compile(r'^\s*#\s*include\s+"(third_party/(?:abseil-cpp|icu/source/common|highway/src|'
                       r'fast_float/src/include|dragonbox/src/include|libyuv/include|brotli/include)/[^"]+)"',
                       re.M)


def dependency_includes(ev):
    found = set()
    for label in ev.reached:
        t = ev.targets.get(label)
        if t is None:
            continue
        for cond, field, op, items in t.ops:
            if field not in ("sources", "public") or op == "-=":
                continue
            for item in items:
                if not item.startswith("${PDFINATE_PDFIUM_DIR}/"):
                    continue
                path = os.path.join(PDFIUM, item[len("${PDFINATE_PDFIUM_DIR}/"):])
                if os.path.isfile(path):
                    with open(path, encoding="utf-8", errors="replace") as f:
                        found.update(SHIMMABLE.findall(f.read()))
    return sorted(found)


# --- Output --------------------------------------------------------------------------------------

def emit(ev):
    try:
        pdfium_head = subprocess.run(["git", "-C", PDFIUM, "rev-parse", "HEAD"], capture_output=True,
                                     text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        pdfium_head = ""
    out = [
        "# Generated by tools/gn2cmake.py from pdfium's BUILD.gn files. Do not edit; run the script again.",
        f"# pdfium commit: {pdfium_head or 'unknown'}",
        "",
        "# The BUILD.gn files this was generated from, and their SHA-256. cmake/gn.cmake refuses to",
        "# configure when any of them has changed since.",
        "set(PDFINATE_GN_INPUTS",
    ]
    for d in sorted(ev.files):
        out.append(f"    \"{d + '/' if d else ''}BUILD.gn\" {ev.files[d]}")
    out.append(")")
    out.append("")
    for label in sorted(l for l in ev.targets if l in ev.reached):
        t = ev.targets[label]
        if t.condition is True:
            out.append(f"pdfinate_gn_target(\"{label}\" {t.kind})")
        else:
            out.append(f"pdfinate_gn_target(\"{label}\" {t.kind} CONDITIONAL)")
            out.append(f"if({t.condition})")
            out.append(f"    pdfinate_gn_defined(\"{label}\")")
            out.append("endif()")
        current = True
        for cond, field, op, items in t.ops:
            if cond is False:
                continue
            verb = {"=": "SET", "+=": "APPEND", "-=": "REMOVE"}[op]
            if (type(cond), cond) != (type(current), current):
                if current is not True:
                    out.append("endif()")
                if cond is not True:
                    out.append(f"if({cond})")
                current = cond
            indent = "    " if current is not True else ""
            if not items:
                out.append(f"{indent}pdfinate_gn_list(\"{label}\" {field} {verb})")
                continue
            out.append(f"{indent}pdfinate_gn_list(\"{label}\" {field} {verb}")
            for x in items:
                out.append(f"{indent}    {cmake_quote(x) if field == 'defines' else chr(34) + x + chr(34)}")
            out.append(f"{indent})")
        if current is not True:
            out.append("endif()")
        out.append("")
    out.append("# The headers of abseil, ICU, highway, fast_float, dragonbox and libyuv that PDFium includes, by")
    out.append("# their path in Chromium's tree. cmake/deps.cmake forwards each to a dependency supplied from outside.")
    out.append("set(PDFINATE_GN_DEPENDENCY_INCLUDES")
    for inc in dependency_includes(ev):
        out.append(f"    \"{inc}\"")
    out.append(")")
    out.append("")
    out.append("# Labels outside the PDFium tree. cmake/deps.cmake supplies a target for each one reached.")
    out.append("set(PDFINATE_GN_EXTERNAL")
    for label in sorted(ev.external):
        out.append(f"    \"{label}\"")
    out.append(")")
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w") as f:
        f.write("\n".join(out) + "\n")


def main():
    ev = Evaluator()
    try:
        ev.run()
    except GNError as e:
        print(f"gn2cmake: {e}", file=sys.stderr)
        return 1
    if ev.missing:
        print("gn2cmake: labels reached but not defined (inside a template this script skips, or "
              "under a condition fixed to false):\n  " + "\n  ".join(sorted(ev.missing)), file=sys.stderr)
        return 1
    emit(ev)
    print(f"gn2cmake: {len(ev.files)} BUILD.gn files, {len(ev.targets)} targets and configs, "
          f"{len(ev.external)} external labels -> {os.path.relpath(OUTPUT, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
