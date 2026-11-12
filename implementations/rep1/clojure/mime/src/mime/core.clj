(ns mime.core
  "Public API of the mime library: parse RFC 5322 / MIME messages and
  produce the normalised text dump and attachment files.

  Typical use:

      (require '[mime.core :as mime])

      (def msg (mime/parse-message (.getBytes \"Subject: hi\\n\\nbody\\n\")))
      (:fields msg)            ;=> [{:name \"Subject\" ...}]
      (mime/message-text 1 \"mbox:1\" msg)   ; the dump of one message

      (mime/convert! \"inbox.mbox\" \"out/\")  ; the whole command-line job"
  (:require [mime.charset :as charset]
            [mime.mailbox :as mailbox]
            [mime.message :as message]
            [mime.render :as render])
  (:import (java.io File)
           (java.nio.file Files OpenOption)))

(set! *warn-on-reflection* true)

(def parse-message
  "Parses message bytes into a data structure; see [[mime.message/parse]]."
  message/parse)

(def read-mailbox
  "Reads an mbox file or a directory of `.eml` files into a vector of
  `{:source-id :data}`; see [[mime.mailbox/read-messages]]."
  mailbox/read-messages)

(def message-text
  "Renders `(message-text n source-id msg)`; see [[mime.render/message-text]]."
  render/message-text)

(def summary-text
  "Renders the summary file for a seq of `{:number :source-id :message}`."
  render/summary)

(defn parse-mailbox
  "Reads the mailbox at `path` and parses every message. Returns a vector of
  `{:number n :source-id s :message msg}` with `n` counting from 1."
  [path]
  (vec (map-indexed (fn [i {:keys [source-id data]}]
                      {:number (inc i) :source-id source-id :message (message/parse data)})
                    (mailbox/read-messages path))))

(defn- write-file!
  [^File f ^bytes content]
  (.mkdirs (.getParentFile f))
  (Files/write (.toPath f) content ^"[Ljava.nio.file.OpenOption;" (make-array OpenOption 0)))

(defn write-output!
  "Writes the dump of the parsed `entries` (as returned by [[parse-mailbox]])
  into the directory `out-dir`: `summary.txt`, `messages/NNNN.txt` and one
  `parts/NNNN/PPP.bin` per attachment."
  [entries out-dir]
  (let [out (File. (str out-dir))]
    (.mkdirs out)
    (write-file! (File. out "summary.txt") (charset/encode-utf8 (render/summary entries)))
    (doseq [{:keys [number source-id message]} entries]
      (write-file! (File. out (format "messages/%04d.txt" number))
                   (charset/encode-utf8 (render/message-text number source-id message)))
      (doseq [p (:attachments message)]
        (write-file! (File. out ^String (render/attachment-path number p)) (:content p))))))

(defn convert!
  "Parses the mailbox at `input` and writes its dump into `out-dir`."
  [input out-dir]
  (write-output! (parse-mailbox input) out-dir))
