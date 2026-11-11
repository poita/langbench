import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("agent_effort", os.path.join(HERE, "..", "tools", "agent_effort.py"))
ae = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ae)


def msg(kind, ts, content, mid=None, usage=None):
    m = {"content": content}
    if mid:
        m["id"] = mid
    if usage:
        m["usage"] = usage
    return json.dumps({"type": kind, "timestamp": ts, "message": m})


def write_run(d, label, lines, result=None, agent="a1"):
    with open(os.path.join(d, f"agent-{agent}.jsonl"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(d, f"agent-{agent}.meta.json"), "w") as f:
        json.dump({"description": label, "model": "m"}, f)
    if result is not None:
        with open(os.path.join(d, "journal.jsonl"), "a") as f:
            f.write(json.dumps({"type": "started", "agentId": agent, "label": label}) + "\n")
            f.write(json.dumps({"type": "result", "agentId": agent, "result": result}) + "\n")


USAGE = {"input_tokens": 10, "output_tokens": 100, "cache_read_input_tokens": 1000,
         "cache_creation_input_tokens": 50}
TRANSCRIPT = [
    msg("user", "2026-01-01T00:00:00Z", "Build the following as a standalone Go project."),
    msg("assistant", "2026-01-01T00:00:10Z", [{"type": "text", "text": "plan"}], "m1", USAGE),
    msg("assistant", "2026-01-01T00:00:10Z",
        [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "cd x && ./build.sh"}}], "m1", USAGE),
    msg("user", "2026-01-01T00:00:15Z", [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]),
    msg("assistant", "2026-01-01T00:00:25Z",
        [{"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": "python3 run_tests.py x -- y"}}],
        "m2", USAGE),
    msg("user", "2026-01-01T00:00:45Z", [{"type": "tool_result", "tool_use_id": "t2", "content": "3/3 passed"}]),
]


class Classify(unittest.TestCase):
    def test_haskell_and_clojure_commands(self):
        c = lambda cmd: ae.classify("Bash", {"command": cmd})
        self.assertEqual(c("cd x && cabal test 2>&1 | tail"), "unit tests")
        self.assertEqual(c("clojure -M:test 2>&1 | tail -5"), "unit tests")
        self.assertEqual(c("clj -X:test"), "unit tests")
        self.assertEqual(c("cabal build -v0"), "build")
        self.assertEqual(c("clojure -M -e \"(compile 'toml.cli)\""), "build")
        self.assertEqual(c("cat > src/a.clj <<'EOF'\n(ns a)\nEOF"), "other shell")


class AgentStats(unittest.TestCase):
    def test_counts_tool_calls_and_deduplicates_usage_by_message(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "rep1:go:sat", TRANSCRIPT)
            s = ae.agent_stats(os.path.join(d, "agent-a1.jsonl"))
            self.assertEqual(s["tool_calls"], 2)
            self.assertEqual(s["output_tokens"], 200)
            self.assertEqual(s["context_tokens"], 2 * (10 + 1000 + 50))

    def test_splits_time_into_inference_and_tools(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "rep1:go:sat", TRANSCRIPT)
            s = ae.agent_stats(os.path.join(d, "agent-a1.jsonl"))
            self.assertEqual(s["seconds"], 45)
            self.assertEqual(s["time"]["inference"], 20)
            self.assertEqual(s["time"]["build"], 5)
            self.assertEqual(s["time"]["harness tests"], 20)


class RunSummary(unittest.TestCase):
    def test_groups_by_language_and_reads_correctness_from_journal(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "rep1:go:sat", TRANSCRIPT, {"lang": "go", "slug": "sat", "passed": 3, "total": 3,
                                                    "all_pass": True, "unit_tests_pass": True})
            rows = ae.summarise([d])
            self.assertEqual(list(rows), ["go"])
            self.assertEqual(rows["go"]["agents"], 1)
            self.assertEqual(rows["go"]["all_pass"], 1)
            self.assertEqual(rows["go"]["tool_calls"], 2)

    def test_per_run_language_filter(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "rep1:go:sat", TRANSCRIPT)
            self.assertEqual(ae.summarise([d + ":d"]), {})
            self.assertEqual(list(ae.summarise([d + ":go,d"])), ["go"])

    def test_problem_filter(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "rep1:go:sat", TRANSCRIPT)
            self.assertEqual(ae.summarise([d], problems={"toml"}), {})
            self.assertEqual(list(ae.summarise([d], problems={"sat"})), ["go"])

    def test_only_agents_present_in_a_directory(self):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as impls:
            write_run(d, "rep1:go:sat", TRANSCRIPT)
            self.assertEqual(ae.summarise([d], present_in=impls), {})
            os.makedirs(os.path.join(impls, "rep1", "go", "sat"))
            self.assertEqual(list(ae.summarise([d], present_in=impls)), ["go"])

    def test_language_filter(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "rep1:go:sat", TRANSCRIPT)
            self.assertEqual(ae.summarise([d], langs={"d"}), {})


class Turns(unittest.TestCase):
    def test_turns_count_model_calls(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "rep1:go:sat", TRANSCRIPT)
            self.assertEqual(ae.agent_stats(os.path.join(d, "agent-a1.jsonl"))["turns"], 2)

    def test_turns_are_summed_and_reported_per_agent(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "rep1:go:sat", TRANSCRIPT, result={"all_pass": True, "unit_tests_pass": True})
            rows = ae.summarise([d])
            self.assertEqual(rows["go"]["turns"], 2)
            self.assertIn("Turns / agent", ae.report(rows))


class SessionRuns(unittest.TestCase):
    def test_run_directory_uses_session_results_and_verification(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "sessions"))
            with open(os.path.join(d, "sessions", "s1.jsonl"), "w") as f:
                f.write("\n".join(TRANSCRIPT) + "\n")
            result = {"type": "result", "num_turns": 7, "total_cost_usd": 0.5,
                      "usage": {"input_tokens": 1, "output_tokens": 999, "cache_read_input_tokens": 10,
                                "cache_creation_input_tokens": 5}}
            with open(os.path.join(d, "manifest.jsonl"), "w") as f:
                f.write(json.dumps({"label": "rep1:go:sat", "session_id": "s0", "infra_error": True}) + "\n")
                f.write(json.dumps({"label": "rep1:go:sat", "session_id": "s1", "infra_error": False,
                                    "result": result}) + "\n")
            with open(os.path.join(d, "results.json"), "w") as f:
                json.dump({"rep1:go:sat": {"public_pass": True}}, f)
            rows = ae.summarise([d])
            self.assertEqual(rows["go"]["agents"], 1)
            self.assertEqual(rows["go"]["all_pass"], 1)
            self.assertEqual(rows["go"]["turns"], 2)
            self.assertEqual(rows["go"]["output_tokens"], 999)
            self.assertEqual(rows["go"]["context_tokens"], 16)
            self.assertAlmostEqual(rows["go"]["cost"], 0.5)


def task(lang, slug, value, rep="rep1", finished=True):
    return {"lang": lang, "slug": slug, "rep": rep, "finished": finished, "output_tokens": value}


class Paired(unittest.TestCase):
    def test_geometric_mean_of_per_problem_ratios_against_the_baseline(self):
        tasks = [task("go", "a", 100), task("d", "a", 200), task("go", "b", 100), task("d", "b", 50)]
        p = ae.paired(tasks, "go", "output_tokens")
        self.assertAlmostEqual(p["d"]["gmean"], 1.0)
        self.assertEqual(p["d"]["problems"], 2)

    def test_repetitions_are_combined_by_median_first(self):
        tasks = [task("go", "a", 100), task("d", "a", 100, "rep1"), task("d", "a", 300, "rep2"),
                 task("d", "a", 200, "rep3")]
        self.assertAlmostEqual(ae.paired(tasks, "go", "output_tokens")["d"]["gmean"], 2.0)

    def test_unfinished_tasks_count_as_at_least_the_worst_finisher(self):
        tasks = [task("go", "a", 100), task("rust", "a", 400), task("d", "a", 50, finished=False)]
        p = ae.paired(tasks, "go", "output_tokens")
        self.assertAlmostEqual(p["d"]["gmean"], 4.0)
        self.assertEqual(p["d"]["completion"], (0, 1))
        self.assertEqual(p["rust"]["completion"], (1, 1))

    def test_bootstrap_interval_is_deterministic_and_brackets_the_estimate(self):
        tasks = [task(l, s, v) for s, (g, d) in zip("abcdefgh", [(1, 2), (1, 1), (2, 3), (1, 3), (3, 2), (1, 2),
                                                                  (2, 2), (1, 4)]) for l, v in (("go", g), ("d", d))]
        a = ae.paired(tasks, "go", "output_tokens")["d"]
        b = ae.paired(tasks, "go", "output_tokens")["d"]
        self.assertEqual((a["lo"], a["hi"]), (b["lo"], b["hi"]))
        self.assertLess(a["lo"], a["gmean"])
        self.assertGreater(a["hi"], a["gmean"])

    def test_session_runs_yield_task_records(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "sessions"))
            with open(os.path.join(d, "sessions", "s1.jsonl"), "w") as f:
                f.write("\n".join(TRANSCRIPT) + "\n")
            with open(os.path.join(d, "manifest.jsonl"), "w") as f:
                f.write(json.dumps({"label": "rep1:go:sat", "rep": "rep1", "lang": "go", "slug": "sat",
                                    "session_id": "s1", "infra_error": False,
                                    "result": {"usage": {"output_tokens": 999}, "total_cost_usd": 0.5}}) + "\n")
            with open(os.path.join(d, "results.json"), "w") as f:
                json.dump({"rep1:go:sat": {"public_pass": True}}, f)
            (t,) = ae.task_records([d])
            self.assertEqual((t["lang"], t["slug"], t["finished"], t["output_tokens"], t["turns"]),
                             ("go", "sat", True, 999, 2))


def session_run(d, entries):
    """A run directory made by impl_run.py launch: (label, session id, output tokens, passes) per task."""
    os.makedirs(os.path.join(d, "sessions"))
    verified = {}
    with open(os.path.join(d, "manifest.jsonl"), "w") as f:
        for label, sid, tokens, passes in entries:
            with open(os.path.join(d, "sessions", sid + ".jsonl"), "w") as t:
                t.write("\n".join(TRANSCRIPT) + "\n")
            f.write(json.dumps({"label": label, "session_id": sid, "infra_error": False,
                                "result": {"usage": {"output_tokens": tokens}, "total_cost_usd": 0.5}}) + "\n")
            verified[label] = {"public_pass": passes}
    with open(os.path.join(d, "results.json"), "w") as f:
        json.dump(verified, f)
    return d


class LaterRuns(unittest.TestCase):
    def test_a_later_run_replaces_the_same_task_of_an_earlier_run(self):
        with tempfile.TemporaryDirectory() as d:
            first = session_run(os.path.join(d, "a"), [("rep1:go:sat", "s1", 100, False), ("rep1:go:jq", "s2", 7, True)])
            second = session_run(os.path.join(d, "b"), [("rep1:go:sat", "s3", 300, True)])
            tasks = sorted((t["slug"], t["output_tokens"], t["finished"]) for t in ae.task_records([first, second]))
            self.assertEqual(tasks, [("jq", 7, True), ("sat", 300, True)])
            row = ae.summarise([first, second])["go"]
            self.assertEqual((row["agents"], row["all_pass"], row["output_tokens"]), (2, 2, 307))


class ModelUsage(unittest.TestCase):
    def test_tokens_come_from_model_usage_which_includes_subagents_and_the_whole_session(self):
        # A session that answered a late notification reports only that last exchange in "usage".
        result = {"usage": {"output_tokens": 81, "input_tokens": 1},
                  "modelUsage": {"claude-sonnet-5-5": {"outputTokens": 36000, "inputTokens": 10,
                                                       "cacheReadInputTokens": 900, "cacheCreationInputTokens": 90},
                                 "claude-haiku-5-5": {"outputTokens": 1000, "inputTokens": 0,
                                                      "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}},
                  "total_cost_usd": 0.7}
        self.assertEqual(ae.result_tokens(result), (37000, 1000))

    def test_falls_back_to_usage_without_model_usage(self):
        result = {"usage": {"output_tokens": 999, "input_tokens": 1, "cache_read_input_tokens": 10,
                            "cache_creation_input_tokens": 5}}
        self.assertEqual(ae.result_tokens(result), (999, 16))


class Archive(unittest.TestCase):
    def test_reads_a_transcript_archive(self):
        import tarfile
        with tempfile.TemporaryDirectory() as d:
            wf = os.path.join(d, "wf_x")
            os.makedirs(wf)
            write_run(wf, "rep1:go:sat", TRANSCRIPT, result={"all_pass": True, "unit_tests_pass": True})
            tar = os.path.join(d, "wf_x.tar.gz")
            with tarfile.open(tar, "w:gz") as t:
                t.add(wf, arcname="wf_x")
            rows = ae.summarise([tar])
            self.assertEqual(rows["go"]["agents"], 1)
            self.assertEqual(rows["go"]["all_pass"], 1)


if __name__ == "__main__":
    unittest.main()
