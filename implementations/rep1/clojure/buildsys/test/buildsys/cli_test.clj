(ns buildsys.cli-test
  (:require [buildsys.main :as main]
            [buildsys.test-util :as u]
            [clojure.string :as str]
            [clojure.test :refer [deftest is]])
  (:import (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(def ^:private tmp u/tmp-dir)

(deftest runs-a-session-directory
  (let [in (tmp "kiln-in") out (tmp "kiln-out")]
    (spit (str in "/main.kiln")
          "step {\n out \"out/a.txt\"\n cmd write(\"A\\n\")\n}\ndefault \"out/a.txt\"\n")
    (spit (str in "/session.txt") "build\nbuild\n")
    (main/run-session! in out)
    (is (= (str "step 1: build (default) -j 1\n  run 0 1 w0 out/a.txt write(\"A\\n\")\n"
                "  ok ran=1 hit=0 time=1\n"
                "step 2: build (default) -j 1\n  hit 0 out/a.txt\n  ok ran=0 hit=1 time=0\n")
           (slurp (str out "/log.txt"))))
    (is (= "A\n" (slurp (str out "/workspace/out/a.txt"))))
    (is (str/starts-with? (slurp (str out "/workspace/.kiln-state")) "kiln-state 1\n"))
    (is (not (.exists (java.io.File. (str out "/workspace/session.txt")))))))
