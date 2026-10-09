#!/usr/bin/env python3
"""Claude Code status line for agentbox.

Prints one line: model, repo directory and git branch, context window use,
subscription limits (5-hour and weekly) with their reset times, session cost.
Reads the JSON Claude Code passes on stdin. Every field is optional: a part
whose data is missing is left out, so a changed payload degrades the line
instead of breaking it.
"""
import datetime
import json
import os
import subprocess
import sys

RESET = "\033[0m"
DIM = "\033[2m"


def get(data, *path):
    """Return the value at path in nested dicts, or None if any step is missing."""
    for key in path:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
    return data


def level(pct):
    """Wrap a percentage in green, yellow or red by how close it is to the limit."""
    color = "\033[32m" if pct < 50 else "\033[33m" if pct < 80 else "\033[31m"
    return f"{color}{pct:.0f}%{RESET}"


def reset_time(value):
    """Format a reset time (epoch seconds or milliseconds, or ISO 8601) as local
    HH:MM today, or a short date with time otherwise; None if unparseable."""
    try:
        if isinstance(value, (int, float)):
            ts = datetime.datetime.fromtimestamp(value / 1000 if value > 1e12 else value)
        else:
            ts = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            ts = ts.astimezone().replace(tzinfo=None)
    except (ValueError, OverflowError, OSError):
        return None
    if ts.date() == datetime.date.today():
        return ts.strftime("%H:%M")
    return ts.strftime("%d.%m %H:%M")


def branch(cwd):
    """Current git branch of cwd, or None outside a repository."""
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "branch", "--show-current"],
            capture_output=True, text=True, timeout=1,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() or None


def tokens(n):
    """Short token count: 950, 45k, 1M, 1.2M."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}".removesuffix(".0") + "M"
    if n >= 1000:
        return f"{n / 1000:.0f}k"
    return str(n)


def main():
    """Build the status line from stdin and print it."""
    try:
        data = json.load(sys.stdin)
    except ValueError:
        data = {}
    parts = []

    model = get(data, "model", "display_name") or get(data, "model", "id")
    if model:
        parts.append(model)

    cwd = get(data, "workspace", "current_dir") or get(data, "cwd") or os.getcwd()
    where = os.path.basename(cwd.rstrip("/")) or cwd
    br = branch(cwd)
    parts.append(f"{where} {DIM}({br}){RESET}" if br else where)

    ctx = get(data, "context_window") or {}
    pct = ctx.get("used_percentage")
    if isinstance(pct, (int, float)):
        size = ctx.get("context_window_size")
        used = ctx.get("total_input_tokens")
        detail = ""
        if isinstance(size, int) and isinstance(used, int):
            detail = f" {DIM}{tokens(used)}/{tokens(size)}{RESET}"
        parts.append(f"ctx {level(pct)}{detail}")

    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        limit = get(data, "rate_limits", key) or {}
        pct = limit.get("used_percentage")
        if isinstance(pct, (int, float)):
            at = reset_time(limit.get("resets_at")) if limit.get("resets_at") else None
            parts.append(f"{label} {level(pct)}" + (f" {DIM}→{at}{RESET}" if at else ""))

    cost = get(data, "cost", "total_cost_usd")
    if isinstance(cost, (int, float)) and cost > 0:
        parts.append(f"{DIM}${cost:.2f}{RESET}")

    print(" │ ".join(parts))


if __name__ == "__main__":
    main()
