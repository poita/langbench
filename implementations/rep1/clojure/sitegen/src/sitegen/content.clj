(ns sitegen.content
  "Parsing of content files: front matter splitting and the post and page
  front-matter schemas."
  (:require [sitegen.toml :as toml]))

(set! *warn-on-reflection* true)

(defn- invalid [file-name msg]
  (throw (ex-info (str file-name ": " msg) {:type ::invalid-content :file file-name})))

(defn split-front-matter
  "Splits the text of a content file into its front matter and body.  The file
  must begin with the line `+++`; the front matter ends at the first later
  line that is exactly `+++`.  Returns `[front-matter body]` (strings), where
  the body is everything after that line's newline, verbatim."
  [^String text]
  (when-not (.startsWith text "+++\n")
    (throw (ex-info "content file does not start with +++" {:type ::invalid-content})))
  (let [n (.length text)]
    (loop [line-start 4]
      (when (> line-start n)
        (throw (ex-info "front matter is not closed by +++" {:type ::invalid-content})))
      (let [nl (.indexOf text (int \newline) (int line-start))
            line-end (if (neg? nl) n nl)]
        (cond
          (and (== (- line-end line-start) 3) (.startsWith text "+++" (int line-start)))
          [(.substring text 4 (max 4 (dec line-start)))
           (if (neg? nl) "" (.substring text (inc line-end)))]

          (neg? nl)
          (throw (ex-info "front matter is not closed by +++" {:type ::invalid-content}))

          :else (recur (inc line-end)))))))

(defn- require-string [file-name front k]
  (let [v (get front k)]
    (when-not (string? v) (invalid file-name (str "front matter key `" k "` must be a string")))
    v))

(defn- optional-bool [file-name front k]
  (let [v (get front k false)]
    (when-not (instance? Boolean v) (invalid file-name (str "`" k "` must be a boolean")))
    v))

(defn- default-slug [^String file-name]
  (if (.endsWith file-name ".md") (.substring file-name 0 (- (.length file-name) 3)) file-name))

(defn- parse-front [file-name text]
  (try
    (let [[front body] (split-front-matter text)]
      [(toml/parse-document front) body])
    (catch clojure.lang.ExceptionInfo e
      (invalid file-name (ex-message e)))))

(defn parse-post
  "Parses the text of the post file `file-name` into a map with the keys
  `:title :date :slug :tags :draft :body`.  `:tags` holds the distinct tag
  names in front-matter order."
  [file-name text]
  (let [[front body] (parse-front file-name text)
        date (require-string file-name front "date")]
    (when-not (re-matches #"\d{4}-\d{2}-\d{2}" date)
      (invalid file-name "`date` must look like YYYY-MM-DD"))
    {:title (require-string file-name front "title")
     :date date
     :slug (if (contains? front "slug") (require-string file-name front "slug") (default-slug file-name))
     :tags (vec (distinct (get front "tags" [])))
     :draft (optional-bool file-name front "draft")
     :body body}))

(defn parse-page
  "Parses the text of the page file `file-name` into a map with the keys
  `:title :slug :draft :body`."
  [file-name text]
  (let [[front body] (parse-front file-name text)]
    {:title (require-string file-name front "title")
     :slug (if (contains? front "slug") (require-string file-name front "slug") (default-slug file-name))
     :draft (optional-bool file-name front "draft")
     :body body}))
