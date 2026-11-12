(ns orderbook.command
  "Command data and the text parser.

  A command is a map with an `:op`:

      {:op :limit   :id \"a\" :side :buy :price 100 :qty 5 :tif :gtc}
      {:op :market  :id \"a\" :side :sell :qty 5}
      {:op :cancel  :id \"a\"}
      {:op :replace :id \"a\" :price 101 :qty 3}
      {:op :book}

  `:side` is `:buy` or `:sell`; `:tif` is `:gtc` (default), `:ioc` or `:fok`.")

(set! *warn-on-reflection* true)

(defn- tokens
  "Splits `line` on single spaces."
  ^java.util.ArrayList [^String line]
  (let [out (java.util.ArrayList. 6)
        n (.length line)]
    (loop [start 0]
      (let [i (.indexOf line (int \space) (int start))]
        (if (neg? i)
          (.add out (.substring line start n))
          (do (.add out (.substring line start i))
              (recur (inc i))))))
    out))

(defn- side [^String s]
  (case s
    "BUY" :buy
    "SELL" :sell
    (throw (ex-info (str "Bad side: " s) {:side s}))))

(defn- num* ^long [^String s] (Long/parseLong s))

(defn parse-line
  "Parses one command line of the text protocol into a command map.
  Throws `ex-info` on a line that is not a valid command."
  [^String line]
  (let [^java.util.ArrayList t (tokens line)
        n (.size t)
        tok (fn [i] (.get t (int i)))]
    (case (tok 0)
      "LIMIT" (if (or (== n 5) (== n 6))
                {:op :limit :id (tok 1) :side (side (tok 2))
                 :price (num* (tok 3)) :qty (num* (tok 4))
                 :tif (if (== n 6)
                        (case (tok 5)
                          "IOC" :ioc
                          "FOK" :fok
                          (throw (ex-info (str "Bad flag: " (tok 5)) {:line line})))
                        :gtc)}
                (throw (ex-info (str "Bad LIMIT: " line) {:line line})))
      "MARKET" {:op :market :id (tok 1) :side (side (tok 2)) :qty (num* (tok 3))}
      "CANCEL" {:op :cancel :id (tok 1)}
      "REPLACE" {:op :replace :id (tok 1) :price (num* (tok 2)) :qty (num* (tok 3))}
      "BOOK" {:op :book}
      (throw (ex-info (str "Unknown command: " line) {:line line})))))
