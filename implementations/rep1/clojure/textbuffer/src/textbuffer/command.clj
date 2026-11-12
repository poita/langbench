(ns textbuffer.command
  "The textual command language of the CLI: parsing command lines into
  command maps, and executing them against a [[textbuffer.buffer/Buffer]]."
  (:require [textbuffer.buffer :as buf])
  (:import (java.io Writer)))

(set! *warn-on-reflection* true)

(defn decode-insert-text
  "Decodes the argument of `insert`: `\\n` (backslash, n) is a newline and
  `\\\\` a single backslash. Any other backslash is kept as it is."
  ^String [^String s]
  (if (neg? (.indexOf s 92))
    s
    (let [n (.length s)
          sb (StringBuilder. n)]
      (loop [i 0]
        (when (< i n)
          (let [ch (.charAt s i)]
            (if (and (= ch \\) (< (inc i) n))
              (let [nx (.charAt s (inc i))]
                (cond (= nx \n) (do (.append sb \newline) (recur (+ i 2)))
                      (= nx \\) (do (.append sb \\) (recur (+ i 2)))
                      :else (do (.append sb ch) (recur (inc i)))))
              (do (.append sb ch) (recur (inc i)))))))
      (.toString sb))))

(defn- parse-long-arg
  [^String s]
  (try (Long/parseLong s)
       (catch NumberFormatException _
         (throw (ex-info (str "bad number: " s) {:arg s})))))

(defn- parse-position-args
  [cmd ^String args]
  (let [i (.indexOf args 32)]
    (when (neg? i)
      (throw (ex-info (str cmd " needs <line> <col>") {:args args})))
    {:op cmd
     :line (parse-long-arg (.substring args 0 i))
     :col (parse-long-arg (.substring args (inc i)))}))

(def ^:private directions
  {"left" :left "right" :right "up" :up "down" :down "home" :home "end" :end})

(defn parse
  "Parses one command line into a map with an `:op` key:

      insert <text>               {:op :insert :text \"...\"}   (text decoded)
      delete | delete-forward     {:op :delete} / {:op :delete-forward}
      move <dir> [select]         {:op :move :dir :left :select? false}
      goto <line> <col>           {:op :goto :line 0 :col 0}
      add-cursor <line> <col>     {:op :add-cursor :line 0 :col 0}
      clear-cursors | undo | redo | print   {:op :clear-cursors} ...

  Throws `ex-info` on a malformed or unknown command."
  [^String line]
  (let [sp (.indexOf line 32)
        word (if (neg? sp) line (.substring line 0 sp))
        args (if (neg? sp) "" (.substring line (inc sp)))]
    (case word
      "insert" (if (neg? sp)
                 (throw (ex-info "insert needs text" {:line line}))
                 {:op :insert :text (decode-insert-text args)})
      "delete" {:op :delete}
      "delete-forward" {:op :delete-forward}
      "move" (let [sp2 (.indexOf args 32)
                   dir (directions (if (neg? sp2) args (.substring args 0 sp2)))
                   select (when-not (neg? sp2) (.substring args (inc sp2)))]
               (when (or (nil? dir) (and select (not= select "select")))
                 (throw (ex-info (str "bad move command: " line) {:line line})))
               {:op :move :dir dir :select? (some? select)})
      "goto" (parse-position-args :goto args)
      "add-cursor" (parse-position-args :add-cursor args)
      "clear-cursors" {:op :clear-cursors}
      "undo" {:op :undo}
      "redo" {:op :redo}
      "print" {:op :print}
      (throw (ex-info (str "unknown command: " line) {:line line})))))

(defn execute
  "Executes parsed command `cmd` on buffer `b` and returns the new buffer.
  `print` writes the buffer snapshot to the `Writer` `out`."
  [b cmd ^Writer out]
  (case (:op cmd)
    :insert (buf/insert b (:text cmd))
    :delete (buf/delete-backward b)
    :delete-forward (buf/delete-forward b)
    :move (buf/move b (:dir cmd) (:select? cmd))
    :goto (buf/goto b (:line cmd) (:col cmd))
    :add-cursor (buf/add-cursor b (:line cmd) (:col cmd))
    :clear-cursors (buf/clear-cursors b)
    :undo (buf/undo b)
    :redo (buf/redo b)
    :print (do (buf/write-state! b out) b)))
