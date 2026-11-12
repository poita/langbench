(ns mime.render
  "Renders parsed messages as the text dump format: `summary.txt` and
  `messages/NNNN.txt`."
  (:require [clojure.string :as str]
            [mime.header :as header]
            [mime.message :as message]))

(set! *warn-on-reflection* true)

(defn esc
  "Escapes `s` for the dump: backslash, quote, LF, CR and TAB get a
  backslash escape; other control characters (below 0x20, 0x7F, 0x80-0x9F)
  become `\\xHH`."
  ^String [^String s]
  (let [n (.length s)
        sb (StringBuilder. (+ n 8))]
    (dotimes [i n]
      (let [c (.charAt s i)
            x (int c)]
        (cond
          (= c \\) (.append sb "\\\\")
          (== x 10) (.append sb "\\n")
          (== x 13) (.append sb "\\r")
          (== x 9) (.append sb "\\t")
          (= c \") (.append sb "\\\"")
          (or (< x 0x20) (== x 0x7F) (and (>= x 0x80) (<= x 0x9F)))
          (.append sb (format "\\x%02x" x))
          :else (.append sb c))))
    (.toString sb)))

(defn q
  "`s` escaped and wrapped in double quotes."
  ^String [^String s]
  (str "\"" (esc s) "\""))

(defn- number4 [n] (format "%04d" n))

(defn attachment-path
  "Relative output path of the attachment `part` of message number `n`."
  [n part]
  (format "parts/%s/%03d.bin" (number4 n) (:index part)))

(defn summary-line
  "The `summary.txt` line for message number `n` with source id `source-id`."
  [n source-id msg]
  (format "%s source=%s bytes=%d parts=%d attachments=%d text=%s html=%s"
          (number4 n) (q source-id) (:size msg) (count (:parts msg))
          (count (:attachments msg))
          (or (:text msg) "-") (or (:html msg) "-")))

(defn summary
  "Full text of `summary.txt` for `entries`, a seq of `{:number :source-id :message}`."
  [entries]
  (str "messages " (count entries) "\n"
       (str/join (map (fn [{:keys [number source-id message]}]
                        (str (summary-line number source-id message) "\n"))
                      entries))))

(defn- structure-line
  [part]
  (let [sb (StringBuilder.)
        add (fn [s] (.append sb " ") (.append sb ^String s))]
    (.append sb (apply str (repeat (* 2 (:depth part)) " ")))
    (.append sb (str (:index part) " " (:type part) "/" (:subtype part)))
    (when (= (:type part) "text") (add (str "charset=" (:charset part))))
    (add (str "cte=" (:cte part)))
    (when (:disposition part) (add (str "disposition=" (:disposition part))))
    (when (:filename part) (add (str "filename=" (q (:filename part)))))
    (when (= (:kind part) :multipart) (add (str "boundary=" (q (:boundary part)))))
    (when (not= (:kind part) :leaf) (add (str "parts=" (:child-count part))))
    (when (= (:kind part) :multipart)
      (add (str "preamble=" (:preamble part)))
      (add (str "epilogue=" (or (:epilogue part) "none"))))
    (when (= (:kind part) :leaf)
      (add (str "size=" (:size part)))
      (add (str "adler32=" (:adler32 part)))
      (add (str "role=" (name (:role part)))))
    (.toString sb)))

(defn- body-lines
  [label msg idx]
  (if (nil? idx)
    [(str label " none")]
    (let [text (message/part-text (nth (:parts msg) idx))
          pieces (str/split text #"\n" -1)
          pieces (if (and (seq pieces) (= "" (peek pieces))) (pop pieces) pieces)]
      (into [(str label " " idx " chars " (.codePointCount text 0 (.length text)))]
            (map #(str "| " (esc %)))
            pieces))))

(defn message-text
  "The text of `messages/NNNN.txt` for message number `n`."
  [n source-id msg]
  (let [section (fn [title lines] (str/join "\n" (cons title lines)))
        sections
        [(section "[message]" [(str "id " (number4 n)) (str "source " (q source-id))])
         (section "[headers]"
                  (map #(str (:key %) ": " (q (header/display-value %))) (:fields msg)))
         (section "[addresses]"
                  (for [name message/address-headers
                        [k a] (map-indexed vector (get (:addresses msg) name))]
                    (str name " " k " display=" (q (:display a)) " spec=" (q (:spec a)))))
         (section "[date]"
                  (if-let [d (:date msg)]
                    (cond-> [(str "raw " (q (:raw d)))
                             (str "valid " (if (:valid? d) "yes" "no"))]
                      (:valid? d) (into [(str "utc " (:utc d))
                                         (str "offset " (:offset d))
                                         (str "epoch " (:epoch d))]))
                    ["none"]))
         (section "[structure]" (map structure-line (:parts msg)))
         (section "[body]" (concat (body-lines "text" msg (:text msg))
                                   (body-lines "html" msg (:html msg))))
         (section "[attachments]"
                  (for [p (:attachments msg)]
                    (str (:index p) " type=" (:type p) "/" (:subtype p)
                         " filename=" (if (:filename p) (q (:filename p)) "-")
                         " size=" (:size p) " adler32=" (:adler32 p)
                         " file=" (attachment-path n p))))]]
    (str (str/join "\n\n" sections) "\n")))
