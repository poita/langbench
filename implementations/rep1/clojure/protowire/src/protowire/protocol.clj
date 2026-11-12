(ns protowire.protocol
  "The line-oriented request protocol: a schema, a `--` separator line, and one
  `decode <Name> <hex>` / `encode <Name> <text>` request per line.

  [[run]] maps the whole input text to the whole output text; [[handle-request]]
  answers a single request line. Malformed requests yield the line `error`."
  (:require [protowire.decode :as decode]
            [protowire.encode :as encode]
            [protowire.error :as err]
            [protowire.hex :as hex]
            [protowire.schema :as schema]
            [protowire.text :as text]))

(set! *warn-on-reflection* true)

(defn- decode-request [desc ^String line ^long hex-start]
  (let [bytes (hex/hex->bytes line hex-start (.length line))]
    (text/append-message! (StringBuilder.) desc (decode/decode desc bytes))))

(defn- encode-request [desc ^String line ^long text-start]
  (let [msg (text/parse (subs line text-start) desc)]
    (hex/bytes->hex (encode/encode desc msg))))

(defn- append-request!
  "Appends the answer to `line` to `sb` (without newline)."
  [^StringBuilder sb schema ^String line]
  (let [sp1 (.indexOf line " ")
        sp2 (if (neg? sp1) -1 (.indexOf line " " (int (inc sp1))))
        cmd (if (neg? sp1) line (subs line 0 sp1))
        name (cond (neg? sp1) nil
                   (neg? sp2) (subs line (inc sp1))
                   :else (subs line (inc sp1) sp2))
        desc (when name (get-in schema [:messages name]))]
    (cond
      (nil? desc) (err/fail "unknown message")
      (= cmd "decode")
      (cond (neg? sp2) (text/append-message! sb desc (decode/decode desc (byte-array 0)))
            ;; `decode Name ` (empty after the separating space) is an error
            (= (inc sp2) (.length line)) (err/fail "trailing space")
            :else (let [bytes (hex/hex->bytes line (inc sp2) (.length line))]
                    (text/append-message! sb desc (decode/decode desc bytes))))
      (= cmd "encode")
      (if (neg? sp2)
        (err/fail "missing message text")
        (hex/append-hex! sb (encode/encode desc (text/parse (subs line (inc sp2)) desc))))
      :else (err/fail "unknown command"))))

(defn handle-request
  "Answers one request line against `schema`: the decoded text, the encoded
  hex, or the string \"error\"."
  ^String [schema ^String line]
  (try
    (let [sb (StringBuilder.)]
      (append-request! sb schema line)
      (str sb))
    (catch Exception _ "error")
    (catch StackOverflowError _ "error")))

(defn split-input
  "Splits input text into `[schema-text request-lines]` at the first line that
  is exactly `--`. Without such a line everything is schema."
  [^String input]
  (let [n (.length input)]
    (loop [start 0]
      (if (>= start n)
        [input []]
        (let [nl (.indexOf input "\n" (int start))
              end (if (neg? nl) n nl)]
          (if (and (= (- end start) 2) (.startsWith input "--" (int start)))
            [(subs input 0 start)
             (loop [s (if (neg? nl) n (inc nl)) acc (transient [])]
               (if (>= s n)
                 (persistent! acc)
                 (let [nl (.indexOf input "\n" (int s))
                       e (if (neg? nl) n nl)]
                   (recur (inc e) (conj! acc (subs input s e))))))]
            (if (neg? nl) [input []] (recur (inc nl)))))))))

(defn run
  "Processes a complete input text and returns the complete output text (one
  line per request, each terminated by a newline)."
  ^String [^String input]
  (let [[schema-text lines] (split-input input)
        sb (StringBuilder.)]
    (if-let [schema (try (schema/parse schema-text) (catch Exception _ nil))]
      (doseq [^String line lines]
        (.append sb (handle-request schema line))
        (.append sb \newline))
      (doseq [_ lines] (.append sb "error\n")))
    (str sb)))
