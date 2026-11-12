(ns cardgame.engine-test
  "Scenario tests of the library API (cardgame.core) over the fixture card
  pool in test/resources/mini.spire."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing use-fixtures]]
            [cardgame.core :as cg]))

(def ^:private db (delay (cg/load-cards "test/resources/mini.spire")))

(defn- game
  "A game over the fixture pool with a quiet, deterministic setup."
  [opts]
  (cg/new-game @db (merge {:seed 1 :spire 10 :opening 0 :shuffle false} opts)))

(defn- events
  "The log of `g` as a vector of event names (the word after the number)."
  [g]
  (->> (str/split-lines (cg/output g))
       (remove #(str/starts-with? % "ERR"))
       (mapv #(second (str/split % #" ")))))

(defn- lines [g] (str/split-lines (cg/output g)))

(defn- pass-both! [g]
  (let [[p] (:decision @g)]
    (cg/submit! g p {:type :pass})
    (cg/submit! g (first (:decision @g)) {:type :pass})))

(deftest setup-emits-the-opening-events
  (let [g (game {:zones {:A {:deck [["CIN-001" 3]]} :B {:deck [["CIN-001" 3]]}}})]
    (is (= ["GAME-START A" "TURN 1 A" "PHASE dawn" "EMBER A 1 1" "EMBER B 0 0"
            "PHASE draw" "PHASE main1"]
           (map #(str/join " " (rest (str/split % #" "))) (lines g))))
    (is (= [:A :priority] (:decision @g)))
    (is (not (cg/over? g)))))

(deftest opening-draw-from-an-empty-vault-loses-immediately
  (let [g (game {:opening 1})]
    (is (cg/over? g))
    (is (some #{"2 DRAW-EMPTY A"} (lines g)))
    (is (= "RESULT draw vault" (str/replace (last (lines g)) #"^\d+ " "")))
    (is (= :game-over (cg/submit! g :A {:type :pass})))))

(deftest a-rite-kills-a-unit
  (let [g (game {:zones {:A {:deck [["CIN-001" 1]] :hand [["CIN-003" 1]]}
                         :B {:deck [["CIN-001" 1]] :field [["TOK-001" 1]]}}})]
    (is (nil? (cg/submit! g :A {:type :play :pos 1 :targets [4]})))
    (pass-both! g)
    (is (some #(str/ends-with? % "DESTROY #4 TOK-001") (lines g)))
    (is (= 1 (count (filter #(str/starts-with? % "ash B") (cg/inspect g :dump)))))))

(deftest errors-are-reported-in-precedence-order
  (let [g (game {:zones {:A {:deck [["CIN-001" 1]] :hand [["CIN-003" 1] ["CIN-016" 1]]}
                         :B {:deck [["CIN-001" 1]]}}})]
    (is (= :not-your-turn (cg/submit! g :B {:type :pass})))
    (is (= :wrong-decision (cg/submit! g :A {:type :attack :oids []})))
    (is (= :no-such-card (cg/submit! g :A {:type :play :pos 5 :targets []})))
    (is (= :bad-target-count (cg/submit! g :A {:type :play :pos 1 :targets []})))
    (is (= :illegal-target (cg/submit! g :A {:type :play :pos 1 :targets [99]})))
    (is (= :cannot-afford (cg/submit! g :A {:type :play :pos 2 :targets []})))
    (is (= :no-such-object (cg/submit! g :A {:type :act :oid 1 :index 1 :targets []})))
    (is (nil? (cg/submit! g :A {:type :play :pos 1 :targets [:A]})))))

(deftest pass-counter-semantics
  ;; A plays, A passes, B passes -> resolves; A holds priority again.
  (let [g (game {:zones {:A {:deck [["CIN-001" 1]] :hand [["CIN-003" 1]]}
                         :B {:deck [["CIN-001" 1]]}}})]
    (cg/submit! g :A {:type :play :pos 1 :targets [:B]})
    (is (= [:A :priority] (:decision @g)))
    (cg/submit! g :A {:type :pass})
    (is (= [:B :priority] (:decision @g)))
    (cg/submit! g :B {:type :pass})
    (is (= [:A :priority] (:decision @g)))
    (is (= 8 (get-in @g [:pl :B :spire])))))

(deftest winning-on-spire-ends-the-match
  (let [g (game {:spire 2 :zones {:A {:deck [["CIN-001" 1]] :hand [["CIN-003" 1]]}
                                  :B {:deck [["CIN-001" 1]]}}})]
    (cg/submit! g :A {:type :play :pos 1 :targets [:B]})
    (pass-both! g)
    (is (cg/over? g))
    (is (= ["LOSE B spire" "RESULT A spire"]
           (map #(str/join " " (drop 1 (str/split % #" "))) (take-last 2 (lines g)))))
    (is (= ["LEGAL BEGIN - over" "LEGAL END"] (cg/inspect g :legal)))
    (is (str/ends-with? (second (cg/inspect g :dump)) "decision - over"))))

(deftest concede-ends-immediately
  (let [g (game {:zones {:A {:deck [["CIN-001" 1]]} :B {:deck [["CIN-001" 1]]}}})]
    (is (nil? (cg/submit! g :A {:type :concede})))
    (is (cg/over? g))
    (is (= ["LOSE A concede" "RESULT B concede"]
           (map #(str/join " " (drop 1 (str/split % #" "))) (take-last 2 (lines g)))))))

(deftest legal-actions-at-priority
  (let [g (game {:caps {:A 2}
                 :zones {:A {:deck [["CIN-001" 1]] :hand [["CIN-003" 1] ["CIN-027" 1]]
                             :field [["TOK-001" 1]]}
                         :B {:deck [["CIN-001" 1]] :field [["TOK-005" 1]]}}})]
    (is (= ["LEGAL BEGIN A priority" "PASS" "PLAY 1 CIN-003 A" "PLAY 1 CIN-003 B"
            "PLAY 1 CIN-003 #4" "PLAY 1 CIN-003 #6" "PLAY 2 CIN-027" "LEGAL END"]
           (cg/inspect g :legal)))))

(deftest combat-with-riposte-and-the-skipped-step
  (let [g (game {:zones {:A {:deck [["CIN-006" 1]] :field [["CIN-006" 1]]}
                         :B {:deck [["CIN-001" 1]] :field [["TOK-001" 1]]}}})]
    (pass-both! g)
    (is (= [:A :attackers] (:decision @g)))
    (is (= ["LEGAL BEGIN A attackers" "CANATTACK #2" "LEGAL END"] (cg/inspect g :legal)))
    (is (= :illegal-attacker (cg/submit! g :A {:type :attack :oids [4]})))
    (is (= :duplicate-attacker (cg/submit! g :A {:type :attack :oids [2 2]})))
    (cg/submit! g :A {:type :attack :oids [2]})
    (pass-both! g)
    (is (= [:B :blockers] (:decision @g)))
    (is (= :illegal-blocker (cg/submit! g :B {:type :block :pairs [[4 9]]})))
    (cg/submit! g :B {:type :block :pairs [[4 2]]})
    (pass-both! g)
    (is (some #{"PHASE clash-riposte"} (map #(last (str/split % #" +(?=\S+ \S+$)")) (lines g))))
    (is (some #(str/ends-with? % "DESTROY #4 TOK-001") (lines g)))))

(deftest no-attackers-skips-the-rest-of-the-clash-phase
  (let [g (game {:zones {:A {:deck [["CIN-001" 1]]} :B {:deck [["CIN-001" 1]]}}})]
    (pass-both! g)
    (cg/submit! g :A {:type :attack :oids []})
    (let [phases (keep #(second (re-find #"PHASE (\S+)" %)) (lines g))]
      (is (= ["dawn" "draw" "main1" "clash-attack" "main2"] phases)))))

(deftest match-limit-is-a-draw
  (let [g (game {:turnlimit 1 :zones {:A {:deck [["CIN-001" 4]]} :B {:deck [["CIN-001" 4]]}}})]
    (loop [n 0]
      (when (and (not (cg/over? g)) (< n 30))
        (case (second (:decision @g))
          :attackers (cg/submit! g :A {:type :attack :oids []})
          :priority (pass-both! g))
        (recur (inc n))))
    (is (cg/over? g))
    (is (= "RESULT draw turn-limit" (str/replace (last (lines g)) #"^\d+ " "")))
    (is (= "turn 2 active B phase dusk-cleanup decision - over"
           (second (cg/inspect g :dump))))))

(deftest inspection-never-changes-the-game
  (let [g (game {:zones {:A {:deck [["CIN-001" 2]] :hand [["CIN-003" 1]]}
                         :B {:deck [["CIN-001" 2]]}}})
        before (cg/output g)]
    (cg/inspect g :dump)
    (cg/inspect g :legal)
    (cg/inspect g :vault)
    (cg/inspect g [:card "CIN-003"])
    (is (= before (cg/output g)))))
