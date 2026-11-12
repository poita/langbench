(ns protowire.core
  "Public API of protowire: a Protocol Buffers (proto3) wire-format codec driven
  by a small schema language.

      (require '[protowire.core :as pw])

      (def schema (pw/parse-schema \"message M { int32 a = 1; repeated string s = 2; }\"))

      (pw/encode-hex schema \"M\" {:a 150 :s [\"x\"]})   ;=> \"089601120178\"
      (pw/decode-hex schema \"M\" \"089601120178\")      ;=> {:a 150, :s [\"x\"]}
      (pw/format-text schema \"M\" {:a 150})             ;=> \"{a: 150}\"
      (pw/parse-text schema \"M\" \"{a: 150}\")           ;=> {:a 150}

  Messages are Clojure maps keyed by `(keyword field-name)`; see
  [[protowire.types]] for how scalar values are represented. Malformed
  input raises an exception for which [[error?]] is true."
  (:require [protowire.decode :as decode]
            [protowire.encode :as encode]
            [protowire.error :as err]
            [protowire.hex :as hex]
            [protowire.protocol :as protocol]
            [protowire.schema :as schema]
            [protowire.text :as text]))

(defn parse-schema
  "Parses schema source text (see README) into a schema value."
  [schema-text]
  (schema/parse schema-text))

(defn error?
  "True if `e` is an exception signalling malformed schema, wire data, text or
  values."
  [e]
  (err/protowire-error? e))

(defn decode
  "Decodes byte array `bs` as message `message-name` of `schema`; returns a
  map. Only fields present on the wire appear (defaults included); unknown
  fields are dropped."
  [schema message-name ^bytes bs]
  (decode/decode (schema/message schema message-name) bs))

(defn encode
  "Encodes message map `msg` as message `message-name` of `schema` in
  canonical form (fields in number order, defaults omitted, repeated numeric
  fields packed); returns a byte array."
  ^bytes [schema message-name msg]
  (encode/encode (schema/message schema message-name) msg))

(defn format-text
  "Canonical text form of message map `msg`, e.g. `{a: 1, s: [\"x\"]}`."
  ^String [schema message-name msg]
  (text/format-message (schema/message schema message-name) msg))

(defn parse-text
  "Parses text form into a message map (inverse of [[format-text]], and more
  lenient about whitespace and field order)."
  [schema message-name ^String s]
  (text/parse s (schema/message schema message-name)))

(defn decode-hex
  "Like [[decode]] on the bytes of lowercase hex string `hex-string`."
  [schema message-name ^String hex-string]
  (decode schema message-name (hex/hex->bytes hex-string)))

(defn encode-hex
  "Like [[encode]], returning lowercase hex."
  ^String [schema message-name msg]
  (hex/bytes->hex (encode schema message-name msg)))

(defn run-requests
  "Processes a protowire request document (schema, a `--` line, then one
  `decode`/`encode` request per line) and returns the output text. This is the
  function behind the command-line tool."
  ^String [^String input]
  (protocol/run input))
