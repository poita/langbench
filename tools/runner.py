"""Run implementation tasks as separate headless Claude Code sessions in a sandbox.

Each (repetition, language, problem) task is one `claude -p` session started in the sandbox with a clean
environment: the prompt in tools/task_prompt.txt, no CLAUDE.md files, memory, user settings, plugins or MCP
servers, in the task's own workspace (<sandbox>/w/<id>/, with its own .claude/settings.json), which holds only
that task's problem and project. Sessions run a few at a time. Each attempt is
appended to <sandbox>/runs/<run>/manifest.jsonl with the session's result (turns, usage, cost, final message).
Attempts that end in an infrastructure error (API or rate-limit errors, crashes) are retried with a fresh
project; a task that completes is never rerun.
"""
import concurrent.futures
import datetime
import json
import os
import re
import shutil
import subprocess
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
LANG_NAMES = {"cpp": "C++", "rust": "Rust", "go": "Go", "d": "D", "python": "Python", "haskell": "Haskell",
              "clojure": "Clojure"}
LARGE = ["langvm", "kvstore", "cardgame", "typeset", "buildsys"]
CLEAN_ENV = {
    "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",  # no CLAUDE.md files or memory in the session's context
    "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
    "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS": "0",  # -p waits for any background work the session starts
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",  # no auto-update mid-run
    "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
}
# Only Bash is pre-approved, and the OS sandbox confines it. The file tools rely on Claude Code's defaults in
# acceptEdits mode: reads and edits inside the working directories are allowed, anything else needs a permission
# nobody can grant in a headless session, so it is refused.
ALLOWED_TOOLS = ["Bash", "Agent", "TodoWrite"]
DISALLOWED_TOOLS = ["WebFetch", "WebSearch"]
SESSION_TIMEOUT = 4 * 3600
# A session whose agent has given its final answer but whose process has not exited for this long is held open
# by a process the agent left running (a command that outlived its timeout, say); those processes are stopped.
LEFTOVER_IDLE = 300
NAMESPACE = uuid.UUID("6f1c2b9e-3d4a-4e8b-9f0a-1c2d3e4f5a6b")


def build_line(lang, dc):
    return {
        "cpp": "build it with CMake as a Release build; GoogleTest is installed for tests.",
        "rust": "build it with cargo build --release.",
        "go": "build it with go build.",
        "d": f"build it with dub build -b release --compiler={dc}, and pass the same --compiler to dub test.",
        "python": "use a pyproject.toml layout; there's no install step, so run.sh runs the package with python3 "
                  "(with PYTHONPATH pointing at the source); pytest is installed for tests.",
        "haskell": "build it with cabal build; GHC's bundled packages are installed, and hspec, tasty and QuickCheck "
                   "for tests.",
        "clojure": "use a deps.edn project run with the clojure CLI; for tests, the Cognitect test-runner is available "
                   "as io.github.cognitect-labs/test-runner {:git/tag \"v0.5.1\" :git/sha \"dfb30dd\"}.",
    }[lang]


def rotate(xs, k):
    k %= len(xs)
    return xs[k:] + xs[:k]


def items(args, all_problems):
    """Every task of a run, in launch order: large problems first, languages rotated per problem so no
    language always starts first, and further repetitions after the first pass."""
    problems = args.get("problems") or [*[p for p in LARGE if p in all_problems],
                                        *[p for p in all_problems if p not in LARGE]]
    langs, reps, rep_problems = args["langs"], args.get("reps", 1), args.get("repProblems")
    out = []
    for r in range(1, reps + 1):
        for i, slug in enumerate(problems):
            if r > 1 and rep_problems is not None and slug not in rep_problems:
                continue
            for lang in rotate(langs, i + r - 1):
                out.append({"rep": f"rep{r}", "lang": lang, "slug": slug, "label": f"rep{r}:{lang}:{slug}"})
    return out


def render_prompt(args, item, template=None):
    template = template or open(os.path.join(HERE, "task_prompt.txt")).read()
    lang, slug, rep = item["lang"], item["slug"], item["rep"]
    root = item.get("root") or args["root"]
    notes = (args.get("notes") or {}).get(lang)
    machine = (args.get("machineNotes") or {}).get(lang)
    return template.format(
        lang_name=LANG_NAMES[lang], lang=lang, slug=slug, rep=rep, root=root,
        proj=slug,
        design=f", using the design in {root}/problems/{slug}/APPROACH.md" if args.get("approach", True) else "",
        toolchain=(args.get("toolchains") or {}).get(lang) or LANG_NAMES[lang],
        build=build_line(lang, args.get("dc", "ldc2")),
        machine_notes=f" {machine}" if machine else "",
        notes=f"\n\n{notes}" if notes else "",
        efficiency=" It's important that the implementation is efficient." if args.get("efficiency") else "")


def project_slug(path):
    """The directory name Claude Code keeps a working directory's transcripts under."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def finished_and_idle(transcript, idle=LEFTOVER_IDLE, now=None):
    """Whether a session transcript ends with the agent's final answer (an assistant message calling no tool)
    and has not changed for idle seconds."""
    try:
        age = (now or time.time()) - os.path.getmtime(transcript)
        with open(transcript, "rb") as f:
            f.seek(max(0, os.path.getsize(transcript) - 65536))
            lines = f.read().decode(errors="replace").splitlines()
    except OSError:
        return False
    for line in reversed(lines):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") not in ("assistant", "user"):
            continue
        content = (e.get("message") or {}).get("content")
        calls = [c for c in content if c.get("type") == "tool_use"] if isinstance(content, list) else []
        return e["type"] == "assistant" and not calls and age >= idle
    return False


def descendants(pid, ps_output=None):
    """Process ids below pid, from `ps -A -o pid=,ppid=` output."""
    if ps_output is None:
        ps_output = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout
    children = {}
    for line in ps_output.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    out, todo = [], [pid]
    while todo:
        for child in children.get(todo.pop(), []):
            out.append(child)
            todo.append(child)
    return out


def wait_for_session(proc, transcript, log=print, label="", poll=30, idle=None):
    """Wait for a claude -p session, at most SESSION_TIMEOUT. Once the agent has finished and gone quiet, stop
    any processes it left running so the session can exit and report its result. Returns (code, stdout,
    stderr)."""
    deadline = time.time() + SESSION_TIMEOUT
    while True:
        try:
            out, err = proc.communicate(timeout=poll)
            return proc.returncode, out, err
        except subprocess.TimeoutExpired:
            pass
        if time.time() > deadline:
            proc.kill()
            out, _ = proc.communicate()
            return -1, out or "", "timeout"
        if finished_and_idle(transcript, LEFTOVER_IDLE if idle is None else idle):
            leftovers = descendants(proc.pid)
            if leftovers:
                log(f"{label}: agent finished; stopping {len(leftovers)} process(es) it left running")
                for pid in leftovers:
                    try:
                        os.kill(pid, 15)
                    except OSError:
                        pass


def transcript_dir(ws, projects=None):
    return os.path.join(projects or os.path.expanduser("~/.claude/projects"), project_slug(ws))


def workspace_id(label):
    """An opaque, stable name for a task's workspace, so its path reveals neither language nor repetition."""
    return uuid.uuid5(NAMESPACE, "workspace/" + label).hex[:8]


def workspace(box, label):
    return os.path.join(box, "w", workspace_id(label))


def session_id(run, label, attempt):
    return str(uuid.uuid5(NAMESPACE, f"{run}/{label}/{attempt}"))


def session_command(args, prompt, sid, base_env=None, auth="env", extra_dirs=()):
    """The environment and argv of one task's headless session.

    auth "env" uses whatever credentials the environment provides (ANTHROPIC_API_KEY wins if set);
    "subscription" drops API credentials so the session uses the Claude Code login."""
    env = {k: v for k, v in (base_env if base_env is not None else os.environ).items()
           if not (k.startswith("CLAUDE") and k != "CLAUDE_CONFIG_DIR")}
    if auth == "subscription":
        env = {k: v for k, v in env.items() if k not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")}
    env.update(CLEAN_ENV)
    env["CLAUDE_CODE_EFFORT_LEVEL"] = args.get("effort", "high")
    argv = ["claude", "-p", prompt, "--model", args.get("model", "claude-sonnet-5-5"), "--session-id", sid,
            "--setting-sources", "project,local", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--permission-mode", "acceptEdits", "--allowedTools", *ALLOWED_TOOLS,
            "--disallowedTools", *DISALLOWED_TOOLS, *[x for d in extra_dirs for x in ("--add-dir", d)],
            "--output-format", "json"]
    return env, argv


def parse_result(stdout):
    for line in reversed(stdout.strip().splitlines()):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("type") == "result":
            return d
    return None


def is_infra_error(code, stdout):
    """Whether an attempt failed for reasons outside the agent's work: no result, an API error or a crash."""
    r = parse_result(stdout)
    if r is None:
        return True
    return bool(r.get("is_error")) and (r.get("api_error_status") is not None
                                        or str(r.get("subtype", "")).startswith("error"))


def attempts(manifest):
    out = {}
    if os.path.isfile(manifest):
        for line in open(manifest):
            e = json.loads(line)
            out.setdefault(e["label"], []).append(e)
    return out


def pending(task_items, manifest, max_attempts=3):
    """(item, next attempt number) for tasks not yet completed that have attempts left."""
    done = attempts(manifest)
    todo = []
    for it in task_items:
        tries = done.get(it["label"], [])
        if tries and not tries[-1]["infra_error"]:
            continue
        if len(tries) < max_attempts:
            todo.append((it, len(tries) + 1))
    return todo


def run(box, args, run_id, all_problems, auth="env", max_attempts=3, log=print):
    rdir = os.path.join(box, "runs", run_id)
    os.makedirs(os.path.join(rdir, "prompts"), exist_ok=True)
    manifest = os.path.join(rdir, "manifest.jsonl")
    task_items = items(args, all_problems)
    lock = threading.Lock()
    template = open(os.path.join(HERE, "task_prompt.txt")).read()

    def one(it, attempt):
        while True:
            label = it["label"]
            ws = workspace(box, label)
            for d in (os.path.join(ws, it["slug"]), os.path.join(ws, "scratch")):
                shutil.rmtree(d, ignore_errors=True)  # a retried task starts from nothing
            prompt = render_prompt(args, {**it, "root": ws}, template)
            with open(os.path.join(rdir, "prompts", label.replace(":", "-") + ".txt"), "w") as f:
                f.write(prompt)
            sid = session_id(run_id, label, attempt)
            # The session's own transcript directory is a working directory so that the file tools, which may
            # not read outside working directories, can read the large outputs Claude Code saves there.
            env, argv = session_command(args, prompt, sid, auth=auth, extra_dirs=[transcript_dir(ws)])
            started = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
            proc = subprocess.Popen(argv, cwd=ws, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
            code, stdout, stderr = wait_for_session(proc, os.path.join(transcript_dir(ws), sid + ".jsonl"),
                                                    log, label)
            infra = is_infra_error(code, stdout)
            entry = {"label": label, **{k: it[k] for k in ("rep", "lang", "slug")}, "attempt": attempt,
                     "session_id": sid, "started": started,
                     "ended": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                     "exit_code": code, "infra_error": infra, "result": parse_result(stdout),
                     "stderr_tail": stderr[-2000:] if infra else ""}
            with lock:
                with open(manifest, "a") as f:
                    f.write(json.dumps(entry) + "\n")
            r = entry["result"] or {}
            log(f"{label} attempt {attempt}: {'INFRA ERROR' if infra else 'done'}"
                f" turns={r.get('num_turns')} cost=${r.get('total_cost_usd') or 0:.2f}")
            if not infra or attempt >= max_attempts:
                return entry
            time.sleep(min(1800, 60 * 2 ** attempt))  # back off before retrying, e.g. for a usage limit
            attempt += 1

    todo = pending(task_items, manifest, max_attempts)
    log(f"run {run_id}: {len(task_items)} tasks, {len(todo)} to do, {args.get('concurrency', 6)} at a time")
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.get("concurrency", 6)) as pool:
        list(pool.map(lambda t: one(*t), todo))
    left = pending(task_items, manifest, max_attempts)
    log(f"run {run_id}: {len(task_items) - len(left)} of {len(task_items)} tasks completed")
    return not left
