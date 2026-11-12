(ns gitrepo.delta-test
  (:require [clojure.test :refer [deftest is]]
            [gitrepo.delta :as delta]
            [gitrepo.error :as err]
            [gitrepo.test-util :refer [bytes-of]]))

(defn- b ^bytes [& xs] (byte-array (map unchecked-byte xs)))

(defn- fails? [f] (try (f) false (catch Exception e (err/failure? e))))

(deftest copy-and-insert
  (let [base (bytes-of "hello world")
        ;; base size 11, result size 11: copy 5 @0, insert ", ", copy 5 @6 ... "hello, world" is 12
        d (b 11 12
             0x90 5                       ; copy size 5, offset 0
             2 (int \,) (int \space)      ; insert ", "
             0x91 6 5)]                   ; copy offset 6, size 5
    (is (= "hello, world" (String. (delta/apply-delta base d))))))

(deftest copy-size-zero-means-0x10000
  (let [base (byte-array 0x10000 (byte 7))
        ;; sizes 0x10000 as varints (0x80 0x80 0x04), then a bare copy instruction
        out (delta/apply-delta base (b 0x80 0x80 0x04 0x80 0x80 0x04 0x80))]
    (is (= 0x10000 (alength out)))))

(deftest invalid-deltas
  (let [base (bytes-of "abc")]
    (is (fails? #(delta/apply-delta base (b 3 3 0))))                  ; instruction 0
    (is (fails? #(delta/apply-delta base (b 4 3 0x90 3))))             ; wrong base size
    (is (fails? #(delta/apply-delta base (b 3 3 0x91 1 3))))           ; copy past end
    (is (fails? #(delta/apply-delta base (b 3 5 0x90 3))))             ; short result
    (is (fails? #(delta/apply-delta base (b 3 2 0x90 3))))             ; long result
    (is (fails? #(delta/apply-delta base (b 3 3 5 1))))))              ; truncated insert
