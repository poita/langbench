#!/usr/bin/env python3
"""Render a run's transcripts as readable Markdown, one file per task, for linking from reports.

    tools/render_transcripts.py ARCHIVE OUTDIR [--langs d,go]

ARCHIVE is a run archive written by `impl_run.py finish` (DEST/transcripts/<run>.tar.gz). OUTDIR gets
<rep>-<lang>-<slug>.md per task and a README.md index. Each tool call is numbered and anchored (#call-N), so
a report can link to the exact step; the agent's visible text is kept, its thinking is not; long tool output is
cut to its first and last lines. The archive keeps the full transcripts.
"""
import argparse
import json
import os
import shutil
import sys
import tarfile
import tempfile

NAMES = {"cpp": "C++", "rust": "Rust", "go": "Go", "d": "D", "python": "Python"}
HEAD, TAIL = 40, 30


def fence(text, lang=""):
    ticks = "```"
    while ticks in text:
        ticks += "`"
    return f"{ticks}{lang}\n{text.rstrip()}\n{ticks}"


def truncate(text):
    lines = text.rstrip().splitlines()
    if len(lines) <= HEAD + TAIL + 5:
        return text
    return "\n".join(lines[:HEAD] + [f"... {len(lines) - HEAD - TAIL} lines omitted ..."] + lines[-TAIL:])


def result_text(content):
    if isinstance(content, str):
        return content
    return "\n".join(x.get("text", "") for x in content or [] if isinstance(x, dict) and x.get("type") == "text")


def describe_call(name, inp):
    if name == "Bash":
        return fence(inp.get("command", ""), "bash")
    if name in ("Write",):
        body = inp.get("content", "")
        return f"`{inp.get('file_path')}` ({len(body.splitlines())} lines)\n\n" + fence(truncate(body))
    if name in ("Edit",):
        return (f"`{inp.get('file_path')}`\n\n" + fence(truncate(inp.get("old_string", "")), "diff-old") + "\n\n"
                + fence(truncate(inp.get("new_string", "")), "diff-new"))
    if name == "Read":
        extra = {k: v for k, v in inp.items() if k != "file_path"}
        return f"`{inp.get('file_path')}`" + (f" {json.dumps(extra)}" if extra else "")
    return fence(json.dumps(inp, indent=1)[:4000], "json")


def render_session(label, transcripts, result, verified=None, counterparts=()):
    """Markdown for one task: summary, then the main session and any subagents, call by call."""
    rep, lang, slug = label.split(":")
    out = [f"# {NAMES.get(lang, lang)} · {slug} · {rep}", ""]
    usage = result.get("modelUsage") or {}
    out_tokens = sum(v.get("outputTokens", 0) for v in usage.values()) or (result.get("usage") or {}).get("output_tokens")
    out += [f"- Tests on a clean build: {(verified or {}).get('public', 'n/a')}"
            + (f"; hidden {verified['hidden']}" if verified and "hidden" in verified else ""),
            f"- Output tokens: {out_tokens}; cost ${result.get('total_cost_usd') or 0:.2f}",
            ]
    if counterparts:
        out.append("- Same task in other languages and repetitions: " + ", ".join(f"[{t}]({f})" for t, f in counterparts))
    out.append("")
    n = 0
    for i, lines in enumerate(transcripts):
        if i:
            out += ["", f"## Subagent {i}", ""]
        pending = {}
        for raw in lines:
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            m = e.get("message") or {}
            content = m.get("content")
            if e.get("type") == "user" and isinstance(content, str) and n == 0 and i == 0:
                out += ["<details><summary>Prompt</summary>", "", fence(content), "", "</details>", ""]
                continue
            for c in content if isinstance(content, list) else []:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "text" and e.get("type") == "assistant" and c.get("text", "").strip():
                    out += ["> " + c["text"].strip().replace("\n", "\n> "), ""]
                elif c.get("type") == "tool_use":
                    n += 1
                    pending[c.get("id")] = n
                    out += [f'### <a id="call-{n}"></a>Call {n} · {c.get("name")}', "",
                            describe_call(c.get("name"), c.get("input") or {}), ""]
                elif c.get("type") == "tool_result" and c.get("tool_use_id") in pending:
                    text = result_text(c.get("content"))
                    k = pending.pop(c.get("tool_use_id"))
                    flag = " (error)" if c.get("is_error") else ""
                    out += [f"<details><summary>Result of call {k}{flag}: {len(text.splitlines())} lines</summary>",
                            "", fence(truncate(text) or "(empty)"), "", "</details>", ""]
    final = result.get("result")
    if final:
        out += ["## Final message", "", "> " + final.strip().replace("\n", "\n> "), ""]
    return "\n".join(out)


def render_archive(archive, outdir, langs=None):
    tmp = tempfile.mkdtemp()
    try:
        with tarfile.open(archive) as t:
            t.extractall(tmp, filter="data")
        (run,) = [os.path.join(tmp, n) for n in os.listdir(tmp)]
        last = {}
        for e in (json.loads(l) for l in open(os.path.join(run, "manifest.jsonl"))):
            last[e["label"]] = e
        rpath = os.path.join(run, "results.json")
        verified = json.load(open(rpath)) if os.path.isfile(rpath) else {}
        os.makedirs(outdir, exist_ok=True)
        fname = lambda label: label.replace(":", "-") + ".md"
        by_slug = {}
        for label in last:
            by_slug.setdefault(label.split(":")[2], []).append(label)
        rows = []
        for label, e in sorted(last.items(), key=lambda kv: (kv[0].split(":")[2], kv[0].split(":")[1], kv[0])):
            rep, lang, slug = label.split(":")
            if langs and lang not in langs:
                continue
            sid = e["session_id"]
            files = [os.path.join(run, "sessions", sid + ".jsonl")]
            subdir = os.path.join(run, "sessions", sid, "subagents")
            for dp, _, fns in os.walk(subdir):
                files += sorted(os.path.join(dp, f) for f in fns if f.endswith(".jsonl"))
            transcripts = [open(f).read().splitlines() for f in files if os.path.isfile(f)]
            others = [(o.replace(":", " "), fname(o)) for o in sorted(by_slug[slug]) if o != label
                      and (not langs or o.split(":")[1] in langs)]
            md = render_session(label, transcripts, e.get("result") or {}, verified.get(label), others)
            with open(os.path.join(outdir, fname(label)), "w") as f:
                f.write(md)
            v = verified.get(label, {})
            rows.append(f"| {slug} | {NAMES.get(lang, lang)} | {rep} | [transcript]({fname(label)}) | "
                        f"{v.get('public', 'n/a')} |")
        with open(os.path.join(outdir, "README.md"), "w") as f:
            f.write(f"# Transcripts of {os.path.basename(run)}\n\nRendered from `{os.path.basename(archive)}` by "
                    "`tools/render_transcripts.py`; tool output is truncated, the archive has it in full.\n\n"
                    "| Problem | Language | Repetition | Transcript | Tests (clean build) |\n|---|---|---|---|---|\n"
                    + "\n".join(rows) + "\n")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("archive")
    ap.add_argument("outdir")
    ap.add_argument("--langs", default="")
    a = ap.parse_args()
    render_archive(a.archive, a.outdir, set(a.langs.split(",")) if a.langs else None)
    print(f"rendered into {a.outdir}")


if __name__ == "__main__":
    main()
