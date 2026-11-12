(ns typeinfer.lexer
  "Tokeniser for the mini-ML language.

  A token is a vector `[kind text offset]` where `kind` is one of

  * `:int`   – an integer literal (`text` is its digits),
  * `:ident` – an identifier,
  * `:tok`   – a keyword or a symbol (`text` is e.g. \"let\" or \"->\").

  `offset` is the index of the first character in the source string and is
  only used for error messages.")

(set! *warn-on-reflection* true)

(def ^:private keywords
  #{"let" "rec" "in" "fun" "if" "then" "else" "true" "false"})

(def ^:private two-char-symbols
  #{";;" "->" "::" "<=" ">=" "&&" "||"})

(def ^:private one-char-symbols
  #{\( \) \[ \] \; \, \+ \- \* \/ \= \< \>})

(defn- ws? [^Character c]
  (case c (\space \tab \return \newline) true false))

(defn- digit? [c] (let [c (char c)] (and (>= (int c) 48) (<= (int c) 57))))

(defn- lower? [c] (let [c (int (char c))] (and (>= c 97) (<= c 122))))

(defn- ident-char? [c]
  (let [c (int (char c))]
    (or (and (>= c 97) (<= c 122))
        (and (>= c 65) (<= c 90))
        (and (>= c 48) (<= c 57))
        (= c 95))))

(defn tokenize
  "Split `src` into a vector of tokens. Throws `ex-info` with
  `{:kind :syntax}` on a character that cannot start a token."
  [^String src]
  (let [n (.length src)]
    (loop [i 0, acc (transient [])]
      (if (>= i n)
        (persistent! acc)
        (let [c (.charAt src i)]
          (cond
            (ws? c)
            (recur (inc i) acc)

            (digit? c)
            (let [j (loop [j (inc i)]
                      (if (and (< j n) (digit? (.charAt src j))) (recur (inc j)) j))]
              (recur (long j) (conj! acc [:int (.substring src i j) i])))

            (lower? c)
            (let [j (loop [j (inc i)]
                      (if (and (< j n) (ident-char? (.charAt src j))) (recur (inc j)) j))
                  text (.substring src i j)]
              (recur (long j) (conj! acc [(if (keywords text) :tok :ident) text i])))

            :else
            (let [two (when (< (inc i) n) (.substring src i (+ i 2)))]
              (cond
                (and two (two-char-symbols two))
                (recur (+ i 2) (conj! acc [:tok two i]))

                (one-char-symbols c)
                (recur (inc i) (conj! acc [:tok (str c) i]))

                :else
                (throw (ex-info (str "unexpected character '" c "' at offset " i)
                                {:kind :syntax :offset i}))))))))))
