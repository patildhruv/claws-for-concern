#!/usr/bin/env python3
"""Cross-checks the search helper's usage figures against an independent reading of the transcripts.

    tools/usage-crosscheck.py [--helper PATH | --dump FILE] [--cached] [--show N]

Runs `ClawsSearch --usage-dump` (by default the one in build/, with a fresh cache in a temporary
folder; --cached uses the helper's own cache), then reads every transcript under ~/.claude/projects
itself, read-only, with nothing shared with the Swift reader: every line goes through json.loads, and
the rules below are written from the facts in docs/usage.md. It prints which fields agree exactly,
the mismatches (session ID prefixes only), and how the estimates compare with Claude Code's own
cost-state figures. It writes no files. Its output describes your own sessions: never commit it.

The rules, as verified on real transcripts (Claude Code 2.1.316, 2026-11-03):
  - files: <project>/<id>.jsonl, its subagents <id>/subagents/*.jsonl and workflow agents
    <id>/subagents/workflows/<run>/agent-*.jsonl, never through a link (a resumed session's run folder
    can link to the starting session's run); lines with "forkedFrom" were copied from another session
    and do not count.
  - a reply is an assistant line's message.id (else requestId), counted once; its usage is the LAST
    line's in the file where the id first appears; model "<synthetic>" is not a reply.
  - API errors: assistant lines with isApiErrorMessage, once per message id.
  - context after a main-thread reply = input + cache read + cache write; compactions are
    system/compact_boundary lines of the main transcript; turns its system/turn_duration lines.
  - tool calls: each tool_use block id once, subagents included.
  - Claude Code's figure: the main transcript's last cost-state, if no main-thread reply follows it
    and it counts at least 99% of the transcript's output tokens and cache reads.
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
HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "Claws for Concern.app",
                      "Contents", "Helpers", "Claws Search.app", "Contents", "MacOS", "ClawsSearch")

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


def base_model(m):
    m = (m or "").lower()
    m = re.sub(r"\[.*$", "", m)
    m = m.split("@")[0]
    if "anthropic." in m:
        m = m.split("anthropic.", 1)[1]
    m = re.sub(r"-v\d+(:\d+)?$", "", m)
    return re.sub(r"-\d{8}$", "", m)


def num(v):
    if isinstance(v, bool) or v is None:
        return 0
    if isinstance(v, (int, float)):
        return v
    try:
        return float(str(v).strip())
    except ValueError:
        return 0


def tokens_of(u):
    u = u if isinstance(u, dict) else {}
    cc = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
    write = int(num(u.get("cache_creation_input_tokens")))
    return {"output": int(num(u.get("output_tokens"))), "cacheRead": int(num(u.get("cache_read_input_tokens"))),
            "cacheWrite": write, "cacheWrite1h": min(write, int(num(cc.get("ephemeral_1h_input_tokens")))),
            "input": int(num(u.get("input_tokens")))}


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
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


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


def read_session(main):
    sid = os.path.basename(main)[:-6]
    sdir = main[:-6]
    subs = subagent_files(sdir)
    owner, last = {}, {}
    order, main_events = [], []        # main_events: ("reply", id) | ("compaction", post)
    errors, error_ids, tools = [], set(), {}
    compactions, turns, prompts = [], [], []
    cost_state, cost_after = None, False
    for i, f in enumerate([main] + subs):
        sub = i > 0
        for o in lines_of(f):
            t = o.get("type")
            if t == "assistant":
                m = o.get("message") if isinstance(o.get("message"), dict) else {}
                if o.get("isApiErrorMessage") is True:
                    key = m.get("id") or o.get("requestId") or o.get("uuid")
                    if key not in error_ids or key is None:
                        error_ids.add(key)
                        errors.append(o.get("error") or "unknown")
                    continue
                content = m.get("content") if isinstance(m.get("content"), list) else []
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id") and b["id"] not in tools:
                        tools[b["id"]] = b.get("name") or "Tool"
                rid = m.get("id") or o.get("requestId")
                if not rid or m.get("model") in (None, "<synthetic>") or not isinstance(m.get("usage"), dict):
                    continue
                if rid in owner and owner[rid] != i:
                    continue
                if rid not in owner:
                    owner[rid] = i
                    order.append(rid)
                    if not sub:
                        main_events.append(("reply", rid))
                u = m["usage"]
                stu = u.get("server_tool_use") if isinstance(u.get("server_tool_use"), dict) else {}
                last[rid] = {"model": m.get("model"), "t": tokens_of(u), "sub": sub, "at": when(o.get("timestamp")),
                             "speed": u.get("speed"), "geo": u.get("inference_geo"),
                             "searches": int(num(stu.get("web_search_requests")))}
                if not sub:
                    cost_after = True
                    if prompts and last[rid]["at"] is not None:
                        prompts[-1][1] = last[rid]["at"]
            elif sub:
                continue
            elif t == "system" and o.get("subtype") == "compact_boundary":
                md = o.get("compactMetadata") if isinstance(o.get("compactMetadata"), dict) else {}
                compactions.append((md.get("trigger"), md.get("preTokens"), md.get("postTokens")))
                main_events.append(("compaction", md.get("postTokens")))
            elif t == "system" and o.get("subtype") == "turn_duration" and o.get("durationMs") is not None:
                if when(o.get("timestamp")) is not None:
                    turns.append(num(o.get("durationMs")) / 1000)
            elif t == "cost-state":
                if o.get("totalCostUSD") is not None:
                    cost_state, cost_after = o, False
            elif t == "user" and not o.get("isMeta") and not o.get("isCompactSummary"):
                c = (o.get("message") or {}).get("content") if isinstance(o.get("message"), dict) else None
                if isinstance(c, str):
                    is_prompt = c.strip() != ""
                elif isinstance(c, list):
                    blocks = [b for b in c if isinstance(b, dict)]
                    is_prompt = (any(b.get("type") == "text" and str(b.get("text") or "").strip() for b in blocks)
                                 and not any(b.get("type") == "tool_result" for b in blocks))
                else:
                    is_prompt = False
                at = when(o.get("timestamp"))
                if is_prompt and at is not None:
                    prompts.append([at, None])

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
    now = None
    for kind, v in main_events:
        if kind == "reply":
            t = last[v]["t"]
            now = t["input"] + t["cacheRead"] + t["cacheWrite"]
        elif v is not None:
            now = v
    if turns:
        turn_count, turn_secs = len(turns), sum(turns)
    else:
        spans = [b - a for a, b in prompts if b is not None and b > a]
        turn_count, turn_secs = len(spans), sum(spans)
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
        cs_out = sum(int(num(v.get("outputTokens"))) for v in mu.values() if isinstance(v, dict))
        cs_read = sum(int(num(v.get("cacheReadInputTokens"))) for v in mu.values() if isinstance(v, dict))
        covers = (not cost_state.get("hasUnknownModelCost") and cs_out >= total["output"] * 0.99 - 100
                  and cs_read >= total["cacheRead"] * 0.99 - 1000)
        cc = {"usd": num(cost_state.get("totalCostUSD")), "current": not cost_after, "covers": covers, "modelUsage": mu,
              "out": cs_out, "read": cs_read,
              "input": sum(int(num(v.get("inputTokens"))) for v in mu.values() if isinstance(v, dict)),
              "write": sum(int(num(v.get("cacheCreationInputTokens"))) for v in mu.values() if isinstance(v, dict))}
    return {
        "id": sid, "replies": len(order), "tokens": total, "subTokens": sub_total, "byModel": dict(by_model),
        "subagents": len(subs), "turns": turn_count, "turnSeconds": turn_secs, "turnSource": "claudeCode" if turns else "estimate",
        "tools": dict(collections.Counter(tools.values())), "compactions": compactions, "errors": sorted(errors),
        "now": now, "estimate": estimate if priced else (0.0 if not order else None), "modelUSD": dict(model_usd), "cc": cc,
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

    mains = sorted(glob.glob(os.path.join(ROOT, "*", "*.jsonl")))
    by_id = collections.defaultdict(list)
    for m in mains:
        by_id[os.path.basename(m)[:-6]].append(m)
    fields = collections.OrderedDict((k, [0, []]) for k in [
        "replies", "tokens", "tokens by model", "subagents", "subagent tokens", "turns", "turn seconds", "tools",
        "compactions", "API errors", "context now", "cost source", "estimate"])
    changed, twice, compared = 0, 0, 0
    rows = []
    for sid, files in sorted(by_id.items()):
        if len(files) > 1:
            twice += 1
            continue                        # filed under two project folders: the dump has one of them
        main_file = files[0]
        sdir = main_file[:-6]
        paths = [main_file] + glob.glob(os.path.join(sdir, "subagents", "**", "*.jsonl"), recursive=True)
        if any(os.path.getmtime(p) > started for p in paths):
            changed += 1
            continue                        # written while we looked: live
        s = swift.get(sid)
        if s is None:
            fields["replies"][1].append((sid, "missing from the dump", ""))
            continue
        p = read_session(main_file)
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

    print(f"\n{len(by_id)} sessions on disk; {compared} compared; {changed} left out as written during the check; "
          f"{twice} left out as filed under two project folders\n")
    print(f"{'field':<18}{'exact':>8}{'mismatch':>10}")
    for name, (ok, bad) in fields.items():
        print(f"{name:<18}{ok:>8}{len(bad):>10}")
    for name, (ok, bad) in fields.items():
        for sid, a, b in bad[:args.show]:
            print(f"  {name}: {sid[:8]}  python {str(a)[:160]}  |  swift {str(b)[:160]}")

    # Estimates against Claude Code's own figures, where it has a current one.
    def pct(e, c):
        return (e - c) / c * 100 if c else (0.0 if abs(e) < 1e-9 else math.inf)
    current = [(p, s) for p, s in rows if p["cc"] and p["cc"]["current"] and p["estimate"] is not None]
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
            counts = [int(num(v.get(x))) for x in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens")]
            if k in tx and counts == tx[k] and k in p["modelUSD"]:
                total_models += 1
                err = abs(pct(p["modelUSD"][k], num(v.get("costUSD"))))
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
    print(f"workflow run folders that are links (not followed): {len(LINKED_RUNS)}")


if __name__ == "__main__":
    main()
