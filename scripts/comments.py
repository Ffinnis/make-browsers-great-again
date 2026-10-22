#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["tree-sitter-language-pack==1.22.1"]
# ///
import os
import re
import subprocess
import sys

from tree_sitter_language_pack import get_parser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DIRECTIVE = re.compile(
    r"^#!|^#\s*///|^#\s*(requires-python|dependencies)\s*=|swiftlint:|swiftformat:|noqa|type:\s*ignore|"
    r"shellcheck\s|SAFETY:|yaml-language-server:|clang-format\s+(on|off)|NOLINT|fmt:\s*(on|off|skip)"
)

BY_SUFFIX = {
    ".swift": "swift",
    ".rs": "rust",
    ".py": "python",
    ".sh": "bash",
    ".toml": "toml",
    ".yml": "yaml",
    ".yaml": "yaml",
    ".mm": "objc",
    ".h": "objc",
    ".js": "javascript",
    ".css": "css",
    ".html": "html",
    ".in": "xml",
    ".entitlements": "xml",
}
BY_NAME = {
    "CMakeLists.txt": "cmake",
    "Brewfile": "ruby",
    ".clang-format": "yaml",
    ".editorconfig": "ini",
    ".gitignore": "gitignore",
    ".shellcheckrc": "lines",
    ".swiftformat": "lines",
    ".git-blame-ignore-revs": "lines",
}
SKIP = re.compile(r"^(third_party|build|core/target)/")


def language(path):
    if SKIP.match(path):
        return None
    name = os.path.basename(path)
    if name in BY_NAME:
        return BY_NAME[name]
    if path.startswith(".githooks/"):
        return "bash"
    return BY_SUFFIX.get(os.path.splitext(name)[1])


def comment_nodes(node):
    if "comment" in node.type:
        yield node
        return
    for child in node.children:
        yield from comment_nodes(child)


def docstrings(node):
    body = node.children if node.type == "module" else []
    if node.type in ("function_definition", "class_definition"):
        block = node.child_by_field_name("body")
        body = block.named_children if block else []
    statements = [c for c in body if c.is_named and c.type != "comment"]
    if statements and statements[0].type == "expression_statement" and len(statements) > 1:
        first = statements[0]
        if first.named_child_count == 1 and first.named_children[0].type == "string":
            yield first
    for child in node.children:
        yield from docstrings(child)


def find(lang, src):
    if lang == "lines":
        offset = 0
        for line in src.split(b"\n"):
            if line.lstrip().startswith(b"#"):
                start = offset + len(line) - len(line.lstrip())
                yield start, offset + len(line)
            offset += len(line) + 1
        return
    tree = get_parser(lang).parse(src)
    for node in comment_nodes(tree.root_node):
        yield node.start_byte, node.end_byte
    if lang == "python":
        for node in docstrings(tree.root_node):
            yield node.start_byte, node.end_byte


def unwanted(lang, src):
    found = []
    kept_end = None
    for start, end in sorted(set(find(lang, src))):
        text = src[start:end].decode("utf-8", "replace")
        continues = (
            kept_end is not None and src[kept_end:start].strip() == b"" and src.count(b"\n", kept_end, start) == 1
        )
        if DIRECTIVE.search(text) or continues:
            kept_end = end if continues or "SAFETY:" in text else None
            continue
        kept_end = None
        if found and start < found[-1][1]:
            continue
        found.append((start, end))
    return found


def blank(src, start, end):
    return src[start:end].strip() == b""


def strip(src, ranges):
    for start, end in reversed(ranges):
        line_start = src.rfind(b"\n", 0, start) + 1
        line_end = src.find(b"\n", end)
        line_end = len(src) if line_end < 0 else line_end
        if blank(src, line_start, start) and blank(src, end, line_end):
            cut_end = min(line_end + 1, len(src))
            prev_start = src.rfind(b"\n", 0, max(line_start - 1, 0)) + 1
            prev_blank = line_start == 0 or blank(src, prev_start, line_start)
            next_end = src.find(b"\n", cut_end)
            next_end = len(src) if next_end < 0 else next_end
            if prev_blank and cut_end < len(src) and blank(src, cut_end, next_end):
                cut_end = min(next_end + 1, len(src))
            src = src[:line_start] + src[cut_end:]
        else:
            before = src[line_start:start]
            src = src[: line_start + len(before.rstrip())] + src[end:]
    return src


def main():
    fix = sys.argv[1:] == ["--fix"]
    if sys.argv[1:] not in ([], ["--fix"]):
        print(f"usage: {sys.argv[0]} [--fix]", file=sys.stderr)
        return 2
    paths = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    failures = []
    for path in paths:
        lang = language(path)
        full = os.path.join(ROOT, path)
        if lang is None or not os.path.isfile(full):
            continue
        with open(full, "rb") as f:
            src = f.read()
        ranges = unwanted(lang, src)
        if not ranges:
            continue
        if fix:
            with open(full, "wb") as f:
                f.write(strip(src, ranges))
            continue
        for start, _ in ranges:
            failures.append(f"{path}:{src.count(b'\n', 0, start) + 1}: comment")
    for line in failures:
        print(line)
    if failures:
        print(f"{len(failures)} comment(s). Run scripts/comments.py --fix.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
