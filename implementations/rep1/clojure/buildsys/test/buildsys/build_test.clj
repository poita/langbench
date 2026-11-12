(ns buildsys.build-test
  "End-to-end tests of builds and sessions, including the worked examples of
  the specification."
  (:require [buildsys.core :as kiln]
            [buildsys.test-util :as u :refer [build-error session-log]]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]))

(defn lines [& ls] (str (str/join "\n" ls) "\n"))

(def hello
  (lines "step {" "    out \"out/hello.txt\"" "    cmd write(\"hello\\n\")" "}"
         "default \"out/hello.txt\""))

(defn- session
  "Run `session-text` over `files`; returns `{:log ... :files {...}}`."
  [files session-text]
  (let [r (kiln/run-session (u/ws files) session-text)]
    {:log (:log r) :files (kiln/files (:workspace r))}))

(deftest example-1-one-step
  (let [r (session {"main.kiln" hello} "build\n")]
    (is (= (lines "step 1: build (default) -j 1"
                  "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                  "  ok ran=1 hit=0 time=1")
           (:log r)))
    (is (= "hello\n" (get-in r [:files "out/hello.txt"])))
    (is (= (lines "kiln-state 1" "step out/hello.txt" "cmd write(\"hello\\n\")"
                  "out out/hello.txt a9bc80cca21f28b3" "end")
           (get-in r [:files ".kiln-state"])))))

(deftest example-2-touch-is-not-a-change
  (is (= (lines "step 1: build (default) -j 1"
                "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                "  ok ran=1 hit=0 time=1"
                "step 2: build (default) -j 1"
                "  hit 0 out/hello.txt"
                "  ok ran=0 hit=1 time=0"
                "step 3: touch main.kiln"
                "  ok"
                "step 4: build (default) -j 1"
                "  hit 0 out/hello.txt"
                "  ok ran=0 hit=1 time=0")
         (session-log {"main.kiln" hello} "build\nbuild\ntouch main.kiln\nbuild\n"))))

(deftest example-3-parallel-scheduling
  (let [main (lines "step {" "out \"out/a.txt\"" "cmd write(\"A\\n\")" "cost 3" "}"
                    "step {" "out \"out/b.txt\"" "cmd write(\"B\\n\")" "cost 1" "}"
                    "step {" "out \"out/c.txt\"" "cmd write(\"C\\n\")" "cost 4" "}"
                    "step {" "out \"out/d.txt\"" "cmd write(\"D\\n\")" "cost 2" "}"
                    "step {" "out \"out/all.txt\""
                    "in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]"
                    "cmd concat()" "cost 2" "}"
                    "default \"out/all.txt\"")]
    (is (= (lines "step 1: build (default) -j 2"
                  "  run 0 3 w0 out/a.txt write(\"A\\n\")"
                  "  run 0 1 w1 out/b.txt write(\"B\\n\")"
                  "  run 1 5 w1 out/c.txt write(\"C\\n\")"
                  "  run 3 5 w0 out/d.txt write(\"D\\n\")"
                  "  run 5 7 w0 out/all.txt concat()"
                  "  ok ran=5 hit=0 time=7")
           (session-log {"main.kiln" main} "build -j 2\n")))))

(deftest example-5-rules
  (let [main (lines "rule bundle(name, parts, weight = 2) {"
                    "    step {" "        out \"out/{name}.txt\"" "        in parts"
                    "        cmd concat()" "        cost weight" "    }" "}"
                    "let base = [\"src/a.txt\", \"src/b.txt\"]"
                    "use bundle(\"one\", base)"
                    "use bundle(name = \"two\", parts = base ++ [\"out/one.txt\"], weight = 5)"
                    "phony all = [\"out/one.txt\", \"out/two.txt\"]"
                    "default \"@all\"")
        r (session {"main.kiln" main "src/a.txt" "AAA\n" "src/b.txt" "BBB\n"} "build -j 2\n")]
    (is (= (lines "step 1: build (default) -j 2"
                  "  run 0 2 w0 out/one.txt concat()"
                  "  run 2 7 w0 out/two.txt concat()"
                  "  ok ran=2 hit=0 time=7")
           (:log r)))
    (is (= "AAA\nBBB\nAAA\nBBB\n" (get-in r [:files "out/two.txt"])))
    (is (= (lines "kiln-state 1"
                  "step out/one.txt" "cmd concat()"
                  "in src/a.txt 8943a78b9f342c58" "in src/b.txt c857dca71c36fafd"
                  "out out/one.txt 5e52e06e8b405ae8" "end"
                  "step out/two.txt" "cmd concat()"
                  "in src/a.txt 8943a78b9f342c58" "in src/b.txt c857dca71c36fafd"
                  "in out/one.txt 5e52e06e8b405ae8"
                  "out out/two.txt f98ee131e7582add" "end")
           (get-in r [:files ".kiln-state"])))))

(deftest example-7-preprocess-and-depfiles
  (let [main (lines "step {" "    out \"out/doc.txt\"" "    depfile \"out/doc.d\""
                    "    in \"src/main.txt\"" "    cmd preprocess()" "}"
                    "default \"out/doc.txt\"")
        files {"main.kiln" main
               "src/main.txt" "title\n@need src/part.txt\nend\n"
               "src/part.txt" "PART-A\n@need src/deep.txt\n"
               "src/deep.txt" "DEEP\n"}
        r (session files "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild\n")]
    (is (= (lines "step 1: build (default) -j 1"
                  "  run 0 6 w0 out/doc.txt preprocess()"
                  "  ok ran=1 hit=0 time=6"
                  "step 2: build (default) -j 1"
                  "  hit 0 out/doc.txt"
                  "  ok ran=0 hit=1 time=0"
                  "step 3: edit src/deep.txt"
                  "  ok size=6"
                  "step 4: build (default) -j 1"
                  "  run 0 6 w0 out/doc.txt preprocess()"
                  "  ok ran=1 hit=0 time=6")
           (:log r)))
    (is (= "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n" (get-in r [:files "out/doc.d"])))
    (is (= (lines "kiln-state 1" "step out/doc.txt" "cmd preprocess()"
                  "in src/main.txt 993a20756b253540"
                  "dep src/deep.txt 06ae7bdd484568d7" "dep src/part.txt a8442a790131f243"
                  "out out/doc.txt f755eb555e1be12f" "out out/doc.d ea603661a409bc02" "end")
           (get-in r [:files ".kiln-state"])))))

(deftest example-8-early-cutoff
  (let [main (lines "step {" "out \"out/mid.txt\"" "in \"src/a.txt\"" "cmd upper()" "}"
                    "step {" "out \"out/final.txt\"" "in \"out/mid.txt\"" "cmd number()" "}"
                    "default \"out/final.txt\"")]
    (is (= (lines "step 1: build (default) -j 1"
                  "  run 0 2 w0 out/mid.txt upper()"
                  "  run 2 4 w0 out/final.txt number()"
                  "  ok ran=2 hit=0 time=4"
                  "step 2: edit src/a.txt"
                  "  ok size=4"
                  "step 3: build (default) -j 1"
                  "  run 0 2 w0 out/mid.txt upper()"
                  "  hit 2 out/final.txt"
                  "  ok ran=1 hit=1 time=2")
           (session-log {"main.kiln" main "src/a.txt" "abc\n"} "build\nedit src/a.txt\nABC\n---\nbuild\n")))))

(deftest example-9-cycle
  (let [main (lines "step {" "out \"out/x.txt\"" "in \"out/y.txt\"" "cmd copy()" "}"
                    "step {" "out \"out/y.txt\"" "in \"out/x.txt\"" "cmd copy()" "}"
                    "default \"out/x.txt\"")
        r (session {"main.kiln" main} "build\n")]
    (is (= (lines "step 1: build (default) -j 1"
                  "  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt")
           (:log r)))
    (is (= ["main.kiln"] (keys (:files r))) "a configuration error writes nothing")))

(deftest example-10-configuration-errors
  (let [step (fn [& body] (lines "step {" "out \"out/z.txt\"" (str/join "\n" body) "}"))]
    (is (= "E_DUP_OUTPUT out/z.txt"
           (build-error {"main.kiln" (str (step "cmd write(\"1\\n\")") (step "cmd write(\"2\\n\")")
                                          "default \"out/z.txt\"\n")})))
    (is (= "E_MISSING_INPUT src/missing.txt required by out/z.txt"
           (build-error {"main.kiln" (str (step "in [\"src/a.txt\", \"src/missing.txt\"]" "cmd concat()")
                                          "default \"out/z.txt\"\n")
                         "src/a.txt" "a\n"})))
    (is (= "E_UNKNOWN_VAR greeting"
           (build-error {"main.kiln" (str (step "cmd write(greeting)") "default \"out/z.txt\"\n")})))
    (is (= "E_ABORT n too large: 3"
           (build-error {"main.kiln" "let n = 3\nwhen n > 2 {\n  abort \"n too large: {n}\"\n}\n"})))
    (is (= "E_NO_DEFAULT" (build-error {"main.kiln" (step "cmd write(\"ok\\n\")")})))
    (is (= "E_NO_BUILD_FILE main.kiln" (build-error {"other" "x"})))
    (is (= "E_UNKNOWN_TARGET nope" (build-error {"main.kiln" "default \"nope\"\n"}))
        "the default list is validated even when the build names targets")
    (is (= "E_UNKNOWN_TARGET @x"
           (build-error {"main.kiln" (step "cmd write(\"ok\\n\")")} ["@x"])))))

(deftest example-11-clean
  (is (= (lines "step 1: build (default) -j 1"
                "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                "  ok ran=1 hit=0 time=1"
                "step 2: clean"
                "  remove .kiln-state"
                "  remove out/hello.txt"
                "  ok removed=2"
                "step 3: build (default) -j 1"
                "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                "  ok ran=1 hit=0 time=1")
         (session-log {"main.kiln" hello} "build\nclean\nbuild\n"))))

(deftest example-12-execution-error-cancels-work
  (let [main (lines "step {" "out \"out/doc.txt\"" "depfile \"out/doc.d\"" "in \"src/main.txt\""
                    "cmd preprocess()" "}"
                    "step {" "out \"out/slow.txt\"" "cmd write(\"slow\\n\")" "cost 10" "}"
                    "step {" "out \"out/after.txt\"" "in \"out/doc.txt\"" "cmd copy()" "}"
                    "phony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]"
                    "default \"@all\"")
        r (session {"main.kiln" main "src/main.txt" "@need src/gone.txt\n"} "build -j 2\n")]
    (is (= (lines "step 1: build (default) -j 2"
                  "  fail 0 6 w0 out/doc.txt preprocess()"
                  "  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")"
                  "  error E_NEED_MISSING src/gone.txt needed by src/main.txt")
           (:log r)))
    (is (= "kiln-state 1\n" (get-in r [:files ".kiln-state"])) "the state is still written")
    (is (not-any? #(str/starts-with? % "out/") (keys (:files r))))))

(deftest example-13-after-is-order-only
  (let [main (lines "step {" "out \"out/gen.txt\"" "in \"src/a.txt\"" "cmd copy()" "}"
                    "step {" "out \"out/rep.txt\"" "after \"out/gen.txt\"" "cmd write(\"report\\n\")" "}"
                    "phony all = [\"out/rep.txt\"]" "default \"@all\"")]
    (is (= (lines "step 1: build (default) -j 1"
                  "  run 0 1 w0 out/gen.txt copy()"
                  "  run 1 2 w0 out/rep.txt write(\"report\\n\")"
                  "  ok ran=2 hit=0 time=2"
                  "step 2: edit src/a.txt"
                  "  ok size=2"
                  "step 3: build (default) -j 1"
                  "  run 0 1 w0 out/gen.txt copy()"
                  "  hit 1 out/rep.txt"
                  "  ok ran=1 hit=1 time=1")
           (session-log {"main.kiln" main "src/a.txt" "a\n"} "build\nedit src/a.txt\nb\n---\nbuild\n")))))

(deftest example-14-cost-is-not-a-change-but-the-dependency-set-is
  (let [main (fn [cost ins]
               (lines "step {" "    out \"out/j.txt\"" (str "    in " ins) "    cmd concat()"
                      cost "}" "default \"out/j.txt\""))
        edit (fn [m] (str "edit main.kiln\n" m "---\nbuild\n"))
        s (str "build\n"
               (edit (main "    cost 5" "[\"src/a.txt\", \"src/b.txt\"]"))
               (edit (main "    cost 5" "[\"src/b.txt\", \"src/a.txt\"]")))
        log (session-log {"main.kiln" (main "" "[\"src/a.txt\", \"src/b.txt\"]")
                          "src/a.txt" "a\n" "src/b.txt" "a\n"}
                         s)]
    (is (str/includes? log "step 3: build (default) -j 1\n  hit 0 out/j.txt\n"))
    (is (str/includes? log "step 5: build (default) -j 1\n  run 0 5 w0 out/j.txt concat()\n"))))

(deftest example-15-tampering
  (let [log (session-log {"main.kiln" hello}
                         "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild\n")]
    (is (= 3 (count (re-seq #"run 0 1 w0 out/hello.txt" log))))))

(deftest corrupt-state-forces-a-rebuild
  (let [log (session-log {"main.kiln" hello ".kiln-state" "garbage\n"} "build\nbuild\n")]
    (is (str/includes? log "  run 0 1 w0 out/hello.txt"))
    (is (str/includes? log "  hit 0 out/hello.txt"))))

(deftest state-entries-for-other-steps-are-carried-over
  (let [r (session {"main.kiln" hello
                    ".kiln-state" (lines "kiln-state 1" "step out/old" "cmd write(\"o\")"
                                         "out out/old 0123456789abcdef" "end")}
                   "build\n")]
    (is (str/includes? (get-in r [:files ".kiln-state"]) "step out/old\n"))))

(deftest phony-and-source-nodes
  (testing "unreachable steps never run"
    (let [main (lines "step {" "out \"out/a\"" "cmd write(\"a\")" "}"
                      "step {" "out \"out/b\"" "cmd write(\"b\")" "}"
                      "phony a = [\"out/a\"]" "phony b = [\"out/b\"]")]
      (is (= (lines "step 1: build @a -j 1" "  run 0 1 w0 out/a write(\"a\")" "  ok ran=1 hit=0 time=1")
             (session-log {"main.kiln" main} "build @a\n")))))
  (testing "duplicate request targets are deduplicated"
    (is (str/includes? (session-log {"main.kiln" hello} "build out/hello.txt out/hello.txt -j 3\n")
                       "ok ran=1 hit=0 time=1")))
  (testing "a phony may depend on a phony"
    (let [main (lines "step {" "out \"out/a\"" "cmd write(\"a\")" "}"
                      "phony x = [\"@y\"]" "phony y = [\"out/a\"]")]
      (is (str/includes? (session-log {"main.kiln" main} "build @x\n") "ok ran=1")))))
