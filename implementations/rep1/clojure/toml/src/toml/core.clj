(ns toml.core
  "A TOML 1.0.0 reader and writer.

  ```clojure
  (require '[toml.core :as toml])

  (toml/parse-string \"a = 1\\nb.c = [1, 2]\")
  ;=> {\"a\" 1, \"b\" {\"c\" [1 2]}}

  (toml/generate-string {:title \"Example\" :ports [80 443]})
  ;=> \"ports = [80, 443]\\ntitle = \\\"Example\\\"\\n\"
  ```

  Reading comes in two flavours.  `parse-string` and `parse-bytes` return
  ordinary Clojure data (see `toml.convert` for the type mapping).
  `parse-tagged` returns a *tagged tree* that keeps every scalar as canonical
  text together with its TOML type, which is lossless; `toml.json` can print
  such a tree in the `toml-test` interchange format.

  Invalid documents throw an `ex-info` for which [[toml.error/parse-error?]]
  is true; its data has `:line` and `:column`."
  (:require [toml.convert :as convert]
            [toml.encoder :as encoder]
            [toml.error :as error]
            [toml.parser :as parser])
  (:import (java.nio ByteBuffer)
           (java.nio.charset CharacterCodingException CodingErrorAction StandardCharsets)))

(set! *warn-on-reflection* true)

(defn parse-tagged
  "Parses the TOML text `text` into a tagged tree (see `toml.data`)."
  [^String text]
  (try
    (parser/parse text)
    (catch clojure.lang.ExceptionInfo e
      (if (error/parse-error? e) (throw (error/locate e text)) (throw e)))))

(defn decode-utf8
  "Decodes `bs` as strict UTF-8; invalid sequences are a parse error."
  ^String [^bytes bs]
  (let [decoder (doto (.newDecoder StandardCharsets/UTF_8)
                  (.onMalformedInput CodingErrorAction/REPORT)
                  (.onUnmappableCharacter CodingErrorAction/REPORT))]
    (try
      (.toString (.decode decoder (ByteBuffer/wrap bs)))
      (catch CharacterCodingException _
        (error/fail "invalid UTF-8" 0)))))

(defn parse-bytes-tagged
  "Like [[parse-tagged]] for a UTF-8 encoded byte array."
  [^bytes bs]
  (parse-tagged (decode-utf8 bs)))

(defn parse-string
  "Parses the TOML text `text` into ordinary Clojure data.  Options:
  `:key-fn` is applied to table keys (e.g. `keyword`); the default leaves
  them as strings."
  ([text] (parse-string text nil))
  ([text opts] (convert/tagged->natural (parse-tagged text) opts)))

(defn parse-bytes
  "Like [[parse-string]] for a UTF-8 encoded byte array."
  ([bs] (parse-bytes bs nil))
  ([bs opts] (convert/tagged->natural (parse-bytes-tagged bs) opts)))

(defn generate-string
  "Returns the canonical TOML text for `data`, a map (or a tagged tree).
  Keywords are accepted as keys; see `toml.convert/natural->tagged` for the
  accepted values."
  ^String [data]
  (let [tree (convert/natural->tagged data)]
    (when-not (map? tree)
      (throw (ex-info "The top level of a TOML document must be a table" {:value data})))
    (encoder/encode tree)))
