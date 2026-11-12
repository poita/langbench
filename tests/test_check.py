import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("check", os.path.join(HERE, "..", "tools", "check.py"))
ck = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ck)


def write_record(d, runs, audits=None):
    with open(os.path.join(d, "run.json"), "w") as f:
        json.dump({"runs": runs}, f)
    for name, findings in (audits or {}).items():
        os.makedirs(os.path.join(d, "audit"), exist_ok=True)
        with open(os.path.join(d, "audit", name), "w") as f:
            json.dump(findings, f)


class Canonical(unittest.TestCase):
    def test_plain_options_are_canonical(self):
        with tempfile.TemporaryDirectory() as d:
            write_record(d, [{"workflow_run": "wf_a", "options": {"approach": True, "efficiency": False, "notes": []}}])
            self.assertEqual(ck.canonical_errors(d), [])

    def test_tips_efficiency_and_unguided_runs_are_not_canonical(self):
        for opts in ({"approach": True, "notes": ["d"]}, {"approach": True, "notes": {"d": "x"}},
                     {"approach": True, "machineNotes": {"d": "x"}}, {"approach": True, "efficiency": True},
                     {"approach": False}):
            with tempfile.TemporaryDirectory() as d:
                write_record(d, [{"workflow_run": "wf_a", "options": opts}])
                self.assertEqual(len(ck.canonical_errors(d)), 1, opts)

    def test_sandboxed_runs_need_a_clean_audit(self):
        run = {"workflow_run": "wf_a", "sandbox": True, "audit": "audit/wf_a.json", "options": {"approach": True}}
        with tempfile.TemporaryDirectory() as d:
            write_record(d, [run], {"wf_a.json": []})
            self.assertEqual(ck.canonical_errors(d), [])
        with tempfile.TemporaryDirectory() as d:
            write_record(d, [run], {"wf_a.json": [{"kind": "forbidden-path"}]})
            self.assertEqual(len(ck.canonical_errors(d)), 1)
        with tempfile.TemporaryDirectory() as d:
            write_record(d, [run], {"wf_a.json": [{"kind": "dependency"}, {"kind": "banned-facility"}]})
            self.assertEqual(ck.canonical_errors(d), [])
        with tempfile.TemporaryDirectory() as d:
            write_record(d, [run])
            self.assertEqual(len(ck.canonical_errors(d)), 1)


    def test_integrity_findings_a_person_reviewed_with_a_reason_are_accepted(self):
        run = {"workflow_run": "wf_a", "sandbox": True, "audit": "audit/wf_a.json", "options": {"approach": True}}
        finding = {"agent": "rep1:go:x", "kind": "forbidden-path", "detail": "Bash: ls /sb/tools"}
        for reviewed, errors in (([{**finding, "reason": "refused by the sandbox; stderr discarded"}], 0),
                                 ([{**finding, "reason": ""}], 1),
                                 ([{**finding, "detail": "other", "reason": "x"}], 1)):
            with tempfile.TemporaryDirectory() as d:
                write_record(d, [run], {"wf_a.json": [finding], "wf_a.reviewed.json": reviewed})
                self.assertEqual(len(ck.canonical_errors(d)), errors, reviewed)


if __name__ == "__main__":
    unittest.main()
