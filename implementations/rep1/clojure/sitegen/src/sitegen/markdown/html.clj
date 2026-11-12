(ns sitegen.markdown.html
  "Renders a parsed Markdown tree to HTML in cmark's output format."
  (:require [sitegen.markdown.node :as nd]
            [sitegen.markdown.text :as t]))

(set! *warn-on-reflection* true)

(defn- cr!
  "Ensures the output ends with a newline (unless it is empty)."
  [^StringBuilder sb]
  (let [n (.length sb)]
    (when (and (pos? n) (not (= (.charAt sb (dec n)) \newline)))
      (.append sb \newline))))

(defn- alt-text
  "The plain text of the descendants of an image node."
  ^String [image]
  (let [sb (StringBuilder.)]
    (nd/walk! image
              (fn [node entering?]
                (when entering?
                  (case (nd/kind node)
                    (:text :code) (.append sb (t/escape-html (nd/text node)))
                    (:softbreak :linebreak) (.append sb \space)
                    nil))))
    (.toString sb)))

(defn- tight-paragraph? [para]
  (let [item (nd/parent para)
        lst (when item (nd/parent item))]
    (boolean (and lst (= :list (nd/kind lst)) (nd/tight lst)))))

(defn- code-class
  "The `class` attribute value for a fenced code block's info string, or nil."
  [^String info]
  (when (pos? (.length info))
    (let [end (loop [i 0] (if (and (< i (.length info)) (not (t/ws? (.charAt info i)))) (recur (inc i)) i))
          word (.substring info 0 end)]
      (t/escape-html (if (.startsWith word "language-") word (str "language-" word))))))

(defn render
  "Renders the document node `root` (after inline parsing) as an HTML string."
  ^String [root]
  (let [sb (StringBuilder.)
        skip (volatile! nil)]
    (nd/walk!
     root
     (fn [node entering?]
       (if @skip
         (when (and (not entering?) (identical? node @skip))
           (vreset! skip nil))
         (case (nd/kind node)
           :document nil

           :block-quote
           (do (cr! sb) (.append sb (if entering? "<blockquote>\n" "</blockquote>\n")))

           :list
           (if entering?
             (do (cr! sb)
                 (.append sb (cond
                               (not (nd/ordered node)) "<ul>\n"
                               (== 1 (long (nd/level node))) "<ol>\n"
                               :else (str "<ol start=\"" (nd/level node) "\">\n"))))
             (.append sb (if (nd/ordered node) "</ol>\n" "</ul>\n")))

           :item
           (if entering?
             (do (cr! sb) (.append sb "<li>"))
             (.append sb "</li>\n"))

           :paragraph
           (when-not (tight-paragraph? node)
             (if entering?
               (do (cr! sb) (.append sb "<p>"))
               (.append sb "</p>\n")))

           :heading
           (if entering?
             (do (cr! sb) (.append sb "<h") (.append sb (long (nd/level node))) (.append sb \>))
             (do (.append sb "</h") (.append sb (long (nd/level node))) (.append sb ">\n")))

           :code-block
           (when entering?
             (cr! sb)
             (if-let [cls (code-class (or (nd/info node) ""))]
               (do (.append sb "<pre><code class=\"") (.append sb ^String cls) (.append sb "\">"))
               (.append sb "<pre><code>"))
             (.append sb (t/escape-html (.toString ^StringBuilder (nd/text node))))
             (.append sb "</code></pre>\n"))

           :thematic-break
           (when entering? (cr! sb) (.append sb "<hr />\n"))

           :text (when entering? (.append sb (t/escape-html (nd/text node))))
           :softbreak (when entering? (.append sb \newline))
           :linebreak (when entering? (.append sb "<br />\n"))
           :code (when entering?
                   (.append sb "<code>")
                   (.append sb (t/escape-html (nd/text node)))
                   (.append sb "</code>"))
           :emph (.append sb (if entering? "<em>" "</em>"))
           :strong (.append sb (if entering? "<strong>" "</strong>"))

           :link
           (if entering?
             (do (.append sb "<a href=\"")
                 (.append sb (t/href (nd/dest node)))
                 (.append sb \")
                 (when-let [title (nd/title node)]
                   (.append sb " title=\"")
                   (.append sb (t/escape-html title))
                   (.append sb \"))
                 (.append sb \>))
             (.append sb "</a>"))

           :image
           (when entering?
             (.append sb "<img src=\"")
             (.append sb (t/href (nd/dest node)))
             (.append sb "\" alt=\"")
             (.append sb (alt-text node))
             (.append sb \")
             (when-let [title (nd/title node)]
               (.append sb " title=\"")
               (.append sb (t/escape-html title))
               (.append sb \"))
             (.append sb " />")
             (vreset! skip node))))))
    (.toString sb)))
