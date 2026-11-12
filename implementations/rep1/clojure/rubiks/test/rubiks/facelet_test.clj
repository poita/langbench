(ns rubiks.facelet-test
  "The specification's own sanity checks, run against the facelet model."
  (:require [clojure.test :refer [deftest is testing]]
            [rubiks.facelet :as f]
            [rubiks.moves :as moves]))

(defn- order
  "Number of repetitions of the sequence needed to return to solved."
  [tokens]
  (loop [state (f/apply-moves f/solved tokens), n 1]
    (cond (f/solved? state) n
          (> n 1000) nil
          :else (recur (f/apply-moves state tokens) (inc n)))))

(deftest solved-test
  (is (= 54 (count f/solved)))
  (is (= "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB" f/solved)))

(deftest u-move-test
  ;; The spec's example: after U, F1-F3 show R, L1-L3 show F, B1-B3 show L and
  ;; R1-R3 show B.
  (let [s (f/apply-move f/solved "U")
        face (fn [c] (subs s (* 9 (.indexOf "URFDLB" (str c))) (* 9 (inc (.indexOf "URFDLB" (str c))))))]
    (is (= "RRR" (subs (face \F) 0 3)))
    (is (= "FFF" (subs (face \L) 0 3)))
    (is (= "LLL" (subs (face \B) 0 3)))
    (is (= "BBB" (subs (face \R) 0 3)))
    (is (= "UUUUUUUUU" (face \U)))))

(deftest orders-test
  (testing "a face turn has order 4, its half turn 2"
    (doseq [x "UDLRFB"]
      (is (= 4 (order [(str x)])))
      (is (= 2 (order [(str x "2")])))
      (is (= 4 (order [(str x "'")])))))
  (testing "inverse moves"
    (doseq [t moves/tokens]
      (is (f/solved? (f/apply-moves f/solved [t (moves/inverse t)])))))
  (is (= 6 (order ["R" "U" "R'" "U'"])))
  (is (= 105 (order ["R" "U"])))
  (is (= 105 (order ["F" "R"])))
  (is (= 4 (order ["U" "D"]))))

(deftest superflip-test
  (let [seq (moves/parse "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2")
        s   (f/apply-moves f/solved seq)
        at  (fn [name] (nth s (f/index name)))]
    (is (not (f/solved? s)))
    ;; corner stickers are home, edge stickers are swapped with their partner
    (is (= [\U \U \U \U] (map at ["U1" "U3" "U7" "U9"])))
    (is (= [\F \R] [(at "U8") (at "U6")]) "UF and UR edges are flipped")
    (is (= [\U \U] [(at "F2") (at "R2")]))
    (is (= [\R \F] [(at "F6") (at "R4")]))
    ;; the superflip is its own inverse
    (is (f/solved? (f/apply-moves s seq)))))
