(ns webhooks.commands
  "The line-oriented command protocol: parse a command line, run it against
  the library, and render the result."
  (:require [clojure.string :as str]
            [webhooks.base64 :as base64]
            [webhooks.block :as block]
            [webhooks.bytes :as bytes]
            [webhooks.fields :as f]
            [webhooks.hex :as hex]
            [webhooks.hmac :as hmac]
            [webhooks.sha256 :as sha256]
            [webhooks.signature :as signature]
            [webhooks.simulator :as simulator]))

(set! *warn-on-reflection* true)

(defn- hex-or-dash
  "Hex of `bs`, or `-` for an empty array."
  [^bytes bs]
  (if (zero? (alength bs)) "-" (hex/encode bs)))

(defn- text-or-dash [^String s]
  (if (.isEmpty s) "-" s))

(defn- with-fields
  "Applies `parsers` to the fields after the command name and calls `f` with
  the results, or returns \"error\" if the field count is wrong or any parser
  rejects its field."
  [fields parsers f]
  (if (= (count fields) (inc (count parsers)))
    (let [vals (mapv (fn [p field] (p field)) parsers (rest fields))]
      (if (every? some? vals)
        (apply f vals)
        "error"))
    "error"))

(defn- verify-line [keys id ts now header body]
  (let [r (signature/verify keys {:id id :timestamp ts :now now
                                  :signature (bytes/latin1-string header)
                                  :body body})]
    (if (:ok r)
      (str "ok " (:secret r) " " (:token r))
      (str "fail " (name (:reason r))))))

(defn- format-simulation [{:keys [attempts deliveries]}]
  (let [sb (StringBuilder.)]
    (.append sb (str "sim " (count attempts) " " (count deliveries)))
    (doseq [a attempts]
      (.append sb (str "\nattempt " (:seq a) " " (:event a) " " (:endpoint a) " "
                       (:n a) " " (:ts a) " " (name (:outcome a)) " "
                       (or (:code a) "-"))))
    (doseq [d deliveries]
      (.append sb (str "\ndelivery " (:event d) " " (:endpoint d) " "
                       (name (:status d)) " " (:attempts d) " "
                       (or (:last-ts d) "-") " " (:header d))))
    (.toString sb)))

(defn run-command
  "Executes one non-simulate command line and returns its output string."
  [^String line]
  (let [fields (f/split-fields line)]
    (case (first fields)
      "sha256" (with-fields fields [f/hex-bytes]
                 #(hex/encode (sha256/digest %)))
      "hmac" (with-fields fields [f/hex-bytes f/hex-bytes]
               #(hex/encode (hmac/hmac-sha256 %1 %2)))
      "b64enc" (with-fields fields [f/hex-bytes]
                 #(text-or-dash (base64/encode %)))
      "b64urlenc" (with-fields fields [f/hex-bytes]
                    #(text-or-dash (base64/encode-url %)))
      "b64dec" (with-fields fields [f/hex-bytes]
                 (fn [bs]
                   (if-let [out (base64/decode (bytes/latin1-string bs))]
                     (hex-or-dash out)
                     "error")))
      "secret" (with-fields fields [f/secret] hex-or-dash)
      "sign" (with-fields fields [f/secrets f/id f/int-field f/hex-bytes]
               (fn [keys id ts body]
                 (signature/signature-header keys id (str ts) body)))
      "verify" (with-fields fields [f/secrets f/id f/received-text f/int-field
                                    f/hex-bytes f/hex-bytes]
                 verify-line)
      "error")))

(defn- run-simulate
  "Reads a simulate block from `lines` (which follow the `simulate` line).
  Returns [output remaining-lines]."
  [lines]
  (let [[blk more] (block/read-block lines)]
    [(if blk
       (format-simulation (simulator/simulate (:endpoints blk) (:events blk)))
       "error")
     more]))

(defn process
  "Processes a sequence of input lines (blank lines already removed) and
  returns a lazy sequence of output strings, one per command."
  [lines]
  (lazy-seq
   (when-let [lines (seq lines)]
     (let [line (first lines)]
       (if (= line "simulate")
         (let [[out more] (run-simulate (rest lines))]
           (cons out (process more)))
         (cons (run-command line) (process (rest lines))))))))
