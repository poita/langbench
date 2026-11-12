(ns sqlitefile.pager
  "The database file as an in-memory sequence of pages: header parsing, page
  addressing and payload (overflow chain) assembly."
  (:require [sqlitefile.bytes :as b])
  (:import (java.nio.file Files Path)
           (java.util Arrays)))

(set! *warn-on-reflection* true)

(defrecord Db [^bytes data ^long page-size ^long usable ^long page-count])

(defn- fail [msg data]
  (throw (ex-info msg (assoc data :type :sqlitefile/corrupt))))

(def ^:private magic (.getBytes "SQLite format 3\u0000" "ISO-8859-1"))

(defn from-bytes
  "Build a [[Db]] from the complete contents of a database file."
  [^bytes data]
  (when (or (< (alength data) 100)
            (not (Arrays/equals (Arrays/copyOfRange data 0 16) ^bytes magic)))
    (fail "not a SQLite 3 database" {}))
  (let [ps (let [v (b/u16 data 16)] (if (= v 1) 65536 v))
        reserved (b/u8 data 20)
        usable (- ps reserved)]
    (when (or (< ps 512) (< usable 480))
      (fail "bad page size" {:page-size ps}))
    (->Db data ps usable (quot (alength data) ps))))

(defn open
  "Read the database file at `path` (a string, `java.io.File` or
  `java.nio.file.Path`) into memory."
  [path]
  (from-bytes (Files/readAllBytes ^Path (.toPath (java.io.File. (str path))))))

(defn page-start
  "Absolute byte offset of the first byte of page `pgno` (1-based)."
  ^long [^Db db ^long pgno]
  (when (or (< pgno 1) (> pgno (.page-count db)))
    (fail "page number out of range" {:page pgno}))
  (* (dec pgno) (.page-size db)))

(defn payload-thresholds
  "Return `[M X]` for usable size `u` as in the file-format specification;
  `table-leaf?` selects the table-leaf variant of `X`."
  [^long u table-leaf?]
  (let [m (- (quot (* (- u 12) 32) 255) 23)
        x (if table-leaf?
            (- u 35)
            (- (quot (* (- u 12) 64) 255) 23))]
    [m x]))

(defn read-payload
  "Assemble the `total`-byte payload of the cell whose payload begins at
  absolute offset `pos`, following the overflow chain when the payload does
  not fit locally. Returns a fresh `byte[]`."
  ^bytes [^Db db ^long pos ^long total table-leaf?]
  (let [^bytes data (.data db)
        u (.usable db)
        [^long m ^long x] (payload-thresholds u table-leaf?)]
    (when (or (neg? total) (> total (alength data)))
      (fail "bad payload size" {:size total}))
    (if (<= total x)
      (Arrays/copyOfRange data (int pos) (int (+ pos total)))
      (let [k (+ m (mod (- total m) (- u 4)))
            local (if (<= k x) k m)
            out (byte-array total)]
        (System/arraycopy data pos out 0 local)
        (loop [filled local
               pg (b/u32 data (+ pos local))
               hops 0]
          (when (< filled total)
            (when (or (zero? pg) (> hops (.page-count db)))
              (fail "truncated overflow chain" {:page pg}))
            (let [start (page-start db pg)
                  n (min (- u 4) (- total filled))]
              (System/arraycopy data (+ start 4) out filled n)
              (recur (+ filled n) (b/u32 data start) (inc hops)))))
        out))))
