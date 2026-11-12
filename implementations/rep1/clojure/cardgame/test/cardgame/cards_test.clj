(ns cardgame.cards-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [cardgame.cards :as cards]
            [cardgame.sexpr :as sx]))

(def ^:private mini-path "test/resources/mini.spire")

(defn- bad? [text]
  (try (cards/parse-database text) false
       (catch clojure.lang.ExceptionInfo e (sx/bad-database? e))))

(deftest loads-the-fixture-database
  (let [db (cards/load-database mini-path)]
    (is (< 20 (count db)))
    (is (= :rite (:type (db "CIN-003"))))
    (is (= [2 1] (:body (db "CIN-006"))))
    (is (= {"riposte" 1} (frequencies (map :kw (:keywords (db "CIN-006"))))))))

(deftest ability-numbering
  (let [db (cards/load-database mini-path)
        c (db "DSK-020")]
    (is (= [:on :act] (map :kind (:abilities c))))
    (is (= [1 2] (map :n (:abilities c))))
    (is (= {"spire-loss" [1]} (:triggers c))))
  (testing "resolve first, then on, act, aura regardless of file order"
    (let [db (cards/parse-database
              "(card AAA-001 (name \"X\") (type rite) (cost 1)
                 (act (cost (once)) (nothing))
                 (on turn-start (nothing))
                 (resolve (nothing))
                 (aura (swapstats (units all))))")]
      (is (= [:resolve :on :act :aura] (map :kind (:abilities (db "AAA-001"))))))))

(deftest card-rendering
  (let [db (cards/load-database mini-path)]
    (is (= ["CARD BEGIN DSK-020" "name Grim Harvester" "type unit" "cost 3" "body 2/2"
            "tags dusk,undead" "keywords -"
            "ability 1 on spire-loss - (counters 1 self)"
            "ability 2 act (cost (exhaust) (spire 2)) (targets (unit)) (damage 2 (t 1))"
            "CARD END"]
           (cards/render-card "DSK-020" (db "DSK-020"))))
    (is (= ["CARD BEGIN NOPE-1" "unknown" "CARD END"] (cards/render-card "NOPE-1" nil)))
    (is (some #{"keywords pierce,plating:1"}
              (cards/render-card "X" (assoc (db "CIN-001") :keywords
                                            [{:kw "plating" :n 1} {:kw "pierce" :n nil}]))))))

(deftest accepts-the-grammar-corners
  (is (= {} (cards/parse-database "")))
  (is (cards/parse-database
       "(card AAA-001 (name \"\") (type relic) (cost 0) (tags) (keywords)
          (text \"t\") (aura (when (and) (when (or (not (myturn))) (modify 1 1 (units all))))))"))
  (testing "ability clauses may be repeated and in any order on any type"
    (is (cards/parse-database
         "(card AAA-001 (cost 1) (type unit) (body 0 0) (name \"x\")
            (on arrive (draw 1 you)) (on arrive (draw 1 you))
            (act (cost) (nothing)))")))
  (testing "keywords rules"
    (is (cards/parse-database "(card AAA-001 (name \"x\") (type rite) (cost 0) (keywords swift)
                                 (resolve (nothing)))"))
    (is (cards/parse-database "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1)
                                 (keywords (plating 2) (plating 1) venom))"))))

(deftest rejects-invalid-databases
  (doseq [[why text]
          {"unbalanced" "(card AAA-001"
           "extra paren" "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1)))"
           "not a card" "(deck AAA-001)"
           "lowercase id" "(card aaa-001 (name \"x\") (type unit) (cost 0) (body 1 1))"
           "duplicate id" (str "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1))"
                               "(card AAA-001 (name \"y\") (type unit) (cost 0) (body 1 1))")
           "negative cost" "(card AAA-001 (name \"x\") (type unit) (cost -1) (body 1 1))"
           "swift on unit" "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1) (keywords swift))"
           "vanguard on rite" "(card AAA-001 (name \"x\") (type rite) (cost 0) (keywords vanguard) (resolve (nothing)))"
           "rite without resolve" "(card AAA-001 (name \"x\") (type rite) (cost 0))"
           "act without cost" "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1) (act (nothing)))"
           "targets after effect" "(card AAA-001 (name \"x\") (type rite) (cost 0) (resolve (nothing) (targets (unit))))"
           "empty aura" "(card AAA-001 (name \"x\") (type relic) (cost 0) (aura))"
           "unknown effect" "(card AAA-001 (name \"x\") (type rite) (cost 0) (resolve (explode 1 foe)))"
           "bad arity" "(card AAA-001 (name \"x\") (type rite) (cost 0) (resolve (damage 1)))"
           "unknown summon" "(card AAA-001 (name \"x\") (type rite) (cost 0) (resolve (summon BBB-001 1 you)))"
           "summon a rite" (str "(card AAA-001 (name \"x\") (type rite) (cost 0) (resolve (summon AAA-002 1 you)))"
                                "(card AAA-002 (name \"y\") (type rite) (cost 0) (resolve (nothing)))")
           "negate non-target" "(card AAA-001 (name \"x\") (type rite) (cost 0) (resolve (negate self)))"
           "if with bare effect" "(card AAA-001 (name \"x\") (type rite) (cost 0) (resolve (if (myturn) (draw 1 you))))"
           "huge int" "(card AAA-001 (name \"x\") (type unit) (cost 99999999999999999999) (body 1 1))"
           "bare plating" "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1) (keywords plating))"
           "bad comparator" "(card AAA-001 (name \"x\") (type rite) (cost 0) (resolve (damage 1 (units all (cost gte 1)))))"
           "bad scope" "(card AAA-001 (name \"x\") (type rite) (cost 0) (resolve (destroy (units mine))))"
           "bad event" "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1) (on sunrise (nothing)))"}]
    (testing why
      (is (bad? text)))))

(deftest missing-file-is-a-bad-database
  (is (try (cards/load-database "test/resources/does-not-exist.spire") false
           (catch clojure.lang.ExceptionInfo e (sx/bad-database? e)))))

(deftest shipped-style-lexer-corner-cases
  (let [db (cards/parse-database
            "(card LEX-001\t(name \"Odd (Name); with ;punctuation\")   (type
unit)(cost 0)(body 0 0)(tags)(keywords)
  (on arrive (modify -2 -3 self)) ; a comment inside the card
  (act (cost (once)) (spire -1 you)))")]
    (is (= "Odd (Name); with ;punctuation" (:name (db "LEX-001"))))
    (is (str/includes? (str/join "\n" (cards/render-card "LEX-001" (db "LEX-001")))
                       "ability 1 on arrive - (modify -2 -3 self)"))))
