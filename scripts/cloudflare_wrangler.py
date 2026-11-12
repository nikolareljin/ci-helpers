#!/usr/bin/env python3
"""Validate what cloudflare-build.yml and cloudflare-deploy.yml hand to wrangler.

    cloudflare_wrangler.py args                      # env: CF_COMMAND, CF_DEPLOY_ARGS
    cloudflare_wrangler.py config TREE CONFIG ENV [--write]
    cloudflare_wrangler.py argv                      # env: see argv_cmd()
    cloudflare_wrangler.py account                   # env: CLOUDFLARE_ACCOUNT_ID

args    Checks the command and every deploy_args word against an allowlist
        and prints `pages_dir=<dir>` (empty for the Workers lane).
config  Reads the wrangler config CONFIG (a path relative to TREE; TOML,
        JSON or JSONC). Refuses a key that makes wrangler run a command,
        build an image or read a file outside TREE (`build` is dropped,
        not refused, with --write: the build job already ran it), an
        assets directory outside TREE, and (with --write) a symlink or a
        `.env` or `.dev.vars` file anywhere under TREE. Prints `assets=<dir under TREE>` and
        `entry=<bundle file name>`. With --write it writes the checked
        config as JSON next to CONFIG and prints `config=<its path>`.
argv    Prints the wrangler argv, NUL-separated, built only from values
        each checked against its own pattern.
account Checks CLOUDFLARE_ACCOUNT_ID is 32 hex characters, without printing it.

Exit 0 on success, 1 on a refusal, 2 on a usage error.
"""
from __future__ import annotations

import json
import os
import posixpath
import re
import sys
from pathlib import Path

COMMANDS = ("deploy", "versions upload", "pages deploy")
NAME = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
ENV_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
FLAG_NAME = re.compile(r"[a-z0-9_]{1,64}")
BRANCH = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}")
COMMIT = re.compile(r"[0-9a-f]{7,40}")
LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:@+/-]{0,99}")
VAR = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,63}")
VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}")
REL_PATH = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.@+-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.@+-]*)*")
ENTRY = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\.(?:js|mjs)")
ACCOUNT = re.compile(r"[0-9a-f]{32}")

# deploy_args the library passes on: flag -> value pattern, or None for a
# flag that takes no value. Nothing else reaches wrangler.
WORKERS_FLAGS: dict[str, re.Pattern | None] = {
    "--name": NAME,
    "--compatibility-date": DATE,
    "--compatibility-flags": FLAG_NAME,
    "--compatibility-flag": FLAG_NAME,
    "--keep-vars": None,
    "--dispatch-namespace": NAME,
    "--tag": LABEL,
    "--message": LABEL,
}
PAGES_FLAGS: dict[str, re.Pattern | None] = {
    "--project-name": NAME,
    "--branch": BRANCH,
    "--commit-hash": COMMIT,
    "--commit-dirty": None,
    "--skip-caching": None,
}
# Config keys that run a command (build, containers), or name a file
# wrangler reads at deploy time outside the bundle and the assets.
REFUSED_KEYS = ("containers", "site", "wasm_modules", "text_blobs", "data_blobs",
                "base_dir", "tsconfig", "alias", "python_modules")
SANITIZED_NAME = "ci-helpers-deploy.wrangler.json"


class Refused(Exception):
    pass


def full(pattern: re.Pattern, value: str, what: str) -> str:
    if not pattern.fullmatch(value):
        raise Refused(f"{what} '{value}' is not allowed (must match {pattern.pattern}).")
    return value


def rel_path(value: str, what: str) -> str:
    full(REL_PATH, value, what)
    if any(p in (".", "..") for p in value.split("/")):
        raise Refused(f"{what} '{value}' has a . or .. component.")
    return value


def parse_args(command: str, raw: str) -> tuple[list[str], str]:
    """deploy_args -> (flags, pages directory)."""
    if command not in COMMANDS:
        raise Refused(f"command must be one of {', '.join(COMMANDS)}, not '{command}'.")
    if "\n" in raw or "\r" in raw:
        raise Refused("deploy_args holds a line break.")
    allowed = PAGES_FLAGS if command == "pages deploy" else WORKERS_FLAGS
    words = raw.split()
    out: list[str] = []
    pages_dir = ""
    i = 0
    while i < len(words):
        w = words[i]
        i += 1
        if not w.startswith("-"):
            if command != "pages deploy" or pages_dir:
                raise Refused(f"deploy_args word '{w}' is not an allowed flag. Allowed: {', '.join(allowed)}.")
            pages_dir = rel_path(w.rstrip("/") or w, "the Pages directory in deploy_args")
            continue
        flag, eq, value = w.partition("=")
        if flag not in allowed:
            raise Refused(f"deploy_args flag '{flag}' is not allowed for '{command}'. Allowed: {', '.join(allowed)}.")
        pattern = allowed[flag]
        if pattern is None:
            if eq and value not in ("true", "false"):
                raise Refused(f"deploy_args flag '{flag}' takes no value, or true or false.")
            out.append(w if eq else flag)
            continue
        if not eq:
            if i >= len(words):
                raise Refused(f"deploy_args flag '{flag}' needs a value.")
            value = words[i]
            i += 1
        full(pattern, value, f"the value of {flag}")
        out += [flag, value]
    if command == "pages deploy" and not pages_dir:
        raise Refused("command 'pages deploy' needs the directory to upload as the first word of "
                      "deploy_args, e.g. 'dist --project-name example-site'.")
    return out, pages_dir


def strip_jsonc(text: str) -> str:
    """Drop // and /* */ comments and trailing commas outside strings."""
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                raise Refused("the config has an unterminated /* comment.")
            i = j + 2
        elif c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "}]":
                i += 1
            else:
                out.append(c)
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def load_config(path: Path) -> dict:
    raw = path.read_text(encoding="utf-8")
    if path.suffix == ".toml":
        import tomllib
        data = tomllib.loads(raw)
    elif path.suffix in (".json", ".jsonc"):
        data = json.loads(strip_jsonc(raw))
    else:
        raise Refused(f"the config '{path.name}' is not .toml, .json or .jsonc.")
    if not isinstance(data, dict):
        raise Refused("the config is not a table.")
    return data


def tables(data: dict, env: str) -> list[tuple[str, dict]]:
    out = [("top level", data)]
    envs = data.get("env")
    if envs is not None:
        if not isinstance(envs, dict):
            raise Refused("the config's env is not a table.")
        for name, t in envs.items():
            if not isinstance(t, dict):
                raise Refused(f"the config's env.{name} is not a table.")
            out.append((f"env.{name}", t))
    return out


def config_cmd(tree: Path, config: str, env: str, write: bool) -> dict[str, str]:
    rel_path(config, "the deploy config path")
    tree = tree.resolve(strict=True)
    path = tree / config
    if path.is_symlink() or not path.is_file():
        raise Refused(f"the deploy config '{config}' is not a regular file.")
    # The deploy tree only: in the build job TREE is the caller's whole
    # working directory, where an .env.example is ordinary.
    for p in tree.rglob("*") if write else ():
        if p.is_symlink() or not (p.is_file() or p.is_dir()):
            raise Refused(f"'{p.relative_to(tree)}' is not a regular file or directory.")
        if p.name == ".env" or p.name.startswith(".env.") or p.name.startswith(".dev.vars"):
            raise Refused(f"'{p.relative_to(tree)}' is an env file wrangler would load; it is refused.")
    data = load_config(path)
    if env != "none":
        full(ENV_NAME, env, "the wrangler environment")
    config_dir = posixpath.dirname(config)
    assets = ""
    main = ""
    for where, t in tables(data, env):
        for key in REFUSED_KEYS:
            if key in t:
                raise Refused(f"the config sets '{key}' ({where}); wrangler would run a command or read "
                              f"a file outside the deploy bundle there, so it is refused.")
    selected = [data]
    if env != "none" and isinstance(data.get("env"), dict) and env in data["env"]:
        selected.append(data["env"][env])
    for t in selected:
        a = t.get("assets")
        if a is not None:
            if not isinstance(a, dict) or not isinstance(a.get("directory", ""), str):
                raise Refused("the config's assets is not a table with a string directory.")
            if a.get("directory"):
                assets = a["directory"]
        if isinstance(t.get("main"), str) and t["main"]:
            main = t["main"]
    if assets:
        joined = posixpath.normpath(posixpath.join(config_dir, assets))
        if joined.startswith("/") or joined == ".." or joined.startswith("../") or joined == ".":
            raise Refused(f"the assets directory '{assets}' is outside the deploy tree.")
        rel_path(joined, "the assets directory")
        assets = joined
    if not main:
        raise Refused("the config names no main entry point.")
    stem = posixpath.basename(main)
    stem = re.sub(r"\.(?:[cm]?[jt]sx?)$", "", stem)
    entry = full(ENTRY, stem + ".js", "the bundle entry")
    result = {"assets": assets, "entry": entry}
    if write:
        for _, t in tables(data, env):
            t.pop("build", None)
        out = posixpath.join(config_dir, SANITIZED_NAME) if config_dir else SANITIZED_NAME
        target = tree / out
        if target.exists() or target.is_symlink():
            raise Refused(f"'{out}' already exists in the deploy tree.")
        target.write_text(json.dumps(data, default=str, indent=2) + "\n", encoding="utf-8")
        result["config"] = out
    return result


def argv_cmd(env: dict[str, str]) -> list[str]:
    """CF_MODE deploy|dryrun, CF_COMMAND, CF_DEPLOY_ARGS, CF_ENV_NAME
    (or 'none'), CF_VERSION_VAR, CF_VERSION, CF_CONFIG, CF_ENTRY,
    CF_BUNDLE_DIR, CF_PAGES_DIR."""
    mode = env.get("CF_MODE", "")
    command = env.get("CF_COMMAND", "")
    flags, _ = parse_args(command, env.get("CF_DEPLOY_ARGS", ""))
    env_name = env.get("CF_ENV_NAME", "")
    if env_name != "none":
        full(ENV_NAME, env_name, "the wrangler environment")
    config = env.get("CF_CONFIG", "")
    if config:
        rel_path(config, "the deploy config path")
    if mode == "dryrun":
        out = env.get("CF_BUNDLE_DIR", "")
        if not out.startswith("/") or "\n" in out:
            raise Refused("CF_BUNDLE_DIR must be an absolute path.")
        argv = ["deploy", "--dry-run", "--outdir", out]
        if config:
            argv += ["--config", config]
        if env_name != "none":
            argv += ["--env", env_name]
        return argv
    if mode != "deploy":
        raise Refused(f"CF_MODE must be deploy or dryrun, not '{mode}'.")
    if command == "pages deploy":
        pages = rel_path(env.get("CF_PAGES_DIR", ""), "the staged Pages directory")
        return ["pages", "deploy", pages, *flags]
    entry = env.get("CF_ENTRY", "")
    full(re.compile(r"bundle/" + ENTRY.pattern), entry, "the bundle entry")
    if not config:
        raise Refused("the Workers lane needs a deploy config.")
    argv = [*command.split(), entry, "--no-bundle", "--config", config]
    if env_name != "none":
        argv += ["--env", env_name]
    var = env.get("CF_VERSION_VAR", "")
    if var:
        full(VAR, var, "version_var")
        version = full(VERSION, env.get("CF_VERSION", ""), "the version string")
        argv += ["--var", f"{var}:{version}"]
    return argv + flags


def main(argv: list[str]) -> int:
    try:
        if argv[:1] == ["args"] and len(argv) == 1:
            _, pages_dir = parse_args(os.environ.get("CF_COMMAND", ""), os.environ.get("CF_DEPLOY_ARGS", ""))
            print(f"pages_dir={pages_dir}")
        elif argv[:1] == ["config"] and len(argv) in (4, 5) and argv[4:] in ([], ["--write"]):
            res = config_cmd(Path(argv[1]), argv[2], argv[3], argv[4:] == ["--write"])
            for k, v in res.items():
                print(f"{k}={v}")
        elif argv[:1] == ["argv"] and len(argv) == 1:
            out = argv_cmd(dict(os.environ))
            sys.stdout.write("".join(a + "\0" for a in out))
        elif argv[:1] == ["account"] and len(argv) == 1:
            if not ACCOUNT.fullmatch(os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")):
                raise Refused("CLOUDFLARE_ACCOUNT_ID is not 32 lowercase hex characters.")
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Refused as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    except (ValueError, OSError) as exc:
        print(f"::error::{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
