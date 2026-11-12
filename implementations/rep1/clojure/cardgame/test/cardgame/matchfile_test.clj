(ns cardgame.matchfile-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [cardgame.matchfile :as mf]))

(defn- setup [& lines] (mf/parse-setup (vec lines)))

(deftest minimal-setup
  (let [r (setup "CARDS x.spire" "SEED 1" "START" "A PASS")]
    (is (= 3 (:start r)))
    (is (= "x.spire" (get-in r [:cfg :cards])))
    (is (= 25 (get-in r [:cfg :spire])))
    (is (= 5 (get-in r [:cfg :opening])))
    (is (= :A (get-in r [:cfg :first])))
    (is (true? (get-in r [:cfg :shuffle])))))

(deftest setup-values-and-zones
  (let [r (setup "# comment" "" "CARDS x" "SEED 18446744073709551615" "SPIRE 007"
                 "FIRST B" "SHUFFLE off" "TRACE state" "CAP A 3" "CAP B 0"
                 "DECK A CIN-001*3 CIN-002" "DECK A CIN-003" "FIELD B TOK-001" "START")]
    (is (= 14 (:start r)))
    (is (= 7 (get-in r [:cfg :spire])))
    (is (= :B (get-in r [:cfg :first])))
    (is (= {:A 3 :B 0} (get-in r [:cfg :caps])))
    (is (= [["CIN-001" 3] ["CIN-002" 1] ["CIN-003" 1]] (get-in r [:cfg :zones :A :deck])))
    (is (= [["TOK-001" 1]] (get-in r [:cfg :zones :B :field])))))

(deftest setup-errors
  (doseq [lines [["SEED 1" "START"]                          ; no CARDS
                 ["CARDS x" "START"]                         ; no SEED
                 ["CARDS x" "SEED 1"]                        ; no START
                 ["CARDS x" "SEED 1" "SEED 2" "START"]       ; duplicate
                 ["CARDS x" "SEED 1" "BOGUS 1" "START"]
                 ["CARDS x" "SEED -1" "START"]
                 ["CARDS x" "SEED 18446744073709551616" "START"]
                 ["CARDS x" "SEED 1" "SPIRE 0" "START"]
                 ["CARDS x" "SEED 1" "SPIRE 1000001" "START"]
                 ["CARDS x" "SEED 1" "OPENING 21" "START"]
                 ["CARDS x" "SEED 1" "HANDMAX 101" "START"]
                 ["CARDS x" "SEED 1" "TRACE all" "START"]
                 ["CARDS x" "SEED 1" "CAP A 1" "CAP A 2" "START"]
                 ["CARDS x" "SEED 1" "CAP C 1" "START"]
                 ["CARDS x" "SEED 1" "DECK A CIN-001*1001" "START"]
                 ["CARDS x" "SEED 1" "DECK A CIN-001*0" "START"]
                 ["CARDS x" "SEED 1" "DECK A" "START"]
                 ["CARDS x" "SEED 1" "DECK C CIN-001" "START"]
                 ["CARDS x" "SEED 1" "START now"]
                 ["CARDS x" "SEED 1" "A PASS" "START"]]]
    (testing (pr-str lines)
      (is (= {:error :bad-setup} (apply setup lines))))))

(deftest duplicate-rules
  (testing "FIRST, SHUFFLE and TRACE are each single-use"
    (is (= {:error :bad-setup} (setup "CARDS x" "SEED 1" "FIRST A" "FIRST B" "START"))))
  (testing "zone lines may repeat, CAP A and CAP B are separate lines"
    (is (:cfg (setup "CARDS x" "SEED 1" "CAP A 1" "CAP B 1" "DECK A X*2" "DECK A Y" "START")))))

(deftest line-splitting
  (is (= ["a" "b" "" "c"] (mf/split-lines "a\r\nb\n\nc\n")))
  (is (= ["a"] (mf/split-lines "a")))
  (is (= [] (mf/split-lines ""))))

(deftest script-lines
  (testing "actions"
    (is (= {:player :A :action {:type :pass}} (mf/parse-line "A PASS")))
    (is (= {:player :B :action {:type :concede}} (mf/parse-line "  B   CONCEDE ")))
    (is (= {:player :A :action {:type :play :pos 1 :targets [:B 7 [:c 2]]}}
           (mf/parse-line "A PLAY 1 B #007 ~2")))
    (is (= {:player :A :action {:type :act :oid 5 :index 2 :targets []}}
           (mf/parse-line "A ACT #5 2")))
    (is (= {:player :A :action {:type :attack :oids [3 4]}} (mf/parse-line "A ATTACK #3 #4")))
    (is (= {:player :A :action {:type :attack :oids []}} (mf/parse-line "A ATTACK")))
    (is (= {:player :B :action {:type :block :pairs [[4 2] [5 3]]}}
           (mf/parse-line "B BLOCK #4:#2 #5:#3"))))
  (testing "directives"
    (is (= {:directive :dump} (mf/parse-line "DUMP")))
    (is (= {:directive :card :id "ZZZ"} (mf/parse-line "CARD ZZZ"))))
  (testing "comments"
    (is (nil? (mf/parse-line "# hi")))
    (is (nil? (mf/parse-line "   ")))
    (is (nil? (mf/parse-line "  # indented"))))
  (testing "syntax errors"
    (doseq [l ["X PASS" "A" "A JUMP" "A PASS now" "A PLAY" "A PLAY x" "A PLAY -1"
               "A PLAY 1 #" "A PLAY 1 C" "A ACT 5 1" "A ACT #5" "A ATTACK 5"
               "A BLOCK #1" "A BLOCK #1:" "A PLAY 99999999999999999999" "DUMP x" "CARD" "CARD a b"
               "a pass"]]
      (testing l
        (is (:bad-syntax (mf/parse-line l)))))))

(defspec parse-line-never-throws 200
  (prop/for-all [s (gen/fmap #(apply str %)
                             (gen/vector (gen/elements (seq "AB PLAYCTNDUMP#~:*0123456789 \t")) 0 30))]
    (let [r (mf/parse-line s)]
      (or (nil? r) (map? r)))))
