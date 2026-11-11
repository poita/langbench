import json
import os
import tarfile
import tempfile
import unittest
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("impl_run", os.path.join(HERE, "..", "tools", "impl_run.py"))
ir = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ir)


def touch(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def fake_repo(root):
    for slug in ("chip8", "gitrepo", "inflate"):
        p = os.path.join(root, "problems", slug)
        for rel in ["SPEC.md", "APPROACH.md", "verify.py", "tests/001/input", "tests/001/expected", "corpus/c.txt",
                    "reference/main.py", "gen_tests.py", "bench/gen_bench.py", "oracle.py", "heldout/001/input"]:
            touch(os.path.join(p, rel))
    touch(os.path.join(root, "problems", "gitrepo", "SPEC.md"), "Inflate as in ../inflate/SPEC.md.")
    touch(os.path.join(root, "CONVENTIONS.md"))
    touch(os.path.join(root, "run_tests.py"))
    touch(os.path.join(root, "run-config.json"),
          json.dumps({"langs": ["go", "d"], "reps": 2, "repProblems": ["chip8"], "effort": "high"}))


class StageSandbox(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = os.path.join(self.tmp.name, "langbench")
        self.box = os.path.join(self.tmp.name, "box")
        self.projects = os.path.join(self.tmp.name, "projects")
        os.makedirs(os.path.join(self.projects, "-Users-u-other"))
        fake_repo(self.repo)

    def tearDown(self):
        self.tmp.cleanup()

    def stage(self, **over):
        return ir.stage_sandbox(self.repo, self.box, toolchains={"go": "go 1.27"}, overrides=over, projects=self.projects,
                                home=self.tmp.name, toolchain_roots=["/opt/ldc"])

    def ws(self, label):
        return os.path.join(os.path.realpath(self.box), json.load(open(os.path.join(self.box, "tasks.json")))[label])

    def settings(self, label):
        return json.load(open(os.path.join(self.ws(label), ".claude", "settings.json")))

    def test_master_copy_has_only_what_agents_may_see(self):
        self.stage()
        p = os.path.join(self.box, "problems", "chip8")
        for rel in ["SPEC.md", "APPROACH.md", "verify.py", "tests/001/input", "tests/001/expected", "corpus/c.txt"]:
            self.assertTrue(os.path.isfile(os.path.join(p, rel)), rel)
        self.assertFalse(os.path.exists(os.path.join(p, "heldout")))
        for rel in ["reference", "gen_tests.py", "bench", "oracle.py"]:
            self.assertFalse(os.path.exists(os.path.join(p, rel)), rel)

    def test_each_task_gets_a_private_workspace(self):
        self.stage()
        tasks = json.load(open(os.path.join(self.box, "tasks.json")))
        self.assertEqual(sorted(tasks), sorted(["rep1:go:chip8", "rep1:d:chip8", "rep1:go:gitrepo", "rep1:d:gitrepo",
                                                "rep1:go:inflate", "rep1:d:inflate", "rep2:go:chip8", "rep2:d:chip8"]))
        self.assertEqual(len(set(tasks.values())), 8)
        w = self.ws("rep1:go:gitrepo")
        for rel in ["CONVENTIONS.md", "run_tests.py", "problems/gitrepo/SPEC.md", "problems/gitrepo/tests/001/input",
                    "problems/gitrepo/corpus/c.txt", "problems/inflate/SPEC.md", "problems/inflate/APPROACH.md"]:
            self.assertTrue(os.path.isfile(os.path.join(w, rel)), rel)
        for rel in ["problems/inflate/tests", "problems/chip8", "problems/gitrepo/reference"]:
            self.assertFalse(os.path.exists(os.path.join(w, rel)), rel)
        self.assertNotIn("go", os.path.relpath(w, os.path.realpath(self.box)))

    def test_args_merge_config_root_toolchains_and_overrides(self):
        args = self.stage(problems=["chip8"], reps=3)
        self.assertEqual(args["root"], os.path.realpath(self.box))
        self.assertEqual(args["reps"], 3)
        self.assertEqual(args["repProblems"], ["chip8"])
        self.assertEqual(args["problems"], ["chip8"])
        self.assertEqual(args["toolchains"], {"go": "go 1.27"})
        self.assertEqual(json.load(open(os.path.join(self.box, "args.json"))), args)
        self.assertEqual(len(json.load(open(os.path.join(self.box, "tasks.json")))), 6)

    def test_workspace_settings_confine_the_task_without_naming_anything(self):
        self.stage()
        ws = self.ws("rep1:go:chip8")
        s = self.settings("rep1:go:chip8")
        box, home = os.path.realpath(self.box), os.path.realpath(self.tmp.name)
        # No path rules: Claude Code would describe them to the agent. The file tools stay inside the working
        # directories because the session runs in acceptEdits mode with only Bash pre-approved.
        self.assertNotIn("permissions", s)
        sb = s["sandbox"]
        fs = sb["filesystem"]
        self.assertEqual(fs["denyRead"], [home])  # box and repo are both under this home
        own_project = os.path.join(self.projects, ir.project_slug(ws))
        self.assertEqual(fs["allowRead"], [ws, own_project, "/opt/ldc"])
        text = json.dumps(s)
        for leak in ("langbench", "hidden", self.ws("rep1:d:chip8"), "-Users-u-other"):
            self.assertNotIn(leak, text)
        self.assertTrue(sb["enabled"] and sb["failIfUnavailable"])
        self.assertFalse(sb["allowUnsandboxedCommands"])
        self.assertEqual(sb["network"]["allowedDomains"], [])
        self.assertIn("/tmp", fs["allowWrite"])
        self.assertTrue(s["env"]["GOCACHE"].startswith(ws))
        self.assertEqual(s["env"]["GOTELEMETRY"], "off")
        self.assertTrue(os.path.isdir(own_project))

    def test_workspaces_get_offline_toolchains_and_test_frameworks(self):
        seed = os.path.join(self.tmp.name, "seed")
        touch(os.path.join(seed, "m2", "org", "clojure", "clojure", "1.12.6", "clojure-1.12.6.jar"))
        touch(os.path.join(seed, "gitlibs", "libs", "io.github.cognitect-labs", "test-runner", "x", "deps.edn"))
        touch(os.path.join(seed, "hackage", "hspec-2.11.18.tar.gz"))
        touch(os.path.join(seed, "store", "ghc-9.14.1", "package.db", "x.conf"))
        seeds = {"clojure": {"m2": os.path.join(seed, "m2"), "gitlibs": os.path.join(seed, "gitlibs")},
                 "haskell": {"repo": os.path.join(seed, "hackage"), "store": os.path.join(seed, "store")}}
        ir.stage_sandbox(self.repo, self.box, toolchains={}, overrides={"langs": ["haskell", "clojure"]},
                         projects=self.projects, home=self.tmp.name, toolchain_roots=[], seeds=seeds)
        hs, clj = self.ws("rep1:haskell:chip8"), self.ws("rep1:clojure:chip8")
        s = self.settings("rep1:haskell:chip8")
        config = open(os.path.join(s["env"]["CABAL_DIR"], "config")).read()
        self.assertIn("url: file+noindex://" + os.path.join(hs, ".cache", "hackage"), config)
        self.assertIn("store-dir: " + os.path.join(seed, "store"), config)
        self.assertTrue(os.path.isfile(os.path.join(hs, ".cache", "hackage", "hspec-2.11.18.tar.gz")))
        self.assertIn(os.path.join(seed, "store"), s["sandbox"]["filesystem"]["allowRead"])
        env = self.settings("rep1:clojure:chip8")["env"]
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertTrue(os.path.isfile(os.path.join(env["GITLIBS"], "libs", "io.github.cognitect-labs", "test-runner",
                                                    "x", "deps.edn")))
        repo = open(os.path.join(env["CLJ_CONFIG"], "deps.edn")).read().split('"')[1]
        self.assertTrue(repo.startswith(clj))
        self.assertTrue(os.path.isfile(os.path.join(repo, "org", "clojure", "clojure", "1.12.6", "clojure-1.12.6.jar")))

    def test_gnu_sed_comes_first_and_the_deployment_target_is_set(self):
        saved = (ir.gnu_tools_dir, ir.macos_version)
        ir.gnu_tools_dir, ir.macos_version = (lambda: "/opt/gnu/bin"), (lambda: "26")
        try:
            env = ir.tool_env("/w")
            self.assertTrue(env["PATH"].startswith("/opt/gnu/bin" + os.pathsep))
            self.assertEqual(env["MACOSX_DEPLOYMENT_TARGET"], "26.0")
        finally:
            ir.gnu_tools_dir, ir.macos_version = saved

    def test_a_workspace_with_a_python_environment_runs_its_python_first(self):
        with tempfile.TemporaryDirectory() as ws:
            os.makedirs(os.path.join(ws, ".cache", "venv", "bin"))
            path = ir.tool_env(ws)["PATH"].split(os.pathsep)
            venv = os.path.join(ws, ".cache", "venv", "bin")
            self.assertIn(venv, path)
            self.assertLess(path.index(venv), path.index(os.environ["PATH"].split(os.pathsep)[0]))
            self.assertNotIn(venv, ir.tool_env(os.path.join(ws, "other")).get("PATH", ""))

    def test_paths_outside_home_are_denied_too(self):
        dirs = ir.read_denials(home="/home/u", box="/srv/box", repo="/data/lb")
        self.assertEqual(dirs, ["/home/u", "/srv/box", "/data/lb"])

    def test_harness_files_are_read_only_and_changes_are_detected(self):
        self.stage()
        spec_md = os.path.join(self.box, "problems", "chip8", "SPEC.md")
        self.assertFalse(os.access(spec_md, os.W_OK))
        self.assertFalse(os.access(os.path.join(self.ws("rep1:go:chip8"), "run_tests.py"), os.W_OK))
        self.assertEqual(ir.changed_harness_files(self.box), [])
        w = self.ws("rep1:go:chip8")
        expected = os.path.join(w, "problems", "chip8", "tests", "001", "expected")
        os.remove(expected)
        touch(expected, "forged")
        rel = os.path.relpath(expected, os.path.realpath(self.box))
        self.assertEqual(ir.changed_harness_files(self.box), [rel])

    def test_refuses_a_sandbox_inside_the_repo(self):
        with self.assertRaises(SystemExit):
            ir.stage_sandbox(self.repo, os.path.join(self.repo, "box"), toolchains={})

    def test_refuses_a_checkout_with_uncommitted_changes(self):
        import subprocess
        subprocess.run(["git", "init", "-q", self.repo], check=True)
        with self.assertRaises(SystemExit):
            self.stage()
        ir.stage_sandbox(self.repo, self.box, toolchains={}, allow_dirty=True, projects=self.projects,
                         home=self.tmp.name, toolchain_roots=[])

    def test_refuses_a_non_empty_destination(self):
        touch(os.path.join(self.box, "stale"))
        with self.assertRaises(SystemExit):
            self.stage()


class CleanVerify(unittest.TestCase):
    RUNNER = ("import subprocess, sys\n"
              "cmd = sys.argv[sys.argv.index('--') + 1:]\n"
              "ok = subprocess.run(cmd).returncode == 0\n"
              "print(f'{sys.argv[1]}: {int(ok)}/1 passed')\n"
              "sys.exit(0 if ok else 1)\n")

    def project(self, d, build):
        ws = os.path.join(d, "w", "aa")
        touch(os.path.join(ws, "run_tests.py"), self.RUNNER)
        proj = os.path.join(ws, "x")
        touch(os.path.join(proj, "build.sh"), build)
        touch(os.path.join(proj, "run.sh"), '#!/bin/sh\nexec "$(dirname "$0")/build/prog"\n')
        touch(os.path.join(proj, "src.txt"), "source")
        for f in ("build.sh", "run.sh"):
            os.chmod(os.path.join(proj, f), 0o755)
        # A binary left from the agent's own build.
        touch(os.path.join(proj, "build", "prog"), "#!/bin/sh\nexit 0\n")
        os.chmod(os.path.join(proj, "build", "prog"), 0o755)
        return ws

    def test_a_project_that_builds_from_clean_passes(self):
        with tempfile.TemporaryDirectory() as d:
            ws = self.project(d, '#!/bin/sh\ncd "$(dirname "$0")" && mkdir -p build && '
                                 'printf "#!/bin/sh\\nexit 0\\n" > build/prog && chmod +x build/prog\n')
            res = ir.verify_task(ws, "x", os.path.join(d, "scratch"), problems="/none")
            self.assertTrue(res["public_pass"], res)
            self.assertTrue(res["clean_build"])

    def test_a_stale_binary_does_not_pass_when_build_sh_fails(self):
        with tempfile.TemporaryDirectory() as d:
            ws = self.project(d, "#!/bin/sh\nexit 1\n")
            res = ir.verify_task(ws, "x", os.path.join(d, "scratch"), problems="/none")
            self.assertFalse(res["clean_build"])
            self.assertFalse(res["public_pass"])


class HeldOutVerify(unittest.TestCase):
    RUNNER = CleanVerify.RUNNER
    project = CleanVerify.project

    def test_held_out_tests_run_from_the_problem_directory(self):
        with tempfile.TemporaryDirectory() as d:
            ws = self.project(d, '#!/bin/sh\ncd "$(dirname "$0")" && mkdir -p build && '
                                 'printf "#!/bin/sh\\nexit 0\\n" > build/prog && chmod +x build/prog\n')
            problems = os.path.join(d, "problems")
            os.makedirs(os.path.join(problems, "x", "heldout"))
            res = ir.verify_task(ws, "x", os.path.join(d, "scratch"), problems=problems)
            self.assertTrue(res["hidden_pass"], res)
            res = ir.verify_task(ws, "x", os.path.join(d, "scratch2"), problems=os.path.join(d, "none"))
            self.assertNotIn("hidden_pass", res)


class VerifyUsesTheWorkspaceToolConfig(unittest.TestCase):
    RUNNER = CleanVerify.RUNNER
    project = CleanVerify.project

    def test_java_is_the_jdk_the_clojure_cli_uses_everywhere(self):
        saved = ir.java_home
        ir.java_home = lambda: "/opt/jdk"
        try:
            self.assertEqual(ir.tool_env("/w")["JAVA_HOME"], "/opt/jdk")
            ir.java_home = lambda: None
            self.assertNotIn("JAVA_HOME", ir.tool_env("/w"))
        finally:
            ir.java_home = saved

    def test_clean_builds_use_the_offline_cabal_and_clojure_config(self):
        with tempfile.TemporaryDirectory() as d:
            ws = self.project(d, '#!/bin/sh\ncd "$(dirname "$0")" && echo "$CABAL_DIR $CLJ_CONFIG" > env.txt && '
                                 'mkdir -p build && printf "#!/bin/sh\\nexit 0\\n" > build/prog && chmod +x build/prog\n')
            ir.offline_tool_config(ws)
            ir.verify_task(ws, "x", os.path.join(d, "scratch"), problems="/none")
            cabal, clj = open(os.path.join(d, "scratch", "x", "env.txt")).read().split()
            self.assertEqual(cabal, os.path.join(ws, ".cache", "cabal"))
            self.assertEqual(clj, os.path.join(ws, ".cache", "clj-config"))


class ImportKeepsSourcePackagesNamedBuild(unittest.TestCase):
    def test_a_go_package_named_build_is_copied(self):
        with tempfile.TemporaryDirectory() as d:
            touch(os.path.join(d, "p", "build", "graph.go"), "package build")
            touch(os.path.join(d, "p", "main.go"), "package main")
            self.assertEqual(ir.import_impls(os.path.join(d, "p"), os.path.join(d, "out"), "go"), 2)


class AnonymiseFindings(unittest.TestCase):
    def test_sandbox_and_home_paths_are_replaced(self):
        findings = [{"agent": "rep1:d:x", "kind": "blocked-attempt",
                     "detail": "Bash: ls /home/u/work/run1/w ; cat /home/u/.gitconfig ; ls /home/u/work/run1/w/aa/x"}]
        out = ir.anonymise_findings(findings, box="/home/u/work/run1", home="/home/u")
        self.assertEqual(out[0]["detail"], "Bash: ls <root>/w ; cat ~/.gitconfig ; ls <root>/w/aa/x")
        self.assertEqual(out[0]["kind"], "blocked-attempt")


class ImportImpls(unittest.TestCase):
    def test_copies_sources_without_build_outputs_or_binaries(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "out")
            touch(os.path.join(src, "rep1", "go", "chip8", "run.sh"))
            touch(os.path.join(src, "rep1", "go", "chip8", "main.go"))
            touch(os.path.join(src, "rep1", "rust", "chip8", "run.sh"))
            touch(os.path.join(src, "rep1", "rust", "chip8", "target", "release", "x"))
            with open(os.path.join(src, "rep1", "go", "chip8", "chip8"), "wb") as f:
                f.write(b"\xcf\xfa\xed\xfe rest")
            dest = os.path.join(d, "dest")
            n = ir.import_impls(src, dest)
            self.assertTrue(os.path.isfile(os.path.join(dest, "rep1", "go", "chip8", "main.go")))
            self.assertFalse(os.path.exists(os.path.join(dest, "rep1", "go", "chip8", "chip8")))
            self.assertFalse(os.path.exists(os.path.join(dest, "rep1", "rust", "chip8", "target")))
            self.assertEqual(n, 3)


class ArchiveTranscripts(unittest.TestCase):
    def test_archive_is_anonymised(self):
        with tempfile.TemporaryDirectory() as d:
            wf = os.path.join(d, "wf_abc")
            touch(os.path.join(wf, "journal.jsonl"), '{"p": "/sb/root/out and /home/u/x"}\n')
            touch(os.path.join(wf, "agent-1.jsonl"), '{"p": "/sb/root/problems", "d": "-sb-root/x -home-u-y"}\n')
            tar = os.path.join(d, "t.tar.gz")
            ir.archive_transcripts(wf, tar, sandbox="/sb/root", home="/home/u")
            with tarfile.open(tar) as t:
                names = sorted(t.getnames())
                text = t.extractfile("wf_abc/journal.jsonl").read().decode()
            self.assertEqual(names, ["wf_abc", "wf_abc/agent-1.jsonl", "wf_abc/journal.jsonl"])
            self.assertEqual(text, '{"p": "<root>/out and ~/x"}\n')
            with tarfile.open(tar) as t:
                text = t.extractfile("wf_abc/agent-1.jsonl").read().decode()
            self.assertEqual(text, '{"p": "<root>/problems", "d": "<root>/x ~/y"}\n')

    def test_archive_redacts_account_identifiers(self):
        with tempfile.TemporaryDirectory() as d:
            wf = os.path.join(d, "run")
            touch(os.path.join(wf, "sessions", "s.jsonl"), "\n".join([
                json.dumps({"type": "session-owner", "accountUuid": "acc-1", "organizationUuid": "org-1"}),
                json.dumps({"type": "user", "message": {"content": "hi"}, "userEmail": "a@b.c"}),
                json.dumps({"attachment": {"type": "credential_org", "org": {"name": "Acme", "uuid": "org-1"}}}),
            ]) + "\n")
            tar = os.path.join(d, "t.tar.gz")
            ir.archive_transcripts(wf, tar, sandbox="/sb", home="/home/u")
            with tarfile.open(tar) as t:
                text = t.extractfile("run/sessions/s.jsonl").read().decode()
            for secret in ("acc-1", "org-1", "a@b.c", "Acme"):
                self.assertNotIn(secret, text)
            self.assertIn('"type": "user"', text)


if __name__ == "__main__":
    unittest.main()
