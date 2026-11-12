(ns buildsys.state-test
  (:require [buildsys.hash :as hash]
            [buildsys.state :as state]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(def ^:private h "0123456789abcdef")

(def valid
  (str "kiln-state 1\n"
       "step out/a\ncmd copy()\nin src/a " h "\ndep src/d " h "\nout out/a " h "\nend\n"
       "step out/b\ncmd write(\"x\")\nout out/b " h "\nend\n"))

(deftest reads-a-valid-file
  (let [s (state/read-state valid)]
    (is (= ["out/a" "out/b"] (keys s)))
    (is (= {:cmd "copy()" :ins [["src/a" h]] :deps [["src/d" h]] :outs [["out/a" h]]}
           (get s "out/a")))))

(deftest round-trips
  (is (= valid (state/write-state (state/read-state valid))))
  (is (= "kiln-state 1\n" (state/write-state {}))))

(deftest corrupt-files-are-empty
  (doseq [[why text]
          {"no header" "step out/a\n"
           "wrong header" "kiln-state 2\n"
           "no final newline" (subs valid 0 (dec (count valid)))
           "unterminated entry" "kiln-state 1\nstep out/a\ncmd x\nout out/a 0123456789abcdef\n"
           "no out line" "kiln-state 1\nstep out/a\ncmd x\nend\n"
           "no cmd line" "kiln-state 1\nstep out/a\nout out/a 0123456789abcdef\nend\n"
           "two cmd lines" "kiln-state 1\nstep out/a\ncmd x\ncmd y\nout out/a 0123456789abcdef\nend\n"
           "empty cmd" "kiln-state 1\nstep out/a\ncmd \nout out/a 0123456789abcdef\nend\n"
           "misordered sections" "kiln-state 1\nstep out/a\ncmd x\nout out/a 0123456789abcdef\nin s 0123456789abcdef\nend\n"
           "key differs from first out" "kiln-state 1\nstep out/a\ncmd x\nout out/b 0123456789abcdef\nend\n"
           "short hash" "kiln-state 1\nstep out/a\ncmd x\nout out/a 0123\nend\n"
           "upper-case hash" "kiln-state 1\nstep out/a\ncmd x\nout out/a 0123456789ABCDEF\nend\n"
           "bad path" "kiln-state 1\nstep ../a\ncmd x\nout ../a 0123456789abcdef\nend\n"
           "stray line" (str valid "junk\n")
           "duplicate step" (str "kiln-state 1\n"
                                 "step out/a\ncmd x\nout out/a 0123456789abcdef\nend\n"
                                 "step out/a\ncmd x\nout out/a 0123456789abcdef\nend\n")}]
    (is (= {} (state/read-state text)) why))
  (is (= {} (state/read-state nil))))

(deftest reading-imposes-no-order-within-a-section
  (let [text (str "kiln-state 1\nstep out/a\ncmd x\ndep z " h "\ndep b " h "\ndep b " h
                  "\nout out/a " h "\nend\n")]
    (is (= ["z" "b" "b"] (map first (:deps (get (state/read-state text) "out/a")))))))

(deftest freshness
  (let [vfs (-> (sorted-map) (buildsys.vfs/write "in" "x") (buildsys.vfs/write "out/o" "y"))
        step {:primary "out/o" :canon "copy()" :full-outs ["out/o"] :file-ins ["in"]}
        entry {:cmd "copy()" :ins [["in" (hash/hash-hex "x")]] :deps []
               :outs [["out/o" (hash/hash-hex "y")]]}
        fresh? (fn [e v s] (state/fresh? {"out/o" e} v s))]
    (is (fresh? entry vfs step))
    (testing "each of the seven staleness rules"
      (is (not (state/fresh? {} vfs step)))
      (is (not (fresh? (assoc entry :cmd "copy2()") vfs step)))
      (is (not (fresh? (assoc entry :outs [["out/o" (hash/hash-hex "y")] ["out/p" h]]) vfs step)))
      (is (not (fresh? entry vfs (assoc step :file-ins ["in" "in"]))))
      (is (not (fresh? entry (buildsys.vfs/write vfs "in" "z") step)))
      (is (not (fresh? (assoc entry :deps [["dep" h]]) vfs step)))
      (is (not (fresh? entry (buildsys.vfs/delete vfs "out/o") step))))))

(defspec write-then-read-round-trips 100
  (let [path (gen/fmap #(str "out/" %) (gen/not-empty gen/string-alphanumeric))
        hex (gen/fmap #(hash/hex %) (gen/choose -1000000 1000000))
        pair (gen/tuple (gen/fmap #(str "src/" %) (gen/not-empty gen/string-alphanumeric)) hex)
        entry (gen/fmap (fn [[p cmd ins deps outs]]
                          [p {:cmd cmd :ins ins :deps deps :outs (into [[p h]] outs)}])
                        (gen/tuple path (gen/not-empty gen/string-alphanumeric)
                                   (gen/vector pair 0 3) (gen/vector pair 0 3)
                                   (gen/vector (gen/tuple path hex) 0 2)))]
    (prop/for-all [entries (gen/fmap #(into (sorted-map) %) (gen/vector entry 0 5))]
      (= entries (state/read-state (state/write-state entries))))))
