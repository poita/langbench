import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("impl_run", os.path.join(HERE, "..", "tools", "impl_run.py"))
ir = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ir)


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


class IsBinary(unittest.TestCase):
    def test_macho_64_is_binary(self):
        self.assertTrue(ir.is_binary_header(b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01"))

    def test_elf_is_binary(self):
        self.assertTrue(ir.is_binary_header(b"\x7fELF\x02\x01\x01\x00"))

    def test_static_archive_is_binary(self):
        self.assertTrue(ir.is_binary_header(b"!<arch>\n"))

    def test_source_text_is_not_binary(self):
        self.assertFalse(ir.is_binary_header(b"module foo;\n"))

    def test_json_is_not_binary(self):
        self.assertFalse(ir.is_binary_header(b'{"name": "x"}'))


class Excluded(unittest.TestCase):
    def test_build_directories_are_excluded(self):
        for p in ["r/rep1/d/x/.dub/obj/a.d", "r/rep1/rust/x/target/release/x", "r/rep1/cpp/x/build/CMakeCache.txt",
                  "r/rep1/python/x/src/__pycache__/m.pyc", "r/rep1/d/x/src/a.o"]:
            self.assertTrue(ir.is_build_output(p), p)

    def test_build_directories_depend_on_the_language(self):
        self.assertFalse(ir.is_build_output("r/rep1/go/buildsys/build/graph.go"))
        self.assertFalse(ir.is_build_output("r/rep1/rust/x/src/build/mod.rs"))
        self.assertTrue(ir.is_build_output("r/rep1/cpp/x/build/CMakeCache.txt"))
        self.assertFalse(ir.is_build_output("/build/graph.go", "go"))
        self.assertTrue(ir.is_build_output("/build/CMakeCache.txt", "cpp"))
        self.assertTrue(ir.is_build_output("/target/release/x", "rust"))

    def test_sources_are_kept(self):
        for p in ["r/rep1/d/x/source/app.d", "r/rep1/d/x/dub.json", "r/rep1/go/x/build.sh", "r/rep1/d/x/tests/build_test.d"]:
            self.assertFalse(ir.is_build_output(p), p)


class FindImpls(unittest.TestCase):
    def test_finds_rep_lang_slug_directories(self):
        with tempfile.TemporaryDirectory() as root:
            write(os.path.join(root, "out", "rep1", "d", "sat", "run.sh"), b"#!/bin/sh\n")
            write(os.path.join(root, "out", "rep2", "go", "toml", "run.sh"), b"#!/bin/sh\n")
            write(os.path.join(root, "out", "rep1", "d", "half", "notes.txt"), b"no run.sh\n")
            found = ir.find_impls(os.path.join(root, "out"))
            self.assertEqual(found, [("rep1", "d", "sat"), ("rep2", "go", "toml")])


class HiddenDir(unittest.TestCase):
    def test_environment_variable_wins(self):
        old = os.environ.get("LANGBENCH_HIDDEN")
        os.environ["LANGBENCH_HIDDEN"] = "/somewhere/hidden"
        try:
            self.assertEqual(ir.hidden_dir("/repo"), "/somewhere/hidden")
        finally:
            if old is None:
                del os.environ["LANGBENCH_HIDDEN"]
            else:
                os.environ["LANGBENCH_HIDDEN"] = old

    def test_default_is_sibling_of_main_checkout(self):
        old = os.environ.pop("LANGBENCH_HIDDEN", None)
        try:
            self.assertEqual(ir.hidden_dir("/x/langbench", main_checkout="/x/langbench"), "/x/langbench-hidden")
        finally:
            if old is not None:
                os.environ["LANGBENCH_HIDDEN"] = old


PROMPT = """
Build the following as a standalone D project.

Problem specification: /x/langbench/problems/sat/SPEC.md
Project directory: /x/langbench/runs-new/rep1/d/sat/

Required approach: read /x/langbench/problems/sat/APPROACH.md in full and follow it.
- D: the LDC compiler at ldc2 and dub 1.40. Use dub; build with dub build -b release --compiler=ldc2, and pass
Write a complete, correct implementation that follows APPROACH.md. It is important that the implementation is efficient.
"""


class Stage(unittest.TestCase):
    def test_staged_deletions_are_skipped_and_binaries_left_out(self):
        import subprocess
        with tempfile.TemporaryDirectory() as root:
            git = lambda *a: subprocess.run(["git", "-C", root] + list(a), check=True, capture_output=True)
            git("init", "-q")
            write(os.path.join(root, "out", "old.txt"), b"old\n")
            git("add", "out/old.txt")
            git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "x")
            git("rm", "-q", "out/old.txt")
            write(os.path.join(root, "out", "rep1", "go", "sat", "main.go"), b"package main\n")
            write(os.path.join(root, "out", "rep1", "go", "sat", "sat-bin"), b"\xcf\xfa\xed\xfe" + b"\0" * 8)
            old = ir.ROOT
            ir.ROOT = root
            try:
                ir.stage("out")
            finally:
                ir.ROOT = old
            staged = subprocess.run(["git", "-C", root, "diff", "--cached", "--name-only"], capture_output=True,
                                    text=True).stdout.split()
            self.assertIn("out/rep1/go/sat/main.go", staged)
            self.assertNotIn("out/rep1/go/sat/sat-bin", staged)


class PromptOptions(unittest.TestCase):
    def test_detects_options_from_prompt_text(self):
        o = ir.prompt_options(PROMPT)
        self.assertEqual(o, {"approach": True, "efficiency": True, "notes": [], "dc": "ldc2"})

    def test_plain_prompt_has_no_options(self):
        o = ir.prompt_options("Build the following as a standalone Go project.\nWrite a complete, correct implementation.")
        self.assertEqual(o, {"approach": False, "efficiency": False, "notes": [], "dc": None})

    def test_language_notes_detected(self):
        p = "- D: ldc2.\n  D notes: use strtod\n- Rust: cargo.\n  Rust notes: avoid clones\n- C++: clang."
        self.assertEqual(ir.prompt_options(p)["notes"], ["d", "rust"])

    def test_notes_detected_in_indented_relayed_prompts(self):
        self.assertEqual(ir.prompt_options("- D: ldc2.\n    D notes: use strtod\n")["notes"], ["d"])


class Anonymise(unittest.TestCase):
    def test_checkout_path_becomes_root(self):
        t = ir.anonymise("Problem specification: /a/b/langbench/problems/sat/SPEC.md\nRun: cd /a/b/langbench && x")
        self.assertEqual(t, "Problem specification: <root>/problems/sat/SPEC.md\nRun: cd <root> && x")

    def test_home_becomes_tilde(self):
        self.assertEqual(ir.anonymise(os.path.expanduser("~") + "/dlang/ldc2"), "~/dlang/ldc2")


class PresentAgents(unittest.TestCase):
    def test_keeps_only_implementations_present_in_out(self):
        with tempfile.TemporaryDirectory() as root:
            write(os.path.join(root, "out", "rep1", "go", "sat", "run.sh"), b"#!/bin/sh\n")
            agents = [("rep1", "go", "sat"), ("rep1", "d", "sat"), ("rep2", "go", "sat")]
            self.assertEqual(ir.present_agents(os.path.join(root, "out"), agents), [("rep1", "go", "sat")])


class RunRecord(unittest.TestCase):
    def test_merges_runs_without_duplicates(self):
        rec = {"runs": [{"workflow_run": "wf_a"}]}
        ir.add_run(rec, {"workflow_run": "wf_b"})
        ir.add_run(rec, {"workflow_run": "wf_a", "model": "m"})
        self.assertEqual([r["workflow_run"] for r in rec["runs"]], ["wf_a", "wf_b"])
        self.assertEqual(rec["runs"][0]["model"], "m")


if __name__ == "__main__":
    unittest.main()
