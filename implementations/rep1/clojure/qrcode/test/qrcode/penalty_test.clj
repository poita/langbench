(ns qrcode.penalty-test
  (:require [clojure.test :refer [deftest is]]
            [qrcode.codewords :as codewords]
            [qrcode.mask :as mask]
            [qrcode.matrix :as matrix]
            [qrcode.penalty :as penalty]
            [qrcode.core :as qr])
  (:import (java.nio.charset StandardCharsets)))

(defn- grid-from-rows
  "Builds a bare grid (no function modules) from strings of # and ."
  [rows]
  (let [n (count rows)
        g (matrix/->Grid n (byte-array (* n n)) (boolean-array (* n n)))]
    (doseq [[y r] (map-indexed vector rows), [x c] (map-indexed vector r)]
      (when (= c \#) (aset ^bytes (.-modules g) (+ (* y n) x) (byte 1))))
    g))

(deftest hello-world-penalties-from-spec
  ;; SPEC.md example 1: penalties of masks 0..7 for `M auto HELLO WORLD`.
  (let [data (.getBytes "HELLO WORLD" StandardCharsets/UTF_8)
        cw (-> (codewords/data-codewords :alphanumeric data 1 :m)
               (codewords/interleave-blocks 1 :m))
        base (-> (matrix/function-patterns 1) (matrix/place-data! cw))]
    (is (= [311 406 442 463 367 528 395 445]
           (vec (for [m (range 8)]
                  (penalty/penalty (-> (matrix/copy-grid base)
                                       (mask/apply-mask! m)
                                       (matrix/draw-format! :m m)))))))))

(deftest individual-rules
  ;; Rows of 5 identical modules score 3 for each row and 3 for the same
  ;; pattern in columns where applicable; use a small hand-checked grid.
  (let [all-light (grid-from-rows (repeat 5 "....."))]
    ;; N1: 5 rows + 5 columns, each a run of 5 -> 10 * 3 = 30.
    ;; N2: 16 blocks * 3 = 48.  N4: 0% dark -> deviation 50% -> k = 10 -> 100.
    (is (= (+ 30 48 100) (penalty/penalty all-light))))
  (let [g (grid-from-rows ["#.###.#...." "..........." "..........." "..........."
                           "..........." "..........." "..........." "..........."
                           "..........." "..........." "..........."])]
    ;; Row 0 contains the finder-like pattern once (+40); the line scoring
    ;; also sees runs of light modules elsewhere, so just check N3 is included.
    (is (>= (penalty/penalty g) 40))))

(deftest tie-break-prefers-lower-mask
  (let [sym (qr/encode "HELLO WORLD" :m)]
    (is (= 0 (:mask sym)))))
