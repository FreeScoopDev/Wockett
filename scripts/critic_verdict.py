#!/usr/bin/env python3
"""The "Critic verdict" check: a major PR must record the critic's verdict in
its description, and the verdict must not be BLOCK.

Usage: critic_verdict.py <base sha> <head sha> <head branch>
  The PR description comes from the PR_BODY environment variable (the workflow
  passes it through env, never by pasting it into a shell command).

Major, as defined once in .claude/app.json and read by PROCESS.md too: a
`feat/` branch, or more than `criticMinLines` changed lines (added plus
deleted) of Swift outside the test targets (`unitTestTarget`, `uiTestTarget`).

The verdict is a line such as `**Critic verdict:** APPROVE WITH FINDINGS`.
HTML comments are removed first, so the PR template's hint text never counts.
This proves a verdict was recorded, not that the review was good.

Exit 0 pass, 1 fail, 2 a usage or config problem. Runs in CI on Linux; it
needs only python3 and git, never the toolkit.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

VERDICT = re.compile(r"^[\s>*_-]*critic verdict[\s*_]*:[\s*_]*(.*)$", re.IGNORECASE | re.MULTILINE)
KINDS = ("APPROVE WITH FINDINGS", "APPROVE", "BLOCK")


def fail(msg: str, code: int) -> None:
    print(msg, file=sys.stderr)
    sys.exit(code)


def swift_lines(base: str, head: str, test_dirs: list[str]) -> int:
    res = subprocess.run(["git", "diff", "--numstat", "--no-renames", f"{base}...{head}", "--", "*.swift"],
                         capture_output=True, text=True)
    if res.returncode != 0:
        fail(f"git diff {base}...{head} failed: {res.stderr.strip()}", 2)
    total = 0
    for line in res.stdout.splitlines():
        added, deleted, path = line.split("\t", 2)
        if any(path.startswith(d + "/") for d in test_dirs):
            continue
        if added != "-":  # "-" is a binary file
            total += int(added) + int(deleted)
    return total


def main() -> None:
    if len(sys.argv) != 4:
        fail("usage: critic_verdict.py <base sha> <head sha> <head branch>", 2)
    base, head, branch = sys.argv[1:]
    try:
        cfg = json.loads(Path(".claude/app.json").read_text())
    except (OSError, json.JSONDecodeError) as e:
        fail(f"cannot read .claude/app.json: {e}", 2)
    limit = cfg.get("criticMinLines")
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 0:
        fail(".claude/app.json needs criticMinLines, a whole number of lines (the template starts at 40)", 2)
    test_dirs = [t for t in (cfg.get("unitTestTarget"), cfg.get("uiTestTarget")) if t]

    lines = swift_lines(base, head, test_dirs)
    reasons = []
    if branch.startswith("feat/"):
        reasons.append("a feat/ branch")
    if lines > limit:
        reasons.append(f"{lines} changed lines of Swift outside the test targets (limit {limit})")
    if not reasons:
        print(f"Not major ({lines} changed lines of Swift outside the test targets, limit {limit}; "
              f"branch {branch}): no critic verdict needed.")
        return

    body = re.sub(r"<!--.*?-->", "", os.environ.get("PR_BODY", ""), flags=re.DOTALL)
    found = [m.group(1).strip().strip("*_` ").upper() for m in VERDICT.finditer(body)]
    found = [v for v in found if v]
    why = " and ".join(reasons)
    if not found:
        fail(f"Major change ({why}), and the PR description has no critic verdict.\n"
             "Run the critic (PROCESS.md, Every change), then add a line like\n"
             "  **Critic verdict:** APPROVE WITH FINDINGS\n"
             "Editing the description re-runs this check.", 1)
    verdict = found[-1]
    kind = next((k for k in KINDS if verdict.startswith(k)), None)
    if kind is None:
        fail(f"Critic verdict '{verdict}' is not one of {', '.join(KINDS)}.", 1)
    if kind == "BLOCK":
        fail(f"Critic verdict is BLOCK ({why}). Fix every BLOCK finding, re-run the critic, "
             "and record the new verdict.", 1)
    print(f"Major change ({why}); critic verdict: {kind}.")


if __name__ == "__main__":
    main()
