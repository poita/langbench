//! The worked examples of the specification, run through the public API.

use buildsys::{parse_session, run_session, Workspace};

fn run(files: &[(&str, &str)], script: &str) -> (String, Workspace) {
    let mut ws = Workspace::new();
    for (p, c) in files {
        ws.write(p.as_bytes(), c.as_bytes().to_vec());
    }
    let log = run_session(&mut ws, &parse_session(script.as_bytes()));
    (String::from_utf8(log).expect("log is UTF-8"), ws)
}

fn file(ws: &Workspace, path: &str) -> String {
    String::from_utf8_lossy(ws.get(path.as_bytes()).unwrap_or_else(|| panic!("missing {path}")).content.as_slice())
        .into_owned()
}

fn paths(ws: &Workspace) -> Vec<String> {
    ws.paths().map(|p| String::from_utf8_lossy(p).into_owned()).collect()
}

const HELLO: &str = "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n";

#[test]
fn example_1_one_step() {
    let (log, ws) = run(&[("main.kiln", HELLO)], "build\n");
    assert_eq!(log, "step 1: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n");
    assert_eq!(file(&ws, "out/hello.txt"), "hello\n");
    assert_eq!(
        file(&ws, ".kiln-state"),
        "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\nout out/hello.txt a9bc80cca21f28b3\nend\n"
    );
}

#[test]
fn example_2_hit_and_touch() {
    let (log, _) = run(&[("main.kiln", HELLO)], "build\nbuild\ntouch main.kiln\nbuild\n");
    let expected = "\
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write(\"hello\\n\")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
step 3: touch main.kiln
  ok
step 4: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
";
    assert_eq!(log, expected);
}

#[test]
fn example_3_parallel_scheduling() {
    let main = "\
step {
    out \"out/a.txt\"
    cmd write(\"A\\n\")
    cost 3
}
step {
    out \"out/b.txt\"
    cmd write(\"B\\n\")
    cost 1
}
step {
    out \"out/c.txt\"
    cmd write(\"C\\n\")
    cost 4
}
step {
    out \"out/d.txt\"
    cmd write(\"D\\n\")
    cost 2
}
step {
    out \"out/all.txt\"
    in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]
    cmd concat()
    cost 2
}
default \"out/all.txt\"
";
    let (log, ws) = run(&[("main.kiln", main)], "build -j 2\n");
    let expected = "\
step 1: build (default) -j 2
  run 0 3 w0 out/a.txt write(\"A\\n\")
  run 0 1 w1 out/b.txt write(\"B\\n\")
  run 1 5 w1 out/c.txt write(\"C\\n\")
  run 3 5 w0 out/d.txt write(\"D\\n\")
  run 5 7 w0 out/all.txt concat()
  ok ran=5 hit=0 time=7
";
    assert_eq!(log, expected);
    assert_eq!(file(&ws, "out/all.txt"), "A\nB\nC\nD\n");
}

#[test]
fn example_4_variables_each_map_phony() {
    let main = "\
let names = [\"alpha\", \"beta\", \"gamma\"]
let outs = map(names, \"out/%.txt\")
each i, n in names {
    step {
        out \"out/{n}.txt\"
        cmd write(\"{i}:{n}\\n\")
        cost 1
    }
}
step {
    out \"out/index.txt\"
    in outs
    cmd concat()
}
phony all = [\"out/index.txt\"]
default \"@all\"
";
    let (log, ws) = run(&[("main.kiln", main)], "build @all -j 3\n");
    let expected = "\
step 1: build @all -j 3
  run 0 1 w0 out/alpha.txt write(\"0:alpha\\n\")
  run 0 1 w1 out/beta.txt write(\"1:beta\\n\")
  run 0 1 w2 out/gamma.txt write(\"2:gamma\\n\")
  run 1 3 w0 out/index.txt concat()
  ok ran=4 hit=0 time=3
";
    assert_eq!(log, expected);
    assert_eq!(file(&ws, "out/index.txt"), "0:alpha\n1:beta\n2:gamma\n");
}

#[test]
fn example_5_rules_and_chain() {
    let main = "\
rule bundle(name, parts, weight = 2) {
    step {
        out \"out/{name}.txt\"
        in parts
        cmd concat()
        cost weight
    }
}

let base = [\"src/a.txt\", \"src/b.txt\"]
use bundle(\"one\", base)
use bundle(name = \"two\", parts = base ++ [\"out/one.txt\"], weight = 5)
phony all = [\"out/one.txt\", \"out/two.txt\"]
default \"@all\"
";
    let (log, ws) = run(&[("main.kiln", main), ("src/a.txt", "AAA\n"), ("src/b.txt", "BBB\n")], "build -j 2\n");
    let expected = "\
step 1: build (default) -j 2
  run 0 2 w0 out/one.txt concat()
  run 2 7 w0 out/two.txt concat()
  ok ran=2 hit=0 time=7
";
    assert_eq!(log, expected);
    let state = "\
kiln-state 1
step out/one.txt
cmd concat()
in src/a.txt 8943a78b9f342c58
in src/b.txt c857dca71c36fafd
out out/one.txt 5e52e06e8b405ae8
end
step out/two.txt
cmd concat()
in src/a.txt 8943a78b9f342c58
in src/b.txt c857dca71c36fafd
in out/one.txt 5e52e06e8b405ae8
out out/two.txt f98ee131e7582add
end
";
    assert_eq!(file(&ws, ".kiln-state"), state);
}

#[test]
fn example_6_glob_include_set_when() {
    let main = "\
let mode = \"fast\"
let flags = []
include \"tune.kiln\"
when mode == \"fast\" {
    set flags = flags ++ [\"F\"]
} otherwise {
    set flags = flags ++ [\"S\"]
}
let srcs = glob(\"src/**/*.txt\")
step {
    out \"out/list.txt\"
    in srcs
    cmd count_lines()
}
step {
    out \"out/flags.txt\"
    cmd write(\"{join(flags, \",\")}\\n\")
}
default [\"out/list.txt\", \"out/flags.txt\"]
";
    let files = [
        ("main.kiln", main),
        ("tune.kiln", "set mode = \"slow\"\nlet extra = 1\n"),
        ("src/a.txt", "a1\n"),
        ("src/b.txt", "b1\n"),
        ("src/sub/c.txt", "c1\n"),
        ("src/notes.md", "note\n"),
    ];
    let (log, ws) = run(&files, "build -j 2\n");
    let expected = "\
step 1: build (default) -j 2
  run 0 2 w0 out/list.txt count_lines()
  run 0 1 w1 out/flags.txt write(\"S\\n\")
  ok ran=2 hit=0 time=2
";
    assert_eq!(log, expected);
    assert_eq!(file(&ws, "out/list.txt"), "1 src/a.txt\n1 src/b.txt\n1 src/sub/c.txt\n3 total\n");
}

#[test]
fn example_7_preprocess_and_depfiles() {
    let main = "step {\n    out \"out/doc.txt\"\n    depfile \"out/doc.d\"\n    in \"src/main.txt\"\n    cmd preprocess()\n}\ndefault \"out/doc.txt\"\n";
    let files = [
        ("main.kiln", main),
        ("src/main.txt", "title\n@need src/part.txt\nend\n"),
        ("src/part.txt", "PART-A\n@need src/deep.txt\n"),
        ("src/deep.txt", "DEEP\n"),
    ];
    let script = "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild\n";
    let (log, ws) = run(&files, script);
    let expected = "\
step 1: build (default) -j 1
  run 0 6 w0 out/doc.txt preprocess()
  ok ran=1 hit=0 time=6
step 2: build (default) -j 1
  hit 0 out/doc.txt
  ok ran=0 hit=1 time=0
step 3: edit src/deep.txt
  ok size=6
step 4: build (default) -j 1
  run 0 6 w0 out/doc.txt preprocess()
  ok ran=1 hit=0 time=6
";
    assert_eq!(log, expected);
    assert_eq!(file(&ws, "out/doc.txt"), "title\nPART-A\nDEEP2\nend\n");
    assert_eq!(file(&ws, "out/doc.d"), "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");
    let state = "\
kiln-state 1
step out/doc.txt
cmd preprocess()
in src/main.txt 993a20756b253540
dep src/deep.txt 06ae7bdd484568d7
dep src/part.txt a8442a790131f243
out out/doc.txt f755eb555e1be12f
out out/doc.d ea603661a409bc02
end
";
    assert_eq!(file(&ws, ".kiln-state"), state);
}

#[test]
fn example_8_early_cutoff() {
    let main = "step {\n    out \"out/mid.txt\"\n    in \"src/a.txt\"\n    cmd upper()\n}\nstep {\n    out \"out/final.txt\"\n    in \"out/mid.txt\"\n    cmd number()\n}\ndefault \"out/final.txt\"\n";
    let (log, ws) = run(&[("main.kiln", main), ("src/a.txt", "abc\n")], "build\nedit src/a.txt\nABC\n---\nbuild\n");
    let expected = "\
step 1: build (default) -j 1
  run 0 2 w0 out/mid.txt upper()
  run 2 4 w0 out/final.txt number()
  ok ran=2 hit=0 time=4
step 2: edit src/a.txt
  ok size=4
step 3: build (default) -j 1
  run 0 2 w0 out/mid.txt upper()
  hit 2 out/final.txt
  ok ran=1 hit=1 time=2
";
    assert_eq!(log, expected);
    assert_eq!(file(&ws, "out/final.txt"), "1: ABC\n");
}

#[test]
fn example_9_cycle_leaves_workspace_untouched() {
    let main = "step {\n    out \"out/x.txt\"\n    in \"out/y.txt\"\n    cmd copy()\n}\nstep {\n    out \"out/y.txt\"\n    in \"out/x.txt\"\n    cmd copy()\n}\ndefault \"out/x.txt\"\n";
    let (log, ws) = run(&[("main.kiln", main)], "build\n");
    assert_eq!(log, "step 1: build (default) -j 1\n  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt\n");
    assert_eq!(paths(&ws), vec!["main.kiln"]);
}

#[test]
fn example_10_configuration_errors() {
    let cases: [(&str, &str, &str); 5] = [
        (
            "step {\n    out \"out/z.txt\"\n    cmd write(\"1\\n\")\n}\nstep {\n    out \"out/z.txt\"\n    cmd write(\"2\\n\")\n}\ndefault \"out/z.txt\"\n",
            "",
            "E_DUP_OUTPUT out/z.txt",
        ),
        (
            "step {\n    out \"out/z.txt\"\n    in [\"src/a.txt\", \"src/missing.txt\"]\n    cmd concat()\n}\ndefault \"out/z.txt\"\n",
            "a\n",
            "E_MISSING_INPUT src/missing.txt required by out/z.txt",
        ),
        ("step {\n    out \"out/z.txt\"\n    cmd write(greeting)\n}\ndefault \"out/z.txt\"\n", "", "E_UNKNOWN_VAR greeting"),
        ("let n = 3\nwhen n > 2 {\n    abort \"n too large: {n}\"\n}\n", "", "E_ABORT n too large: 3"),
        ("step {\n    out \"out/z.txt\"\n    cmd write(\"ok\\n\")\n}\n", "", "E_NO_DEFAULT"),
    ];
    for (main, src, err) in cases {
        let (log, _) = run(&[("main.kiln", main), ("src/a.txt", src)], "build\n");
        assert_eq!(log, format!("step 1: build (default) -j 1\n  error {err}\n"));
    }
}

#[test]
fn example_11_clean() {
    let (log, _) = run(&[("main.kiln", HELLO)], "build\nclean\nbuild\n");
    let expected = "\
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write(\"hello\\n\")
  ok ran=1 hit=0 time=1
step 2: clean
  remove .kiln-state
  remove out/hello.txt
  ok removed=2
step 3: build (default) -j 1
  run 0 1 w0 out/hello.txt write(\"hello\\n\")
  ok ran=1 hit=0 time=1
";
    assert_eq!(log, expected);
}

#[test]
fn example_12_execution_error_cancels_work() {
    let main = "\
step {
    out \"out/doc.txt\"
    depfile \"out/doc.d\"
    in \"src/main.txt\"
    cmd preprocess()
}
step {
    out \"out/slow.txt\"
    cmd write(\"slow\\n\")
    cost 10
}
step {
    out \"out/after.txt\"
    in \"out/doc.txt\"
    cmd copy()
}
phony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]
default \"@all\"
";
    let (log, ws) = run(&[("main.kiln", main), ("src/main.txt", "@need src/gone.txt\n")], "build -j 2\n");
    let expected = "\
step 1: build (default) -j 2
  fail 0 6 w0 out/doc.txt preprocess()
  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")
  error E_NEED_MISSING src/gone.txt needed by src/main.txt
";
    assert_eq!(log, expected);
    assert_eq!(file(&ws, ".kiln-state"), "kiln-state 1\n");
    assert!(!ws.contains(b"out/slow.txt"));
}

#[test]
fn example_13_after_is_order_only() {
    let main = "step {\n    out \"out/gen.txt\"\n    in \"src/a.txt\"\n    cmd copy()\n}\nstep {\n    out \"out/rep.txt\"\n    after \"out/gen.txt\"\n    cmd write(\"report\\n\")\n}\nphony all = [\"out/rep.txt\"]\ndefault \"@all\"\n";
    let (log, ws) = run(&[("main.kiln", main), ("src/a.txt", "a\n")], "build\nedit src/a.txt\nb\n---\nbuild\n");
    let expected = "\
step 1: build (default) -j 1
  run 0 1 w0 out/gen.txt copy()
  run 1 2 w0 out/rep.txt write(\"report\\n\")
  ok ran=2 hit=0 time=2
step 2: edit src/a.txt
  ok size=2
step 3: build (default) -j 1
  run 0 1 w0 out/gen.txt copy()
  hit 1 out/rep.txt
  ok ran=1 hit=1 time=1
";
    assert_eq!(log, expected);
    assert!(file(&ws, ".kiln-state").contains("out out/rep.txt 11aab68ba3164db3\n"));
}

#[test]
fn example_14_cost_is_not_a_change_but_input_order_is() {
    let v1 = "step {\n    out \"out/j.txt\"\n    in [\"src/a.txt\", \"src/b.txt\"]\n    cmd concat()\n}\ndefault \"out/j.txt\"\n";
    let script = "build\nedit main.kiln\nstep {\n    out \"out/j.txt\"\n    in [\"src/a.txt\", \"src/b.txt\"]\n    cmd concat()\n    cost 5\n}\ndefault \"out/j.txt\"\n---\nbuild\nedit main.kiln\nstep {\n    out \"out/j.txt\"\n    in [\"src/b.txt\", \"src/a.txt\"]\n    cmd concat()\n    cost 5\n}\ndefault \"out/j.txt\"\n---\nbuild\n";
    let (log, ws) = run(&[("main.kiln", v1), ("src/a.txt", "a\n"), ("src/b.txt", "a\n")], script);
    let expected = "\
step 1: build (default) -j 1
  run 0 2 w0 out/j.txt concat()
  ok ran=1 hit=0 time=2
step 2: edit main.kiln
  ok size=111
step 3: build (default) -j 1
  hit 0 out/j.txt
  ok ran=0 hit=1 time=0
step 4: edit main.kiln
  ok size=111
step 5: build (default) -j 1
  run 0 5 w0 out/j.txt concat()
  ok ran=1 hit=0 time=5
";
    assert_eq!(log, expected);
    assert!(file(&ws, ".kiln-state").contains("in src/b.txt 089bdc07b544e7b2\nin src/a.txt 089bdc07b544e7b2\n"));
}

#[test]
fn example_15_tampered_and_deleted_outputs_rebuild() {
    let script = "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild\n";
    let (log, _) = run(&[("main.kiln", HELLO)], script);
    assert_eq!(log.matches("  run 0 1 w0 out/hello.txt").count(), 3);
    assert!(!log.contains("  hit "));
}

#[test]
fn corrupt_state_means_rebuild_everything() {
    let script = "build\nedit .kiln-state\nkiln-state 1\ngarbage\n---\nbuild\n";
    let (log, ws) = run(&[("main.kiln", HELLO)], script);
    assert_eq!(log.matches("  run 0 1 w0 out/hello.txt").count(), 2);
    assert!(file(&ws, ".kiln-state").starts_with("kiln-state 1\nstep out/hello.txt\n"));
}

#[test]
fn state_for_unreachable_steps_is_preserved() {
    let main = "step {\n out \"out/a\"\n cmd write(\"a\")\n}\nstep {\n out \"out/b\"\n cmd write(\"b\")\n}\n";
    let (log, ws) = run(&[("main.kiln", main)], "build out/a\nbuild out/b\nbuild out/a out/b\n");
    assert!(log.ends_with("  hit 0 out/a\n  hit 0 out/b\n  ok ran=0 hit=2 time=0\n"));
    assert_eq!(file(&ws, ".kiln-state").matches("\nstep ").count(), 2);
}

#[test]
fn missing_build_file_is_an_error() {
    let (log, _) = run(&[], "build\n");
    assert_eq!(log, "step 1: build (default) -j 1\n  error E_NO_BUILD_FILE main.kiln\n");
}

#[test]
fn readme_library_example() {
    use buildsys::build;
    let mut ws = Workspace::new();
    ws.write(b"main.kiln", HELLO.as_bytes().to_vec());
    let log = run_session(&mut ws, &parse_session(b"build\nbuild\n"));
    assert!(String::from_utf8(log).unwrap().contains("hit 0 out/hello.txt"));
    let report = build(&mut ws, &[b"out/hello.txt".to_vec()], 4);
    let summary = report.result.unwrap();
    assert_eq!((summary.ran, summary.hits), (0, 1));
}
