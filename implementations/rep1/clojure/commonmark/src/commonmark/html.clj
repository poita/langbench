(ns commonmark.html
  "Rendering of a parsed document (see `commonmark.core/parse`) as HTML, in the
  exact format of the cmark reference implementation."
  (:require [commonmark.text :as t :refer [ch char-at]]))

(set! *warn-on-reflection* true)

(defn- cr!
  "Output a newline unless the output is empty or already ends with one."
  [^StringBuilder sb]
  (let [n (.length sb)]
    (when (and (pos? n) (not (== (long (int (.charAt sb (dec n)))) 10)))
      (.append sb \newline))))

;; ---------------------------------------------------------------------------
;; Inlines
;; ---------------------------------------------------------------------------

(defn- write-title!
  [^StringBuilder sb title]
  (when (some? title)
    (.append sb " title=\"")
    (t/escape-html! sb title)
    (.append sb \")))

(defn render-inlines!
  "Append the HTML for the vector of inline `events` to `sb` and return `sb`.
  Inside an image only the plain text of the descendants is written (for the
  `alt` attribute)."
  ^StringBuilder [^StringBuilder sb events]
  (loop [evs (seq events) alt-depth 0 image-title nil]
    (when evs
      (let [ev (first evs)
            more (next evs)
            kind (nth ev 0)]
        (case kind
          :text (do (t/escape-html! sb (nth ev 1))
                    (recur more alt-depth image-title))
          :code (do (if (zero? alt-depth)
                      (do (.append sb "<code>")
                          (t/escape-html! sb (nth ev 1))
                          (.append sb "</code>"))
                      (t/escape-html! sb (nth ev 1)))
                    (recur more alt-depth image-title))
          :softbreak (do (.append sb (if (zero? alt-depth) "\n" " "))
                         (recur more alt-depth image-title))
          :linebreak (do (.append sb (if (zero? alt-depth) "<br />\n" " "))
                         (recur more alt-depth image-title))
          :start
          (let [what (nth ev 1)]
            (case what
              :emph (do (when (zero? alt-depth) (.append sb "<em>"))
                        (recur more alt-depth image-title))
              :strong (do (when (zero? alt-depth) (.append sb "<strong>"))
                          (recur more alt-depth image-title))
              :link (do (when (zero? alt-depth)
                          (.append sb "<a href=\"")
                          (t/encode-url! sb (:destination (nth ev 2)))
                          (.append sb \")
                          (write-title! sb (:title (nth ev 2)))
                          (.append sb \>))
                        (recur more alt-depth image-title))
              :image (if (zero? alt-depth)
                       (do (.append sb "<img src=\"")
                           (t/encode-url! sb (:destination (nth ev 2)))
                           (.append sb "\" alt=\"")
                           (recur more 1 (:title (nth ev 2))))
                       (recur more (inc alt-depth) image-title))))
          :end
          (let [what (nth ev 1)]
            (case what
              :emph (do (when (zero? alt-depth) (.append sb "</em>"))
                        (recur more alt-depth image-title))
              :strong (do (when (zero? alt-depth) (.append sb "</strong>"))
                          (recur more alt-depth image-title))
              :link (do (when (zero? alt-depth) (.append sb "</a>"))
                        (recur more alt-depth image-title))
              :image (if (== alt-depth 1)
                       (do (.append sb \")
                           (write-title! sb image-title)
                           (.append sb " />")
                           (recur more 0 nil))
                       (recur more (dec alt-depth) image-title))))))))
  sb)

;; ---------------------------------------------------------------------------
;; Blocks
;; ---------------------------------------------------------------------------

(defn- language-class
  "The value of the `class` attribute for a code block with the given info
  string, or nil."
  [^String info]
  (let [end (loop [i 0] (if (and (< i (.length info)) (not (t/ws? (char-at info i)))) (recur (inc i)) i))
        word (.substring info 0 end)]
    (when-not (zero? (.length word))
      (if (.startsWith word "language-") word (str "language-" word)))))

(defn- render-block!
  [^StringBuilder sb node tight-item?]
  (case (:type node)
    :document (doseq [c (:children node)] (render-block! sb c false))

    :block-quote
    (do (cr! sb)
        (.append sb "<blockquote>\n")
        (doseq [c (:children node)] (render-block! sb c false))
        (cr! sb)
        (.append sb "</blockquote>\n"))

    :list
    (let [ordered? (:ordered? node)
          tag (if ordered? "ol" "ul")]
      (cr! sb)
      (.append sb \<)
      (.append sb tag)
      (when (and ordered? (not= 1 (:start node)))
        (.append sb " start=\"")
        (.append sb (long (:start node)))
        (.append sb \"))
      (.append sb ">\n")
      (let [tight? (:tight? node)]
        (doseq [item (:children node)]
          (cr! sb)
          (.append sb "<li>")
          (doseq [c (:children item)] (render-block! sb c tight?))
          (.append sb "</li>\n")))
      (.append sb "</")
      (.append sb tag)
      (.append sb ">\n"))

    ;; list items are rendered by their list
    :list-item (doseq [c (:children node)] (render-block! sb c false))

    :paragraph
    (if tight-item?
      (render-inlines! sb (:inlines node))
      (do (cr! sb)
          (.append sb "<p>")
          (render-inlines! sb (:inlines node))
          (.append sb "</p>\n")))

    :heading
    (let [level (long (:level node))]
      (cr! sb)
      (.append sb "<h")
      (.append sb level)
      (.append sb \>)
      (render-inlines! sb (:inlines node))
      (.append sb "</h")
      (.append sb level)
      (.append sb ">\n"))

    :code-block
    (do (cr! sb)
        (if-let [cls (language-class (:info node))]
          (do (.append sb "<pre><code class=\"")
              (t/escape-html! sb cls)
              (.append sb "\">"))
          (.append sb "<pre><code>"))
        (t/escape-html! sb (:literal node))
        (.append sb "</code></pre>\n"))

    :thematic-break
    (do (cr! sb)
        (.append sb "<hr />\n"))))

(defn render-document
  "Render a parsed document node to an HTML string."
  ^String [doc]
  (let [sb (StringBuilder.)]
    (render-block! sb doc false)
    (.toString sb)))
