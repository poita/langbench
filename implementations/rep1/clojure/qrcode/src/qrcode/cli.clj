(ns qrcode.cli
  "Command-line tool: reads query lines `<ecl> <mask> <text>` from stdin and
  writes the encoded symbols to stdout. See README.md for the format."
  (:require [qrcode.core :as qr]
            [qrcode.render :as render])
  (:import (java.io BufferedOutputStream ByteArrayOutputStream InputStream)
           (java.nio.charset StandardCharsets)
           (java.util Arrays))
  (:gen-class))

(set! *warn-on-reflection* true)

(def ^:private ecl-codes {"L" :l, "M" :m, "Q" :q, "H" :h})

(defn- read-all-bytes ^bytes [^InputStream in]
  (let [out (ByteArrayOutputStream.)]
    (.transferTo in out)
    (.toByteArray out)))

(defn split-lines
  "Splits `data` on newline bytes into a vector of byte arrays. A final
  newline is optional and does not produce an empty trailing line."
  [^bytes data]
  (let [n (alength data)]
    (loop [start 0, i 0, acc (transient [])]
      (cond
        (== i n) (persistent! (if (< start n)
                                (conj! acc (Arrays/copyOfRange data start n))
                                acc))
        (== (aget data i) 10) (recur (inc i) (inc i)
                                     (conj! acc (Arrays/copyOfRange data start i)))
        :else (recur start (inc i) acc)))))

(defn- index-of-space ^long [^bytes line ^long from]
  (loop [i from]
    (cond (>= i (alength line)) -1
          (== (aget line i) 32) i
          :else (recur (inc i)))))

(defn parse-query
  "Parses one query line (a byte array `<ecl> <mask> <text>`) into
  `[ecl mask text-bytes]`, where `ecl` is :l/:m/:q/:h and `mask` is 0..7 or
  :auto. Throws ex-info when the line is malformed."
  [^bytes line]
  (let [a (index-of-space line 0)
        b (if (neg? a) -1 (index-of-space line (inc a)))]
    (when (or (neg? a) (neg? b) (== (inc b) (alength line)))
      (throw (ex-info "Expected '<ecl> <mask> <text>'"
                      {:line (String. line StandardCharsets/UTF_8)})))
    (let [ecl-token (String. line 0 (int a) StandardCharsets/UTF_8)
          mask-token (String. line (int (inc a)) (int (- b a 1)) StandardCharsets/UTF_8)
          ecl (or (ecl-codes ecl-token)
                  (throw (ex-info "Unknown error correction level" {:ecl ecl-token})))
          mask (if (= mask-token "auto")
                 :auto
                 (let [m (when (re-matches #"[0-7]" mask-token) (parse-long mask-token))]
                   (or m (throw (ex-info "Mask must be 0..7 or auto" {:mask mask-token})))))]
      [ecl mask (Arrays/copyOfRange line (int (inc b)) (alength line))])))

(defn run-query
  "Encodes one query line (byte array) and returns the output text."
  [^bytes line]
  (let [[ecl mask text] (parse-query line)]
    (str (render/append-symbol! (StringBuilder.) (qr/encode-bytes text ecl mask)))))

(defn process
  "Reads queries from `in` and writes symbols to `out` in input order."
  [^InputStream in ^java.io.OutputStream out]
  (let [lines (split-lines (read-all-bytes in))
        out (BufferedOutputStream. out 65536)]
    (doseq [^String s (pmap run-query lines)]
      (.write out (.getBytes s StandardCharsets/ISO_8859_1)))
    (.flush out)))

(defn -main
  "Entry point: stdin -> stdout. Exits 0 on success, 1 on a bad query."
  [& _args]
  (try
    (process System/in System/out)
    (shutdown-agents)
    (catch Exception e
      (binding [*out* *err*]
        (println "error:" (ex-message e) (pr-str (ex-data e))))
      (shutdown-agents)
      (System/exit 1))))
