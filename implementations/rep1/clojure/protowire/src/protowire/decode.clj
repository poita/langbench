(ns protowire.decode
  "Wire bytes -> Clojure data.

  A decoded message is a map from field keyword (`(keyword field-name)`) to
  value. Only fields that occurred on the wire are present; repeated fields
  are vectors; sub-messages are maps. Unknown fields are dropped."
  (:require [protowire.error :as err]
            [protowire.schema :as schema]
            [protowire.types :as types]
            [protowire.wire :as wire])
  (:import (java.nio ByteBuffer)
           (java.nio.charset CharacterCodingException StandardCharsets)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

(defn- decode-string
  "Strictly validates and decodes bytes [start, start+len) as UTF-8."
  ^String [^bytes buf ^long start ^long len]
  (let [end (+ start len)]
    (if (loop [i start]
          (cond (>= i end) true
                (neg? (aget buf i)) false
                :else (recur (inc i))))
      (String. buf (int start) (int len) StandardCharsets/ISO_8859_1)
      (try
        (str (.decode (doto (.newDecoder StandardCharsets/UTF_8)
                        (.onMalformedInput java.nio.charset.CodingErrorAction/REPORT)
                        (.onUnmappableCharacter java.nio.charset.CodingErrorAction/REPORT))
                      (ByteBuffer/wrap buf (int start) (int len))))
        (catch CharacterCodingException _
          (err/fail "invalid UTF-8 in string field"))))))

(defn- read-element
  "Reads one unpacked/packed element of numeric `type`/`kind` at the cursor."
  [type kind ^bytes buf ^longs pos end]
  (case kind
    :varint  (types/from-varint type (wire/read-varint buf pos end 10))
    :fixed32 (types/from-fixed32 type (wire/read-fixed32 buf pos end))
    :fixed64 (types/from-fixed64 type (wire/read-fixed64 buf pos end))))

(declare decode-message)

(defn- decode-packed
  "Appends the elements of a packed payload of `len` bytes to vector `acc`."
  [field acc ^bytes buf ^longs pos end len]
  (let [len (long len)
        type (:type field) kind (:kind field)
        pend (+ (aget pos 0) len)]
    (when (and (identical? kind :fixed32) (not (zero? (rem len 4))))
      (err/fail "packed fixed32 length not a multiple of 4"))
    (when (and (identical? kind :fixed64) (not (zero? (rem len 8))))
      (err/fail "packed fixed64 length not a multiple of 8"))
    (loop [acc (transient acc)]
      (if (< (aget pos 0) pend)
        (recur (conj! acc (read-element type kind buf pos pend)))
        (persistent! acc)))))

(defn- decode-known
  "Handles an occurrence of known `field` with wire type `wt`; returns the
  updated message map `m`."
  [m field ^bytes buf ^longs pos end fnum wt]
  (let [wt (long wt)
        k (:key field)
        kind (:kind field)
        repeated? (:repeated? field)]
    (cond
      (= wt (long (:wire-type field)))
      (let [v (case kind
                :message
                (let [len (wire/read-length buf pos end)
                      sub-end (+ (aget pos 0) len)
                      sub (decode-message (schema/field-message field) buf pos sub-end
                                          (if repeated? {} (get m k {})))]
                  sub)
                :string
                (let [len (wire/read-length buf pos end)
                      p (aget pos 0)
                      s (decode-string buf p len)]
                  (aset pos 0 (+ p len))
                  s)
                :bytes
                (let [len (wire/read-length buf pos end)
                      p (aget pos 0)
                      b (java.util.Arrays/copyOfRange buf (int p) (int (+ p len)))]
                  (aset pos 0 (+ p len))
                  b)
                (read-element (:type field) kind buf pos end))]
        (if repeated?
          (assoc m k (conj (get m k []) v))
          (assoc m k v)))

      (and (= wt 2) (:packable? field))
      (let [len (wire/read-length buf pos end)
            acc (decode-packed field (get m k []) buf pos end len)]
        (if (zero? len) m (assoc m k acc)))

      :else
      (do (wire/skip-field! buf pos end fnum wt) m))))

(defn decode-message
  "Decodes the message occupying the bytes from the cursor `pos` up to `end`
  using descriptor `desc`, merging into the existing message map `init`.
  Leaves the cursor at `end`."
  [desc ^bytes buf ^longs pos end init]
  (let [end (long end)
        by-number (:by-number desc)]
    (loop [m init]
      (if (< (aget pos 0) end)
        (let [tag (wire/read-tag buf pos end)
              fnum (unsigned-bit-shift-right tag 3)
              wt (bit-and tag 7)]
          (when (zero? fnum) (err/fail "field number 0"))
          (when (or (= wt 4) (= wt 6) (= wt 7)) (err/fail "invalid wire type"))
          (if-let [field (get by-number fnum)]
            (recur (decode-known m field buf pos end fnum wt))
            (do (wire/skip-field! buf pos end fnum wt) (recur m))))
        m))))

(defn decode
  "Decodes byte array `buf` as a message of descriptor `desc`; returns the
  message map. Throws a protowire error on malformed input."
  [desc ^bytes buf]
  (decode-message desc buf (long-array 1) (alength buf) {}))
