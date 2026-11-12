(ns buildsys.state-test
  (:require [buildsys.state :as state]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(def ^:private h1 "a9bc80cca21f28b3")

(def ^:private valid
  (str "kiln-state 1\nstep out/a\ncmd write(\"x y\")\nin src/a " h1 "\ndep src/d " h1
       "\nout out/a " h1 "\nend\n"))

(deftest reads-a-valid-state
  (is (= {"out/a" {:cmd "write(\"x y\")" :in [["src/a" h1]] :dep [["src/d" h1]] :out [["out/a" h1]]}}
         (state/parse valid))))

(deftest render-is-canonical
  (is (= valid (state/render (state/parse valid))))
  (is (= "kiln-state 1\n" (state/render {}))))

(deftest anything-malformed-means-empty
  (doseq [bad ["" "kiln-state 2\n" "kiln-state 1"
               (subs valid 0 (dec (count valid)))                  ; no final newline
               (str "kiln-state 1\nstep out/a\nout out/a " h1 "\nend\n") ; no cmd
               (str "kiln-state 1\nstep out/a\ncmd c\ncmd d\nout out/a " h1 "\nend\n")
               (str "kiln-state 1\nstep out/a\ncmd c\nend\n")      ; no out
               (str "kiln-state 1\nstep out/a\ncmd c\nout out/b " h1 "\nend\n") ; key mismatch
               (str "kiln-state 1\nstep out/a\ncmd c\nout out/a A9BC80CCA21F28B3\nend\n")
               (str "kiln-state 1\nstep out/a\ncmd c\nout out/a " h1 "\nin x " h1 "\nend\n") ; order
               (str "kiln-state 1\nstep out/a\ncmd \nout out/a " h1 "\nend\n")
               (str "kiln-state 1\nstep out/a\ncmd c\nout out/a " h1 "\nend \n")
               (str "kiln-state 1\nstep out/a\ncmd c\nout ../a " h1 "\nend\n")
               (str "kiln-state 1\nstep out/a\ncmd c\nout out/a " h1 "\nend\n"
                    "step out/a\ncmd c\nout out/a " h1 "\nend\n")]]    ; duplicate key
    (is (= {} (state/parse bad)) (pr-str bad))))

(deftest freshness
  (let [step {:cmd-str "copy()" :outputs ["out/a"] :file-ins ["src/a"]}
        vfs (-> (buildsys.vfs/empty-vfs) (buildsys.vfs/put "src/a" "x\n") (buildsys.vfs/put "out/a" "x\n"))
        hash-a (buildsys.vfs/content-hash vfs "src/a")
        entry {:cmd "copy()" :in [["src/a" hash-a]] :dep [] :out [["out/a" hash-a]]}]
    (is (false? (state/stale? entry step vfs)))
    (is (state/stale? nil step vfs))
    (is (state/stale? (assoc entry :cmd "upper()") step vfs))
    (is (state/stale? (assoc entry :in [["src/b" hash-a]]) step vfs))
    (is (state/stale? entry step (buildsys.vfs/put vfs "out/a" "tampered")))
    (is (state/stale? entry step (buildsys.vfs/delete vfs "out/a")))))

(def ^:private gen-hash
  (gen/fmap #(apply str %) (gen/vector (gen/elements "0123456789abcdef") 16)))

(def ^:private gen-entry
  (gen/let [n (gen/choose 1 9)
            ins (gen/vector (gen/tuple (gen/elements ["src/a" "src/b"]) gen-hash) 0 3)
            deps (gen/vector (gen/tuple (gen/elements ["src/c" "src/d"]) gen-hash) 0 3)
            h gen-hash]
    [(str "out/" n) {:cmd "copy()" :in ins :dep deps :out [[(str "out/" n) h]]}]))

(defspec render-then-parse-round-trips 100
  (prop/for-all [entries (gen/fmap #(into {} %) (gen/vector gen-entry 0 5))]
    (= entries (state/parse (state/render entries)))))
