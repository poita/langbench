(ns commonmark.core
  "Convert CommonMark text to HTML.

  The supported dialect is the CommonMark 0.31.2 subset that the cmark
  reference implementation handles without HTML: thematic breaks, ATX and
  setext headings, indented and fenced code blocks, paragraphs, block quotes,
  lists, backslash escapes, the entities `&amp;` `&lt;` `&gt;` `&quot;` and
  numeric ones, code spans, emphasis, inline links and images, autolinks and
  line breaks. Raw HTML, link reference definitions and extensions are not
  supported.

  The conversion is split into three modules:

  * `commonmark.blocks`  - the block structure (phase 1),
  * `commonmark.inlines` - the inline events of each paragraph and heading
                           (phase 2),
  * `commonmark.html`    - the HTML renderer.

  This namespace ties them together."
  (:require [commonmark.blocks :as blocks]
            [commonmark.html :as html]
            [commonmark.inlines :as inlines]))

(set! *warn-on-reflection* true)

(defn- add-inlines
  [node]
  (case (:type node)
    (:paragraph :heading) (assoc node :inlines (inlines/parse-inlines (:content node)))
    (:document :block-quote :list :list-item) (update node :children #(mapv add-inlines %))
    node))

(defn parse
  "Parse the Markdown string `md` into a document tree: nested maps with a
  `:type` key (`:document`, `:block-quote`, `:list`, `:list-item`,
  `:paragraph`, `:heading`, `:thematic-break`, `:code-block`). Container nodes
  have `:children`; paragraphs and headings have their raw `:content` and the
  parsed `:inlines` (a vector of events, see `commonmark.inlines`). Details of
  the other keys are in the docstring of `commonmark.blocks`."
  [md]
  (add-inlines (blocks/parse-blocks md)))

(defn render
  "Render a document tree produced by [[parse]] as an HTML string."
  [doc]
  (html/render-document doc))

(defn markdown->html
  "Convert the Markdown string `md` to HTML.

      (markdown->html \"# Hi\\n\\n*there*\")
      ;; => \"<h1>Hi</h1>\\n<p><em>there</em></p>\\n\""
  [md]
  (render (parse md)))
