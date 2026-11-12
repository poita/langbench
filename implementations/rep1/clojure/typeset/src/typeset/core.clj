(ns typeset.core
  "The public API of the Codexa typesetting engine.

  The main entry points are [[typeset]], which runs the whole pipeline over an
  input directory and returns the files to write, and [[typeset-strings]],
  which does the same for in-memory document and settings text."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [typeset.hlist]
            [typeset.hyphenation :as hyphenation]
            [typeset.layout :as layout]
            [typeset.linebreak :as lb]
            [typeset.metrics :as metrics]
            [typeset.out :as out]
            [typeset.page :as page]
            [typeset.paginate :as paginate]
            [typeset.parser :as parser]
            [typeset.settings :as settings]
            [typeset.text :as text]
            [typeset.toc :as toc]
            [typeset.util :as u]))

(set! *warn-on-reflection* true)

(def default-data-dir "data")

(defn load-data
  "Load the font faces and hyphenation pattern sets from `data-dir`
  (`<data-dir>/faces/*.cfm`, `<data-dir>/hyphen/*.chp`)."
  [data-dir]
  {:faces (metrics/load-faces data-dir)
   :hyph (hyphenation/load-all data-dir)})

(defn- make-env [settings meta* {:keys [faces hyph]}]
  {:settings settings :meta meta* :faces faces :hyph hyph
   :lb (lb/params settings)
   :stats (text/new-stats)
   :footnotes (atom {}) :figures (atom {}) :headings (atom [])
   :counters (atom [0 0 0 0])
   :footnote-ctx (layout/footnote-context settings)})

(defn- body-label [settings m] (str (+ (long (settings "page-start")) (dec (long m)))))

(defn- layout-text [settings pages]
  (let [bx (:body-x settings) by (:body-y settings)
        bw (:body-width settings) bh (:body-height settings)
        sb (StringBuilder.)]
    (.append sb "layout 1\n")
    (.append sb (str "pages " (count pages) "\n"))
    (doseq [[idx {:keys [label items]}] (map-indexed vector pages)]
      (.append sb (str "page " (inc idx) " " label " " (settings "page-width") " "
                       (settings "page-height") " " bx " " by " " bw " " bh "\n"))
      (doseq [s (out/sorted-lines items)]
        (.append sb "  ") (.append sb ^String s) (.append sb "\n")))
    (str sb)))

(defn- report-text [stats pages front]
  (let [s @stats
        rows [["pages" pages] ["front-pages" front] ["body-pages" (- pages front)]
              ["lines" (:lines s)] ["paragraphs" (:paragraphs s)] ["headings" (:headings s)]
              ["tables" (:tables s)] ["figures" (:figures s)] ["footnotes" (:footnotes s)]
              ["footnote-split-lines" (:footnote-split-lines s)]
              ["hyphenated-lines" (:hyphenated-lines s)] ["overfull-lines" (:overfull-lines s)]
              ["emergency-lists" (:emergency-lists s)] ["total-demerits" (:total-demerits s)]]]
    (str "report 1\n" (apply str (map (fn [[k v]] (str k " " v "\n")) rows)))))

(defn- run-pipeline [doc-text settings-text data]
  (let [settings (settings/parse settings-text)
        doc (parser/parse doc-text)
        env (make-env settings (:meta doc) data)
        items (layout/layout-body env (:blocks doc))
        body (paginate/paginate env items @(:figures env) @(:footnotes env))
        body-pages (:pages body)
        n-body (count body-pages)
        headings @(:headings env)
        ;; page labels of headings
        head-page (reduce (fn [m [pi pg]] (reduce #(assoc %1 %2 (inc pi)) m (:heads pg)))
                          {} (map-indexed vector body-pages))
        _ (text/bump! env :footnote-split-lines (:split-lines body))
        front-pages
        (when-let [tc (:toc doc)]
          (let [entries (for [[hid h] (map-indexed vector headings)
                              :when (and (not (:star? h))
                                         (<= (long (:level h)) (long (settings "toc-depth"))))]
                          {:level (:level h) :number (:number h) :text (:text h)
                           :label (body-label settings (head-page hid))})
                title (or (:title tc) (settings "toc-title"))
                titems (toc/build env title entries)]
            (:pages (paginate/paginate env titems {} {}))))
        n-front (count front-pages)
        render (fn [pg info] (update pg :out into (page/render env (assoc info :pages n-body))))
        front-out (vec (map-indexed
                        (fn [mi pg]
                          (let [m (inc mi)]
                            {:label (u/roman m)
                             :items (:out (render pg {:label (u/roman m) :number m
                                                      :chapter "" :section ""}))}))
                        front-pages))
        body-out (loop [pgs (seq body-pages) m 1 chapter "" section "" out []]
                   (if pgs
                     (let [pg (first pgs)
                           [chapter section]
                           (reduce (fn [[c s] hid]
                                     (let [h (nth headings hid)
                                           t (if (seq (:number h)) (str (:number h) " " (:text h)) (:text h))]
                                       (case (long (:level h))
                                         1 [t s]
                                         2 [c t]
                                         [c s])))
                                   [chapter section] (:heads pg))
                           label (body-label settings m)
                           num (+ (long (settings "page-start")) (dec m))]
                       (recur (next pgs) (inc m) chapter section
                              (conj out {:label label
                                         :items (:out (render pg {:label label :number num
                                                                  :chapter chapter :section section}))})))
                     out))
        pages (into front-out body-out)]
    {"layout.txt" (layout-text settings pages)
     "report.txt" (report-text (:stats env) (count pages) n-front)}))

(defn typeset-strings
  "Typeset the document text `doc-text` (nil when absent) with the settings
  text `settings-text` (nil when absent). `data` comes from [[load-data]].

  Returns a map of output file name to its text: `layout.txt` and `report.txt`
  for a valid document, or `error.txt` alone when the input is invalid."
  [doc-text settings-text data]
  (if (nil? doc-text)
    {"error.txt" (str (u/error-line {:file "-" :line 0 :col 0 :code "missing-document"}) "\n")}
    (try
      (run-pipeline doc-text settings-text data)
      (catch clojure.lang.ExceptionInfo e
        (if-let [err (u/input-error e)]
          {"error.txt" (str (u/error-line err) "\n")}
          (throw e))))))

(defn- slurp-if-exists [^java.io.File f]
  (when (.isFile f) (slurp f :encoding "UTF-8")))

(defn typeset
  "Typeset the document in directory `input-dir` (`document.cdx` and the
  optional `settings.cfg`). Options: `:data-dir` (default `\"data\"`).
  Returns a map of output file name to text, see [[typeset-strings]]."
  ([input-dir] (typeset input-dir {}))
  ([input-dir {:keys [data-dir] :or {data-dir default-data-dir}}]
   (typeset-strings (slurp-if-exists (io/file input-dir "document.cdx"))
                    (slurp-if-exists (io/file input-dir "settings.cfg"))
                    (load-data data-dir))))

(defn write-outputs!
  "Write the result map of [[typeset]] into directory `out-dir`, creating it
  when missing."
  [out-dir files]
  (let [dir (io/file out-dir)]
    (.mkdirs dir)
    (doseq [[name content] files]
      (spit (io/file dir ^String name) ^String content :encoding "UTF-8"))))
