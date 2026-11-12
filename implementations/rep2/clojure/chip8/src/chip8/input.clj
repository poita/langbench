(ns chip8.input
  "Parsing of the textual job format: ROM hex, cycle count, key schedule."
  (:require [clojure.string :as str]))

(defn parse-hex-bytes
  "Parses a string of hex digit pairs into a vector of byte values 0-255."
  [^String s]
  (mapv #(Long/parseLong (subs s % (+ % 2)) 16) (range 0 (count s) 2)))

(defn parse-schedule
  "Parses `\"9:0300 12:0000\"` into `[[9 0x300] [12 0]]`. Blank/nil gives []."
  [s]
  (if (str/blank? s)
    []
    (mapv (fn [ev]
            (let [[c mask] (str/split ev #":")]
              [(Long/parseLong c) (Long/parseLong mask 16)]))
          (str/split (str/trim s) #" +"))))

(defn parse-input
  "Parses the job text into `{:rom [byte ...] :cycles n :schedule [[cycle mask] ...]}`."
  [text]
  (let [[rom cycles schedule] (str/split-lines text)]
    {:rom (parse-hex-bytes (str/trim rom))
     :cycles (Long/parseLong (str/trim cycles))
     :schedule (parse-schedule schedule)}))
