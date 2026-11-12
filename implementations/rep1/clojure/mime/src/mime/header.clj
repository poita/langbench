(ns mime.header
  "Header block parsing: finds where the headers end, unfolds fields and
  decodes them as UTF-8."
  (:require [mime.bytes :as bytes]
            [mime.charset :as charset]
            [mime.rfc2047 :as rfc2047]
            [mime.text :as text])
  (:import (java.io ByteArrayOutputStream)))

(set! *warn-on-reflection* true)

(defn- field-line?
  "True when the line `[from, to)` of `b` is `name:` with a non-empty name of
  printable ASCII characters other than SPACE and `:`."
  [^bytes b ^long from ^long to]
  (loop [i from]
    (if (>= i to)
      false
      (let [x (bit-and (aget b i) 0xff)]
        (cond (== x 0x3A) (> i from)
              (and (>= x 0x21) (<= x 0x7E)) (recur (inc i))
              :else false)))))

(defn- make-field
  [^ByteArrayOutputStream out]
  (let [s (charset/decode-utf8 (.toByteArray out))
        colon (.indexOf s ":")
        name (.substring s 0 colon)]
    {:name name
     :key (text/ascii-lower (text/strip name))
     :raw (.substring s (inc colon))}))

(defn parse-block
  "Parses the header block at the start of the message `data` (line endings
  already normalised to LF).

  Returns `{:fields [...] :body-start i}`. Each field is
  `{:name :key :raw}`: the unfolded, UTF-8 decoded name, the name stripped and
  lower-cased, and the raw value after the first colon."
  [^bytes data]
  (let [n (alength data)]
    (loop [pos 0 fields [] cur nil]
      (let [finish (fn [body-start]
                     {:fields (if cur (conj fields (make-field cur)) fields)
                      :body-start body-start})]
        (if (>= pos n)
          (finish n)
          (let [le (bytes/index-of-lf data pos n)
                len (- le pos)
                nxt (min n (inc le))
                x (aget data pos)]
            (cond
              (zero? len) (finish nxt)

              (and cur (or (== x 0x20) (== x 0x09)))
              (do (.write ^ByteArrayOutputStream cur data (int pos) (int len))
                  (recur nxt fields cur))

              (field-line? data pos le)
              (let [fields (if cur (conj fields (make-field cur)) fields)
                    out (ByteArrayOutputStream.)]
                (.write out data (int pos) (int len))
                (recur nxt fields out))

              :else (finish pos))))))))

(defn find-field
  "The first field whose key equals `key` (lower case), or nil."
  [fields ^String key]
  (some #(when (= (:key %) key) %) fields))

(def ^:private collapsed-names
  #{"content-disposition" "content-id" "content-transfer-encoding"
    "content-type" "date" "in-reply-to" "message-id" "mime-version"
    "received" "references" "return-path"})

(defn display-value
  "The value of `field` as shown in the dump: whitespace-collapsed for the
  fields in a fixed list, otherwise decoded as unstructured text."
  ^String [{:keys [key raw]}]
  (if (contains? collapsed-names key)
    (text/collapse raw)
    (rfc2047/decode-unstructured raw)))
