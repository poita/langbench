(ns webhooks.hmac
  "HMAC-SHA-256 (RFC 2104) built on `webhooks.sha256`."
  (:require [webhooks.bytes :as bytes]
            [webhooks.sha256 :as sha256]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:private ^:const block-size 64)

(defn- xor-pad
  "The key padded to the block size, with every byte xor-ed with `pad`."
  ^bytes [^bytes key ^long pad]
  (let [out (byte-array block-size)]
    (dotimes [i block-size]
      (let [kb (long (if (< i (alength key)) (aget key i) 0))]
        (aset out i (unchecked-byte (bit-xor kb pad)))))
    out))

(defn hmac-sha256
  "Returns the 32-byte HMAC-SHA-256 of byte array `msg` under byte array `key`.
  A key of any length, including zero, is accepted."
  ^bytes [^bytes key ^bytes msg]
  (let [key (if (> (alength key) block-size) (sha256/digest key) key)
        inner (sha256/digest (bytes/concat-bytes (xor-pad key 0x36) msg))]
    (sha256/digest (bytes/concat-bytes (xor-pad key 0x5c) inner))))
