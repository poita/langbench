(ns webhooks.signature
  "The Standard Webhooks signature scheme: secrets, signing and verification.

  Timestamps are handled as the decimal text that travels in the
  `webhook-timestamp` header, because the exact text is part of the signed
  content."
  (:require [clojure.string :as str]
            [webhooks.base64 :as base64]
            [webhooks.bytes :as bytes]
            [webhooks.hmac :as hmac])
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(def ^:const tolerance-seconds
  "Maximum accepted difference between the timestamp and the current time."
  300)

(def ^:const max-timestamp
  "Largest absolute timestamp value accepted."
  1000000000000000)

(defn parse-secret
  "Turns a secret string into the raw HMAC key (a byte array).

  A single leading `whsec_` is removed and the rest is Base64-decoded.
  Returns nil if the remainder is not valid Base64 or decodes to nothing."
  [^String secret]
  (let [body (if (.startsWith secret "whsec_") (subs secret 6) secret)
        key (base64/decode body)]
    (when (and key (pos? (alength ^bytes key)))
      key)))

(defn parse-timestamp
  "Parses a canonical decimal integer (`0`, or an optionally negative run of
  digits without leading zeros, absolute value at most 10^15) into a long.
  Returns nil for anything else."
  [^String s]
  (let [n (.length s)
        neg? (and (pos? n) (= \- (.charAt s 0)))
        start (if neg? 1 0)
        digits (- n start)]
    (when (and (<= 1 digits 16)
               (every? #(<= 48 (long %) 57) (subs s start))
               (or (= digits 1) (not= \0 (.charAt s start)))
               (not (and neg? (= digits 1) (= \0 (.charAt s start)))))
      (let [v (Long/parseLong s)]
        (when (<= (Math/abs v) max-timestamp)
          v)))))

(defn signed-content
  "The bytes that are signed: `id.timestamp.body`."
  ^bytes [^String id ^String timestamp ^bytes body]
  (bytes/concat-bytes (bytes/utf8 id) (bytes/ascii ".") (bytes/ascii timestamp)
                      (bytes/ascii ".") body))

(defn- mac ^bytes [^bytes key ^bytes content]
  (hmac/hmac-sha256 key content))

(defn signature-header
  "The `webhook-signature` header value for `body`: one `v1,<base64>` per key
  in `keys` (byte arrays), in order, joined by single spaces."
  ^String [keys ^String id ^String timestamp ^bytes body]
  (let [content (signed-content id timestamp body)]
    (str/join \space (map #(str "v1," (base64/encode (mac % content))) keys))))

(defn verify
  "Verifies a received webhook.

  `keys` is the sequence of active keys (byte arrays, see `parse-secret`).
  `message` is a map with:

    :id         the webhook-id string
    :timestamp  the webhook-timestamp text
    :signature  the webhook-signature header value (a string)
    :body       the payload (byte array)
    :now        the current Unix time in seconds (long)

  Returns `{:ok true :secret i :token j}` with the 0-based index of the first
  matching secret and header token, or `{:ok false :reason r}` where r is one of
  :missing-signature :invalid-timestamp :timestamp-too-old :timestamp-too-new
  :no-match."
  [keys {:keys [id timestamp signature body now]}]
  (let [tokens (vec (str/split signature #" " -1))]
    (if (every? empty? tokens)
      {:ok false :reason :missing-signature}
      (if-let [ts (parse-timestamp timestamp)]
        (let [diff (- (long now) (long ts))]
          (cond
            (> diff tolerance-seconds) {:ok false :reason :timestamp-too-old}
            (> (- diff) tolerance-seconds) {:ok false :reason :timestamp-too-new}
            :else
            (let [content (signed-content id timestamp body)
                  ;; decoded value of each `v1,<base64>` token, nil otherwise
                  decoded (mapv (fn [^String token]
                                  (let [comma (.indexOf token ",")]
                                    (when (and (>= comma 0)
                                               (= "v1" (subs token 0 comma)))
                                      (base64/decode (subs token (inc comma))))))
                                tokens)]
              (or (first
                   (for [[i key] (map-indexed vector keys)
                         :let [expected (mac key content)]
                         [j ^bytes d] (map-indexed vector decoded)
                         :when (and d (Arrays/equals expected d))]
                     {:ok true :secret i :token j}))
                  {:ok false :reason :no-match}))))
        {:ok false :reason :invalid-timestamp}))))
