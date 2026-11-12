(ns inflate.core
  "Pure-Clojure DEFLATE (RFC 1951) decompression.

      (require '[inflate.core :as inflate])
      (inflate/inflate-hex \"4b4c4a862000\")  ;=> \"616263616263616263\"

  Malformed input raises an `ex-info` whose data is `{:type :inflate/malformed}`;
  test for it with `malformed?`."
  (:require [inflate.decoder :as decoder]
            [inflate.error :as err]
            [inflate.hex :as hex]))

(defn inflate
  "Decompresses the raw DEFLATE stream in the byte array `data` and returns the
  result as a byte array. There is no zlib/gzip wrapper, and bytes after the
  final block are an error.

  Options: `:max-output` - maximum number of bytes to produce (a guard against
  decompression bombs); exceeding it counts as malformed input.

  Throws (see `malformed?`) if the stream is invalid, truncated or has trailing
  data."
  (^bytes [data] (inflate data {}))
  (^bytes [data opts] (decoder/inflate-stream data opts)))

(defn inflate-hex
  "Like `inflate`, but takes and returns lowercase hex strings."
  (^String [s] (inflate-hex s {}))
  (^String [s opts] (hex/encode (inflate (hex/decode s) opts))))

(def malformed?
  "True if the given Throwable reports a malformed DEFLATE stream."
  err/malformed?)
