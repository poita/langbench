(ns kvstore.recovery-test
  "Crash recovery: logs cut at arbitrary offsets and damaged logs (spec 16)."
  (:require [clojure.test :refer [deftest is testing]]
            [kvstore.bytes :as b]
            [kvstore.core :as kv]
            [kvstore.test-util :as tu]))

(def fresh (:main (tu/script "")))
(def full-log (:wal (tu/script ["put \"a\" 1" "put \"b\" 2"])))

(defn- recovered [^bytes wal]
  (let [db (kv/open {:main fresh :wal wal})]
    {:keys (kv/scan db {:keys? true})
     :wal-size (:wal (kv/stat db))}))

(deftest full-log-has-expected-size
  (is (= 4272 (alength ^bytes full-log))))

(deftest truncation-drops-the-unfinished-transaction
  (doseq [cut [0 10 31 32 33 55 56 1079 1080 2000 2151 2152 2153 2175 2176 3000 3199 4247 4248 4271 4272]]
    (let [{:keys [keys wal-size]} (recovered (b/sub full-log 0 cut))
          [expect-keys expect-size] (cond (< cut 2152) [[] 32]
                                          (< cut 4272) [["a"] 2152]
                                          :else [["a" "b"] 4272])]
      (is (= expect-keys keys) (str "cut " cut))
      (is (= expect-size wal-size) (str "cut " cut)))))

(deftest damaged-headers-discard-the-log
  (let [damage (fn [i] (let [l (b/sub full-log 0 (alength ^bytes full-log))]
                         (aset-byte l i (unchecked-byte (inc (aget l i)))) l))]
    (doseq [i [0 8 10 12 20 28]]
      (is (= {:keys [] :wal-size 32} (recovered (damage i))) (str "byte " i)))))

(deftest trailing-garbage-is-trimmed
  (let [log (b/concat-bytes full-log (byte-array (range 100)))
        {:keys [main wal]} (tu/script ["scan keys"] fresh log)]
    (is (= 4272 (alength ^bytes wal)))
    (is (= 1024 (alength ^bytes main)) "recovery never touches the main file")))

(deftest corrupt-record-stops-the-scan
  (let [log (b/sub full-log 0 (alength ^bytes full-log))]
    (aset-byte log 2200 (unchecked-byte 0x55)) ; inside transaction 2's first image
    (is (= {:keys ["a"] :wal-size 2152} (recovered log)))))

(deftest recovered-database-keeps-working
  (testing "the spec's example 21.10"
    (let [{:keys [results wal]} (tu/script ["scan" "put \"c\" 3" "scan keys"] fresh (b/sub full-log 0 3000))]
      (is (= "[1] ok scan 1\n  \"a\" = 1\n[2] ok put created\n[3] ok scan 2\n  \"a\"\n  \"c\"\n" results))
      (is (= 4272 (alength ^bytes wal))))))

(deftest log-without-main-file
  (let [{:keys [results]} (tu/script ["scan keys"] nil full-log)]
    (is (= "[1] ok scan 2\n  \"a\"\n  \"b\"\n" results))))
