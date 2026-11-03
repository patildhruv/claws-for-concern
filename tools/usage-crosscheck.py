#!/usr/bin/env python3
"""Cross-checks the search helper's usage figures against an independent reading of the transcripts.

    tools/usage-crosscheck.py [--helper PATH | --dump FILE] [--cached] [--show N]

Runs `ClawsSearch --usage-dump` (by default the one in build/, with a fresh cache in a temporary
folder; --cached uses the helper's own cache), then reads every transcript under ~/.claude/projects
itself, read-only, with nothing shared with the Swift reader: every line goes through json.loads, and
the rules below are written from the facts in docs/usage.md. It prints which fields agree exactly,
the mismatches (session ID prefixes only), and how the estimates compare with Claude Code's own
cost-state figures. It writes no files. Its output describes your own sessions: never commit it.

The rules, as verified on real transcripts (Claude Code 2.1.316, 2026-11-03, and the review after):
  - files: <project>/<id>.jsonl, its subagents <id>/subagents/*.jsonl and workflow agents
    <id>/subagents/workflows/<run>/agent-*.jsonl, never through a link (a resumed session's run folder
    can link to the starting session's run); lines with "forkedFrom" were copied from another session
    and do not count. A transcript that is a link is its target, read once. One ID filed as several
    real transcripts is one conversation: lines they share (one uuid) and replies count once.
  - a reply is an assistant line's message.id (else requestId), counted once; its usage is the LAST
    line's in the file where the id first appears; model "<synthetic>" is not a reply.
  - numbers: finite, 0 or more, at most 1e12 (a turn at most 48 h), else missing; dates from 2020 to 2100.
  - API errors: assistant lines with isApiErrorMessage, once per message id.
  - context after a main-thread reply = input + cache read + cache write; a compaction after it sets
    context to its postTokens (unknown without); compactions are the main transcript's.
  - turns: each prompt starts one (a reply after a recorded turn with no prompt, too); a turn with a
    turn_duration takes it, else prompt to last reply, minus any time a recorded turn covers.
  - tool time: main-thread calls from tool_use to tool_result, overlaps once, never AskUserQuestion
    or ExitPlanMode, and only within the turns' working time.
  - lines: each Edit or Write call once, only with a successful result (no is_error, not a text
    result): Claude Code's diff in the result (a new file's lines, or the + and - lines of its hunks,
    none for an unchanged write), else the call's input.
  - tool calls: each tool_use block id once, subagents included.
  - Claude Code's figure: the main transcript's last cost-state, if no reply follows it in that
    transcript and it counts at least 99% of the transcript's output tokens and cache reads.
"""
import argparse
import collections
import glob
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime

ROOT = os.path.expanduser("~/.claude/projects")
HOME = os.path.expanduser("~")
HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "Claws for Concern.app",
                      "Contents", "Helpers", "Claws Search.app", "Contents", "MacOS", "ClawsSearch")
PROTECTED = [os.path.join(HOME, p) for p in ("Desktop", "Documents", "Downloads", "Library/Mobile Documents",
                                             "Library/CloudStorage", "Library/Containers", "Library/Group Containers")] + ["/Volumes"]

# $ per million tokens: input, output, cache read (writes are 1.25x and 2x input). From
# platform.claude.com/docs/en/about-claude/pricing, read 2026-11-03.
PRICES = {
    "claude-fable-5-1": (10, 50, 0.25), "claude-mythos-5-1": (10, 50, 0.25),
    "claude-fable-5": (10, 50, 1), "claude-mythos-5": (10, 50, 1),
    "claude-opus-5-5": (4, 20, 0.20), "claude-opus-5": (5, 25, 0.50), "claude-opus-4-8": (5, 25, 0.50),
    "claude-opus-4-7": (5, 25, 0.50), "claude-opus-4-6": (5, 25, 0.50), "claude-opus-4-5": (5, 25, 0.50),
    "claude-opus-4-1": (15, 75, 1.50), "claude-opus-4": (15, 75, 1.50),
    "claude-sonnet-5-5": (2, 10, 0.10), "claude-sonnet-5": (2, 10, 0.20), "claude-sonnet-4-6": (3, 15, 0.30),
    "claude-sonnet-4-5": (3, 15, 0.30), "claude-sonnet-4": (3, 15, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.01), "claude-haiku-4-5": (1, 5, 0.10), "claude-3-5-haiku": (0.80, 4, 0.08),
}
HAIKU_55_LONG = (0.50, 2.50, 0.05)    # prompts over 100,000 tokens
FAST = {"claude-opus-5-5": (8, 40), "claude-opus-5": (10, 50), "claude-opus-4-8": (10, 50)}
NO_RESIDENCY = {"claude-opus-4-5", "claude-opus-4-1", "claude-opus-4", "claude-sonnet-4-5", "claude-sonnet-4",
                "claude-haiku-4-5", "claude-3-5-haiku"}
WAITING = {"AskUserQuestion", "ExitPlanMode"}
LIMIT, MAX_SECONDS = 1e12, 48 * 3600
EARLIEST, LATEST = 1_577_836_800, 4_102_444_800     # 2020-01-01, 2100-01-01


def base_model(m):
    m = (m or "").lower()
    m = re.sub(r"\[.*$", "", m)
    m = m.split("@")[0]
    if "anthropic." in m:
        m = m.split("anthropic.", 1)[1]
    m = re.sub(r"-v\d+(:\d+)?$", "", m)
    return re.sub(r"-\d{8}$", "", m)


def number(v, limit=LIMIT):
    """A finite number in 0..limit, or one written as a string; else None."""
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, str):
        try:
            v = float(v.strip())
        except ValueError:
            return None
    if not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0 or v > limit:
        return None
    return v


def count(v, limit=LIMIT):
    n = number(v, limit)
    return None if n is None else int(n)


def truthy(v):
    return v is True or v in ("true", "True")


def tokens_of(u):
    u = u if isinstance(u, dict) else {}
    cc = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
    write = count(u.get("cache_creation_input_tokens")) or 0
    return {"output": count(u.get("output_tokens")) or 0, "cacheRead": count(u.get("cache_read_input_tokens")) or 0,
            "cacheWrite": write, "cacheWrite1h": min(write, count(cc.get("ephemeral_1h_input_tokens")) or 0),
            "input": count(u.get("input_tokens")) or 0}


def price(model, t, speed=None, geo=None, searches=0):
    key = base_model(model)
    if key not in PRICES:
        return None
    inp, out, read = PRICES[key]
    prompt = t["input"] + t["cacheRead"] + t["cacheWrite"]
    if key in ("claude-sonnet-4-5", "claude-sonnet-4") and prompt > 200_000:
        return None
    if key == "claude-haiku-5-5" and prompt > 100_000:
        inp, out, read = HAIKU_55_LONG
    if speed == "fast" and key in FAST:
        read = read / inp * FAST[key][0]
        inp, out = FAST[key]
    w1h = t["cacheWrite1h"]
    usd = (t["input"] * inp + t["output"] * out + (t["cacheWrite"] - w1h) * inp * 1.25 + w1h * inp * 2
           + t["cacheRead"] * read) / 1e6
    if geo == "us" and key not in NO_RESIDENCY:
        usd *= 1.1
    return usd + searches * 0.01


def when(s):
    try:
        t = datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None
    return t if EARLIEST <= t < LATEST else None


def lines_of(path):
    with open(path, "rb") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            if isinstance(o, dict) and o.get("forkedFrom") is None:
                yield o


def merge(iv):
    out = []
    for a, b in sorted(x for x in iv if x[1] > x[0]):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def length(iv):
    return sum(b - a for a, b in merge(iv))


def intersect(a, b):
    out, i, j = [], 0, 0
    while i < len(a) and j < len(b):
        lo, hi = max(a[i][0], b[j][0]), min(a[i][1], b[j][1])
        if hi > lo:
            out.append([lo, hi])
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return out


def subtract(x, cover):
    out, start = [], x[0]
    for a, b in cover:
        if b > start and a < x[1]:
            if a > start:
                out.append([start, a])
            start = max(start, b)
    if x[1] > start:
        out.append([start, x[1]])
    return out


def head_tail_change(old, new):
    a, b = old.split("\n"), new.split("\n")
    h = 0
    while h < len(a) and h < len(b) and a[h] == b[h]:
        h += 1
    t = 0
    while t < len(a) - h and t < len(b) - h and a[len(a) - 1 - t] == b[len(b) - 1 - t]:
        t += 1
    return len(b) - h - t, len(a) - h - t


LINKED_RUNS = []


def subagent_files(sdir):
    """subagents/*.jsonl and subagents/workflows/<run>/agent-*.jsonl, never through a link: a resumed
    session's run folder can link to the run of the session that started it, which counts it."""
    def entries(d):
        if not os.path.isdir(d) or os.path.islink(d):
            return []
        return [os.path.join(d, n) for n in sorted(os.listdir(d)) if not n.startswith(".")]
    out = [p for p in entries(os.path.join(sdir, "subagents")) if p.endswith(".jsonl") and not os.path.islink(p)]
    for run in entries(os.path.join(sdir, "subagents", "workflows")):
        if os.path.islink(run):
            LINKED_RUNS.append(run)
            continue
        out += [p for p in entries(run) if os.path.basename(p).startswith("agent-") and p.endswith(".jsonl")
                and not os.path.islink(p)]
    return sorted(out)


def resolve(path):
    """A transcript's real file; None for a link into a privacy-protected folder (never touched)."""
    for _ in range(8):
        if not os.path.islink(path):
            return os.path.realpath(path)
        path = os.path.normpath(os.path.join(os.path.dirname(path), os.readlink(path)))
        if any(path == p or path.startswith(p + "/") for p in PROTECTED):
            return None
    return None


def read_session(sid, mains, subs):
    files = [(p, True) for p in mains] + [(p, False) for p in subs]
    owner, last, order, marks = {}, {}, [], []
    errors, error_ids, tool_names, tool_start, tool_iv = [], set(), {}, {}, []
    compactions, turns, seen_uuid = [], [], set()
    cost_state, cs_file, current = None, None, False
    inputs, outcomes, diffs = {}, {}, {}
    for i, (f, is_main) in enumerate(files):
        for o in lines_of(f):
            if is_main and isinstance(o.get("uuid"), str):
                if o["uuid"] in seen_uuid:
                    continue
                seen_uuid.add(o["uuid"])
            t = o.get("type")
            at = when(o.get("timestamp"))
            if t == "assistant":
                m = o.get("message")
                if not isinstance(m, dict):
                    continue
                if truthy(o.get("isApiErrorMessage")):
                    key = m.get("id") or o.get("requestId") or o.get("uuid")
                    if key is None or key not in error_ids:
                        error_ids.add(key)
                        errors.append(o.get("error") if isinstance(o.get("error"), str) else "unknown")
                    continue
                content = m.get("content") if isinstance(m.get("content"), list) else []
                for b in content:
                    if not (isinstance(b, dict) and b.get("type") == "tool_use" and isinstance(b.get("id"), str)):
                        continue
                    tid = b["id"]
                    if tid not in tool_names:
                        tool_names[tid] = b.get("name") if isinstance(b.get("name"), str) else "Tool"
                        if is_main and at is not None:
                            tool_start[tid] = at
                    inp = b.get("input")
                    if b.get("name") in ("Edit", "Write") and isinstance(inp, dict) and tid not in inputs:
                        if b["name"] == "Write":
                            c = inp.get("content")
                            inputs[tid] = (len(c.split("\n")) if isinstance(c, str) else 0, 0)
                        elif isinstance(inp.get("old_string"), str) and isinstance(inp.get("new_string"), str):
                            inputs[tid] = head_tail_change(inp["old_string"], inp["new_string"])
                rid = m.get("id") or o.get("requestId")
                model = m.get("model")
                if not rid or not isinstance(model, str) or model == "<synthetic>" or not isinstance(m.get("usage"), dict):
                    continue
                if rid in owner and owner[rid] != i:
                    continue
                if rid not in owner:
                    owner[rid] = i
                    order.append(rid)
                    if is_main:
                        marks.append(("reply", rid, at))
                u = m["usage"]
                stu = u.get("server_tool_use") if isinstance(u.get("server_tool_use"), dict) else {}
                last[rid] = {"model": model, "t": tokens_of(u), "sub": not is_main, "at": at,
                             "speed": u.get("speed"), "geo": u.get("inference_geo"),
                             "searches": count(stu.get("web_search_requests"), 1e6) or 0}
                if is_main:
                    if i == cs_file:
                        current = False
                    if at is not None:
                        if turns and turns[-1]["record"] is None:
                            turns[-1]["last"] = max(turns[-1]["last"] or at, at)
                        else:
                            turns.append({"start": at, "last": at, "record": None})
            elif t == "user":
                msg = o.get("message") if isinstance(o.get("message"), dict) else {}
                c = msg.get("content")
                blocks = [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []
                results = [(b["tool_use_id"], truthy(b.get("is_error"))) for b in blocks
                           if b.get("type") == "tool_result" and isinstance(b.get("tool_use_id"), str)]
                tur = o.get("toolUseResult")
                for tid, err in results:
                    if is_main and at is not None and tid in tool_start:
                        start = tool_start.pop(tid)
                        if at >= start:
                            tool_iv.append((start, at, tool_names.get(tid, "")))
                    outcomes.setdefault(tid, err or isinstance(tur, str))
                if isinstance(tur, dict):
                    diff = None
                    if tur.get("type") == "create" and isinstance(tur.get("content"), str):
                        diff = (len(tur["content"].split("\n")), 0)
                    elif isinstance(tur.get("structuredPatch"), list):
                        add = rem = 0
                        for h in tur["structuredPatch"]:
                            ls = h.get("lines") if isinstance(h, dict) else None
                            if isinstance(ls, list) and all(isinstance(x, str) for x in ls):
                                add += sum(1 for x in ls if x.startswith("+"))
                                rem += sum(1 for x in ls if x.startswith("-"))
                        diff = (add, rem)
                    if diff is not None:
                        for tid, err in results:
                            if not err:
                                diffs.setdefault(tid, diff)
                if is_main and not truthy(o.get("isMeta")) and not truthy(o.get("isCompactSummary")) and at is not None:
                    if isinstance(c, str):
                        is_prompt = c.strip() != ""
                    else:
                        is_prompt = (any(b.get("type") == "text" and isinstance(b.get("text"), str) and b["text"].strip()
                                         for b in blocks) and not results)
                    if is_prompt:
                        turns.append({"start": at, "last": None, "record": None})
            elif not is_main:
                continue
            elif t == "system" and o.get("subtype") == "compact_boundary" and at is not None:
                md = o.get("compactMetadata") if isinstance(o.get("compactMetadata"), dict) else {}
                post = count(md.get("postTokens"))
                compactions.append((md.get("trigger") if isinstance(md.get("trigger"), str) else None,
                                    count(md.get("preTokens")), post))
                marks.append(("compaction", post, at))
            elif t == "system" and o.get("subtype") == "turn_duration" and at is not None:
                ms = number(o.get("durationMs"), MAX_SECONDS * 1000)
                if ms is not None:
                    s = ms / 1000
                    if turns and turns[-1]["record"] is None and (turns[-1]["start"] or -math.inf) <= at:
                        turns[-1]["record"] = (at, s)
                    else:
                        turns.append({"start": None, "last": None, "record": (at, s)})
            elif t == "cost-state" and number(o.get("totalCostUSD"), 1e7) is not None:
                cost_state, cs_file, current = o, i, True

    kinds = ["output", "cacheRead", "cacheWrite", "cacheWrite1h", "input"]
    total = dict.fromkeys(kinds, 0)
    sub_total = dict.fromkeys(kinds, 0)
    by_model = collections.defaultdict(lambda: dict.fromkeys(kinds, 0))
    estimate, priced, model_usd = 0.0, False, collections.defaultdict(float)
    for rid in order:
        r = last[rid]
        for k in kinds:
            total[k] += r["t"][k]
            by_model[r["model"]][k] += r["t"][k]
            if r["sub"]:
                sub_total[k] += r["t"][k]
        p = price(r["model"], r["t"], r["speed"], r["geo"], r["searches"])
        if p is not None:
            estimate += p
            priced = True
            model_usd[base_model(r["model"])] += p
    if len(mains) > 1:      # copies of one conversation: context in time order
        key, keyed = -math.inf, []
        for n, mk in enumerate(marks):
            key = mk[2] if mk[2] is not None else key
            keyed.append((key, n, mk))
        marks = [mk for _, _, mk in sorted(keyed, key=lambda x: (x[0], x[1]))]
    now = None
    for kind, v, _ in marks:
        if kind == "reply":
            t = last[v]["t"]
            now = t["input"] + t["cacheRead"] + t["cacheWrite"]
        else:
            now = v

    recorded = merge([[r[0] - r[1], r[0]] for r in (t["record"] for t in turns) if r])
    working, turn_count, turn_secs, estimated = [], 0, 0.0, 0
    for tu in turns:
        if tu["record"]:
            end, s = tu["record"]
            turn_count += 1
            turn_secs += s
            working.append([end - s, end])
        elif tu["start"] is not None and tu["last"] is not None and tu["last"] > tu["start"] \
                and tu["last"] - tu["start"] <= MAX_SECONDS:
            pieces = subtract([tu["start"], tu["last"]], recorded)
            secs = length(pieces)
            if secs > 0:
                turn_count += 1
                turn_secs += secs
                working += pieces
                estimated += 1
    tool_secs = length(intersect(merge([[a, b] for a, b, n in tool_iv if n not in WAITING]), merge(working)))

    added = removed = 0
    for tid in sorted(set(inputs) | set(diffs)):
        if outcomes.get(tid, True):        # no result, or failed: nothing changed
            continue
        a, r = diffs[tid] if tid in diffs else inputs[tid]
        added += a
        removed += r

    cc = None
    if cost_state is not None:
        mu = cost_state.get("modelUsage")
        if isinstance(mu, str):
            try:
                mu = json.loads(mu)
            except ValueError:
                try:
                    mu = json.loads(mu.replace("'", '"').replace("True", "true").replace("False", "false").replace("None", "null"))
                except ValueError:
                    mu = {}
        mu = mu if isinstance(mu, dict) else {}
        def total_of(key):
            return sum(count(v.get(key)) or 0 for v in mu.values() if isinstance(v, dict))
        cs_out, cs_read = total_of("outputTokens"), total_of("cacheReadInputTokens")
        covers = (not truthy(cost_state.get("hasUnknownModelCost")) and cs_out >= total["output"] * 0.99 - 100
                  and cs_read >= total["cacheRead"] * 0.99 - 1000)
        cc = {"usd": number(cost_state.get("totalCostUSD"), 1e7), "current": current, "covers": covers, "modelUsage": mu,
              "out": cs_out, "read": cs_read, "input": total_of("inputTokens"), "write": total_of("cacheCreationInputTokens"),
              "linesAdded": count(cost_state.get("totalLinesAdded")), "linesRemoved": count(cost_state.get("totalLinesRemoved"))}
    lines = (added, removed, "estimate")
    if cc and cc["current"] and cc["covers"] and cc["linesAdded"] is not None and cc["linesRemoved"] is not None:
        lines = (cc["linesAdded"], cc["linesRemoved"], "claudeCode")
    return {
        "id": sid, "replies": len(order), "tokens": total, "subTokens": sub_total, "byModel": dict(by_model),
        "subagents": len(subs), "turns": turn_count, "turnSeconds": turn_secs,
        "turnSource": "estimate" if estimated or not recorded else "claudeCode", "toolSeconds": tool_secs,
        "tools": dict(collections.Counter(tool_names.values())), "compactions": compactions, "errors": sorted(errors),
        "now": now, "estimate": estimate if priced else (0.0 if not order else None), "modelUSD": dict(model_usd), "cc": cc,
        "lines": lines, "countedLines": (added, removed),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--helper", default=HELPER)
    ap.add_argument("--dump", help="a saved --usage-dump instead of running the helper")
    ap.add_argument("--cached", action="store_true", help="let the helper use its own cache")
    ap.add_argument("--show", type=int, default=12, help="mismatches to list per field")
    args = ap.parse_args()

    started = time.time()
    if args.dump:
        dump = json.load(open(args.dump))
        started = os.path.getmtime(args.dump) - 60
    else:
        env = dict(os.environ)
        tmp = tempfile.mkdtemp(prefix="claws-crosscheck-")
        if not args.cached:
            env["CLAWS_SEARCH_CACHE"] = tmp
        out = subprocess.run([args.helper, "--usage-dump"], env=env, capture_output=True, check=True)
        dump = json.loads(out.stdout)
        sys.stderr.write(out.stderr.decode())
        for f in glob.glob(os.path.join(tmp, "*")):
            os.remove(f)
        os.rmdir(tmp)
    swift = {u["sessionID"]: u for u in dump}

    # Real files, a listed one before a link to it; then each ID's copies, oldest first.
    listed = [p for d in sorted(glob.glob(os.path.join(ROOT, "*"))) if os.path.isdir(d) and not os.path.islink(d)
              for p in sorted(glob.glob(os.path.join(d, "*.jsonl")))]
    canonical = {}
    links = 0
    for p in sorted(listed, key=lambda p: (os.path.islink(p), p)):
        real = resolve(p)
        links += os.path.islink(p)
        if real and os.path.isfile(real) and real not in canonical:
            canonical[real] = os.path.basename(p)[:-6]
    by_id = collections.defaultdict(list)
    for real, sid in canonical.items():
        by_id[sid].append(real)
    fields = collections.OrderedDict((k, [0, []]) for k in [
        "replies", "tokens", "tokens by model", "subagents", "subagent tokens", "turns", "turn seconds", "tool seconds",
        "tools", "compactions", "API errors", "context now", "cost source", "estimate", "lines"])
    changed, twice, compared = 0, 0, 0
    rows = []
    for sid, reals in sorted(by_id.items()):
        reals = sorted(reals, key=lambda r: (os.path.getmtime(r), r))
        subs = [s for r in reals for s in subagent_files(r[:-6])]
        paths = reals + [p for r in reals for p in glob.glob(os.path.join(r[:-6], "subagents", "**", "*.jsonl"), recursive=True)]
        if any(os.path.getmtime(p) > started for p in paths):
            changed += 1
            continue                        # written while we looked: live
        twice += len(reals) > 1
        s = swift.get(sid)
        if s is None:
            fields["replies"][1].append((sid, "missing from the dump", ""))
            continue
        p = read_session(sid, reals, subs)
        compared += 1
        rows.append((p, s))

        def same(name, a, b):
            if a == b:
                fields[name][0] += 1
            else:
                fields[name][1].append((sid, a, b))
        same("replies", p["replies"], s["replies"])
        same("tokens", p["tokens"], s["tokens"])
        same("tokens by model", p["byModel"], {k: v["tokens"] for k, v in s["byModel"].items()})
        same("subagents", p["subagents"], s["subagents"]["count"])
        same("subagent tokens", p["subTokens"], s["subagents"]["tokens"])
        same("turns", (p["turns"], p["turnSource"]), (s["turns"]["count"], s["turns"]["source"]))
        same("turn seconds", round(p["turnSeconds"], 3), round(s["turns"]["seconds"], 3))
        same("tool seconds", round(p["toolSeconds"], 3), round(s["toolSeconds"], 3))
        same("tools", p["tools"], s["tools"])
        same("compactions", p["compactions"],
             [(c.get("trigger"), c.get("preTokens"), c.get("postTokens")) for c in s["context"]["compactions"]])
        same("API errors", p["errors"], sorted(e["kind"] for e in s["apiErrors"]))
        same("context now", p["now"], s["context"].get("now"))
        cc = p["cc"]
        source = "claudeCode" if cc and cc["current"] and cc["covers"] else "estimate"
        same("cost source", source, s["cost"]["source"])
        est, sest = p["estimate"], s["cost"].get("estimateUSD")
        same("estimate", True if est is None and sest is None else (est is not None and sest is not None
                                                                     and math.isclose(est, sest, rel_tol=1e-9, abs_tol=1e-9)),
             True)
        same("lines", p["lines"], (s["lines"]["added"], s["lines"]["removed"], s["lines"]["source"]))

    print(f"\n{len(by_id)} sessions on disk ({links} transcripts are links, read as their targets); {compared} compared, "
          f"{twice} of them filed as several copies; {changed} left out as written during the check\n")
    print(f"{'field':<18}{'exact':>8}{'mismatch':>10}")
    for name, (ok, bad) in fields.items():
        print(f"{name:<18}{ok:>8}{len(bad):>10}")
    for name, (ok, bad) in fields.items():
        for sid, a, b in bad[:args.show]:
            print(f"  {name}: {sid[:8]}  python {str(a)[:160]}  |  swift {str(b)[:160]}")
    over = sum(1 for p, _ in rows if p["toolSeconds"] > p["turnSeconds"] + 1e-6)
    print(f"\ntool time over Claude's working time: {over} sessions")

    # Estimates against Claude Code's own figures, where it has a current one.
    def pct(e, c):
        return (e - c) / c * 100 if c else (0.0 if abs(e) < 1e-9 else math.inf)
    current = [(p, s) for p, s in rows if p["cc"] and p["cc"]["current"] and p["estimate"] is not None and p["cc"]["usd"] is not None]
    covering = [(p, s) for p, s in current if p["cc"]["covers"]]
    for title, group in (("current cost-state", current), ("current and covering the transcript", covering)):
        errs = sorted(pct(p["estimate"], p["cc"]["usd"]) for p, _ in group)
        finite = [e for e in errs if math.isfinite(e)]
        within = sum(1 for e in errs if abs(e) <= 3)
        print(f"\nestimate vs Claude Code, {title}: {len(errs)} sessions, {within} within 3% ({within * 100 // max(1, len(errs))}%)")
        if finite:
            q = lambda f: finite[min(len(finite) - 1, int(f * len(finite)))]
            print(f"  error %: min {finite[0]:.2f}  p10 {q(.1):.2f}  median {q(.5):.2f}  p90 {q(.9):.2f}  max {finite[-1]:.2f}")
            bins = collections.Counter()
            for e in errs:
                bins["≤ -10%" if e <= -10 else "-10..-3%" if e < -3 else "-3..-1%" if e < -1 else "±1%" if e <= 1
                     else "1..3%" if e <= 3 else "3..10%" if e <= 10 else "> 10%"] += 1
            print("  " + "  ".join(f"{k}: {bins[k]}" for k in ["≤ -10%", "-10..-3%", "-3..-1%", "±1%", "1..3%", "3..10%", "> 10%"]))
    # Lines counted here against Claude Code's own totals, where its record covers the transcript.
    lc = [(p["countedLines"], (p["cc"]["linesAdded"], p["cc"]["linesRemoved"])) for p, _ in covering
          if p["cc"]["linesAdded"] is not None and p["cc"]["linesRemoved"] is not None]
    print(f"\nlines counted vs Claude Code's, covering records: {sum(1 for a, b in lc if a == b)} of {len(lc)} exact")
    # Why the covering ones miss: what Claude Code counted that no transcript holds.
    misses = [(p, s) for p, s in covering if abs(pct(p["estimate"], p["cc"]["usd"])) > 3]
    if misses:
        print(f"\ncovering but over 3% off ({len(misses)}): Claude Code's counts against the transcripts'")
        for p, _ in misses[:args.show]:
            cc = p["cc"]
            t = p["tokens"]
            print(f"  {p['id'][:8]}  est {pct(p['estimate'], cc['usd']):+.1f}%  output {cc['out'] / max(1, t['output']):.3f}x"
                  f"  cache reads {cc['read'] / max(1, t['cacheRead']):.3f}x  cache writes {cc['write'] / max(1, t['cacheWrite']):.3f}x"
                  f"  input {cc['input'] / max(1, t['input']):.2f}x  models {sorted(cc['modelUsage'])}")
        print("  (every ratio >= 1: Claude Code counted calls that no transcript holds)" if all(
            p["cc"][k] >= p["tokens"][t] for p, _ in misses for k, t in (("out", "output"), ("read", "cacheRead")))
            else "  (some ratio < 1: not explained by uncounted calls alone)")
    # The price table against Claude Code's: models whose token counts match exactly.
    agree, total_models, worst = 0, 0, 0.0
    for p, _ in current:
        mu = p["cc"]["modelUsage"]
        tx = collections.defaultdict(lambda: [0, 0, 0, 0])
        for m, t in p["byModel"].items():
            v = tx[base_model(m)]
            v[0] += t["input"]; v[1] += t["output"]; v[2] += t["cacheRead"]; v[3] += t["cacheWrite"]
        for m, v in mu.items():
            if not isinstance(v, dict):
                continue
            k = base_model(m)
            counts = [count(v.get(x)) or 0 for x in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens")]
            if k in tx and counts == tx[k] and k in p["modelUSD"] and number(v.get("costUSD"), 1e7) is not None:
                total_models += 1
                err = abs(pct(p["modelUSD"][k], number(v.get("costUSD"), 1e7)))
                worst = max(worst, err)
                agree += err <= 0.01
    print(f"\nprice table: {total_models} model entries whose token counts match Claude Code's exactly; "
          f"{agree} priced within 0.01% of its costUSD (worst {worst:.4f}%)")

    # Models with no price, by both readers.
    mine = collections.Counter()
    for p, _ in rows:
        for m in {m for m in p["byModel"] if base_model(m) not in PRICES}:
            mine[m] += 1
    theirs = collections.Counter(m for u in dump for m in u["cost"].get("unpriced", []))
    print(f"\nmodels with no price: in {sum(1 for u in dump if u['cost'].get('unpriced'))} of {len(dump)} sessions (helper): "
          f"{dict(theirs) or 'none'}; python: {dict(mine) or 'none'}")
    print(f"workflow run folders that are links (not followed): {len(set(LINKED_RUNS))}")


if __name__ == "__main__":
    main()
