(ns kvstore.wal
  "The write-ahead log (spec section 15): header, records, appending a commit
  and scanning a log for recovery."
  (:require [kvstore.bytes :as b]
            [kvstore.crc :as crc]
            [kvstore.limits :as lim])
  (:import (java.io ByteArrayOutputStream)))

(set! *warn-on-reflection* true)

(def ^:const header-size 32)
(def ^:const record-header-size 24)
(def ^:const image-record-size (+ 24 lim/page-size))
(def ^:const type-image 1)
(def ^:const type-commit 2)

(defn header-bytes
  "The constant 32-byte log header."
  ^bytes []
  (let [h (byte-array header-size)]
    (b/put-bytes! h 0 (b/utf8 "TESSWAL1"))
    (b/put-u16! h 8 1)
    (b/put-u16! h 10 lim/page-size)
    (b/put-u32! h 28 (crc/crc32 h 0 28))
    h))

(defn header-valid?
  "Whether `log` starts with a valid log header (section 16.2)."
  [^bytes log]
  (and (>= (alength log) header-size)
       (b/bytes= (b/sub log 0 8) (b/utf8 "TESSWAL1"))
       (== 1 (b/u16 log 8))
       (== lim/page-size (b/u16 log 10))
       (every? zero? (map #(b/u8 log %) (range 12 28)))
       (== (b/u32 log 28) (crc/crc32 log 0 28))))

(defn- record-crc
  "CRC over the first 20 header bytes followed by the payload."
  ^long [^bytes rec ^long payload-off ^long payload-len]
  (crc/finish (crc/update-crc (crc/update-crc crc/init rec 0 20) rec payload-off payload-len)))

(defn image-record
  "Encode a page image record for `page-no` carrying `payload` (1024 bytes)."
  ^bytes [^long txn-id ^long page-no ^bytes payload]
  (let [rec (byte-array image-record-size)]
    (b/put-u8! rec 0 type-image)
    (b/put-u64! rec 4 txn-id)
    (b/put-u32! rec 12 page-no)
    (b/put-u32! rec 16 lim/page-size)
    (b/put-bytes! rec record-header-size payload)
    (b/put-u32! rec 20 (record-crc rec record-header-size lim/page-size))
    rec))

(defn commit-record
  "Encode the commit record of a transaction with `frame-count` images."
  ^bytes [^long txn-id ^long frame-count]
  (let [rec (byte-array record-header-size)]
    (b/put-u8! rec 0 type-commit)
    (b/put-u64! rec 4 txn-id)
    (b/put-u32! rec 12 frame-count)
    (b/put-u32! rec 20 (record-crc rec record-header-size 0))
    rec))

(defn new-log
  "A fresh log buffer holding only the header."
  ^ByteArrayOutputStream []
  (doto (ByteArrayOutputStream. 4096)
    (.write (header-bytes) 0 header-size)))

(defn append-commit!
  "Append the records of one transaction to `log`: an image per entry of
  `images` (a sorted map of page number to bytes), then the commit record."
  [^ByteArrayOutputStream log ^long txn-id images]
  (doseq [[page-no ^bytes img] images]
    (let [^bytes rec (image-record txn-id page-no img)]
      (.write log rec 0 (alength rec))))
  (let [^bytes rec (commit-record txn-id (count images))]
    (.write log rec 0 (alength rec))))

(defn reset-log!
  "Truncate `log` back to its bare header."
  [^ByteArrayOutputStream log]
  (.reset log)
  (.write log (header-bytes) 0 header-size))

(defn scan
  "Scan a log image for recovery (sections 16.2-16.4).  Returns a map with
  `:valid-end`, the offset just past the last accepted commit record (the log
  is to be trimmed to that length), and `:images`, the committed page images
  as a vector of `[page-no bytes]` in file order."
  [^bytes log]
  (if-not (header-valid? log)
    {:valid-end header-size :images [] :header-ok? false}
    (let [len (alength log)]
      (loop [off (long header-size)
             group-txn nil
             group []
             valid-end (long header-size)
             committed (transient [])]
        (let [stop (fn [] {:valid-end valid-end :images (persistent! committed)
                           :header-ok? true})
              rem (- len off)]
          (if (< rem record-header-size)
            (stop)
            (let [typ (b/u8 log off)
                  payload-len (b/u32 log (+ off 16))
                  field12 (b/u32 log (+ off 12))
                  txn (b/u64 log (+ off 4))
                  ok? (and (or (== typ type-image) (== typ type-commit))
                           (zero? (b/u8 log (+ off 1)))
                           (zero? (b/u8 log (+ off 2)))
                           (zero? (b/u8 log (+ off 3)))
                           (if (== typ type-image) (== payload-len lim/page-size) (zero? payload-len))
                           (>= field12 1)
                           (>= rem (+ record-header-size payload-len))
                           (let [c (crc/finish
                                    (crc/update-crc (crc/update-crc crc/init log off 20)
                                                    log (+ off record-header-size) payload-len))]
                             (== c (b/u32 log (+ off 20)))))]
              (cond
                (not ok?) (stop)

                (== typ type-image)
                (if (and group-txn (not (== group-txn txn)))
                  (stop)
                  (recur (+ off image-record-size) txn
                         (conj group [field12 (b/sub log (+ off record-header-size)
                                                     (+ off image-record-size))])
                         valid-end committed))

                :else
                (if (and group-txn (== group-txn txn) (== (count group) field12))
                  (recur (+ off record-header-size) nil [] (+ off record-header-size)
                         (reduce conj! committed group))
                  (stop))))))))))
