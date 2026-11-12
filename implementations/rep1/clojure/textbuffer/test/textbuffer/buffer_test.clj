(ns textbuffer.buffer-test
  (:require [clojure.test :refer [deftest is testing]]
            [textbuffer.buffer :as b]))

(defn- run
  "Applies a sequence of `(fn buffer)` steps to a buffer made from `text`."
  [text & steps]
  (reduce (fn [buf step] (step buf)) (b/from-text text) steps))

(defn- mv [dir & [select?]] #(b/move % dir (boolean select?)))
(defn- goto [l c] #(b/goto % l c))
(defn- add [l c] #(b/add-cursor % l c))
(defn- ins [s] #(b/insert % s))

(deftest initial-state
  (let [buf (b/from-lines [])]
    (is (= [""] (b/lines buf)))
    (is (= [[0 0]] (b/cursor-positions buf)))
    (is (true? (:primary (first (b/cursors buf)))))
    (is (not (b/can-undo? buf)))
    (is (not (b/can-redo? buf)))))

(deftest single-cursor-editing
  (let [buf (run "hello world\nsecond line"
                 (mv :end) (ins "!") (mv :down) (ins " (edited)") (goto 0 5) (ins ","))]
    (is (= ["hello, world!" "second line (edited)"] (b/lines buf)))
    (is (= [[0 6]] (b/cursor-positions buf)))
    (let [buf (-> buf b/delete-backward b/delete-backward)]
      (is (= ["hell world!" "second line (edited)"] (b/lines buf)))
      (is (= [[0 4]] (b/cursor-positions buf))))))

(deftest insert-newlines
  (let [buf (run "abc" (goto 0 1) (ins "X\nY\n"))]
    (is (= ["aX" "Y" "bc"] (b/lines buf)))
    (is (= [[2 0]] (b/cursor-positions buf)))))

(deftest backspace-and-forward-delete-across-lines
  (let [buf (run "ab\ncd" (goto 1 0) b/delete-backward)]
    (is (= ["abcd"] (b/lines buf)))
    (is (= [[0 2]] (b/cursor-positions buf))))
  (let [buf (run "ab\ncd" (goto 0 2) b/delete-forward)]
    (is (= ["abcd"] (b/lines buf)))
    (is (= [[0 2]] (b/cursor-positions buf)))))

(deftest edits-at-document-edges-change-nothing
  (let [buf (run "ab")]
    (is (= buf (b/delete-backward buf)))
    (is (= (b/lines buf) (b/lines (-> buf (b/goto 0 2) b/delete-forward))))
    (is (not (b/can-undo? (b/delete-backward buf))))))

(deftest multi-cursor-insert
  (let [buf (run "alpha\nbeta\ngamma" (add 1 0) (add 2 0) (ins "- "))]
    (is (= ["- alpha" "- beta" "- gamma"] (b/lines buf)))
    (is (= [[0 2] [1 2] [2 2]] (b/cursor-positions buf)))))

(deftest multi-cursor-on-one-line
  (let [buf (run "abcdef" (goto 0 1) (add 0 3) (add 0 5) (ins "XY"))]
    (is (= ["aXYbcXYdeXYf"] (b/lines buf)))
    (is (= [[0 3] [0 7] [0 11]] (b/cursor-positions buf)))))

(deftest multi-cursor-with-newlines-and-later-cursors-on-same-line
  (let [buf (run "abcdef" (goto 0 2) (add 0 4) (ins "\n"))]
    (is (= ["ab" "cd" "ef"] (b/lines buf)))
    (is (= [[1 0] [2 0]] (b/cursor-positions buf)))))

(deftest adjacent-cursors-delete-and-merge
  (let [buf (run "abcdef" (goto 0 3) (add 0 4) b/delete-backward)]
    (is (= ["abef"] (b/lines buf)))
    (is (= [[0 2]] (b/cursor-positions buf)))))

(deftest selection-edits
  (let [buf (run "alpha beta" (goto 0 0) (mv :right true) (mv :right true) (ins "ZZ"))]
    (is (= ["ZZpha beta"] (b/lines buf)))
    (is (= [[0 2]] (b/cursor-positions buf))))
  (let [buf (run "alpha\nbeta" (goto 1 2) (mv :left true) (mv :left true) (mv :left true) b/delete-forward)]
    (is (= ["alphata"] (b/lines buf)) "backward selection across the newline")
    (is (= [[0 5]] (b/cursor-positions buf)))))

(deftest goto-clamps
  (let [buf (run "abc\nde" (goto 99 99))]
    (is (= [[1 2]] (b/cursor-positions buf))))
  (is (= [[0 3]] (b/cursor-positions (run "abc\nde" (goto 0 1000000000))))))

(deftest add-cursor-merges
  (is (= 1 (count (b/cursors (run "abc" (add 0 0))))))
  (is (= 2 (count (b/cursors (run "abc" (add 0 1)))))))

(deftest clear-cursors-keeps-primary-with-selection
  (let [buf (run "abc\ndef" (goto 0 1) (mv :right true) (add 1 1) b/clear-cursors)]
    (is (= 1 (count (b/cursors buf))))
    (is (some? (:anchor (first (b/cursors buf)))))
    (is (= [[0 2]] (b/cursor-positions buf)))))

(deftest goal-column-persists-over-vertical-moves
  (let [buf (run "long line\n\nlong line" (mv :end) (mv :down) (mv :down))]
    (is (= [[2 9]] (b/cursor-positions buf)))
    (is (= [[1 0]] (b/cursor-positions (b/move buf :up))))
    (testing "any other command resets the goal column"
      (let [buf (-> buf (b/move :up) (b/move :left) (b/move :up))]
        (is (= [[0 0]] (b/cursor-positions buf)))))))

(deftest vertical-edges-set-the-goal
  (let [buf (run "abc\nde" (goto 1 1) (mv :down) (mv :up))]
    (is (= [[0 2]] (b/cursor-positions buf)))))

(deftest undo-redo
  (let [buf (run "abc" (mv :end) (ins "d\ne"))
        buf2 (-> buf b/delete-backward b/delete-backward)]
    (is (= ["abcd"] (b/lines buf2)))
    (let [u1 (b/undo buf2)]
      (is (= ["abcd" ""] (b/lines u1)))
      (is (= [[1 0]] (b/cursor-positions u1)))
      (let [u2 (b/undo u1)]
        (is (= ["abcd" "e"] (b/lines u2)))
        (is (= [[1 1]] (b/cursor-positions u2)))
        (is (= ["abcd" ""] (b/lines (b/redo u2))))
        (is (= ["abcd"] (b/lines (-> u2 b/redo b/redo))))
        (let [u3 (b/undo u2)]
          (is (= ["abc"] (b/lines u3)))
          (is (= [[0 3]] (b/cursor-positions u3)))))
      (testing "a new edit clears the redo stack"
        (let [fresh (b/insert u1 "Z")]
          (is (not (b/can-redo? fresh)))
          (is (= ["abcd" "Z"] (b/lines fresh)))
          (is (= (b/lines fresh) (b/lines (b/redo fresh)))))))))

(deftest undo-restores-all-cursors-and-selections
  (let [buf (run "ab\ncd\nef" (goto 0 0) (mv :end true) (add 1 1) (add 2 0) (ins "Q"))
        before (-> (run "ab\ncd\nef" (goto 0 0) (mv :end true) (add 1 1) (add 2 0)) b/cursors)]
    (is (= before (b/cursors (b/undo buf))))
    (is (= (b/cursors buf) (b/cursors (-> buf b/undo b/redo))))))

(deftest undo-on-empty-history-is-a-no-op
  (let [buf (run "abc" (goto 0 2))]
    (is (= (b/lines buf) (b/lines (b/undo buf))))
    (is (= [[0 2]] (b/cursor-positions (b/redo (b/undo buf)))))))

(deftest cursor-moves-do-not-touch-history
  (let [buf (-> (run "abc" (ins "x")) (b/move :left) (b/goto 0 0))]
    (is (= ["abc"] (b/lines (b/undo buf))))
    (is (= ["xabc"] (b/lines (b/redo (b/undo buf)))))))

(deftest buffers-are-values
  (let [buf (run "abc" (ins "x"))
        _ (b/insert buf "y")
        _ (b/undo buf)]
    (is (= ["xabc"] (b/lines buf)))))

(deftest rendering
  (is (= "ab\n\ncursor 1 0\n--\n"
         (b/render (run "ab\n" (goto 1 0)))))
  (is (= "a\ncursor 0 0\ncursor 0 1\n--\n"
         (b/render (run "a" (add 0 1))))))
