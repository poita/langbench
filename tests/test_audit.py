import json
import os
import tempfile
import unittest
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("audit", os.path.join(HERE, "..", "tools", "audit.py"))
au = importlib.util.module_from_spec(spec)
spec.loader.exec_module(au)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def tool_use(name, inp):
    return json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": name, "input": inp}]}})


def agent(wf, aid, label, lines):
    write(os.path.join(wf, f"agent-{aid}.meta.json"), json.dumps({"description": label}))
    write(os.path.join(wf, f"agent-{aid}.jsonl"), "\n".join(lines) + "\n")


class Transcripts(unittest.TestCase):
    def scan(self, lines, label="rep1:go:chip8"):
        with tempfile.TemporaryDirectory() as d:
            agent(d, "a", label, lines)
            return au.scan_transcripts(d, forbidden=["/repo"])

    def test_clean_agent_has_no_findings(self):
        self.assertEqual(self.scan([tool_use("Read", {"file_path": "/sb/problems/chip8/SPEC.md"}),
                                    tool_use("Bash", {"command": "ls /sb/out/rep1/go/"})]), [])

    def test_own_spilled_tool_output_is_allowed(self):
        with tempfile.TemporaryDirectory() as d:
            agent(d, "a", "rep1:go:chip8",
                  [tool_use("Read", {"file_path": "/home/.claude/projects/-sb/s1/tool-results/x.txt"}),
                   tool_use("Read", {"file_path": "/home/.claude/projects/-sb/s1/subagents/a.jsonl"})])
            f = au.scan_transcripts(d, forbidden=["/home/.claude/projects"],
                                    allowed=[r"/home/\.claude/projects/-sb/[^/]+/tool-results/"])
            self.assertEqual(len(f), 1)
            self.assertIn("subagents", f[0]["detail"])

    def test_forbidden_path_is_reported(self):
        f = self.scan([tool_use("Bash", {"command": "cat /repo/problems/chip8/reference/main.py"})])
        self.assertEqual([x["kind"] for x in f], ["forbidden-path"])

    def test_reference_and_generator_names_are_reported_anywhere(self):
        f = self.scan([tool_use("Read", {"file_path": "/sb/problems/chip8/gen_tests.py"})])
        self.assertEqual([x["kind"] for x in f], ["forbidden-path"])

    def test_held_out_tests_are_reported_anywhere(self):
        f = self.scan([tool_use("Bash", {"command": "ls /elsewhere/problems/kvstore/heldout/"})])
        self.assertEqual([x["kind"] for x in f], ["forbidden-path"])

    def test_another_implementations_files_are_reported(self):
        f = self.scan([tool_use("Read", {"file_path": "/sb/out/rep1/rust/chip8/src/main.rs"}),
                       tool_use("Read", {"file_path": "/sb/out/rep1/go/json/main.go"}),
                       tool_use("Read", {"file_path": "/sb/out/rep1/go/chip8/main.go"})])
        self.assertEqual(sorted(x["detail"] for x in f if x["kind"] == "other-implementation"),
                         ["out/rep1/go/json/main.go", "out/rep1/rust/chip8/src/main.rs"])

    def test_another_agents_scratch_files_are_reported(self):
        f = self.scan([tool_use("Bash", {"command": "cat /sb/scratch/rep1-rust-chess-perft/out.txt"}),
                       tool_use("Bash", {"command": "mkdir -p /sb/scratch/rep1-go-chip8 && cd /sb/scratch/rep1-go-chip8/x"})],
                      label="rep1:go:chip8")
        self.assertEqual([x["detail"] for x in f], ["scratch/rep1-rust-chess-perft/out.txt"])

    def test_injected_instruction_files_are_reported(self):
        inj = json.dumps({"type": "attachment", "attachment": {"type": "instructions", "files": [
            {"path": "/home/u/.claude/CLAUDE.md", "type": "User", "content": "tips"}]}})
        f = self.scan([inj])
        self.assertEqual([x["kind"] for x in f], ["environment"])

    def test_non_implementation_agents_are_ignored(self):
        self.assertEqual(self.scan([tool_use("Bash", {"command": "cat /repo/x"})], label="orchestrator"), [])


class SessionRuns(unittest.TestCase):
    def test_run_directory_with_manifest_and_subagents(self):
        with tempfile.TemporaryDirectory() as d:
            write(os.path.join(d, "manifest.jsonl"), "\n".join(json.dumps(e) for e in [
                {"label": "rep1:go:sat", "session_id": "s1"}, {"label": "rep1:d:sat", "session_id": "s2"}]) + "\n")
            write(os.path.join(d, "sessions", "s1.jsonl"),
                  tool_use("Read", {"file_path": "/p/own/s1/tool-results/x.txt"}) + "\n")
            write(os.path.join(d, "sessions", "s2.jsonl"),
                  tool_use("Read", {"file_path": "/p/own/s1/tool-results/x.txt"}) + "\n")
            write(os.path.join(d, "sessions", "s2", "subagents", "agent-1.jsonl"),
                  tool_use("Read", {"file_path": "/sb/out/rep1/go/sat/main.go"}) + "\n")
            f = au.scan_run(d, forbidden=["/p"], own_project="/p/own")
            self.assertEqual(sorted((x["agent"], x["kind"]) for x in f),
                             [("rep1:d:sat", "forbidden-path"), ("rep1:d:sat", "other-implementation")])


class Workspaces(unittest.TestCase):
    def test_a_session_may_name_only_its_own_workspace_and_outputs(self):
        with tempfile.TemporaryDirectory() as d:
            write(os.path.join(d, "manifest.jsonl"), "\n".join(json.dumps(e) for e in [
                {"label": "rep1:go:sat", "session_id": "s1"}, {"label": "rep1:d:sat", "session_id": "s2"}]) + "\n")
            write(os.path.join(d, "sessions", "s1.jsonl"), "\n".join([
                tool_use("Read", {"file_path": "/sb/w/aa/sat/main.go"}),
                tool_use("Bash", {"command": "cat /p/-sb-w-aa/s1/tool-results/x.txt; ls /sb/w/aa"})]) + "\n")
            write(os.path.join(d, "sessions", "s2.jsonl"), "\n".join([
                tool_use("Read", {"file_path": "/sb/w/aab/sat/main.go"}),
                tool_use("Bash", {"command": "ls /sb/w"})]) + "\n")
            f = au.scan_run(d, forbidden=["/p", "/sb"], workspaces={"rep1:go:sat": "/sb/w/aa", "rep1:d:sat": "/sb/w/aab"},
                            projects="/p")
            self.assertEqual([x["agent"] for x in f], ["rep1:d:sat"])


def tool_call(tid, name, inp, result):
    return [json.dumps({"type": "assistant", "message": {"content": [
                {"type": "tool_use", "id": tid, "name": name, "input": inp}]}}),
            json.dumps({"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": tid, "content": result}]}})]


class BlockedAttempts(unittest.TestCase):
    def scan(self, lines):
        with tempfile.TemporaryDirectory() as d:
            write(os.path.join(d, "manifest.jsonl"), json.dumps({"label": "rep1:d:x", "session_id": "s1"}) + "\n")
            write(os.path.join(d, "sessions", "s1.jsonl"), "\n".join(lines) + "\n")
            return au.scan_run(d, forbidden=["/sb"], workspaces={"rep1:d:x": "/sb/w/aa"}, projects="/p")

    def test_a_refused_shell_read_is_a_blocked_attempt(self):
        f = self.scan(tool_call("t1", "Bash", {"command": "ls /sb/w/aa/x; ls /sb/w"},
                                "x\nls: /sb/w: Operation not permitted"))
        self.assertEqual([x["kind"] for x in f], ["blocked-attempt"])
        self.assertNotIn("blocked-attempt", au.INTEGRITY)

    def test_a_refused_read_tool_call_is_a_blocked_attempt(self):
        f = self.scan(tool_call("t1", "Read", {"file_path": "/sb/w/bb/x/main.go"},
                                "Claude requested permissions to read from /sb/w/bb/x/main.go, but you haven't granted it yet."))
        self.assertEqual([x["kind"] for x in f], ["blocked-attempt"])

    def test_a_read_that_succeeded_stays_an_integrity_finding(self):
        f = self.scan(tool_call("t1", "Bash", {"command": "cat /sb/w/bb/x/main.go; ls /sb/w"},
                                "package main\nls: /sb/w: Operation not permitted"))
        self.assertEqual([x["kind"] for x in f], ["forbidden-path"])


class ClaudeTemp(unittest.TestCase):
    def test_other_projects_temp_outputs_are_forbidden(self):
        with tempfile.TemporaryDirectory() as d:
            write(os.path.join(d, "manifest.jsonl"), json.dumps({"label": "rep1:go:sat", "session_id": "s1"}) + "\n")
            write(os.path.join(d, "sessions", "s1.jsonl"), "\n".join([
                tool_use("Bash", {"command": "cat /private/tmp/claude-501/-sb-w-aa/s1/tasks/x.output"}),
                tool_use("Bash", {"command": "mkdir -p /tmp/claude-501/build && cd /tmp/claude-501/build"}),
                tool_use("Bash", {"command": "cat /private/tmp/claude-501/-Users-u/abc/tasks/y.output"})]) + "\n")
            f = au.scan_run(d, forbidden=[], workspaces={"rep1:go:sat": "/sb/w/aa"}, projects="/p")
            self.assertEqual(len(f), 1)
            self.assertIn("-Users-u", f[0]["detail"])


class Dependencies(unittest.TestCase):
    def deps(self, lang, files):
        with tempfile.TemporaryDirectory() as d:
            for rel, text in files.items():
                write(os.path.join(d, rel), text)
            return au.scan_dependencies(d, lang)

    def test_cargo_dependencies(self):
        self.assertEqual(self.deps("rust", {"Cargo.toml": "[package]\nname='x'\n[dependencies]\n"}), [])
        self.assertEqual(len(self.deps("rust", {"Cargo.toml": "[dependencies]\nserde = '1'\n"})), 1)
        self.assertEqual(len(self.deps("rust", {"Cargo.toml": "[dev-dependencies]\nproptest = '1'\n"})), 1)

    def test_go_requires(self):
        self.assertEqual(self.deps("go", {"go.mod": "module x\n\ngo 1.22\n"}), [])
        self.assertEqual(len(self.deps("go", {"go.mod": "module x\nrequire github.com/a/b v1.0.0\n"})), 1)
        self.assertEqual(len(self.deps("go", {"go.mod": "module x\nrequire (\n\tgithub.com/a/b v1.0.0\n)\n"})), 1)

    def test_dub_dependencies(self):
        self.assertEqual(self.deps("d", {"dub.json": json.dumps({"name": "x"})}), [])
        self.assertEqual(len(self.deps("d", {"dub.json": json.dumps({"dependencies": {"mir": "~>1"}})})), 1)
        self.assertEqual(len(self.deps("d", {"dub.sdl": 'name "x"\ndependency "mir" version="~>1"\n'})), 1)

    def test_cmake_fetching(self):
        self.assertEqual(self.deps("cpp", {"CMakeLists.txt": "find_package(Threads)\nadd_executable(x a.cpp)\n"}), [])
        self.assertEqual(len(self.deps("cpp", {"CMakeLists.txt": "include(FetchContent)\nFetchContent_Declare(gtest)\n"})), 1)

    def test_banned_facilities_depend_on_the_problem(self):
        t = au.scan_banned_facilities_text
        self.assertEqual(t("python", "import os, sys\nimport struct\n", "jsonschema"), [])
        self.assertEqual(t("python", "import re\nfrom json import loads\n", "jsonschema"), ["re", "json"])
        self.assertEqual(t("python", "import re\nfrom json import loads\n", "jq"), ["json"])
        self.assertEqual(t("python", "import re\n", "template"), [])
        self.assertEqual(t("go", 'import (\n\t"fmt"\n\t"regexp"\n)\n', "regex"), ["regexp"])
        self.assertEqual(t("go", 'import (\n\t"fmt"\n\t"regexp"\n)\n', "toml"), [])
        self.assertEqual(t("d", "import std.stdio;\nimport std.regex : regex;\n", "regex"), ["std.regex"])
        self.assertEqual(t("cpp", "#include <vector>\n#include <regex>\n", "regex"), ["<regex>"])
        self.assertEqual(t("python", "import hashlib, hmac\n", "webhooks"), ["hashlib", "hmac"])
        self.assertEqual(t("go", 'import "math/big"\n', "bigint"), ["math/big"])
        self.assertEqual(t("rust", "use std::collections::BTreeMap;\n", "ordered-map"), ["BTreeMap"])
        self.assertEqual(t("cpp", "#include <map>\nstd::map<int,int> m;\n", "ordered-map"), ["<map>"])
        self.assertEqual(t("rust", "use std::collections::BTreeMap;\n", "datalog"), [])

    def test_non_default_optimisation_settings(self):
        self.assertEqual(self.flags("cpp", {"CMakeLists.txt": "set(CMAKE_CXX_STANDARD 20)\n"}), [])
        self.assertEqual(len(self.flags("cpp", {"CMakeLists.txt": "add_compile_options(-march=native -flto)\n"})), 2)
        self.assertEqual(self.flags("rust", {"Cargo.toml": "[package]\nname = 'x'\n"}), [])
        self.assertEqual(len(self.flags("rust", {"Cargo.toml": "[profile.release]\nlto = true\n"})), 1)
        self.assertEqual(len(self.flags("rust", {".cargo/config.toml": "rustflags = ['-C', 'target-cpu=native']\n"})), 1)
        self.assertEqual(len(self.flags("d", {"dub.json": json.dumps({"dflags-ldc": ["-mcpu=native"]})})), 1)
        self.assertEqual(len(self.flags("go", {"default.pgo": "x"})), 1)
        self.assertEqual(len(self.flags("go", {"build.sh": "go build -gcflags=-B ./cmd/x\n"})), 1)
        self.assertEqual(self.flags("python", {"build.sh": "true\n"}), [])

    def flags(self, lang, files):
        with tempfile.TemporaryDirectory() as d:
            for rel, text in files.items():
                write(os.path.join(d, rel), text)
            return au.scan_build_flags(d, lang)

    def test_python_third_party_imports(self):
        files = {"src/pkg/__init__.py": "", "src/pkg/a.py": "import json, os\nfrom . import b\nfrom pkg import c\n",
                 "tests/test_a.py": "import unittest\nimport pkg.a\n"}
        self.assertEqual(self.deps("python", files), [])
        files["src/pkg/b.py"] = "import numpy as np\n"
        self.assertEqual([x["detail"] for x in self.deps("python", files)], ["numpy (src/pkg/b.py)"])


if __name__ == "__main__":
    unittest.main()
