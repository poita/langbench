(ns webhooks.fields
  "Parsing and validation of the argument kinds used on command lines.

  Every parser takes the field text and returns the parsed value, or nil when
  the field is invalid. (Parsed values are never nil or false, so nil is
  unambiguous.)"
  (:require [clojure.string :as str]
            [webhooks.hex :as hex]
            [webhooks.signature :as signature]))

(set! *warn-on-reflection* true)

(defn split-fields
  "Splits `line` on single space characters, keeping empty fields."
  [^String line]
  (str/split line #" " -1))

(defn hex-bytes
  "A `<hex>` or `<text-hex>` field: lowercase hex digits, or `-` for no
  bytes. Returns a byte array."
  [^String s]
  (if (= s "-") (byte-array 0) (when (seq s) (hex/decode s))))

(defn- printable? [^String s lo hi]
  (and (<= lo (.length s) hi)
       (every? #(<= 0x21 (long %) 0x7e) s)))

(defn id
  "An `<id>`: 1..256 printable ASCII characters other than space."
  [^String s]
  (when (printable? s 1 256) s))

(defn received-text
  "A received timestamp field: 1..64 printable ASCII characters."
  [^String s]
  (when (printable? s 1 64) s))

(defn int-field
  "An `<int>`: canonical decimal integer, absolute value at most 10^15."
  [^String s]
  (signature/parse-timestamp s))

(defn secret
  "A `<secret>`; returns the raw key bytes."
  [^String s]
  (when (and (printable? s 1 512) (not (str/includes? s ",")))
    (signature/parse-secret s)))

(defn secrets
  "A `<secrets>` field: 1..16 comma-joined secrets. Returns a vector of keys."
  [^String s]
  (let [parts (str/split s #"," -1)]
    (when (<= 1 (count parts) 16)
      (let [ks (mapv secret parts)]
        (when (every? some? ks) ks)))))

(defn name-token
  "1..64 characters from [A-Za-z0-9_.-] (endpoint/event ids, event types)."
  [^String s]
  (when (and (<= 1 (.length s) 64)
             (every? #(or (<= 48 (long %) 57) (<= 65 (long %) 90)
                          (<= 97 (long %) 122) (#{\_ \. \-} %))
                     s))
    s))

(defn filter-field
  "An endpoint filter: `*` (returns :all) or 1..16 comma-separated event
  types (returns a set)."
  [^String s]
  (if (= s "*")
    :all
    (let [parts (str/split s #"," -1)]
      (when (<= 1 (count parts) 16)
        (let [types (mapv name-token parts)]
          (when (every? some? types) (set types)))))))

(defn- response [^String s]
  (cond (= s "timeout") :timeout
        (re-matches #"[1-5][0-9][0-9]" s)
        (let [v (Long/parseLong s)] (when (<= 100 v 599) v))))

(defn script
  "An endpoint script: 1..64 comma-separated responses, each a status code
  100..599 or `timeout`. Returns a vector of longs and :timeout."
  [^String s]
  (let [parts (str/split s #"," -1)]
    (when (<= 1 (count parts) 64)
      (let [rs (mapv response parts)]
        (when (every? some? rs) rs)))))
