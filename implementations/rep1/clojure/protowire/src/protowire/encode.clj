(ns protowire.encode
  "Clojure data -> wire bytes, in canonical form.

  Encoding is two passes over the message tree: a *plan* pass that validates
  values and computes the size of every node exactly once, and a *write* pass
  that fills a pre-sized byte array. No sub-message is encoded more than once
  and no size is recomputed per ancestor, so the work is linear in the output
  size regardless of nesting depth."
  (:require [protowire.error :as err]
            [protowire.schema :as schema]
            [protowire.types :as types]
            [protowire.wire :as wire])
  (:import (java.nio CharBuffer)
           (java.nio.charset CharacterCodingException CodingErrorAction StandardCharsets)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

(defn- string-bytes
  "UTF-8 bytes of `s`; fails if `s` holds an unpaired surrogate."
  ^bytes [^String s]
  (let [n (.length s)]
    (if (loop [i 0] (cond (>= i n) true (< (int (.charAt s i)) 128) (recur (inc i)) :else false))
      (.getBytes s StandardCharsets/ISO_8859_1)
      (try
        (let [bb (.encode (doto (.newEncoder StandardCharsets/UTF_8)
                            (.onMalformedInput CodingErrorAction/REPORT)
                            (.onUnmappableCharacter CodingErrorAction/REPORT))
                          (CharBuffer/wrap s))
              out (byte-array (.remaining bb))]
          (.get bb out)
          out)
        (catch CharacterCodingException _
          (err/fail "string is not encodable as UTF-8"))))))

(deftype Plan [^long size ^objects slots])

(declare plan-message)

(defn- element-size
  "Encoded size of numeric element `raw` of `kind`."
  ^long [kind ^long raw]
  (case kind
    :varint (wire/varint-size raw)
    :fixed32 4
    :fixed64 8))

(defn- len-field-size
  "Size of tag + length prefix + `len` payload bytes."
  ^long [^long tag ^long len]
  (+ (wire/varint-size tag) (wire/varint-size len) len))

(defn- plan-field!
  "Validates `v` for `field`, stores any plan data in `slots[i]` and returns
  the total encoded size of the field (0 if it is omitted)."
  ^long [field v ^objects slots ^long i]
  (let [type (:type field) kind (:kind field)
        tag (long (:tag field))]
    (if (:repeated? field)
      (do
        (when-not (sequential? v) (err/fail (str "field " (:name field) " expects a sequence")))
        (let [v (if (vector? v) v (vec v))
              n (count v)]
          (if (zero? n)
            0
            (case kind
              (:varint :fixed32 :fixed64)
              (let [body (loop [i 0 total 0]
                           (if (< i n)
                             (let [x (types/check-value type (nth v i))]
                               (recur (inc i) (+ total (element-size kind (types/to-raw type x)))))
                             total))]
                (aset slots i body)
                (len-field-size (:packed-tag field) body))

              :string
              (let [arr (object-array n)
                    total (loop [j 0 total 0]
                            (if (< j n)
                              (let [x (types/check-value :string (nth v j))
                                    b (string-bytes x)]
                                (aset arr j b)
                                (recur (inc j) (+ total (len-field-size tag (alength b)))))
                              total))]
                (aset slots i arr)
                total)

              :bytes
              (loop [j 0 total 0]
                (if (< j n)
                  (let [^bytes b (types/check-value :bytes (nth v j))]
                    (recur (inc j) (+ total (len-field-size tag (alength b)))))
                  total))

              :message
              (let [desc (schema/field-message field)
                    arr (object-array n)
                    total (loop [j 0 total 0]
                            (if (< j n)
                              (let [^Plan p (plan-message desc (nth v j))]
                                (aset arr j p)
                                (recur (inc j) (+ total (len-field-size tag (.size p)))))
                              total))]
                (aset slots i arr)
                total)))))
      (case kind
        (:varint :fixed32 :fixed64)
        (let [raw (types/to-raw type (types/check-value type v))]
          (if (zero? raw) 0 (+ (wire/varint-size tag) (element-size kind raw))))

        :string
        (let [b (string-bytes (types/check-value :string v))]
          (if (zero? (alength b))
            0
            (do (aset slots i b) (len-field-size tag (alength b)))))

        :bytes
        (let [^bytes b (types/check-value :bytes v)]
          (if (zero? (alength b)) 0 (len-field-size tag (alength b))))

        :message
        (let [^Plan p (plan-message (schema/field-message field) v)]
          (aset slots i p)
          (len-field-size tag (.size p)))))))

(defn- plan-message
  "Computes the Plan (total size and per-field slots) of message map `msg`."
  ^Plan [desc msg]
  (when-not (map? msg) (err/fail "message value must be a map"))
  (let [fields (:fields desc)
        n (count fields)
        slots (object-array n)]
    (loop [i 0 total 0 matched 0]
      (if (< i n)
        (let [field (nth fields i)
              k (:key field)
              v (get msg k)]
          (if (nil? v)
            (recur (inc i) total (if (contains? msg k) (inc matched) matched))
            (recur (inc i) (+ total (plan-field! field v slots i)) (inc matched))))
        (do (when-not (= matched (count msg))
              (err/fail (str "unknown field(s) in message " (:name desc))))
            (Plan. total slots))))))

(declare write-message!)

(defn- write-field!
  "Writes field `field` (value `v`, plan slot `slot`) at `pos`; returns the new
  position. Mirrors the omission rules of [[plan-field!]]."
  [^bytes out pos field v slot]
  (let [pos (long pos)
        type (:type field) kind (:kind field)
        tag (long (:tag field))]
    (if (:repeated? field)
      (let [v (if (vector? v) v (vec v))
            n (count v)]
        (if (zero? n)
          pos
          (case kind
            (:varint :fixed32 :fixed64)
            (let [pos (wire/write-varint! out pos (long (:packed-tag field)))
                  pos (wire/write-varint! out pos (long slot))]
              (loop [i 0 pos pos]
                (if (< i n)
                  (let [raw (types/to-raw type (nth v i))]
                    (recur (inc i)
                           (case kind
                             :varint (wire/write-varint! out pos raw)
                             :fixed32 (wire/write-fixed32! out pos raw)
                             :fixed64 (wire/write-fixed64! out pos raw))))
                  pos)))

            :string
            (let [^objects arr slot]
              (loop [j 0 pos pos]
                (if (< j n)
                  (let [^bytes b (aget arr j)
                        pos (wire/write-varint! out pos tag)
                        pos (wire/write-varint! out pos (alength b))]
                    (recur (inc j) (wire/write-bytes! out pos b)))
                  pos)))

            :bytes
            (loop [j 0 pos pos]
              (if (< j n)
                (let [^bytes b (nth v j)
                      pos (wire/write-varint! out pos tag)
                      pos (wire/write-varint! out pos (alength b))]
                  (recur (inc j) (wire/write-bytes! out pos b)))
                pos))

            :message
            (let [^objects arr slot
                  desc (schema/field-message field)]
              (loop [j 0 pos pos]
                (if (< j n)
                  (let [^Plan p (aget arr j)
                        pos (wire/write-varint! out pos tag)
                        pos (wire/write-varint! out pos (.size p))]
                    (recur (inc j) (long (write-message! out pos desc (nth v j) p))))
                  pos))))))
      (case kind
        (:varint :fixed32 :fixed64)
        (let [raw (types/to-raw type v)]
          (if (zero? raw)
            pos
            (let [pos (wire/write-varint! out pos tag)]
              (case kind
                :varint (wire/write-varint! out pos raw)
                :fixed32 (wire/write-fixed32! out pos raw)
                :fixed64 (wire/write-fixed64! out pos raw)))))

        :string
        (if (nil? slot)
          pos
          (let [^bytes b slot
                pos (wire/write-varint! out pos tag)
                pos (wire/write-varint! out pos (alength b))]
            (wire/write-bytes! out pos b)))

        :bytes
        (let [^bytes b v]
          (if (zero? (alength b))
            pos
            (let [pos (wire/write-varint! out pos tag)
                  pos (wire/write-varint! out pos (alength b))]
              (wire/write-bytes! out pos b))))

        :message
        (let [^Plan p slot
              pos (wire/write-varint! out pos tag)
              pos (wire/write-varint! out pos (.size p))]
          (write-message! out pos (schema/field-message field) v p))))))

(defn- write-message!
  "Writes the body of message `msg` described by `plan`; returns the new
  position."
  [^bytes out pos desc msg ^Plan plan]
  (let [pos (long pos)
        fields (:fields desc)
        n (count fields)
        ^objects slots (.slots plan)]
    (loop [i 0 pos pos]
      (if (< i n)
        (let [field (nth fields i)
              v (get msg (:key field))]
          (recur (inc i) (if (nil? v) pos (long (write-field! out pos field v (aget slots i))))))
        pos))))

(defn encode
  "Encodes message map `msg` as a message of descriptor `desc`; returns the
  canonical encoding as a byte array. Throws a protowire error if a value does
  not fit its field's type or a key is not a field of the message."
  ^bytes [desc msg]
  (let [^Plan plan (plan-message desc msg)
        out (byte-array (.size plan))
        end (write-message! out 0 desc msg plan)]
    (assert (= end (alength out)))
    out))
