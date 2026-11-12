#!/usr/bin/env python3
"""Write results/README.md from the committed implementations and their run records.

    python3 tools/results_report.py [--impl implementations] [--baseline go] [--out results/README.md]

Everything on the page comes from DIR/run.json, DIR/results/, DIR/audit/, the transcript archives in
DIR/transcripts/ (through agent_effort.py) and the sources (through code_stats.py). Runs are taken in the order
run.json lists them; a task a later run repeats is taken from the later run.
"""
import argparse
import collections
import json
import os
import statistics
import subprocess
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
import agent_effort  # noqa: E402
from audit import INTEGRITY  # noqa: E402

NAMES = {"cpp": "C++", "rust": "Rust", "go": "Go", "d": "D", "python": "Python", "haskell": "Haskell",
         "clojure": "Clojure"}
MODELS = {"claude-sonnet-5-5": "Claude Sonnet 5.5"}


def name(lang):
    return NAMES.get(lang, lang)


def tool_output(*args):
    return subprocess.run([sys.executable, *args], cwd=ROOT, capture_output=True, text=True,
                          check=True).stdout.strip()


def rel(path):
    return os.path.relpath(path, ROOT)


def order(langs, baseline):
    """The baseline first, then the other languages in run-config order."""
    return [baseline] + [lang for lang in langs if lang != baseline] if baseline in langs else list(langs)


def merged_findings(per_run):
    """The audit findings of several runs, each once: a later run's audit also rescans the implementations
    already in the destination, so it repeats their findings."""
    seen, out = set(), []
    for findings in per_run:
        for f in findings:
            key = (f.get("kind"), f.get("agent"), f.get("detail"))
            if key not in seen:
                seen.add(key)
                out.append(f)
    return out


def render(impl, baseline="go"):
    runs = json.load(open(os.path.join(impl, "run.json")))["runs"]
    first, later = runs[0], runs[1:]
    archives = [os.path.join(impl, r["transcripts"]) for r in runs]
    results = {}
    for r in runs:
        results.update(json.load(open(os.path.join(impl, r["results"]))))
    audit = merged_findings([json.load(open(os.path.join(impl, r["audit"]))) for r in runs])
    reviewed = []
    for r in runs:
        path = os.path.join(impl, r["audit"])[:-len(".json")] + ".reviewed.json"
        if os.path.isfile(path):
            reviewed += json.load(open(path))
    accepted = {(f.get("agent"), f.get("kind"), f.get("detail")) for f in reviewed if f.get("reason")}
    kinds = collections.Counter(f["kind"] for f in audit)
    integrity = sum(1 for f in audit if f["kind"] in INTEGRITY
                    and (f.get("agent"), f.get("kind"), f.get("detail")) not in accepted)
    reviewed_note = (f" ({len(accepted)} reviewed and found harmless, with reasons, in "
                     f"`implementations/audit/<run>.reviewed.json`)" if accepted else "")
    tasks = agent_effort.task_records(archives)
    opts = first["options"]
    langs = order(opts["langs"], baseline)
    per_lang = collections.Counter(t["lang"] for t in tasks)
    problems = sorted({t["slug"] for t in tasks})
    archive_args = " ".join(rel(a) for a in archives)
    effort = tool_output("tools/agent_effort.py", *map(rel, archives), "--baseline", baseline)
    code = tool_output("tools/code_stats.py", rel(impl))

    toolchains = "; ".join(f"{name(lang)} ({first['toolchains'][lang]})" for lang in langs)
    reps = opts.get("reps", 1)
    repeated = opts.get("repProblems") or []
    tasks_line = (f"all {len(problems)} problems once" + (
        f", plus {reps} repetitions of {', '.join(sorted(repeated))}" if reps > 1 and repeated else "")
        + ": " + ", ".join(f"{per_lang[lang]} tasks for {name(lang)}" for lang in langs) + ".")
    planned = len(problems) + (reps - 1) * len([p for p in repeated if p in problems])
    if any(per_lang[lang] < planned for lang in langs):
        missing = len(langs) * planned - sum(per_lang[lang] for lang in langs)
        covered = all(any(t["slug"] == p and t["lang"] == lang for t in tasks) for p in problems for lang in langs)
        tasks_line += (f" The run was stopped before it finished: {missing} of {len(langs) * planned} planned tasks did "
                       + ("not run, all of them repetitions, so every problem has at least one task per language."
                          if covered else "not run, and some problems have no task in some languages."))
    reruns = "".join(
        f"\n- **Rerun `{r['workflow_run']}`:** {', '.join(sorted(r['implementations']))}, with the same prompt, "
        f"model and sandbox at a later harness commit; it replaces the earlier attempts at those tasks "
        f"([why](../docs/generating.md))." for r in later)
    failed = sorted(f"{label}: {v.get('public')}" + (f"; held-out {v['hidden']}" if "hidden" in v else "")
                    for label, v in results.items() if not v.get("public_pass") or v.get("hidden_pass") is False)
    finished = "; ".join(f"{name(lang)}: {sum(t['finished'] for t in tasks if t['lang'] == lang)} of "
                         f"{per_lang[lang]}" for lang in langs)

    by = collections.defaultdict(list)
    for t in tasks:
        by[(t["slug"], t["lang"])].append(t)

    def median(slug, lang, key):
        xs = by[(slug, lang)]
        return statistics.median(x[key] for x in xs) if xs else None

    others = [lang for lang in langs if lang != baseline]
    head = (["Problem", "Runs"] + [f"{name(lang)} output tokens" for lang in langs]
            + [f"{name(lang)}/{name(baseline)}" for lang in others] + [f"{name(lang)} turns" for lang in langs]
            + [f"{name(lang)} finished" for lang in langs])
    rows = ["| " + " | ".join(head) + " |", "|---|" + "---:|" * (len(head) - 1)]
    for slug in problems:
        base = median(slug, baseline, "output_tokens")
        cells = [slug, str(max(len(by[(slug, lang)]) for lang in langs))]
        cells += [f"{median(slug, lang, 'output_tokens') / 1000:.1f}k" for lang in langs]
        cells += [f"{median(slug, lang, 'output_tokens') / base:.2f}" for lang in others]
        cells += [f"{median(slug, lang, 'turns'):.0f}" for lang in langs]
        cells += [f"{sum(x['finished'] for x in by[(slug, lang)])}/{len(by[(slug, lang)])}" for lang in langs]
        rows.append("| " + " | ".join(cells) + " |")
    names = [name(lang) for lang in langs]
    language_list = ", ".join(names[:-1]) + " and " + names[-1] if len(names) > 1 else "".join(names)

    return f"""# Results

Generated by `python3 tools/results_report.py` (`make results`) from the implementations in
[`implementations/`](../implementations/) and their run records. Agent effort for {language_list}; performance
results and further languages will follow. Every table can also be regenerated with the command above it.

## The runs

- **Languages:** {toolchains}.
- **Tasks:** {tasks_line}
- **Agent:** {MODELS.get(first['models'][0], first['models'][0])} at {opts.get('effort', 'default')} effort, in Claude Code \
{first.get('claude_code', '').split(' ')[0]}; one headless session per task in a private sandboxed workspace, from
  `tools/task_prompt.txt` ([how runs work](../docs/generating.md)).
- **Verification:** each project rebuilt from a clean copy of its sources and run against the public tests and,
  for the five large problems, the held-out tests.
- **Run `{first['workflow_run']}`:** {first['agents']} sessions.{reruns}
- **Usage:** ${sum(t['cost'] for t in tasks):.0f} at API list prices for the {len(tasks)} sessions counted.

## Agent effort

`python3 tools/agent_effort.py {archive_args} --baseline {baseline}`

Per problem, the median over repetitions; then the ratio to {name(baseline)} on the same problem; then the
geometric mean over problems with a 95% bootstrap interval. Output tokens are the headline measure. An unfinished
task counts as at least as costly as the costliest finished task on its problem.

{effort}

## Completion and audit

`implementations/results/<run>.json`, `implementations/audit/<run>.json`

- Tasks that pass every public and held-out test on a clean build: {finished}.
- Not passing: {'; '.join(failed) if failed else 'none'}.
- Audit: {integrity or 'no'} unreviewed integrity findings{reviewed_note}. Blocked attempts (reads the sandbox refused): \
{kinds.get('blocked-attempt', 0)}; non-default optimisation settings in build files: {kinds.get('build-flags', 0)};
  uses of a standard-library facility the problem's spec rules out: {kinds.get('banned-facility', 0)};
  third-party dependencies: {kinds.get('dependency', 0)}.

## Code size

`python3 tools/code_stats.py {rel(impl)}`

{code}

## By problem

Medians over repetitions; "finished" counts tasks that pass on a clean build.

""" + "\n".join(rows) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--impl", default=os.path.join(ROOT, "implementations"))
    ap.add_argument("--baseline", default="go")
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "README.md"))
    a = ap.parse_args()
    text = render(os.path.abspath(a.impl), a.baseline)
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        f.write(text)
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
