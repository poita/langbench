(ns json.core
  "Public API: strict JSON parsing and canonical serialization.

  ```clojure
  (require '[json.core :as json])

  (json/canonicalize \"{ \\\"b\\\": 1E+3, \\\"a\\\": [true, null] }\")
  ;;=> \"{\\\"a\\\":[true,null],\\\"b\\\":1e3}\"
  ```

  See [[json.tree]] for the tree representation returned by [[parse]]."
  (:require [json.parse :as parse]
            [json.tree :as tree]
            [json.write :as write])
  (:import (java.io InputStream)
           (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(defn- ->bytes
  ^bytes [input]
  (cond
    (bytes? input)               input
    (string? input)              (.getBytes ^String input StandardCharsets/UTF_8)
    (instance? InputStream input) (.readAllBytes ^InputStream input)
    :else (throw (IllegalArgumentException.
                  (str "expected byte array, String or InputStream, got "
                       (class input))))))

(defn parse
  "Parses one JSON document and returns its tree (see [[json.tree]]).

  `input` is a byte array (UTF-8), a String (encoded as UTF-8 first) or an
  InputStream (read to its end). The whole input must be a single valid
  document in strict RFC 8259 syntax, valid UTF-8, nested at most
  [[max-depth]] deep. Otherwise throws an exception for which [[invalid?]]
  returns true."
  [input]
  (parse/parse-bytes (->bytes input)))

(def max-depth
  "Deepest supported nesting of arrays and objects."
  parse/max-depth)

(defn invalid?
  "True if `e` is the exception [[parse]] throws for a malformed document."
  [e]
  (parse/invalid? e))

(defn valid?
  "True if `input` (see [[parse]]) is a valid JSON document."
  [input]
  (try (parse input) true
       (catch clojure.lang.ExceptionInfo e
         (if (invalid? e) false (throw e)))))

(defn serialize
  "Returns the canonical serialization of `tree` as a String.

  Object members are sorted by key in UTF-16 code unit order, with duplicate
  keys collapsed to the last occurrence; there is no insignificant whitespace;
  numbers keep their text with the exponent normalized."
  ^String [tree]
  (write/write-string tree))

(defn serialize-bytes
  "Like [[serialize]] but returns UTF-8 bytes."
  ^bytes [tree]
  (write/write-bytes tree))

(defn canonicalize
  "Parses `input` (see [[parse]]) and returns its canonical serialization as a
  String. Throws like [[parse]] for an invalid document."
  ^String [input]
  (serialize (parse input)))

(defn canonicalize-bytes
  "Like [[canonicalize]] but returns UTF-8 bytes."
  ^bytes [input]
  (serialize-bytes (parse input)))

;; Re-exported tree constructors and accessors, so callers need only this
;; namespace to build or inspect trees.

(def num-node     "See [[json.tree/num-node]]."     tree/num-node)
(def obj-node     "See [[json.tree/obj-node]]."     tree/obj-node)
(def num-node?    "See [[json.tree/num-node?]]."    tree/num-node?)
(def obj-node?    "See [[json.tree/obj-node?]]."    tree/obj-node?)
(def number-text  "See [[json.tree/number-text]]."  tree/number-text)
(def members      "See [[json.tree/members]]."      tree/members)
