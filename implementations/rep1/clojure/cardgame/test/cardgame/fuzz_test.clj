(ns cardgame.fuzz-test
  "Property tests: whatever script is thrown at the engine, it terminates
  with a well-formed log."
  (:require [clojure.string :as str]
            [clojure.test :refer [is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [cardgame.core :as cg]))

(def ^:private header
  (str "CARDS test/resources/mini.spire\nSEED %d\nSPIRE 8\nOPENING 3\nHANDMAX 4\nTURNLIMIT 12\n"
       "DECK A CIN-001*3 CIN-003*3 CIN-005*2 DSK-002*2 LOM-003*2 TID-003*2 CIN-006*2 CIN-018*2 NEU-001*2\n"
       "DECK B CIN-001*3 CIN-003*3 DSK-020*2 DSK-024*2 TID-004*2 CIN-007*2 CIN-033*2 LOM-039*2 NEU-015*2\n"
       "FIELD A TOK-001 DSK-036\nFIELD B TOK-003\nSTART\n"))

(def ^:private line-gen
  (gen/frequency
   [[6 (gen/elements ["A PASS" "B PASS"])]
    [3 (gen/fmap (fn [[p n t]] (str p " PLAY " n (when t (str " " t))))
                 (gen/tuple (gen/elements ["A" "B"]) (gen/choose 0 5)
                            (gen/elements [nil "A" "B" "#3" "#5" "#9" "~1"])))]
    [2 (gen/fmap (fn [[p o]] (str p " ATTACK" o))
                 (gen/tuple (gen/elements ["A" "B"])
                            (gen/elements ["" " #1" " #2" " #3" " #4" " #5" " #2 #3"])))]
    [2 (gen/fmap (fn [[p o]] (str p " BLOCK" o))
                 (gen/tuple (gen/elements ["A" "B"])
                            (gen/elements ["" " #4:#2" " #5:#3" " #6:#1" " #9:#9"])))]
    [1 (gen/fmap (fn [[p o i]] (str p " ACT #" o " " i))
                 (gen/tuple (gen/elements ["A" "B"]) (gen/choose 1 12) (gen/choose 0 3)))]
    [1 (gen/elements ["DUMP" "LEGAL" "VAULT" "CARD CIN-003" "garbage line" "# note" ""])]]))

(defn- event-lines [out]
  (filter #(re-matches #"\d+ [A-Z-]+( .*)?" %) (str/split-lines out)))

(defspec arbitrary-scripts-produce-a-wellformed-log 60
  (prop/for-all [seed (gen/choose 0 1000)
                 script (gen/vector line-gen 0 120)]
    (let [text (str (format header seed) (str/join "\n" script) "\n")
          out (cg/run-match text)
          events (event-lines out)
          seqs (map #(Long/parseLong (first (str/split % #" "))) events)]
      (and (= seqs (range 1 (inc (count seqs))))           ; contiguous numbering
           (= 1 (count (filter #(re-matches #"\d+ RESULT .*" %) events)))
           (re-matches #"\d+ RESULT .*" (last events))      ; and it is last
           (= out (cg/run-match text))))))                 ; deterministic
