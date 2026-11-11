import importlib.util
import json
import os
import time
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("runner", os.path.join(HERE, "..", "tools", "runner.py"))
rn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rn)

ARGS = {"root": "/sb", "langs": ["cpp", "rust", "go", "d", "python"], "reps": 3,
        "repProblems": ["chip8"], "model": "claude-sonnet-5-5", "effort": "high", "concurrency": 6,
        "approach": True, "dc": "ldc2", "out": "out",
        "toolchains": {"cpp": "clang 21 and cmake 4.2", "rust": "rustc 1.96", "go": "go 1.27",
                       "d": "LDC 1.41.0 and DUB 1.40.0", "python": "Python 3.14"}}
PROBLEMS = ["chip8", "kvstore", "sat"]


class Items(unittest.TestCase):
    def test_large_problems_first_reps_on_subset_and_rotation(self):
        items = rn.items(ARGS, PROBLEMS)
        labels = [i["label"] for i in items]
        self.assertEqual(len(items), 3 * 5 + 2 * 5)
        self.assertEqual([i["slug"] for i in items[:5]], ["kvstore"] * 5)
        self.assertEqual(items[0]["lang"], "cpp")
        self.assertEqual(items[5]["lang"], "rust")  # second problem starts one language later
        self.assertEqual([l for l in labels if not l.startswith("rep1")],
                         [f"rep{r}:{l}:chip8" for r in (2, 3) for l in rn.rotate(ARGS["langs"], 1 + r - 1)])

    def test_explicit_problem_list_keeps_its_order(self):
        items = rn.items({**ARGS, "problems": ["sat", "chip8"], "reps": 1}, PROBLEMS)
        self.assertEqual([i["slug"] for i in items[::5]], ["sat", "chip8"])

    def test_workspace_ids_are_opaque_and_distinct(self):
        ids = {rn.workspace_id(i["label"]) for i in rn.items(ARGS, PROBLEMS)}
        self.assertEqual(len(ids), 25)
        for i in ids:
            self.assertRegex(i, r"^[0-9a-f]{8}$")

    def test_session_ids_are_deterministic_uuids_per_attempt(self):
        a = rn.session_id("run-1", "rep1:go:sat", 1)
        self.assertEqual(a, rn.session_id("run-1", "rep1:go:sat", 1))
        self.assertNotEqual(a, rn.session_id("run-1", "rep1:go:sat", 2))
        self.assertEqual(len(a), 36)


class LeftoverProcesses(unittest.TestCase):
    def transcript(self, d, lines, age):
        import json as j
        path = os.path.join(d, "s.jsonl")
        with open(path, "w") as f:
            f.write("\n".join(j.dumps(x) for x in lines) + "\n")
        os.utime(path, (time.time() - age, time.time() - age))
        return path

    def test_a_finished_idle_session_is_recognised(self):
        import tempfile
        final = {"type": "assistant", "message": {"stop_reason": "end_turn", "content": [{"type": "text", "text": "Done."}]}}
        calling = {"type": "assistant", "message": {"stop_reason": "tool_use",
                                                   "content": [{"type": "tool_use", "name": "Bash", "input": {}}]}}
        with tempfile.TemporaryDirectory() as d:
            self.assertTrue(rn.finished_and_idle(self.transcript(d, [calling, final], 600), idle=300))
            self.assertFalse(rn.finished_and_idle(self.transcript(d, [calling, final], 60), idle=300))
            self.assertFalse(rn.finished_and_idle(self.transcript(d, [final, calling], 600), idle=300))
            self.assertFalse(rn.finished_and_idle(os.path.join(d, "missing.jsonl"), idle=300))

    def test_leftover_processes_are_stopped_so_the_session_exits(self):
        import subprocess
        import tempfile
        final = {"type": "assistant", "message": {"content": [{"type": "text", "text": "Done."}]}}
        with tempfile.TemporaryDirectory() as d:
            path = self.transcript(d, [final], 0)
            proc = subprocess.Popen(["sh", "-c", "sleep 600 & wait; echo exited"], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
            started = time.time()
            code, out, _ = rn.wait_for_session(proc, path, log=lambda *_: None, poll=0.2, idle=0)
            self.assertLess(time.time() - started, 30)
            self.assertEqual((code, out.strip()), (0, "exited"))

    def test_descendants_of_a_process(self):
        ps = "  1     0\n 10     1\n 11    10\n 12    11\n 13    10\n 20     1\n"
        self.assertEqual(sorted(rn.descendants(10, ps)), [11, 12, 13])


class Prompt(unittest.TestCase):
    def render(self, **over):
        item = {"rep": "rep1", "lang": "d", "slug": "chip8", "label": "rep1:d:chip8", "root": "/sb/w/1a2b3c4d"}
        return rn.render_prompt({**ARGS, **over}, item)

    def test_reads_like_a_task_not_a_benchmark(self):
        p = self.render().lower()
        for word in ("benchmark", "every language", "all languages", "other languages", "structured output",
                     "claude.md", "langbench"):
            self.assertNotIn(word, p)

    def test_names_only_its_own_toolchain(self):
        p = self.render()
        self.assertIn("LDC 1.41.0 and DUB 1.40.0", p)
        self.assertIn("dub build -b release --compiler=ldc2", p)
        for other in ("rustc", "cargo", "CMake", "go build", "python3 -m"):
            self.assertNotIn(other, p)

    def test_haskell_and_clojure_prompts_name_their_build_tools(self):
        args = {**ARGS, "langs": ["haskell", "clojure"],
                "toolchains": {"haskell": "GHC 9.14.1 and cabal 3.18.2.0", "clojure": "Clojure 1.12.6 on OpenJDK 27.0.1"}}
        hs = rn.render_prompt(args, {"rep": "rep1", "lang": "haskell", "slug": "chip8", "label": "x", "root": "/sb"})
        clj = rn.render_prompt(args, {"rep": "rep1", "lang": "clojure", "slug": "chip8", "label": "x", "root": "/sb"})
        self.assertIn("standalone Haskell project", hs)
        self.assertIn("GHC 9.14.1 and cabal 3.18.2.0", hs)
        self.assertIn("cabal build", hs)
        self.assertIn("standalone Clojure project", clj)
        self.assertIn("deps.edn", clj)
        self.assertIn("clojure.test", clj)

    def test_paths_and_validation_command(self):
        p = self.render()
        self.assertIn("/sb/w/1a2b3c4d/problems/chip8/SPEC.md", p)
        self.assertIn("/sb/w/1a2b3c4d/problems/chip8/APPROACH.md", p)
        self.assertIn("Put the project in /sb/w/1a2b3c4d/chip8/.", p)
        self.assertIn("cd /sb/w/1a2b3c4d && chip8/build.sh && python3 run_tests.py chip8 -- chip8/run.sh", p)
        self.assertIn("/sb/w/1a2b3c4d/scratch/", p)

    def test_paths_reveal_neither_language_nor_repetition(self):
        p = self.render()
        for leak in ("rep1", "/d/", "-d-", "out/"):
            self.assertNotIn(leak, p)

    def test_unguided_runs_omit_the_design(self):
        self.assertNotIn("APPROACH.md", self.render(approach=False))

    def test_experiment_options(self):
        self.assertIn("It's important that the implementation is efficient.", self.render(efficiency=True))
        p = self.render(notes={"d": "Prefer strtod.", "go": "x"}, machineNotes={"d": "Run ulimit first."})
        self.assertIn("Prefer strtod.", p)
        self.assertIn("Run ulimit first.", p)
        self.assertNotIn("\nx", p)


class Attempts(unittest.TestCase):
    def test_classify(self):
        ok = {"type": "result", "subtype": "success", "is_error": False}
        self.assertFalse(rn.is_infra_error(0, json.dumps(ok)))
        self.assertTrue(rn.is_infra_error(1, ""))
        self.assertTrue(rn.is_infra_error(143, "not json"))
        self.assertTrue(rn.is_infra_error(1, json.dumps({**ok, "is_error": True, "api_error_status": 429})))
        self.assertTrue(rn.is_infra_error(1, json.dumps({**ok, "subtype": "error_during_execution", "is_error": True})))

    def test_pending_skips_completed_and_retries_infra_errors(self):
        with tempfile.TemporaryDirectory() as d:
            m = os.path.join(d, "manifest.jsonl")
            with open(m, "w") as f:
                for e in [{"label": "a", "attempt": 1, "infra_error": False},
                          {"label": "b", "attempt": 1, "infra_error": True},
                          {"label": "c", "attempt": 1, "infra_error": True},
                          {"label": "c", "attempt": 2, "infra_error": True},
                          {"label": "c", "attempt": 3, "infra_error": True}]:
                    f.write(json.dumps(e) + "\n")
            todo = rn.pending([{"label": x} for x in "abcd"], m, max_attempts=3)
            self.assertEqual([(i["label"], n) for i, n in todo], [("b", 2), ("d", 1)])


class Command(unittest.TestCase):
    def test_session_command(self):
        env, argv = rn.session_command(ARGS, "prompt text", "sid-1", base_env={"PATH": "/bin", "ANTHROPIC_API_KEY": "k"},
                                       auth="subscription")
        self.assertEqual(argv[:3], ["claude", "-p", "prompt text"])
        self.assertEqual(argv[argv.index("--session-id") + 1], "sid-1")
        self.assertEqual(argv[argv.index("--model") + 1], "claude-sonnet-5-5")
        self.assertEqual(env["CLAUDE_CODE_EFFORT_LEVEL"], "high")
        self.assertEqual(env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"], "1")
        self.assertNotIn("ANTHROPIC_API_KEY", env)
        self.assertIn("WebSearch", argv[argv.index("--disallowedTools") + 1:])
        self.assertNotIn("Workflow(langbench-implement)", argv)
        self.assertEqual(argv[argv.index("--permission-mode") + 1], "acceptEdits")
        allowed = argv[argv.index("--allowedTools") + 1:argv.index("--disallowedTools")]
        self.assertNotIn("Read", allowed)
        self.assertNotIn("Write", allowed)
        self.assertIn("Bash", allowed)


if __name__ == "__main__":
    unittest.main()
