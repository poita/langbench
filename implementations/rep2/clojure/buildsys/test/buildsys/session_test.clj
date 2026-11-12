(ns buildsys.session-test
  "End-to-end sessions, mostly the worked examples of the specification."
  (:require [buildsys.core :as kiln]
            [buildsys.session :as session]
            [buildsys.test-util :refer [lines session-log]]
            [clojure.test :refer [deftest is testing]]))

(def hello
  (lines "step {" "    out \"out/hello.txt\"" "    cmd write(\"hello\\n\")" "}" "default \"out/hello.txt\""))

(deftest session-parsing
  (is (= [{:op :build :targets ["@all" "x"] :jobs 4}
          {:op :build :targets ["-j"] :jobs 1}
          {:op :create :path "a" :content "l1\n\n  # not a comment\n"}
          {:op :clean}]
         (session/parse (lines "# comment" "" "  build @all x -j 4" "build -j"
                               "create a" "l1" "" "  # not a comment" "---" "clean")))))

(deftest example-1-one-step-and-state
  (let [r (kiln/run-session {"main.kiln" hello} "build\n")]
    (is (= (lines "step 1: build (default) -j 1"
                  "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                  "  ok ran=1 hit=0 time=1")
           (:log r)))
    (is (= "hello\n" (kiln/file-text (:files r) "out/hello.txt")))
    (is (= (lines "kiln-state 1" "step out/hello.txt" "cmd write(\"hello\\n\")"
                  "out out/hello.txt a9bc80cca21f28b3" "end")
           (kiln/file-text (:files r) ".kiln-state")))))

(deftest example-2-and-11-hits-touch-and-clean
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
                "  ok ran=0 hit=1 time=0"
                "step 5: clean"
                "  remove .kiln-state"
                "  remove out/hello.txt"
                "  ok removed=2")
         (session-log {"main.kiln" hello} (lines "build" "build" "touch main.kiln" "build" "clean")))))

(deftest example-3-parallel-scheduling
  (let [main (lines "step {" "out \"out/a.txt\"" "cmd write(\"A\\n\")" "cost 3" "}"
                    "step {" "out \"out/b.txt\"" "cmd write(\"B\\n\")" "cost 1" "}"
                    "step {" "out \"out/c.txt\"" "cmd write(\"C\\n\")" "cost 4" "}"
                    "step {" "out \"out/d.txt\"" "cmd write(\"D\\n\")" "cost 2" "}"
                    "step {" "out \"out/all.txt\"" "in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]"
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

(deftest example-7-preprocess-and-discovered-dependencies
  (let [files {"main.kiln" (lines "step {" "out \"out/doc.txt\"" "depfile \"out/doc.d\""
                                  "in \"src/main.txt\"" "cmd preprocess()" "}" "default \"out/doc.txt\"")
               "src/main.txt" "title\n@need src/part.txt\nend\n"
               "src/part.txt" "PART-A\n@need src/deep.txt\n"
               "src/deep.txt" "DEEP\n"}
        r (kiln/run-session files (lines "build" "build" "edit src/deep.txt" "DEEP2" "---" "build"))]
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
    (is (= "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n" (kiln/file-text (:files r) "out/doc.d")))))

(deftest example-8-early-cutoff
  (let [files {"main.kiln" (lines "step {" "out \"out/mid.txt\"" "in \"src/a.txt\"" "cmd upper()" "}"
                                  "step {" "out \"out/final.txt\"" "in \"out/mid.txt\"" "cmd number()" "}"
                                  "default \"out/final.txt\"")
               "src/a.txt" "abc\n"}]
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
           (session-log files (lines "build" "edit src/a.txt" "ABC" "---" "build"))))))

(deftest example-9-cycle-leaves-workspace-untouched
  (let [files {"main.kiln" (lines "step {" "out \"out/x.txt\"" "in \"out/y.txt\"" "cmd copy()" "}"
                                  "step {" "out \"out/y.txt\"" "in \"out/x.txt\"" "cmd copy()" "}"
                                  "default \"out/x.txt\"")}
        r (kiln/run-session files "build\n")]
    (is (= (lines "step 1: build (default) -j 1"
                  "  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt")
           (:log r)))
    (is (= ["main.kiln"] (keys (:files r))))))

(deftest example-12-failure-cancels-work-in-flight
  (let [files {"main.kiln" (lines "step {" "out \"out/doc.txt\"" "depfile \"out/doc.d\"" "in \"src/main.txt\"" "cmd preprocess()" "}"
                                  "step {" "out \"out/slow.txt\"" "cmd write(\"slow\\n\")" "cost 10" "}"
                                  "step {" "out \"out/after.txt\"" "in \"out/doc.txt\"" "cmd copy()" "}"
                                  "phony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]"
                                  "default \"@all\"")
               "src/main.txt" "@need src/gone.txt\n"}
        r (kiln/run-session files "build -j 2\n")]
    (is (= (lines "step 1: build (default) -j 2"
                  "  fail 0 6 w0 out/doc.txt preprocess()"
                  "  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")"
                  "  error E_NEED_MISSING src/gone.txt needed by src/main.txt")
           (:log r)))
    (is (= "kiln-state 1\n" (kiln/file-text (:files r) ".kiln-state")))
    (is (not-any? #(.startsWith ^String % "out/") (keys (:files r))))))

(deftest example-14-cost-is-not-a-change-but-the-dependency-set-is
  (let [step (fn [ins cost]
               (lines "step {" "    out \"out/j.txt\"" (str "    in " ins) "    cmd concat()"
                      (if cost "    cost 5" "") "}" "default \"out/j.txt\""))
        files {"main.kiln" (step "[\"src/a.txt\", \"src/b.txt\"]" false) "src/a.txt" "a\n" "src/b.txt" "a\n"}
        edit (fn [text] (str "edit main.kiln\n" text "---\nbuild\n"))]
    (is (= (lines "step 1: build (default) -j 1"
                  "  run 0 2 w0 out/j.txt concat()"
                  "  ok ran=1 hit=0 time=2"
                  "step 2: edit main.kiln"
                  "  ok size=111"
                  "step 3: build (default) -j 1"
                  "  hit 0 out/j.txt"
                  "  ok ran=0 hit=1 time=0"
                  "step 4: edit main.kiln"
                  "  ok size=111"
                  "step 5: build (default) -j 1"
                  "  run 0 5 w0 out/j.txt concat()"
                  "  ok ran=1 hit=0 time=5")
           (session-log files (str "build\n"
                                   (edit (step "[\"src/a.txt\", \"src/b.txt\"]" true))
                                   (edit (step "[\"src/b.txt\", \"src/a.txt\"]" true))))))))

(deftest tampering-with-an-output-makes-its-step-stale
  (is (= (lines "step 1: build (default) -j 1"
                "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                "  ok ran=1 hit=0 time=1"
                "step 2: edit out/hello.txt"
                "  ok size=9"
                "step 3: build (default) -j 1"
                "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                "  ok ran=1 hit=0 time=1"
                "step 4: delete out/hello.txt"
                "  ok"
                "step 5: build (default) -j 1"
                "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                "  ok ran=1 hit=0 time=1")
         (session-log {"main.kiln" hello}
                      (lines "build" "edit out/hello.txt" "tampered" "---" "build" "delete out/hello.txt" "build")))))

(deftest configuration-errors
  (let [err (fn [main] (:error (kiln/build {"main.kiln" main})))]
    (is (= "E_NO_DEFAULT" (err (lines "step {" "out \"out/z.txt\"" "cmd write(\"ok\\n\")" "}"))))
    (is (= "E_DUP_OUTPUT out/z.txt"
           (err (lines "step {" "out \"out/z.txt\"" "cmd write(\"1\")" "}"
                       "step {" "out \"out/z.txt\"" "cmd write(\"2\")" "}" "default \"out/z.txt\""))))
    (is (= "E_MISSING_INPUT src/missing.txt required by out/z.txt"
           (err (lines "step {" "out \"out/z.txt\"" "in \"src/missing.txt\"" "cmd copy()" "}" "default \"out/z.txt\""))))
    (is (= "E_ABORT n too large: 3" (err (lines "let n = 3" "when n > 2 {" "abort \"n too large: {n}\"" "}"))))
    (is (= "E_OUTPUT_PATH src/z.txt" (err (lines "step {" "out \"src/z.txt\"" "cmd write(\"\")" "}"))))
    (is (= "E_NO_BUILD_FILE main.kiln" (:error (kiln/build {"x" "y"}))))))

(deftest library-api
  (let [r (kiln/build {"main.kiln" hello "src/unused" "x"} :jobs 2)]
    (is (:ok? r))
    (is (= [:run] (map :kind (:events r))))
    (is (= {:ran 1 :hits 0 :time 1} (select-keys r [:ran :hits :time])))
    (is (= "hello\n" (kiln/file-text (:files r) "out/hello.txt"))))
  (testing "explicit targets"
    (let [r (kiln/build {"main.kiln" hello} :targets ["out/hello.txt"])]
      (is (:ok? r)))
    (is (= "E_UNKNOWN_TARGET nope" (:error (kiln/build {"main.kiln" hello} :targets ["nope"]))))))
