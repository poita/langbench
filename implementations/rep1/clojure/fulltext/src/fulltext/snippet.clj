(ns fulltext.snippet
  "Snippet selection: find the best window of `W` tokens and cut it out of
  the original text."
  (:require [fulltext.analysis :as analysis])
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(def ^:const window-size
  "W, the number of tokens in a snippet window."
  30)

(defn best-window
  "The start `s` of the best window of a document of `len` tokens.

  `occurrences` is a collection of `[n starts]` pairs, one per positive atom
  that occurs in the document: `n` is the atom's length in terms and `starts`
  an `int` array of its sorted occurrence positions. The best window maximises
  (1) the number of distinct atoms with an occurrence inside it, then (2) the
  total number of occurrences inside it, then (3) prefers the smallest start.

  Runs in O(len + occurrences): each occurrence is inside a contiguous range
  of window starts, so counts are accumulated in difference arrays and a single
  prefix-sum sweep picks the winner."
  ^long [^long len occurrences]
  (let [max-s (max 0 (- len window-size))
        size (+ max-s 2)
        distinct-diff (long-array size)
        total-diff (long-array size)]
    (doseq [[^long n ^ints starts] occurrences]
      ;; Ranges [lo, hi] of window starts, non-decreasing in both ends, so a
      ;; running `covered` bound gives the union without double counting.
      (loop [i 0 covered -1]
        (when (< i (alength starts))
          (let [p (aget starts i)
                lo (max 0 (- (+ p n) window-size))
                hi (min p max-s)]
            (if (<= lo hi)
              (let [from (max lo (inc covered))]
                (aset total-diff lo (inc (aget total-diff lo)))
                (aset total-diff (inc hi) (dec (aget total-diff (inc hi))))
                (when (<= from hi)
                  (aset distinct-diff from (inc (aget distinct-diff from)))
                  (aset distinct-diff (inc hi) (dec (aget distinct-diff (inc hi)))))
                (recur (inc i) (max covered hi)))
              (recur (inc i) covered))))))
    (loop [s 0 d 0 t 0 best 0 best-d 0 best-t 0]
      (if (<= s max-s)
        (let [d (+ d (aget distinct-diff s))
              t (+ t (aget total-diff s))]
          (if (or (> d best-d) (and (== d best-d) (> t best-t)))
            (recur (inc s) d t s d t)
            (recur (inc s) d t best best-d best-t)))
        best))))

(defn collapse-whitespace
  "Replace each maximal run of the seven whitespace characters in `s` with a
  single space."
  ^String [^String s]
  (let [n (.length s)
        sb (StringBuilder. n)]
    (loop [i 0 in-ws? false]
      (when (< i n)
        (let [c (.charAt s i)]
          (if (analysis/whitespace? c)
            (do (when-not in-ws? (.append sb \space))
                (recur (inc i) true))
            (do (.append sb c)
                (recur (inc i) false))))))
    (.toString sb)))

(defn extract
  "The snippet text for the window starting at token `s` of a document whose
  token spans are `starts`/`ends` (int arrays): the original text from the
  first character of token `s` to the last character of the window's final
  token, whitespace collapsed. Empty for a document without tokens."
  ^String [^String text ^ints starts ^ints ends ^long s]
  (let [len (alength starts)]
    (if (zero? len)
      ""
      (let [last-tok (dec (min (+ s window-size) len))]
        (collapse-whitespace
         (.substring text (aget starts s) (aget ends last-tok)))))))
