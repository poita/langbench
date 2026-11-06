"""Unit tests for lbench's build-script rewriting, suite selection and statistics."""
import importlib.machinery
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("lbench", os.path.join(HERE, "..", "lbench"))
_spec = importlib.util.spec_from_loader("lbench", _loader)
lb = importlib.util.module_from_spec(_spec)
_loader.exec_module(lb)

def need_bench(test, slug):
    """Skip a test that reads benchmark data when it has not been generated (make bench)."""
    bdir = os.path.join(lb.ROOT, "problems", slug, "bench")
    if not any(f.endswith(".in") or os.path.isdir(os.path.join(bdir, f, "input")) for f in os.listdir(bdir)):
        test.skipTest("benchmark data not generated (make bench)")


DMD = "/opt/dmd/bin/dmd"
LDC = "/opt/ldc/bin/ldc2"


class RetargetDub(unittest.TestCase):
    def test_compiler_flag_with_absolute_path(self):
        src = 'dub build -b release --config=cli --compiler=/opt/dmd-fast/bin/dmd\n'
        self.assertEqual(lb.retarget_d(src, LDC, "ldc"), f'dub build -b release --config=cli --compiler={LDC}\n')

    def test_compiler_flag_quoted(self):
        src = 'dub build :cli -b release --compiler="$DMD" --quiet\n'
        self.assertIn(f"--compiler={DMD} --quiet", lb.retarget_d(src, DMD, "dmd"))

    def test_compiler_flag_by_name(self):
        src = 'dub build -b release --compiler=ldc2 -q\n'
        self.assertEqual(lb.retarget_d(src, DMD, "dmd"), f'dub build -b release --compiler={DMD} -q\n')


class RetargetDirect(unittest.TestCase):
    def test_ldc2_command_to_dmd(self):
        src = 'ldc2 -O -release -of="$dir/x" "$dir/main.d"\n'
        self.assertEqual(lb.retarget_d(src, DMD, "dmd"), f'"{DMD}" -O -release -of="$dir/x" "$dir/main.d"\n')

    def test_command_after_and(self):
        src = 'cd "$dir" && ldc2 -O -release -of=x main.d\n'
        self.assertIn(f'&& "{DMD}" -O', lb.retarget_d(src, DMD, "dmd"))

    def test_exec_prefix(self):
        src = 'exec ldc2 -O -release -of=x main.d\n'
        self.assertIn(f'exec "{DMD}"', lb.retarget_d(src, DMD, "dmd"))

    def test_ldc_only_flags_mapped_for_dmd(self):
        out = lb.retarget_d('ldc2 -O3 --boundscheck=off -mcpu=native -of=x a.d\n', DMD, "dmd")
        self.assertIn("-O ", out)
        self.assertIn("-boundscheck=off", out)
        self.assertNotIn("-mcpu", out)

    def test_dmd_inline_mapped_for_ldc(self):
        out = lb.retarget_d('dmd -O -release -inline -of=x a.d\n', LDC, "ldc")
        self.assertIn("-enable-inlining", out)

    def test_word_containing_dmd_untouched(self):
        src = '# Builds with the fast dmd toolchain\nldc2 -O -of=x a.d\n'
        out = lb.retarget_d(src, DMD, "dmd")
        self.assertIn("# Builds with the fast dmd toolchain", out)

    def test_already_targeted_script_is_accepted(self):
        src = f'dub build -b release --compiler={DMD}\n'
        self.assertEqual(lb.retarget_d(src, DMD, "dmd"), src)

    def test_no_compiler_returns_none(self):
        self.assertIsNone(lb.retarget_d('go build -o x ./cmd/x\n', DMD, "dmd"))


class CompilerInfo(unittest.TestCase):
    def test_snapshot_inside_benchmark_repo_has_no_git_revision(self):
        snap = os.path.join(lb.ROOT, "toolchains", "dmd-fast", "bin", "dmd")
        if not os.path.exists(snap):
            self.skipTest("no DMD snapshot")
        self.assertEqual(lb.compiler_info(snap)["git"], "")


class CompilerWrapper(unittest.TestCase):
    def _run_wrapper(self, extra):
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            fake = os.path.join(d, "fake-ldc2")
            with open(fake, "w") as f:
                f.write("#!/bin/bash\necho \"$@\"\n")
            os.chmod(fake, 0o755)
            dc = {"path": fake, "kind": "ldc"}
            w = lb.compiler_wrapper(dc, os.path.join(d, "wrap"), extra) if extra is not None \
                else lb.compiler_wrapper(dc, os.path.join(d, "wrap"))
            env = {k: v for k, v in os.environ.items() if k != "LBENCH_TIMELOG"}
            return os.path.basename(w), subprocess.run([w, "-O3", "-release", "a.d"], capture_output=True,
                                                       text=True, env=env).stdout.split()

    def test_wrapper_passes_arguments_through(self):
        name, args = self._run_wrapper(None)
        self.assertEqual(name, "ldc2")
        self.assertEqual(args, ["-O3", "-release", "a.d"])

    def test_extra_flags_come_after_build_flags(self):
        _, args = self._run_wrapper(["-boundscheck=on"])
        self.assertEqual(args, ["-O3", "-release", "a.d", "-boundscheck=on"])


class TimeLog(unittest.TestCase):
    def test_sums_every_invocation(self):
        log = ("        0.50 real         0.40 user         0.05 sys\n"
               "          1000  instructions retired\n           500  cycles elapsed\n"
               "        0.20 real         0.10 user         0.02 sys\n"
               "          2500  instructions retired\n           900  cycles elapsed\n")
        self.assertEqual(lb.parse_time_log(log), {"invocations": 2, "instr": 3500, "cycles": 1400,
                                                  "cpu": 0.57})

    def test_empty_log(self):
        self.assertEqual(lb.parse_time_log(""), {"invocations": 0, "instr": 0, "cycles": 0, "cpu": 0.0})


class Counters(unittest.TestCase):
    def test_a_perf_that_cannot_run_is_not_used(self):
        """Ubuntu's linux-tools wrapper puts a `perf` on PATH that exits 1 when no perf matches the kernel."""
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            fake = os.path.join(d, "perf")
            with open(fake, "w") as f:
                f.write("#!/bin/sh\necho 'WARNING: perf not found for kernel' >&2\nexit 1\n")
            os.chmod(fake, 0o755)
            saved = (lb.sys.platform, os.environ["PATH"])
            lb.sys.platform, os.environ["PATH"] = "linux", d + os.pathsep + os.environ["PATH"]
            lb.perf_usable.cache_clear()
            try:
                self.assertEqual(lb.counter_prefix("log"), [])
            finally:
                lb.sys.platform, os.environ["PATH"] = saved
                lb.perf_usable.cache_clear()


class Timing(unittest.TestCase):
    def test_wall_time_does_not_come_from_polling_wait(self):
        # lbench run always passes a timeout, and Popen.wait(timeout) polls with back-off up to 50 ms,
        # which bunches short runs' wall times at its poll instants; timed() must reap the child itself.
        import subprocess
        real_wait = subprocess.Popen.wait

        def no_polling(proc, timeout=None):
            if timeout is not None:
                raise AssertionError("timed() used Popen.wait(timeout)")
            return real_wait(proc)
        subprocess.Popen.wait = no_polling
        try:
            m = lb.timed([sys.executable, "-c", "pass"], HERE, timeout=60)
        finally:
            subprocess.Popen.wait = real_wait
        self.assertEqual(m["rc"], 0)

    def test_timeout_kills_and_reports_no_exit_code(self):
        m = lb.timed([sys.executable, "-c", "import time; time.sleep(5)"], HERE, timeout=0.3)
        self.assertIsNone(m["rc"])
        self.assertLess(m["wall"], 2.0)

    def test_exit_code_and_rss_are_reported(self):
        m = lb.timed([sys.executable, "-c", "import sys; sys.exit(3)"], HERE)
        self.assertEqual(m["rc"], 3)
        self.assertGreater(m["rss"], 0)
        self.assertGreater(m["cpu"], 0)


class PerfStat(unittest.TestCase):
    SAMPLE = ("# started on Sat Oct 31 12:00:00 2026\n\n"
              "12.50,msec,task-clock:u,12500000,100.00,0.987,CPUs utilized\n"
              "45000000,,instructions:u,12500000,100.00,1.50,insn per cycle\n"
              "30000000,,cycles:u,12500000,100.00,2.400,GHz\n")

    def test_parses_one_run(self):
        self.assertEqual(lb.parse_perf_stat(self.SAMPLE), {"invocations": 1, "instr": 45000000,
                                                         "cycles": 30000000, "cpu": 0.0125})

    def test_sums_appended_runs(self):
        self.assertEqual(lb.parse_perf_stat(self.SAMPLE + self.SAMPLE)["instr"], 90000000)
        self.assertEqual(lb.parse_perf_stat(self.SAMPLE + self.SAMPLE)["invocations"], 2)

    def test_not_counted_reads_as_zero(self):
        text = "<not counted>,,instructions:u,0,0.00,,\n<not supported>,,cycles:u,0,0.00,,\n"
        self.assertEqual(lb.parse_perf_stat(text)["instr"], 0)


class Tiers(unittest.TestCase):
    def test_suites_name_their_tier(self):
        self.assertEqual(lb.suite_tier("fast"), "short")
        self.assertEqual(lb.suite_tier("quick"), "long")
        self.assertEqual(lb.suite_tier("all"), "long")

    def test_long_tier_reads_bench_long(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "problems", "sat", "bench-long"))
            with open(os.path.join(d, "problems", "sat", "bench-long", "001_x.in"), "w") as f:
                f.write("p cnf 1 1\n1 0\n")
            old = lb.ROOT
            lb.ROOT = d
            try:
                tdir, cases = lb.bench_cases("sat", "long")
                self.assertTrue(tdir.endswith(os.path.join("sat", "bench-long")))
                self.assertEqual(cases, [("001_x.in", "stdin")])
            finally:
                lb.ROOT = old

    def test_missing_long_tier_says_how_to_generate_it(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "problems", "sat", "bench"))
            old = lb.ROOT
            lb.ROOT = d
            try:
                with self.assertRaises(SystemExit) as cm:
                    lb.bench_cases("sat", "long")
                self.assertIn("make bench-long", str(cm.exception))
            finally:
                lb.ROOT = old


class TierFallback(unittest.TestCase):
    def _root(self, d, short=True, long=False):
        if short:
            os.makedirs(os.path.join(d, "problems", "sat", "bench"))
            open(os.path.join(d, "problems", "sat", "bench", "001_x.in"), "w").write("1\n")
        if long:
            os.makedirs(os.path.join(d, "problems", "sat", "bench-long"))
            open(os.path.join(d, "problems", "sat", "bench-long", "001_x.in"), "w").write("1\n")

    def _tier(self, short, long, want):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            self._root(d, short, long)
            old = lb.ROOT
            lb.ROOT = d
            try:
                return lb.effective_tier("sat", want)
            finally:
                lb.ROOT = old

    def test_long_used_when_present(self):
        self.assertEqual(self._tier(True, True, "long"), "long")

    def test_problem_without_long_tier_falls_back_to_short(self):
        self.assertEqual(self._tier(True, False, "long"), "short")

    def test_short_requested_stays_short(self):
        self.assertEqual(self._tier(True, True, "short"), "short")


class BenchData(unittest.TestCase):
    def test_missing_bench_data_says_how_to_generate_it(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "problems", "sat", "bench"))
            old = lb.ROOT
            lb.ROOT = d
            try:
                with self.assertRaises(SystemExit) as cm:
                    lb.bench_cases("sat")
                self.assertIn("make bench", str(cm.exception))
            finally:
                lb.ROOT = old


class Stats(unittest.TestCase):
    def test_gmean(self):
        self.assertAlmostEqual(lb.gmean([2.0, 0.5]), 1.0)

    def test_gmean_ignores_nonpositive(self):
        self.assertAlmostEqual(lb.gmean([4.0, 0.0]), 4.0)


class Selection(unittest.TestCase):
    def test_quick_has_one_implementation_per_problem_and_language(self):
        sel = lb.select("quick", langs={"d", "go"})
        pairs = [(lang, s) for _, lang, s in sel]
        self.assertEqual(len(pairs), len(set(pairs)))
        self.assertEqual({lang for lang, _ in pairs}, {"d", "go"})

    def test_explicit_roots_take_every_implementation_there(self):
        sel = lb.select("quick", roots=["implementations/rep2"])
        self.assertTrue(sel)
        self.assertTrue(all(root == "implementations/rep2" for root, _, _ in sel))

    def test_every_suite_root_exists(self):
        for name, spec in lb.SUITES.items():
            for root in spec["roots"]:
                self.assertTrue(os.path.isdir(os.path.join(lb.ROOT, root)), f"{name}: {root}")

    def test_core_suites_cover_every_language(self):
        for name in ("fast", "quick", "all"):
            self.assertEqual(lb.SUITES[name]["langs"], lb.LANGS, name)

    def test_fast_uses_each_problems_first_input(self):
        need_bench(self, "toml")
        _, cases = lb.bench_cases("toml")
        self.assertEqual(lb.suite_cases("fast", "toml"), cases[:1])

    def test_quick_keeps_every_input(self):
        need_bench(self, "toml")
        self.assertEqual(len(lb.suite_cases("quick", "toml", "short")), 3)

    def test_run_defaults(self):
        self.assertEqual(lb.run_defaults("fast"), {"reps": 1, "warmup": False})
        self.assertEqual(lb.run_defaults("quick"), {"reps": 3, "warmup": True})


    def test_problem_filter(self):
        sel = lb.select("all", problems={"toml"})
        self.assertTrue(sel and all(s == "toml" for _, _, s in sel))


class Toolchains(unittest.TestCase):
    def test_parse_toolchain_arguments(self):
        self.assertEqual(lb.parse_toolchains(["d=ldc2", "go=/x/go"]), {"d": "ldc2", "go": "/x/go"})

    def test_parse_rejects_unknown_language_and_bad_syntax(self):
        with self.assertRaises(SystemExit):
            lb.parse_toolchains(["java=/x/javac"])
        with self.assertRaises(SystemExit):
            lb.parse_toolchains(["ldc2"])

    def _env(self, lang, tc=None):
        import shutil
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        return d, lb.build_env(lang, tc, os.path.join(d, "wrap"), os.path.join(d, "log"), os.path.join(d, "dst"))

    def test_cpp_compiles_through_a_counting_wrapper(self):
        d, env = self._env("cpp", {"path": "/usr/bin/clang++", "flags": ["-O3"]})
        self.assertTrue(env["CXX"].startswith(os.path.join(d, "wrap")))
        self.assertIn("/usr/bin/clang++", open(env["CXX"]).read())
        self.assertEqual(env["CXXFLAGS"], "-O3")

    def test_rust_uses_rustc_wrapper_and_rustflags(self):
        d, env = self._env("rust", {"path": "/opt/rust/bin/rustc", "flags": ["-C", "target-cpu=native"]})
        self.assertIn("/opt/rust/bin/rustc", open(env["RUSTC"]).read())
        self.assertEqual(env["RUSTFLAGS"], "-C target-cpu=native")

    def test_go_counts_via_toolexec_with_a_per_tag_cache(self):
        # One cache per tag, warmed with the standard library before the builds, so each build
        # compiles only its own packages, as C++, Rust and D builds do.
        d, env = self._env("go", {"path": "/opt/go/bin/go", "flags": []})
        self.assertIn("-toolexec=", env["GOFLAGS"])
        self.assertTrue(env["GOCACHE"].startswith(os.path.join(d, "wrap")))
        self.assertTrue(env["PATH"].startswith("/opt/go/bin" + os.pathsep))

    def test_clang_compiles_in_process_so_counters_see_it(self):
        # Apple clang runs its compile stage as a child process, which per-process counters miss.
        d, env = self._env("cpp", {"path": "/usr/bin/clang++", "version": "Apple clang version 21", "flags": []})
        self.assertIn("-fintegrated-cc1", open(env["CXX"]).read())

    def test_other_cpp_compilers_get_no_clang_flag(self):
        d, env = self._env("cpp", {"path": "/usr/bin/g++", "version": "g++ (GCC) 15.1.0", "flags": []})
        self.assertNotIn("-fintegrated-cc1", open(env["CXX"]).read())

    def test_python_interpreter_goes_first_on_path(self):
        d, env = self._env("python", {"path": sys.executable, "flags": []})
        first = env["PATH"].split(os.pathsep)[0]
        self.assertEqual(os.path.realpath(os.path.join(first, "python3")), os.path.realpath(sys.executable))

    def test_d_compiler_named_in_build_script(self):
        self.assertEqual(lb.d_compiler_in("dub build -b release --compiler=ldc2\n"), "ldc2")
        self.assertEqual(lb.d_compiler_in("ldc2 -O3 app.d -of=app\n"), "ldc2")
        self.assertIsNone(lb.d_compiler_in("go build ./...\n"))


if __name__ == "__main__":
    unittest.main()
