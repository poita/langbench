(ns mime.mailbox
  "Reading a mailbox: an mbox file or a directory of `.eml` files."
  (:require [mime.bytes :as bytes])
  (:import (java.io File)
           (java.nio.file Files)))

(set! *warn-on-reflection* true)

(defn- empty-line?
  [^bytes b ^long from ^long to]
  (or (== from to)
      (and (== (- to from) 1) (== (aget b from) 13))))

(defn- separator-at?
  [^bytes b ^long pos ^long n]
  (and (<= (+ pos 5) n)
       (== (aget b pos) 70) (== (aget b (+ pos 1)) 114)
       (== (aget b (+ pos 2)) 111) (== (aget b (+ pos 3)) 109)
       (== (aget b (+ pos 4)) 32)))

(defn split-mbox
  "Splits the bytes of an mbox archive into a vector of message byte arrays.

  A separator line starts with `From ` and is either the first line or follows
  an empty line. The text before the first separator is discarded, and a
  message that ends with LF LF loses one LF."
  [^bytes data]
  (let [n (alength data)
        ;; [line-start body-start] of every separator line
        seps (loop [pos 0 prev-empty? true out []]
               (if (>= pos n)
                 out
                 (let [le (bytes/index-of-lf data pos n)
                       nxt (min n (inc le))]
                   (recur nxt
                          (empty-line? data pos le)
                          (if (and prev-empty? (separator-at? data pos n))
                            (conj out [pos nxt])
                            out)))))]
    (vec
     (map-indexed
      (fn [i [_ body-start]]
        (let [end (if (< (inc i) (count seps)) (first (seps (inc i))) n)
              end (if (and (>= (- end body-start) 2)
                           (== (aget data (- end 1)) 10) (== (aget data (- end 2)) 10))
                    (dec end)
                    end)]
          (bytes/sub data body-start end)))
      seps))))

(defn- eml-files
  [^File dir]
  (->> (.listFiles dir)
       (filter (fn [^File f] (and (.isFile f) (.endsWith (.getName f) ".eml"))))
       (sort-by (fn [^File f] (.getName f)))))

(defn read-messages
  "Reads the mailbox at `path` (a file name or `java.io.File`). Returns a
  vector of `{:source-id s :data bytes}` in mailbox order: `mbox:<i>` for each
  message of an mbox file, or the file name for each `.eml` file of a directory."
  [path]
  (let [f (if (instance? File path) ^File path (File. ^String path))]
    (if (.isDirectory f)
      (mapv (fn [^File e] {:source-id (.getName e)
                           :data (Files/readAllBytes (.toPath e))})
            (eml-files f))
      (vec (map-indexed (fn [i m] {:source-id (str "mbox:" (inc i)) :data m})
                        (split-mbox (Files/readAllBytes (.toPath f))))))))
