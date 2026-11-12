(ns protowire.types
  "Scalar type table: wire types, defaults, range checks and the conversions
  between wire-level 64-bit patterns and Clojure values.

  Clojure representation of field values:

  | proto type                               | Clojure value                    |
  |------------------------------------------|----------------------------------|
  | int32 int64 sint32 sint64 sfixed32 sfixed64 | `long`                        |
  | uint32 fixed32                           | `long`                           |
  | uint64 fixed64                           | `long`, or `BigInt` above 2^63-1 |
  | bool                                     | `true` / `false`                 |
  | string                                   | `String`                         |
  | bytes                                    | `byte[]`                         |"
  (:require [protowire.error :as err]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

(def scalar-types
  "Scalar type name -> `{:kind k :wire-type n}`. `:kind` is one of `:varint`,
  `:fixed32`, `:fixed64`, `:string`, `:bytes`."
  {"int32"    {:kind :varint  :wire-type 0}
   "int64"    {:kind :varint  :wire-type 0}
   "uint32"   {:kind :varint  :wire-type 0}
   "uint64"   {:kind :varint  :wire-type 0}
   "sint32"   {:kind :varint  :wire-type 0}
   "sint64"   {:kind :varint  :wire-type 0}
   "bool"     {:kind :varint  :wire-type 0}
   "fixed32"  {:kind :fixed32 :wire-type 5}
   "sfixed32" {:kind :fixed32 :wire-type 5}
   "fixed64"  {:kind :fixed64 :wire-type 1}
   "sfixed64" {:kind :fixed64 :wire-type 1}
   "string"   {:kind :string  :wire-type 2}
   "bytes"    {:kind :bytes   :wire-type 2}})

(def ^:private ^java.math.BigInteger mask64
  (.subtract (.shiftLeft java.math.BigInteger/ONE 64) java.math.BigInteger/ONE))

(defn unsigned->num
  "Interprets the 64-bit pattern `raw` as unsigned: a `long` when it is
  non-negative, otherwise a `BigInt`."
  [^long raw]
  (if (neg? raw)
    (clojure.lang.BigInt/fromBigInteger (.and (java.math.BigInteger/valueOf raw) mask64))
    raw))

(defn from-varint
  "Converts the decoded varint `v` (a 64-bit pattern) to the value of `type`."
  [type ^long v]
  (case type
    :int32  (long (unchecked-int v))
    :int64  v
    :uint32 (bit-and v 0xffffffff)
    :uint64 (unsigned->num v)
    :sint32 (let [u (bit-and v 0xffffffff)]
              (bit-xor (unsigned-bit-shift-right u 1) (- (bit-and u 1))))
    :sint64 (bit-xor (unsigned-bit-shift-right v 1) (- (bit-and v 1)))
    :bool   (not (zero? v))))

(defn from-fixed32
  "Converts the little-endian 32-bit pattern `v` (0..2^32-1) to a value."
  [type ^long v]
  (if (identical? type :sfixed32) (long (unchecked-int v)) v))

(defn from-fixed64
  "Converts the 64-bit pattern `v` to a value."
  [type ^long v]
  (if (identical? type :fixed64) (unsigned->num v) v))

(def ^:private ranges
  {:int32    [-2147483648 2147483647]
   :sint32   [-2147483648 2147483647]
   :sfixed32 [-2147483648 2147483647]
   :int64    [Long/MIN_VALUE Long/MAX_VALUE]
   :sint64   [Long/MIN_VALUE Long/MAX_VALUE]
   :sfixed64 [Long/MIN_VALUE Long/MAX_VALUE]
   :uint32   [0 4294967295]
   :fixed32  [0 4294967295]
   :uint64   [0 18446744073709551615N]
   :fixed64  [0 18446744073709551615N]})

(defn check-value
  "Returns `v` (normalised) if it is a legal value for scalar `type`; throws a
  protowire error otherwise. Integers outside the type's range, non-integers
  for integer types, non-booleans for bool, etc. are rejected. Never accepts
  nil."
  [type v]
  (case type
    :bool   (if (instance? Boolean v) v (err/fail (str "expected boolean, got " (pr-str v))))
    :string (if (instance? String v) v (err/fail "expected string"))
    :bytes  (if (bytes? v) v (err/fail "expected byte array"))
    (if (integer? v)
      (let [[lo hi] (ranges type)]
        (if (<= lo v hi)
          (if (instance? Long v) v (if (<= Long/MIN_VALUE v Long/MAX_VALUE) (long v) (bigint v)))
          (err/fail (str "integer out of range for " (name type) ": " v))))
      (err/fail (str "expected integer for " (name type) ", got " (pr-str v))))))

(defn to-raw
  "Converts a value already accepted by [[check-value]] to the 64-bit pattern
  written on the wire for the numeric `type` (before zigzag for sint)."
  ^long [type v]
  (case type
    :bool   (if v 1 0)
    :sint32 (let [n (long v)]
              (bit-and (bit-xor (bit-shift-left n 1) (bit-shift-right n 31)) 0xffffffff))
    :sint64 (let [n (long v)]
              (bit-xor (bit-shift-left n 1) (bit-shift-right n 63)))
    (.longValue ^Number v)))
