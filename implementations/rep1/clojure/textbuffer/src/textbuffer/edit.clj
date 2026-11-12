(ns textbuffer.edit
  "Multi-cursor edits and the replacements they produce.

  An edit visits the cursors once, in cursor order. Each cursor yields one
  *replacement* (a range of the current document and the text that replaces
  it), which is applied immediately. Cursors that have not been visited yet
  are never rewritten: their positions are mapped into the current document
  through the composed effect of all earlier replacements, kept as three
  numbers (see [[apply-edit!]]), so the cursor work is O(C)."
  (:require [textbuffer.cursor :as c]
            [textbuffer.document :as doc]
            [textbuffer.position :as p])
  (:import (textbuffer.cursor Cursor)))

(set! *warn-on-reflection* true)

(defrecord Replacement [start removed inserted])

(defn- shift-position
  "Maps position `pos` of the pre-edit document into the current one, given
  the composed shift: positions on `anchor-line` move by `col-delta` columns
  and by `line-delta` lines; positions on later lines only by `line-delta`.
  (Positions never lie before `anchor-line`: a cursor not yet visited starts
  at or after the end of every earlier replacement.)"
  ^long [^long pos ^long anchor-line ^long line-delta ^long col-delta]
  (let [l (p/line pos)]
    (cond (== l anchor-line) (p/pos (+ l line-delta) (+ (p/col pos) col-delta))
          (> l anchor-line) (p/pos (+ l line-delta) (p/col pos))
          :else pos)))

(defn- previous-position
  "The position one character before `head` (which is not the origin)."
  ^long [d ^long head]
  (let [l (p/line head) col (p/col head)]
    (if (pos? col)
      (p/pos l (dec col))
      (p/pos (dec l) (doc/line-length d (dec l))))))

(defn- next-position
  "The position one character after `head` (which is not the document end)."
  ^long [d ^long head]
  (let [l (p/line head) col (p/col head)]
    (if (< col (doc/line-length d l))
      (p/pos l (inc col))
      (p/pos (inc l) 0))))

(defn apply-edit!
  "Applies an edit of `kind` to the thawed document `d` for every cursor of
  the cursor set `cursors` (in cursor order) and returns
  `{:cursors cursors', :replacements [Replacement ...]}`.

  `kind` is `:insert` (with `text`, replacing selections), `:delete`
  (backspace) or `:delete-forward`. The returned cursors have no selection,
  sit after the replaced text and are not yet normalized. `:replacements`
  lists only non-trivial replacements, each with its start position in the
  document as it was just before that replacement was applied, so replaying
  them in order (or their inverses in reverse order) reproduces the edit.

  Composed shift: after each replacement the mapping from pre-edit positions
  to current ones is updated in O(1). It is described by `anchor-line` (the
  pre-edit line on which the last replacement ended), `col-delta` (the column
  shift for positions on that line) and `line-delta` (the line shift for
  that and all later lines)."
  [d cursors kind ^String text]
  (loop [i 0
         anchor-line -1
         line-delta 0
         col-delta 0
         out (transient [])
         reps (transient [])]
    (if (== i (count cursors))
      {:cursors (persistent! out) :replacements (persistent! reps)}
      (let [^Cursor cur (nth cursors i)
            head (shift-position (.head cur) anchor-line line-delta col-delta)
            anchor (when-let [a (.anchor cur)]
                     (shift-position a anchor-line line-delta col-delta))
            selected? (some? anchor)
            from (long (cond selected? (p/min head anchor)
                             (and (= kind :delete) (not (zero? head))) (previous-position d head)
                             :else head))
            to (long (cond selected? (p/max head anchor)
                           (and (= kind :delete-forward)
                                (not (== head (doc/end-position d)))) (next-position d head)
                           :else head))
            inserted (if (= kind :insert) text "")]
        (if (and (== from to) (zero? (.length inserted)))
          ;; nothing to do for this cursor
          (recur (inc i) anchor-line line-delta col-delta
                 (conj! out (c/->Cursor head nil (.primary cur) (.goal cur)))
                 reps)
          (let [removed (doc/slice d from to)
                _ (doc/replace! d from to inserted)
                new-end (p/advance from inserted)
                end-line (p/line to)
                new-anchor-line (- end-line line-delta)]
            (recur (inc i)
                   new-anchor-line
                   (+ line-delta (- (p/line new-end) end-line))
                   (+ (- (p/col new-end) (p/col to))
                      (if (== new-anchor-line anchor-line) col-delta 0))
                   (conj! out (c/->Cursor new-end nil (.primary cur) (.goal cur)))
                   (conj! reps (->Replacement from removed inserted)))))))))

(defn revert!
  "Undoes `replacements` (as returned by [[apply-edit!]]) on the thawed
  document `d`: each is inverted, in reverse order."
  [d replacements]
  (doseq [^Replacement r (rseq replacements)]
    (let [start (long (.start r))]
      (doc/replace! d start (p/advance start (.inserted r)) (.removed r))))
  d)

(defn reapply!
  "Re-applies `replacements` in order on the thawed document `d`."
  [d replacements]
  (doseq [^Replacement r replacements]
    (let [start (long (.start r))]
      (doc/replace! d start (p/advance start (.removed r)) (.inserted r))))
  d)
