(ns sitegen.core
  "The public API of the site generator.

  The pipeline has four stages: *load* the source tree, build the content
  *model*, *render* every page through the templates, and *emit* the files
  and the static assets.  `generate!` runs all four; `build-site` runs the
  middle two on in-memory data, which is convenient for tests and tools.

      (require '[sitegen.core :as sitegen])
      (sitegen/generate! \"my-site\" \"out\")"
  (:require [sitegen.content :as content]
            [sitegen.io :as io]
            [sitegen.model :as model]
            [sitegen.render :as render]
            [sitegen.template :as template]
            [sitegen.toml :as toml]))

(defn build-site
  "Builds the site described by `source`, a map with

  `:config`     the text of site.toml
  `:posts`      a collection of [file-name text] for the post files
  `:pages`      a collection of [file-name text] for the page files
  `:templates`  a map from template name to source text

  and returns a map from relative output path to file text (everything
  except the static files)."
  [{:keys [config posts pages templates]}]
  (let [site (toml/parse-document config)
        model (model/build site
                           (mapv (fn [[name text]] (content/parse-post name text)) posts)
                           (mapv (fn [[name text]] (content/parse-page name text)) pages))
        env (template/make-env templates)]
    (render/render-files model env)))

(defn generate!
  "Reads the site source in `input-dir`, and writes the generated site into
  `output-dir` (which is created if missing): every page, `feed.xml`,
  `sitemap.xml` and a copy of `static/`.  Returns the number of generated
  files, not counting static files."
  [input-dir output-dir]
  (let [source (io/read-source input-dir)
        files (build-site source)]
    (doseq [[path text] files]
      (io/write-text! output-dir path text))
    (io/copy-static! (:static-dir source) output-dir)
    (count files)))
