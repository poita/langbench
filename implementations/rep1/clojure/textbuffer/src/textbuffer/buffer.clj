(ns textbuffer.buffer
  "The public API of the text buffer: a document, a set of cursors and an
  undo/redo history, all as one immutable value.

  Every operation takes a [[Buffer]] and returns a new one; the arguments are
  never modified. Positions in the API are `[line col]`-free packed longs
  (see [[textbuffer.position]]); use [[cursor-positions]] to read them as
  `[line col]` pairs.

      (require '[textbuffer.buffer :as buf])

      (-> (buf/from-text \"hello\\nworld\")
          (buf/goto 0 5)
          (buf/add-cursor 1 5)
          (buf/insert \"!\")
          buf/text)
      ;=> \"hello!\\nworld!\"

  Cursor semantics (normalization, goal columns), the editing rules and the
  history model follow SPEC.md of the textbuffer problem."
  (:require [textbuffer.cursor :as c]
            [textbuffer.document :as doc]
            [textbuffer.edit :as edit]
            [textbuffer.motion :as motion]
            [textbuffer.position :as p])
  (:import (java.io Writer)))

(set! *warn-on-reflection* true)

(defrecord UndoEntry [before after replacements])

(defrecord Buffer [doc cursors undo redo])

;; ---------------------------------------------------------------------------
;; Construction and queries

(defn from-doc
  "A buffer over document `d` with one primary cursor at `(0, 0)` and empty
  history."
  [d]
  (->Buffer d (c/initial-cursors) () ()))

(defn from-lines
  "A buffer whose document consists of the given collection of lines (an
  empty collection gives one empty line)."
  [lines]
  (from-doc (doc/document lines)))

(defn from-text
  "A buffer whose document is `text`, lines separated by `\\n`."
  [^String text]
  (from-doc (doc/from-text text)))

(defn lines
  "The document lines as a vector of strings."
  [^Buffer b]
  (doc/lines (:doc b)))

(defn text
  "The document text: lines joined by `\\n`."
  [^Buffer b]
  (doc/text (:doc b)))

(defn cursors
  "The cursor set, a vector of [[textbuffer.cursor/Cursor]] records in cursor
  order."
  [^Buffer b]
  (:cursors b))

(defn cursor-positions
  "The head of every cursor, in cursor order, as `[line col]` pairs."
  [^Buffer b]
  (mapv #(p/->vec (:head %)) (:cursors b)))

(defn can-undo?
  "True when there is an edit to undo."
  [^Buffer b]
  (boolean (seq (:undo b))))

(defn can-redo?
  "True when there is an undone edit to redo."
  [^Buffer b]
  (boolean (seq (:redo b))))

;; ---------------------------------------------------------------------------
;; Editing

(defn- with-cursors
  "Normalizes `cursors` and resets goal columns (the end of every command
  except vertical movement)."
  [^Buffer b cursors]
  (assoc b :cursors (c/reset-goals (c/normalize cursors))))

(defn- edit
  [^Buffer b kind text]
  (let [d (doc/thaw (:doc b))
        {:keys [cursors replacements]} (edit/apply-edit! d (:cursors b) kind text)
        after (c/normalize cursors)]
    (if (empty? replacements)
      (assoc b :cursors (c/reset-goals after))
      (let [after (c/reset-goals after)]
        (assoc b
               :doc (doc/freeze d)
               :cursors after
               :undo (conj (:undo b) (->UndoEntry (:cursors b) after replacements))
               :redo ())))))

(defn insert
  "Inserts `text` (which may contain `\\n`) at every cursor, replacing
  selections. Cursors end after the inserted text, without selection."
  [^Buffer b ^String text]
  (if (zero? (.length text))
    (with-cursors b (:cursors b))
    (edit b :insert text)))

(defn delete-backward
  "Backspace: deletes every selection, or the character (or newline) before
  each cursor."
  [^Buffer b]
  (edit b :delete ""))

(defn delete-forward
  "Deletes every selection, or the character (or newline) after each cursor."
  [^Buffer b]
  (edit b :delete-forward ""))

;; ---------------------------------------------------------------------------
;; Cursors

(defn move
  "Moves every cursor in direction `dir` (`:left`, `:right`, `:up`, `:down`,
  `:home` or `:end`). With `select?` true, selections are extended or
  started. Does not touch the history."
  ([^Buffer b dir] (move b dir false))
  ([^Buffer b dir select?]
   (let [d (:doc b)
         moved (mapv #(motion/move-cursor d % dir select?) (:cursors b))
         vertical? (or (= dir :up) (= dir :down))
         normalized (c/normalize moved)]
     (assoc b :cursors (if vertical? normalized (c/reset-goals normalized))))))

(defn goto
  "Replaces all cursors by a single primary cursor at `[line col]`, clamped
  to the document."
  [^Buffer b line col]
  (let [head (doc/clamp (:doc b) line col)]
    (assoc b :cursors [(c/->Cursor head nil true (p/col head))])))

(defn add-cursor
  "Adds a non-primary cursor at `[line col]` (clamped). It merges with any
  cursor whose range it touches."
  [^Buffer b line col]
  (let [head (doc/clamp (:doc b) line col)]
    (with-cursors b (conj (:cursors b) (c/->Cursor head nil false (p/col head))))))

(defn clear-cursors
  "Removes every cursor except the primary one (which keeps its selection)."
  [^Buffer b]
  (with-cursors b (filterv :primary (:cursors b))))

;; ---------------------------------------------------------------------------
;; History

(defn undo
  "Reverts the most recent edit command and restores the cursors as they were
  before it. Does nothing when there is nothing to undo."
  [^Buffer b]
  (if-let [^UndoEntry entry (peek (:undo b))]
    (let [d (doc/thaw (:doc b))]
      (edit/revert! d (:replacements entry))
      (assoc b
             :doc (doc/freeze d)
             :cursors (c/reset-goals (:before entry))
             :undo (pop (:undo b))
             :redo (conj (:redo b) entry)))
    (with-cursors b (:cursors b))))

(defn redo
  "Re-applies the most recently undone edit and restores the cursors as they
  were after it. Does nothing when there is nothing to redo."
  [^Buffer b]
  (if-let [^UndoEntry entry (peek (:redo b))]
    (let [d (doc/thaw (:doc b))]
      (edit/reapply! d (:replacements entry))
      (assoc b
             :doc (doc/freeze d)
             :cursors (c/reset-goals (:after entry))
             :undo (conj (:undo b) entry)
             :redo (pop (:redo b))))
    (with-cursors b (:cursors b))))

;; ---------------------------------------------------------------------------
;; Rendering

(defn write-state!
  "Writes the snapshot printed by the `print` command to `w`: every document
  line followed by a newline, then `cursor <line> <col>` for every cursor's
  head in cursor order, then `--`."
  [^Buffer b ^Writer w]
  (let [d (:doc b)]
    (dotimes [i (doc/line-count d)]
      (.write w (doc/line-text d i))
      (.write w "\n"))
    (doseq [cur (:cursors b)]
      (let [h (long (:head cur))]
        (.write w "cursor ")
        (.write w (Long/toString (p/line h)))
        (.write w " ")
        (.write w (Long/toString (p/col h)))
        (.write w "\n")))
    (.write w "--\n")))

(defn render
  "The snapshot printed by `print`, as a string (see [[write-state!]])."
  [^Buffer b]
  (let [w (java.io.StringWriter.)]
    (write-state! b w)
    (str w)))
