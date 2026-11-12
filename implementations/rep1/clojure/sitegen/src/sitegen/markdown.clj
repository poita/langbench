(ns sitegen.markdown
  "A CommonMark-subset to HTML converter that reproduces the output of cmark
  0.31.2 (default options) for the supported subset: thematic breaks, ATX and
  setext headings, indented and fenced code, paragraphs, block quotes, lists,
  backslash escapes, entities, code spans, emphasis, inline links and images,
  autolinks and line breaks.  HTML blocks, raw inline HTML, link reference
  definitions and extensions are not supported.

  The conversion has two phases (see `sitegen.markdown.block` and
  `sitegen.markdown.inline`) followed by a single rendering walk
  (`sitegen.markdown.html`).

      (require '[sitegen.markdown :as md])
      (md/->html \"Hello *world*\")
      ;; => \"<p>Hello <em>world</em></p>\\n\""
  (:require [sitegen.markdown.block :as block]
            [sitegen.markdown.inline :as inline]
            [sitegen.markdown.html :as html]))

(defn ->html
  "Converts the Markdown text `src` to HTML.  The result ends with a newline
  unless it is empty (which it is exactly for blank input)."
  ^String [^String src]
  (let [root (block/parse src)]
    (inline/parse-all! root)
    (html/render root)))
