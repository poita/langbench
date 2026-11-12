(ns sitegen.markdown.node
  "The mutable document tree shared by the Markdown block parser, inline parser
  and renderer.  One `Node` type represents blocks (document, block-quote,
  list, item, paragraph, heading, thematic-break, code-block) and inlines
  (text, softbreak, linebreak, code, emph, strong, link, image), linked
  through `parent`, `first-child`, `last-child` and sibling pointers so that
  detaching and splicing nodes costs O(1) per node.

  Field usage by kind:

  * `text`   - accumulated lines (StringBuilder) of paragraphs, headings and
               code blocks; the literal (String) of text and code inlines.
  * `level`  - heading level; start number of an ordered list.
  * `dest`/`title` - link and image destination and title.
  * `info`   - info string of a fenced code block.
  * the remaining fields are the list, item and fence bookkeeping of the
    block parser."
  (:require [sitegen.mutable :refer [defmutable]]))

(set! *warn-on-reflection* true)

(defmutable Node ""
  [kind parent first-child last-child next-sibling prev-sibling
   open last-blank checked
   text level dest title info
   fenced ordered bullet tight setext
   marker-offset padding fence-char fence-offset start-line])

(defn make
  "A fresh detached node of the given kind."
  [kind]
  (->Node kind nil nil nil nil nil
          false false false
          nil 0 nil nil nil
          false false nil false false
          0 0 nil 0 0))

(defn make-text
  "A fresh detached inline node of `kind` carrying the literal `s`."
  [kind s]
  (doto ^Node (make kind) (text! s)))

(defn append-child!
  "Appends the detached `child` as the last child of `parent`."
  [parent child]
  (let [tail (last-child parent)]
    (parent! child parent)
    (prev-sibling! child tail)
    (next-sibling! child nil)
    (if tail
      (next-sibling! tail child)
      (first-child! parent child))
    (last-child! parent child)
    child))

(defn unlink!
  "Detaches `n` from its parent and siblings."
  [n]
  (let [p (parent n) prev (prev-sibling n) nxt (next-sibling n)]
    (if prev (next-sibling! prev nxt) (when p (first-child! p nxt)))
    (if nxt (prev-sibling! nxt prev) (when p (last-child! p prev)))
    (parent! n nil)
    (prev-sibling! n nil)
    (next-sibling! n nil)
    n))

(defn insert-after!
  "Inserts the detached `new` right after `anchor` among its siblings."
  [anchor new]
  (let [p (parent anchor) nxt (next-sibling anchor)]
    (parent! new p)
    (prev-sibling! new anchor)
    (next-sibling! new nxt)
    (next-sibling! anchor new)
    (if nxt (prev-sibling! nxt new) (when p (last-child! p new)))
    new))

(defn walk!
  "Visits the tree rooted at `root` depth-first without recursion, calling
  `(f node entering?)` with `true` when a node is entered and `false` when it
  is left (leaves get both events in a row)."
  [root f]
  (loop [cur root entering true]
    (if entering
      (do (f cur true)
          (if-let [c (first-child cur)]
            (recur c true)
            (recur cur false)))
      (do (f cur false)
          (when-not (identical? cur root)
            (if-let [nx (next-sibling cur)]
              (recur nx true)
              (recur (parent cur) false)))))))
