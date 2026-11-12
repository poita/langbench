(ns gitrepo.object
  "Parsing of commits, trees and tags, with parsed results cached in the
  store. Names, messages and idents are byte-strings (see `gitrepo.hex`)."
  (:require [clojure.string :as str]
            [gitrepo.error :as err]
            [gitrepo.hex :as hex]
            [gitrepo.store :as store]))

(set! *warn-on-reflection* true)

(def ^:private ws-chars #{\space \tab \return \newline \u000B \u000C})

(defn- damaged [msg] (err/fail :damaged msg))

;; --------------------------------------------------------------------------
;; header blocks (commits and tags)

(defn parse-headers
  "Splits a commit/tag payload (as a byte-string) into `[headers message]`.
  `headers` is a vector of `[key value]` pairs in order; continuation lines
  (starting with a space) are folded into the preceding header's value with
  a newline. `message` is everything after the first empty line, or \"\"."
  [^String s]
  (let [n (.length s)]
    (loop [pos 0 headers []]
      (if (>= pos n)
        [headers ""]
        (let [eol (let [i (.indexOf s "\n" (int pos))] (if (neg? i) n i))
              line (.substring s pos eol)]
          (cond
            (.isEmpty line) [headers (if (< eol n) (.substring s (inc eol)) "")]

            (and (= \space (.charAt line 0)) (seq headers))
            (let [[k v] (peek headers)]
              (recur (inc eol) (conj (pop headers) [k (str v "\n" (.substring line 1))])))

            :else
            (let [sp (.indexOf line " ")
                  h (if (neg? sp) [line ""] [(.substring line 0 sp) (.substring line (inc sp))])]
              (recur (inc eol) (conj headers h)))))))))

(defn- last-header [headers k]
  (some (fn [[hk v]] (when (= hk k) v)) (rseq headers)))

(defn- strip-trailing-ws [^String s]
  (loop [e (.length s)]
    (if (and (pos? e) (ws-chars (.charAt s (dec e)))) (recur (dec e)) (.substring s 0 e))))

(defn- parse-digits [^String s start]
  (let [n (.length s)
        end (loop [i start] (if (and (< i n) (<= (int \0) (int (.charAt s i)) (int \9))) (recur (inc i)) i))]
    (when (> end start)
      (let [d (.substring s start end)]
        (if (<= (count d) 18) (Long/parseLong d) (bigint (BigInteger. d)))))))

(defn parse-ident
  "Parses an `author`/`committer`/`tagger` header value into
  `{:name <byte-string> :timestamp <non-negative integer>}`. A nil ident
  gives an empty name and timestamp 0."
  [^String line]
  (if (nil? line)
    {:name "" :timestamp 0}
    (let [lt (.indexOf line "<")
          name (strip-trailing-ws (if (neg? lt) line (.substring line 0 lt)))
          gt (if (neg? lt) -1 (.indexOf line ">" (int lt)))
          ts (when-not (neg? gt)
               (let [n (.length line)
                     i (loop [i (inc gt)] (if (and (< i n) (= \space (.charAt line i))) (recur (inc i)) i))
                     i (if (and (< i n) (#{\+ \-} (.charAt line i))) (inc i) i)]
                 (parse-digits line i)))]
      {:name name :timestamp (or ts 0)})))

(defn subject
  "The subject of commit message `message`: the first paragraph of non-blank
  lines, trailing whitespace stripped from each, joined by single spaces."
  [^String message]
  (let [lines (map strip-trailing-ws (str/split message #"\n" -1))
        lines (drop-while empty? lines)]
    (str/join " " (take-while (complement empty?) lines))))

(defn parse-commit
  "Parses a commit payload (bytes) into
  `{:tree id :parents [id ...] :author ident :committer ident :message s}`.
  The last occurrence of a repeated header wins, except `parent`."
  [^bytes data]
  (let [[headers message] (parse-headers (hex/latin1 data))
        parents (mapv second (filter #(= "parent" (first %)) headers))
        tree (last-header headers "tree")]
    (doseq [p parents]
      (when-not (hex/object-id? p) (damaged "commit: bad parent id")))
    (when-not (or (nil? tree) (hex/object-id? tree)) (damaged "commit: bad tree id"))
    {:tree tree
     :parents parents
     :author (parse-ident (last-header headers "author"))
     :committer (parse-ident (last-header headers "committer"))
     :message message}))

(defn parse-tag
  "Parses a tag payload (bytes) into `{:object id}` (plus `:tag`, `:tagger`)."
  [^bytes data]
  (let [[headers] (parse-headers (hex/latin1 data))
        object (last-header headers "object")]
    (when-not (hex/object-id? object) (damaged "tag: missing object header"))
    {:object object
     :tag (last-header headers "tag")
     :tagger (when-let [t (last-header headers "tagger")] (parse-ident t))}))

;; --------------------------------------------------------------------------
;; trees

(defn parse-tree
  "Parses a tree payload (bytes) into a vector, in stored order, of
  `{:mode <long> :name <byte-string> :id <hex>}`."
  [^bytes data]
  (let [n (alength data)]
    (loop [pos 0 entries (transient [])]
      (if (>= pos n)
        (persistent! entries)
        (let [sp (long (loop [i pos] (cond (>= i n) -1 (= 32 (aget data i)) i :else (recur (inc i)))))
              _ (when (or (neg? sp) (= sp pos)) (damaged "tree: bad mode"))
              mode (try (Long/parseLong (hex/latin1 data pos (- sp pos)) 8)
                        (catch NumberFormatException _ (damaged "tree: bad mode")))
              nul (long (loop [i (inc sp)] (cond (>= i n) -1 (zero? (aget data i)) i :else (recur (inc i)))))
              _ (when (or (neg? nul) (= nul (inc sp))) (damaged "tree: bad name"))
              _ (when (> (+ nul 21) n) (damaged "tree: truncated entry"))]
          (recur (+ nul 21)
                 (conj! entries {:mode mode
                                 :name (hex/latin1 data (inc sp) (- nul sp 1))
                                 :id (hex/bytes->hex data (inc nul) 20)})))))))

(defn mode-type
  "The object type (`:tree`, `:commit` or `:blob`) implied by tree-entry `mode`."
  [^long mode]
  (case (long (bit-and mode 2r1111000000000000))
    2r0100000000000000 :tree
    2r1110000000000000 :commit
    :blob))

;; --------------------------------------------------------------------------
;; typed, cached readers

(defn- read-typed [repo id type parse]
  (store/cached repo [type id]
                (fn []
                  (let [obj (store/read-object repo id)]
                    (when-not (= type (:type obj))
                      (damaged (str "object " id " is a " (name (:type obj)) ", not a " (name type))))
                    (parse (:data obj))))))

(defn commit
  "The parsed commit `id` (see `parse-commit`)."
  [repo id] (read-typed repo id :commit parse-commit))

(defn tree
  "The parsed tree `id` (see `parse-tree`)."
  [repo id] (read-typed repo id :tree parse-tree))

(defn tag
  "The parsed tag `id` (see `parse-tag`)."
  [repo id] (read-typed repo id :tag parse-tag))
