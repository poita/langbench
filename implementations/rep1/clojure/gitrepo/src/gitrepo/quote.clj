(ns gitrepo.quote
  "Git's default (C-style) path quoting.")

(set! *warn-on-reflection* true)

(defn- plain? [c]
  (let [c (int c)]
    (and (<= 0x20 c 0x7e) (not= c 0x22) (not= c 0x5c))))

(defn quote-path
  "Quotes byte-string `name` the way git prints paths: unchanged when every
  byte is printable ASCII other than `\"` and `\\`, otherwise wrapped in double
  quotes with C-style escapes and three-digit octal for the other bytes."
  ^String [^String name]
  (if (every? plain? name)
    name
    (let [sb (StringBuilder. "\"")]
      (doseq [c name]
        (let [b (int c)]
          (case b
            7 (.append sb "\\a")
            8 (.append sb "\\b")
            9 (.append sb "\\t")
            10 (.append sb "\\n")
            11 (.append sb "\\v")
            12 (.append sb "\\f")
            13 (.append sb "\\r")
            34 (.append sb "\\\"")
            92 (.append sb "\\\\")
            (if (plain? c)
              (.append sb c)
              (do (.append sb \\)
                  (.append sb (char (+ 48 (bit-and 7 (bit-shift-right b 6)))))
                  (.append sb (char (+ 48 (bit-and 7 (bit-shift-right b 3)))))
                  (.append sb (char (+ 48 (bit-and 7 b)))))))))
      (.append sb \")
      (.toString sb))))
