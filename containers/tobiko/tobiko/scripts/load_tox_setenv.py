#!/usr/bin/env python3
"""Print shell exports for a tox env's setenv. Reads tox.ini; does not use tox."""
from __future__ import annotations

import configparser
import os
import re
import shlex
import sys

# Install-time / venv keys. Reports use TOBIKO_REPORT_DIR, not tox's envlogdir.
SKIP = {
    "TOX_CONSTRAINTS",
    "TOX_EXTRA_REQUIREMENTS",
    "VIRTUAL_ENV",
    "TOX_REPORT_DIR",
    "TOX_COVER_DIR",
}

INCLUDE_SETENV = re.compile(r"^\{\[([^\]]+)\]setenv\}$")
ENV_FACTOR = re.compile(r"\{env:([^:}]+)(?::([^}]*))?\}")


def read_ini(path: str) -> configparser.ConfigParser:
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    with open(path, encoding="utf-8") as handle:
        parser.read_file(handle)
    return parser


def setenv_lines(
    parser: configparser.ConfigParser,
    section: str,
    seen: set[str] | None = None,
) -> list[str]:
    if seen is None:
        seen = set()
    if section in seen or not parser.has_section(section):
        return []
    seen.add(section)
    raw = parser.get(section, "setenv", fallback="")
    lines: list[str] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = INCLUDE_SETENV.match(line)
        if match:
            lines.extend(setenv_lines(parser, match.group(1), seen))
            continue
        lines.append(line)
    return lines


def substitute(value: str, envname: str, toxinidir: str, environ: dict[str, str]) -> str:
    value = (
        value.replace("{toxinidir}", toxinidir)
        .replace("{envname}", envname)
        .replace("{envpython}", sys.executable)
        .replace("{envdir}", "")
        .replace("{toxworkdir}", "")
        .replace("{envlogdir}", toxinidir)
    )

    def env_repl(match: re.Match[str]) -> str:
        name, default = match.group(1), match.group(2)
        if default is None:
            default = ""
        return environ.get(name, default)

    return ENV_FACTOR.sub(env_repl, value)


def resolve_env(parser: configparser.ConfigParser, envname: str, toxinidir: str) -> dict[str, str]:
    section = f"testenv:{envname}"
    if not parser.has_section(section):
        raise SystemExit(f"Unknown tox env {envname!r}: no [{section}] in tox.ini")
    if parser.has_option(section, "setenv"):
        lines = setenv_lines(parser, section)
    else:
        lines = setenv_lines(parser, "testenv")

    environ = dict(os.environ)
    resolved: dict[str, str] = {}
    for line in lines:
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key, val = key.strip(), val.strip()
        if key in SKIP:
            continue
        value = substitute(val, envname, toxinidir, environ)
        resolved[key] = value
        environ[key] = value
    if "OS_TEST_PATH" in resolved:
        resolved["TOBIKO_TEST_PATH"] = resolved["OS_TEST_PATH"]
        environ["TOBIKO_TEST_PATH"] = resolved["OS_TEST_PATH"]
    return resolved


def split_pytest_addopts(addopts: str, site_packages: str) -> tuple[list[str], list[str]]:
    tokens = shlex.split(addopts or "")
    flags: list[str] = []
    paths: list[str] = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token.startswith("-"):
            flags.append(token)
            if "=" not in token and i + 1 < len(tokens) and not tokens[i + 1].startswith("-"):
                i += 1
                flags.append(tokens[i])
        else:
            filepart, sep, node = token.partition("::")
            if site_packages and not os.path.isabs(filepart):
                candidate = os.path.join(site_packages, filepart)
                if os.path.exists(candidate):
                    filepart = candidate
            paths.append(filepart + (sep + node if sep else ""))
        i += 1
    return flags, paths


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] == "--split-addopts":
        site = sys.argv[2] if len(sys.argv) > 2 else ""
        flags, paths = split_pytest_addopts(os.environ.get("PYTEST_ADDOPTS", ""), site)
        print("ADDOPTS_FLAGS_ARR=(" + " ".join(shlex.quote(x) for x in flags) + ")")
        print("ADDOPTS_PATHS_ARR=(" + " ".join(shlex.quote(x) for x in paths) + ")")
        return
    if len(sys.argv) < 3:
        raise SystemExit(
            f"usage: {sys.argv[0]} ENVNAME TOXINIDIR [TOX_INI]\n"
            f"       {sys.argv[0]} --split-addopts SITE_PACKAGES"
        )
    envname = sys.argv[1]
    toxinidir = sys.argv[2]
    tox_ini = sys.argv[3] if len(sys.argv) > 3 else "/usr/share/tobiko/tox.ini"
    resolved = resolve_env(read_ini(tox_ini), envname, toxinidir)
    extra_arr = "()"
    for key, value in resolved.items():
        print(f"export {key}={shlex.quote(value)}")
        if key == "RUN_TESTS_EXTRA_ARGS":
            extra_arr = "(" + " ".join(shlex.quote(p) for p in shlex.split(value)) + ")"
    print(f"RUN_TESTS_EXTRA_ARGS_ARR={extra_arr}")


if __name__ == "__main__":
    main()
