(ns chip8.input
  "Parsing of the textual input format (ROM hex, cycle count, key schedule)."
  (:require [clojure.string :as str]))

(defn parse-hex-bytes
  "Parse a string of hex digit pairs into a vector of byte values (0-255)."
  [^String s]
  (when (odd? (count s))
    (throw (ex-info "ROM hex has odd length" {:length (count s)})))
  (vec (for [k (range 0 (count s) 2)]
         (Integer/parseInt (subs s k (+ k 2)) 16))))

(defn parse-key-schedule
  "Parse `\"9:0300 12:0000\"` into `[[9 0x0300] [12 0]]`. A blank string
  yields an empty vector."
  [s]
  (if (str/blank? s)
    []
    (vec (for [event (str/split (str/trim s) #"\s+")
               :let [[c m] (str/split event #":")]]
           [(Long/parseLong c) (Long/parseLong m 16)]))))

(defn parse-input
  "Parse the full input text into
  `{:rom [byte ...] :cycles n :keys [[cycle mask] ...]}`."
  [text]
  (let [[rom cycles keys] (str/split text #"\r?\n" 3)]
    (when (or (nil? rom) (nil? cycles))
      (throw (ex-info "Input must contain a ROM line and a cycle count" {})))
    {:rom (parse-hex-bytes (str/trim rom))
     :cycles (Long/parseLong (str/trim cycles))
     :keys (parse-key-schedule (some-> keys str/trim))}))
