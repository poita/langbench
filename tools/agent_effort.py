#!/usr/bin/env python3
"""How effectively agents wrote each language: correctness, tool calls, tokens and time per language.

    tools/agent_effort.py RUN[:LANGS] [RUN[:LANGS] ...] [--langs d,go] [--baseline go]

RUN is a transcript archive (.tar.gz) as `impl_run.py finish` writes (implementations/transcripts/<run>.tar.gz),
or a run directory; older workflow runs can be given by run id (wf_...); :LANGS (e.g. wf_x:go,rust) takes only those languages from that run. Each agent's transcript gives its tool calls, token usage and time; the run's journal gives
whether its implementation passed. For runs made by impl_run.py launch with --baseline, the headline is output
tokens (then turns and cost) as paired per-problem ratios to the baseline language: the median over repetitions
on each problem, the geometric mean of the ratios over problems with a 95% bootstrap interval, and the share of
tasks finished; an unfinished task counts as at least as costly as the costliest finished task on its problem. Time is split into model inference and tool categories: tool time runs from a
tool request to its result, inference from a result to the model's next message.
"""
import argparse
import atexit
import collections
import datetime
import glob
import json
import math
import os
import random
import re
import shutil
import sys
import tarfile
import tempfile

CATEGORIES = ["inference", "build", "unit tests", "harness tests", "other shell", "files"]
NAMES = {"cpp": "C++", "rust": "Rust", "go": "Go", "d": "D", "python": "Python", "haskell": "Haskell",
         "clojure": "Clojure"}


def run_dir(run):
    if os.path.isdir(run):
        return run
    if run.endswith(".tar.gz") and os.path.isfile(run):
        tmp = tempfile.mkdtemp()
        atexit.register(shutil.rmtree, tmp, True)
        with tarfile.open(run) as t:
            t.extractall(tmp, filter="data")
        (top,) = os.listdir(tmp)
        return os.path.join(tmp, top)
    hits = glob.glob(os.path.expanduser(f"~/.claude/projects/*/*/subagents/workflows/{run}"))
    if not hits:
        sys.exit(f"no transcripts found for workflow run {run}")
    return hits[0]


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def classify(name, inp):
    if name != "Bash":
        return "files" if name in ("Read", "Grep", "Glob", "Write", "Edit", "MultiEdit") else "other shell"
    c = inp.get("command", "")
    if "run_tests.py" in c:
        return "harness tests"
    if re.search(r"\b(dub|go|cargo|cabal)\s+test\b|\bctest\b|python3? -m unittest|unittest|"
                 r"\b(clojure|clj)\s+-[MXA]:test\b", c):
        return "unit tests"
    if re.search(r"build\.sh|\bdub (build|run)|\bgo (build|vet)|cargo build|\bcmake\b|\bmake\b|ldc2|\bdmd\b|"
                 r"clang\+\+|g\+\+|\bcabal (build|configure)\b|\(compile '", c):
        return "build"
    return "other shell"


def agent_stats(path):
    """Tool calls, tokens (each API message counted once) and time split for one agent transcript."""
    events = [json.loads(l) for l in open(path)]
    events = [e for e in events if e.get("type") in ("user", "assistant") and "timestamp" in e]
    usage, calls, pending, turns = {}, 0, {}, set()
    time = collections.Counter()
    last_ready = None
    for e in events:
        t = ts(e["timestamp"])
        m = e.get("message", {})
        content = m.get("content")
        if e["type"] == "assistant":
            turns.add(m.get("id") or id(e))
            if m.get("usage"):
                usage[m.get("id") or id(e)] = m["usage"]
            if last_ready is not None:
                time["inference"] += max(0.0, t - last_ready)
                last_ready = t
            for c in content if isinstance(content, list) else []:
                if c.get("type") == "tool_use":
                    calls += 1
                    pending[c["id"]] = (t, classify(c.get("name"), c.get("input") or {}))
        else:
            for c in content if isinstance(content, list) else []:
                if c.get("type") == "tool_result" and c.get("tool_use_id") in pending:
                    t0, cat = pending.pop(c["tool_use_id"])
                    time[cat] += max(0.0, t - max(t0, last_ready or t0))
            last_ready = t
    seconds = ts(events[-1]["timestamp"]) - ts(events[0]["timestamp"]) if events else 0.0
    return {"turns": len(turns), "tool_calls": calls,
            "output_tokens": sum(u.get("output_tokens", 0) or 0 for u in usage.values()),
            "context_tokens": sum((u.get("input_tokens", 0) or 0) + (u.get("cache_read_input_tokens", 0) or 0)
                                  + (u.get("cache_creation_input_tokens", 0) or 0) for u in usage.values()),
            "seconds": seconds, "time": time}


def journal_results(rdir):
    """{agentId: result} for agents that returned a result."""
    out = {}
    path = os.path.join(rdir, "journal.jsonl")
    for line in open(path) if os.path.exists(path) else []:
        d = json.loads(line)
        if d.get("type") == "result" and isinstance(d.get("result"), dict):
            out[d.get("agentId")] = d["result"]
    return out


def result_tokens(result):
    """(output tokens, context tokens) of a whole headless session from its result. modelUsage covers the whole
    session, subagents included; "usage" covers only the main agent's last exchange, which is not the whole
    session when it answered a notification after its final reply."""
    mu = result.get("modelUsage") or {}
    if mu:
        return (sum(v.get("outputTokens", 0) or 0 for v in mu.values()),
                sum((v.get(k, 0) or 0) for v in mu.values()
                    for k in ("inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens")))
    u = result.get("usage") or {}
    return (u.get("output_tokens", 0) or 0,
            sum((u.get(k, 0) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")))


def last_labels(rdirs):
    """The labels each run made by impl_run.py launch owns: a task a later run repeats belongs to the later run."""
    owner = {}
    for rdir in rdirs:
        path = os.path.join(rdir, "manifest.jsonl")
        if os.path.isfile(path):
            for e in (json.loads(line) for line in open(path)):
                owner[e["label"]] = rdir
    return {rdir: {label for label, r in owner.items() if r == rdir} for rdir in rdirs}


def summarise_sessions(rdir, row, langs=None, only=None, problems=None, present_in=None, owned=None):
    """Add the completed tasks of a run made by impl_run.py launch (manifest.jsonl, sessions/, results.json).
    Turns, tool calls and time come from the session transcripts (subagents included); tokens and cost from the
    session's own result, which counts output tokens exactly; pass/fail from finish's rerun of the tests."""
    last = {}
    for e in (json.loads(line) for line in open(os.path.join(rdir, "manifest.jsonl"))):
        last[e["label"]] = e
    rpath = os.path.join(rdir, "results.json")
    verified = json.load(open(rpath)) if os.path.isfile(rpath) else {}
    for label, e in last.items():
        rep, lang, slug = label.split(":")
        if (owned is not None and label not in owned) or e.get("infra_error") or (langs and lang not in langs) or (only and lang not in only) \
                or (problems and slug not in problems) \
                or (present_in and not os.path.isdir(os.path.join(present_in, rep, lang, slug))):
            continue
        sid = e["session_id"]
        files = [os.path.join(rdir, "sessions", sid + ".jsonl")]
        files += sorted(glob.glob(os.path.join(rdir, "sessions", sid, "subagents", "**", "*.jsonl"), recursive=True))
        r = row(lang)
        r["agents"] += 1
        v = verified.get(label, {})
        r["all_pass"] += bool(v.get("public_pass") and v.get("hidden_pass") is not False)
        for path in (f for f in files if os.path.isfile(f)):
            s = agent_stats(path)
            for k in ("turns", "tool_calls"):
                r[k] += s[k]
            if path == files[0]:
                r["seconds"] += s["seconds"]
            r["time"].update(s["time"])
        out_tokens, ctx_tokens = result_tokens(e.get("result") or {})
        r["output_tokens"] += out_tokens
        r["context_tokens"] += ctx_tokens
        r["cost"] += (e.get("result") or {}).get("total_cost_usd") or 0.0


def summarise(runs, langs=None, problems=None, present_in=None):
    """Per-language totals over the implementation agents of the given runs."""
    rows = {}

    def row(lang):
        return rows.setdefault(lang, {"agents": 0, "all_pass": 0, "turns": 0, "tool_calls": 0, "output_tokens": 0,
                                      "context_tokens": 0, "cost": 0.0, "seconds": 0.0, "time": collections.Counter()})

    specs = [(spec.partition(":")[0], spec.partition(":")[2]) for spec in runs]
    rdirs = [run_dir(run) for run, _ in specs]
    owned = last_labels(rdirs)
    for (run, only), rdir in zip(specs, rdirs):
        only = set(only.split(",")) if only else None
        if os.path.isfile(os.path.join(rdir, "manifest.jsonl")):
            summarise_sessions(rdir, row, langs, only, problems, present_in, owned[rdir])
            continue
        results = journal_results(rdir)
        for meta_path in sorted(glob.glob(os.path.join(rdir, "agent-*.meta.json"))):
            parts = json.load(open(meta_path)).get("description", "").split(":")
            if len(parts) != 3 or (langs and parts[1] not in langs) or (only and parts[1] not in only) \
                    or (problems and parts[2] not in problems) \
                    or (present_in and not os.path.isdir(os.path.join(present_in, *parts))):
                continue
            lang = parts[1]
            agent = os.path.basename(meta_path)[len("agent-"):-len(".meta.json")]
            s = agent_stats(meta_path[:-len(".meta.json")] + ".jsonl")
            r = row(lang)
            res = results.get(agent) or {}
            r["agents"] += 1
            r["all_pass"] += bool(res.get("all_pass") and res.get("unit_tests_pass"))
            for k in ("turns", "tool_calls", "output_tokens", "context_tokens", "seconds"):
                r[k] += s[k]
            r["time"].update(s["time"])
    return rows


def task_records(runs):
    """One record per task (last attempt) of runs made by impl_run.py launch: lang, slug, rep, whether it
    finished (its public tests, and any held-out tests, pass on finish's rerun), output tokens, turns and cost.
    A task that a later run repeats is taken from the later run."""
    out = []
    rdirs = [run_dir(run) for run in runs]
    owned = last_labels(rdirs)
    for rdir in rdirs:
        last = {}
        for e in (json.loads(line) for line in open(os.path.join(rdir, "manifest.jsonl"))):
            last[e["label"]] = e
        rpath = os.path.join(rdir, "results.json")
        verified = json.load(open(rpath)) if os.path.isfile(rpath) else {}
        for label, e in last.items():
            if label not in owned[rdir]:
                continue
            rep, lang, slug = label.split(":")
            v = verified.get(label, {})
            sid = e["session_id"]
            files = [os.path.join(rdir, "sessions", sid + ".jsonl")]
            files += sorted(glob.glob(os.path.join(rdir, "sessions", sid, "subagents", "**", "*.jsonl"), recursive=True))
            r = e.get("result") or {}
            out.append({"lang": lang, "slug": slug, "rep": rep,
                        "finished": bool(not e.get("infra_error") and v.get("public_pass")
                                         and v.get("hidden_pass") is not False),
                        "output_tokens": result_tokens(r)[0],
                        "turns": sum(agent_stats(f)["turns"] for f in files if os.path.isfile(f)),
                        "cost": r.get("total_cost_usd") or 0.0})
    return out


def percentile(xs, p):
    xs = sorted(xs)
    k = (len(xs) - 1) * p / 100
    lo, hi = math.floor(k), math.ceil(k)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def gmean(xs):
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def paired(tasks, baseline, metric="output_tokens", samples=2000, seed=0):
    """Each language against the baseline, problem by problem: the median over repetitions of the metric, the
    ratio to the baseline's median on the same problem, and the geometric mean of those ratios with a 95%
    bootstrap interval over problems. A task that did not finish counts as at least as costly as the most
    costly finished task on its problem, in any language, so unfinished work is never cheaper than finishing."""
    worst = {}
    for t in tasks:
        if t["finished"]:
            worst[t["slug"]] = max(worst.get(t["slug"], 0), t[metric])
    values = collections.defaultdict(lambda: collections.defaultdict(list))
    done = collections.defaultdict(lambda: [0, 0])
    for t in tasks:
        v = t[metric] if t["finished"] else max(t[metric], worst.get(t["slug"], t[metric]))
        values[t["lang"]][t["slug"]].append(v)
        done[t["lang"]][0] += t["finished"]
        done[t["lang"]][1] += 1
    med = {lang: {slug: percentile(vs, 50) for slug, vs in per.items()} for lang, per in values.items()}
    rng = random.Random(seed)
    out = {}
    for lang in med:
        if lang == baseline or baseline not in med:
            continue
        ratios = {s: med[lang][s] / med[baseline][s] for s in med[lang] if s in med[baseline] and med[baseline][s] > 0
                  and med[lang][s] > 0}
        if not ratios:
            continue
        rs = list(ratios.values())
        boots = [gmean([rng.choice(rs) for _ in rs]) for _ in range(samples)]
        out[lang] = {"gmean": gmean(rs), "lo": percentile(boots, 2.5), "hi": percentile(boots, 97.5),
                     "problems": len(rs), "completion": tuple(done[lang]), "ratios": ratios}
    return out


def report_paired(p, baseline, metric, tasks):
    b = NAMES.get(baseline, baseline)
    done = collections.Counter((t["lang"], t["finished"]) for t in tasks if t["lang"] == baseline)
    out = [f"{metric.replace('_', ' ')} relative to {b}, per problem (median over repetitions), geometric mean "
           f"with 95% bootstrap interval over problems; below 1 is less effort", "",
           "| Language | vs " + b + " | 95% interval | Problems | Finished |", "|---|---:|---:|---:|---:|",
           f"| {b} | 1.00x | | | {done[(baseline, True)]}/{done[(baseline, True)] + done[(baseline, False)]} |"]
    for lang in sorted(p, key=lambda l: p[l]["gmean"]):
        x = p[lang]
        out.append(f"| {NAMES.get(lang, lang)} | {x['gmean']:.2f}x | {x['lo']:.2f}–{x['hi']:.2f} | {x['problems']} | "
                   f"{x['completion'][0]}/{x['completion'][1]} |")
    return "\n".join(out)


def report(rows, baseline=None):
    out = ["| Language | Agents | All tests pass | Turns / agent | Tool calls / agent | Output tokens / agent | "
           "Context tokens / agent | Cost / agent | Minutes / agent | "
           + " | ".join(c.capitalize() for c in CATEGORIES) + " |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|" + "---:|" * len(CATEGORIES)]
    for lang in sorted(rows, key=lambda l: list(NAMES).index(l) if l in NAMES else 99):
        r = rows[lang]
        n = r["agents"]
        tot = sum(r["time"][c] for c in CATEGORIES) or 1
        out.append(f"| {NAMES.get(lang, lang)} | {n} | {r['all_pass']}/{n} | {r['turns'] / n:.1f} | {r['tool_calls'] / n:.1f} | "
                   f"{r['output_tokens'] / n / 1000:.0f}k | {r['context_tokens'] / n / 1e6:.2f}M | "
                   f"${r.get('cost', 0) / n:.2f} | "
                   f"{r['seconds'] / n / 60:.1f} | "
                   + " | ".join(f"{100 * r['time'][c] / tot:.0f}%" for c in CATEGORIES) + " |")
    if baseline and baseline in rows:
        b = rows[baseline]
        out += ["", f"Relative to {NAMES.get(baseline, baseline)} (per agent):", "",
                "| Language | Turns | Tool calls | Output tokens | Context tokens | Time |", "|---|---:|---:|---:|---:|---:|"]
        for lang, r in rows.items():
            if lang == baseline:
                continue
            ratio = lambda k: (r[k] / r["agents"]) / (b[k] / b["agents"]) if b[k] else math.nan
            out.append(f"| {NAMES.get(lang, lang)} | {ratio('turns'):.2f}x | {ratio('tool_calls'):.2f}x | {ratio('output_tokens'):.2f}x | "
                       f"{ratio('context_tokens'):.2f}x | {ratio('seconds'):.2f}x |")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", help="workflow run ids, directories or transcript archives; a task a later run "
                    "repeats is taken from the later run")
    ap.add_argument("--langs", default="", help="comma-separated languages to include")
    ap.add_argument("--problems", default="", help="comma-separated problems to include, e.g. the ones every "
                    "language has, for a like-for-like comparison")
    ap.add_argument("--in", dest="present_in", help="count only agents whose implementation is in this directory "
                    "(e.g. implementations), when a run's code was later moved or pruned")
    ap.add_argument("--baseline", help="language to express the others relative to")
    a = ap.parse_args()
    langs = set(a.langs.split(",")) if a.langs else None
    problems = set(a.problems.split(",")) if a.problems else None
    rows = summarise(a.runs, langs, problems, a.present_in)
    if not rows:
        sys.exit("no implementation agents found")
    if a.baseline and all(os.path.isfile(os.path.join(run_dir(r), "manifest.jsonl")) for r in a.runs):
        tasks = [t for t in task_records(a.runs) if (not langs or t["lang"] in langs | {a.baseline})
                 and (not problems or t["slug"] in problems)]
        for metric in ("output_tokens", "turns", "cost"):
            print(report_paired(paired(tasks, a.baseline, metric), a.baseline, metric, tasks), end="\n\n")
        print("Per agent, all problems pooled:\n")
    print(report(rows, a.baseline))


if __name__ == "__main__":
    main()
