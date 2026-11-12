(ns textbuffer.cursor
  "Cursors, their ranges, and normalization (merging of colliding cursors).

  A cursor is a [[Cursor]] record:

  * `:head`    the caret position (packed, see [[textbuffer.position]]);
  * `:anchor`  the other end of the selection, or `nil` when there is no
               selection. It is never equal to the head;
  * `:primary` true for exactly one cursor in a set;
  * `:goal`    the goal column used by vertical movement.

  A *cursor set* is a vector of cursors in cursor order (ascending range
  start; after [[normalize]] all starts are distinct)."
  (:require [textbuffer.position :as p]))

(set! *warn-on-reflection* true)

(defrecord Cursor [head anchor primary goal])

(defn cursor
  "Creates a cursor with `head` and optional `anchor` (nil or equal to head
  means no selection)."
  ([head] (cursor head nil))
  ([head anchor] (cursor head anchor false))
  ([head anchor primary]
   (cursor head anchor primary (p/col head)))
  ([head anchor primary goal]
   (->Cursor head (when-not (== (long head) (long (or anchor head))) anchor)
             (boolean primary) goal)))

(defn initial-cursors
  "The cursor set of a fresh buffer: one primary cursor at `(0, 0)`."
  []
  [(->Cursor p/origin nil true 0)])

(defn selection?
  "True when the cursor has a selection."
  [^Cursor c]
  (some? (.anchor c)))

(defn start
  "Start of the cursor's range."
  ^long [^Cursor c]
  (let [h (long (.head c))]
    (if-let [a (.anchor c)] (p/min h (long a)) h)))

(defn end
  "End of the cursor's range."
  ^long [^Cursor c]
  (let [h (long (.head c))]
    (if-let [a (.anchor c)] (p/max h (long a)) h)))

(defn backward?
  "True when the cursor has a selection whose head is at its start."
  [^Cursor c]
  (boolean (when-let [a (.anchor c)] (< (long (.head c)) (long a)))))

(defn with-goal-from-head
  "Sets the goal column of `c` to the column of its head."
  [^Cursor c]
  (->Cursor (.head c) (.anchor c) (.primary c) (p/col (.head c))))

(defn reset-goals
  "Sets every cursor's goal column to the column of its head."
  [cursors]
  (mapv with-goal-from-head cursors))

;; ---------------------------------------------------------------------------
;; Normalization

(defn- compare-cursors
  "Ascending start, then descending end."
  ^long [a b]
  (let [sa (start a) sb (start b)]
    (cond (< sa sb) -1
          (> sa sb) 1
          :else (let [ea (end a) eb (end b)]
                  (cond (> ea eb) -1
                        (< ea eb) 1
                        :else 0)))))

(defn- joins?
  "Whether `c` belongs to the group whose merged cursor is `cur`."
  [cur c]
  (if (or (not (selection? cur)) (not (selection? c)))
    (<= (start c) (end cur))
    (< (start c) (end cur))))

(defn- merge-cursors
  "The merged cursor of a group `cur` that `c` joins."
  [cur c]
  (let [s (start cur)
        e (p/max (end cur) (end c))
        primary (boolean (or (:primary cur) (:primary c)))
        goal (:goal cur)]
    (cond (== s e) (->Cursor s nil primary goal)
          (backward? cur) (->Cursor s e primary goal)
          :else (->Cursor e s primary goal))))

(defn- sweep
  "Merges colliding cursors of the sorted vector `sorted`."
  [sorted]
  (let [n (count sorted)]
    (loop [i 1
           cur (nth sorted 0)
           out (transient [])]
      (if (== i n)
        (persistent! (conj! out cur))
        (let [c (nth sorted i)]
          (if (joins? cur c)
            (recur (inc i) (merge-cursors cur c) out)
            (recur (inc i) c (conj! out cur))))))))

(defn normalize
  "Normalizes a cursor set: stable-sorts it by range start (ties: larger end
  first), then merges colliding cursors in one sweep. Returns a vector.

  A selection and a point cursor merge when the point touches or lies in the
  selection; two selections merge only when they overlap (touching ends do
  not merge). The merged cursor keeps the direction and goal column of the
  first cursor of its group and is primary if any member was.

  O(C log C); O(C) when the set is already in order."
  [cursors]
  (let [cursors (vec cursors)]
    (if (<= (count cursors) 1)
      cursors
      (sweep (vec (sort compare-cursors cursors))))))
