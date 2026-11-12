(ns typeset.text
  "Typesetting one piece of running text: build its horizontal list, break it
  into lines, set the lines and record the statistics."
  (:require [typeset.hlist :as hlist]
            [typeset.line :as line]
            [typeset.linebreak :as lb]))

(set! *warn-on-reflection* true)

(def ^:const min-measure 1000)

(defn clamp-measure ^long [^long m] (max min-measure m))

(defn new-stats []
  (atom {:lines 0 :paragraphs 0 :headings 0 :tables 0 :figures 0 :footnotes 0
         :footnote-split-lines 0 :hyphenated-lines 0 :overfull-lines 0
         :emergency-lists 0 :total-demerits 0}))

(defn bump!
  "Add `n` to counter `k` of the environment's statistics."
  ([env k] (bump! env k 1))
  ([env k n] (swap! (:stats env) update k + n)))

(defn record-lines!
  "Record the statistics of freshly set `lines`."
  [env lines]
  (bump! env :lines (count lines))
  (bump! env :hyphenated-lines (count (filter :hyph? lines)))
  (bump! env :overfull-lines (count (filter :overfull? lines))))

(defn record-break! [env {:keys [total emergency?]}]
  (bump! env :total-demerits total)
  (when emergency? (bump! env :emergency-lists)))

(declare typeset)

(defn- register-notes!
  "Typeset the footnotes referenced from `hl` and store their lines."
  [env hl]
  (doseq [{:keys [n units]} (:notes hl)]
    (let [{:keys [lines]} (typeset env (:footnote-ctx env) units 0 false)]
      (bump! env :footnotes)
      (swap! (:footnotes env) assoc n {:n n :lines lines}))))

(defn break-and-set
  "Break the built list `hl` in context `ctx` (using `ctx`'s `:measure`) and set
  its lines. Records statistics; returns the lines."
  [env ctx hl first-indent]
  (let [r (lb/break-list hl (:measure ctx) first-indent (:lb env))
        lines (line/set-lines (:faces env) ctx hl (:breaks r) first-indent)]
    (record-break! env r)
    (record-lines! env lines)
    lines))

(defn typeset
  "Typeset `units` in context `ctx`; returns `{:lines :hl}`. When
  `notes?` footnotes referenced from the text are registered."
  ([env ctx units first-indent] (typeset env ctx units first-indent true))
  ([env ctx units first-indent notes?]
   (let [hl (hlist/build env ctx units)
         lines (break-and-set env ctx hl first-indent)]
     (when notes? (register-notes! env hl))
     {:lines lines :hl hl})))
