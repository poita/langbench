(ns fulltext.index
  "The positional inverted index.

  An [[Index]] holds, for every term, the documents that contain it and the
  sorted positions of the term in each of them, plus the per-document data
  needed for scoring and snippets. Documents are numbered `0 … N-1` in
  document-id order; those numbers (\"doc indexes\") are what the rest of the
  library passes around."
  (:require [fulltext.analysis :as analysis])
  (:import (java.util ArrayList HashMap Map)))

(set! *warn-on-reflection* true)

(defrecord Doc
  [id      ; String — document id
   text    ; String — the original text
   length  ; long   — number of tokens |d|
   starts  ; int[]  — start character offset of every token
   ends])  ; int[]  — end character offset (exclusive) of every token

(defrecord Postings
  [docs        ; int[]    — sorted doc indexes containing the term
   positions]) ; Object[] — parallel to docs; each an int[] of sorted positions

(defrecord Index
  [docs          ; vector of Doc, ordered by id
   postings      ; java.util.Map String -> Postings
   total-tokens  ; long
   avgdl         ; double
   term-fn])     ; fn String -> String, the analyser's term function

;; A minimal growable int buffer, used only while building.
(definterface IIntBuf
  (add [^int x])
  (size [])
  (toArray []))

(deftype IntBuf [^:unsynchronized-mutable ^ints arr
                 ^:unsynchronized-mutable ^int n]
  IIntBuf
  (add [_ x]
    (when (== n (alength arr))
      (set! arr (java.util.Arrays/copyOf arr (int (max 4 (* 2 n))))))
    (aset arr n x)
    (set! n (unchecked-inc-int n)))
  (size [_] n)
  (toArray [_] (java.util.Arrays/copyOf arr n)))

(defn- new-buf ^IntBuf [] (IntBuf. (int-array 4) (int 0)))

(deftype PostingsBuilder [^IntBuf docs ^ArrayList positions])

(defn- document-terms
  "The term of every token of a tokenised document, as an Object array."
  ^objects [term-fn {:keys [^objects texts]}]
  (let [n (alength texts)
        out (object-array n)]
    (dotimes [i n]
      (aset out i (term-fn (aget texts i))))
    out))

(defn- add-document!
  "Add one analysed document (as doc index `di`) to the builders map."
  [^Map builders term-fn ^long di tokens]
  (let [terms (document-terms term-fn tokens)
        local (HashMap.)]
    (dotimes [p (alength terms)]
      (let [t (aget terms p)
            ^IntBuf buf (or (.get local t)
                            (let [b (new-buf)] (.put local t b) b))]
        (.add buf (int p))))
    (doseq [^java.util.Map$Entry e (.entrySet local)]
      (let [t (.getKey e)
            ^IntBuf buf (.getValue e)
            ^PostingsBuilder pb (or (.get builders t)
                                    (let [b (PostingsBuilder. (new-buf) (ArrayList.))]
                                      (.put builders t b)
                                      b))]
        (.add ^IntBuf (.docs pb) (int di))
        (.add ^ArrayList (.positions pb) (.toArray buf))))))

(defn- freeze
  "Turn the mutable builders into immutable-by-convention Postings."
  ^Map [^Map builders]
  (let [out (HashMap. (* 2 (.size builders)))]
    (doseq [^java.util.Map$Entry e (.entrySet builders)]
      (let [^PostingsBuilder pb (.getValue e)]
        (.put out (.getKey e)
              (->Postings (.toArray ^IntBuf (.docs pb))
                          (.toArray ^ArrayList (.positions pb))))))
    out))

(defn build-index
  "Build an [[Index]] from `docs`, a collection of `[id text]` pairs (a map
  from id to text works). Ids must be unique; the index orders documents by
  id (Unicode code point order for ASCII ids, which is what `compare` gives)."
  [docs]
  (let [sorted (vec (sort-by first (seq docs)))
        term-fn (analysis/memoizing-term-fn)
        builders (HashMap.)
        doc-vec
        (persistent!
         (reduce
          (fn [acc [di [id text]]]
            (let [tokens (analysis/tokenize text)]
              (add-document! builders term-fn di tokens)
              (conj! acc (->Doc id text (alength ^objects (:texts tokens))
                                (:starts tokens) (:ends tokens)))))
          (transient [])
          (map-indexed vector sorted)))
        total (reduce + 0 (map :length doc-vec))
        n (count doc-vec)]
    (->Index doc-vec (freeze builders) total
             (if (zero? n) 0.0 (/ (double total) n))
             term-fn)))

(defn doc-count
  "N, the number of documents in the index."
  ^long [index]
  (count (:docs index)))

(defn term-count
  "The number of distinct terms in the index (stop words included)."
  ^long [^Index index]
  (.size ^Map (:postings index)))

(defn postings
  "The [[Postings]] of `term`, or `nil` if no document contains it."
  [^Index index term]
  (.get ^Map (:postings index) term))

(defn stats
  "Corpus statistics as a map: `:documents`, `:tokens`, `:terms`, `:avgdl`."
  [index]
  {:documents (doc-count index)
   :tokens (:total-tokens index)
   :terms (term-count index)
   :avgdl (:avgdl index)})
