(ns sqlitefile.record
  "Decoding of SQLite records (table rows and index entries).

  Values decode to plain Clojure data: `nil` (NULL), `Long` (INTEGER),
  `Double` (REAL), `String` (TEXT) and `byte[]` (BLOB)."
  (:require [sqlitefile.bytes :as b])
  (:import (java.nio.charset StandardCharsets)
           (java.util Arrays)))

(set! *warn-on-reflection* true)

(def ^:private int-sizes [0 1 2 3 4 6 8])

(defn- fail [msg data]
  (throw (ex-info msg (assoc data :type :sqlitefile/corrupt))))

(defn- decode-value [^bytes rec ^long serial ^long pos]
  (cond
    (= serial 0) nil
    (<= 1 serial 6) (b/signed rec pos (long (nth int-sizes serial)))
    (= serial 7) (Double/longBitsToDouble (b/signed rec pos 8))
    (= serial 8) 0
    (= serial 9) 1
    (< serial 12) (fail "reserved serial type" {:serial serial})
    (even? serial) (Arrays/copyOfRange rec (int pos) (int (+ pos (quot (- serial 12) 2))))
    :else (String. rec (int pos) (int (quot (- serial 13) 2)) StandardCharsets/UTF_8)))

(defn- body-size ^long [^long serial]
  (cond
    (<= 0 serial 9) (if (<= 1 serial 6) (long (nth int-sizes serial)) (if (= serial 7) 8 0))
    (< serial 12) 0
    (even? serial) (quot (- serial 12) 2)
    :else (quot (- serial 13) 2)))

(defn decode
  "Decode the record held in `rec` into a vector of values."
  [^bytes rec]
  (let [len (alength rec)
        hsize (b/varint rec 0)]
    (when (or (< hsize 1) (> hsize len))
      (fail "bad record header" {:header-size hsize}))
    (loop [hp (b/varint-size rec 0)
           bp hsize
           out (transient [])]
      (if (>= hp hsize)
        (persistent! out)
        (let [serial (b/varint rec hp)
              size (body-size serial)]
          (when (> (+ bp size) len)
            (fail "record body overruns payload" {:serial serial}))
          (recur (+ hp (b/varint-size rec hp))
                 (+ bp size)
                 (conj! out (decode-value rec serial bp))))))))

(defn- serial-type [v]
  (cond
    (nil? v) [0 0]
    (integer? v) (let [n (long v)]
                   (cond (= n 0) [8 0]
                         (= n 1) [9 0]
                         (<= -128 n 127) [1 1]
                         (<= -32768 n 32767) [2 2]
                         (<= -8388608 n 8388607) [3 3]
                         (<= -2147483648 n 2147483647) [4 4]
                         (<= -140737488355328 n 140737488355327) [5 6]
                         :else [6 8]))
    (float? v) [7 8]
    (string? v) (let [n (alength (.getBytes ^String v StandardCharsets/UTF_8))] [(+ 13 (* 2 n)) n])
    :else [(+ 12 (* 2 (alength ^bytes v))) (alength ^bytes v)]))

(defn encode
  "Encode a vector of values into record bytes (the inverse of [[decode]]).
  Mainly useful for building test fixtures."
  ^bytes [values]
  (let [types (mapv serial-type values)
        hdr-body (mapv #(seq (b/encode-varint (first %))) types)
        hdr-len (count (apply concat hdr-body))
        ;; header size varint counts itself; sizes here stay below 128
        hsize (+ hdr-len (count (b/encode-varint (+ hdr-len 1))))
        out (java.io.ByteArrayOutputStream.)]
    (.write out ^bytes (b/encode-varint hsize))
    (doseq [h hdr-body] (.write out ^bytes (byte-array h)))
    (doseq [[v [serial size]] (map vector values types)]
      (cond
        (nil? v) nil
        (integer? v) (let [n (long v)]
                       (dotimes [k size]
                         (.write out (int (bit-and 0xff (bit-shift-right n (* 8 (- size k 1))))))))
        (float? v) (let [n (Double/doubleToLongBits (double v))]
                     (dotimes [k 8] (.write out (int (bit-and 0xff (bit-shift-right n (* 8 (- 7 k))))))))
        (string? v) (.write out (.getBytes ^String v StandardCharsets/UTF_8))
        :else (.write out ^bytes v)))
    (.toByteArray out)))
