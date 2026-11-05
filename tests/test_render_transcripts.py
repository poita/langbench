import importlib.util
import json
import os
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rt", os.path.join(HERE, "..", "tools", "render_transcripts.py"))
rt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rt)


def line(kind, content, mid=None):
    m = {"content": content}
    if mid:
        m["id"] = mid
    return json.dumps({"type": kind, "message": m})


SESSION = [
    line("user", "Build a standalone Go project that implements ..."),
    line("assistant", [{"type": "thinking", "thinking": "secret plan"}, {"type": "text", "text": "Reading the spec."}], "m1"),
    line("assistant", [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "go build ./..."}}], "m1"),
    line("user", [{"type": "tool_result", "tool_use_id": "t1", "is_error": True,
                   "content": "\n".join(f"line {i}" for i in range(200))}]),
    line("assistant", [{"type": "tool_use", "id": "t2", "name": "Write",
                        "input": {"file_path": "<root>/w/aa/x/main.go", "content": "package main\n"}}], "m2"),
    line("user", [{"type": "tool_result", "tool_use_id": "t2", "content": "File created"}]),
]


class Render(unittest.TestCase):
    def test_calls_are_numbered_anchored_and_long_outputs_truncated(self):
        md = rt.render_session("rep1:go:x", [SESSION], {"num_turns": 2})
        self.assertIn('<a id="call-1"></a>', md)
        self.assertIn('<a id="call-2"></a>', md)
        self.assertIn("go build ./...", md)
        self.assertIn("error", md.lower())
        self.assertIn("line 0", md)
        self.assertIn("line 199", md)
        self.assertNotIn("line 100\n", md)
        self.assertIn("lines omitted", md)
        self.assertIn("Reading the spec.", md)
        self.assertNotIn("secret plan", md)

    def test_archive_renders_one_file_per_task_and_an_index(self):
        with tempfile.TemporaryDirectory() as d:
            run = os.path.join(d, "run-x")
            os.makedirs(os.path.join(run, "sessions"))
            with open(os.path.join(run, "manifest.jsonl"), "w") as f:
                f.write(json.dumps({"label": "rep1:go:x", "rep": "rep1", "lang": "go", "slug": "x",
                                    "session_id": "s1", "infra_error": False, "result": {"num_turns": 2}}) + "\n")
            with open(os.path.join(run, "sessions", "s1.jsonl"), "w") as f:
                f.write("\n".join(SESSION) + "\n")
            with open(os.path.join(run, "results.json"), "w") as f:
                json.dump({"rep1:go:x": {"public": "x: 3/3 passed", "public_pass": True}}, f)
            tar = os.path.join(d, "run-x.tar.gz")
            with tarfile.open(tar, "w:gz") as t:
                t.add(run, arcname="run-x")
            out = os.path.join(d, "out")
            rt.render_archive(tar, out)
            self.assertTrue(os.path.isfile(os.path.join(out, "rep1-go-x.md")))
            index = open(os.path.join(out, "README.md")).read()
            self.assertIn("(rep1-go-x.md)", index)
            self.assertIn("3/3 passed", index)


if __name__ == "__main__":
    unittest.main()
