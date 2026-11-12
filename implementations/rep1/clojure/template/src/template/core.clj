(ns template.core
  "Public API of the template engine, a Jinja2-style subset.

      (require '[template.core :as t])

      (t/render-string \"Hello {{ name|upper }}!\" {:name \"ada\"})
      ;=> \"Hello ADA!\"

      (t/render {\"main\" \"{% extends 'base' %}{% block b %}x{% endblock %}\"
                 \"base\" \"<{% block b %}{% endblock %}>\"}
                \"main\" {})
      ;=> \"<x>\"

  Rendering is all-or-nothing: on failure an `ex-info` is thrown whose data has
  `:template/error` set to one of `:syntax`, `:filter`, `:undefined`,
  `:template`, `:type` (see [[error-kind]])."
  (:require [template.errors :as err]
            [template.input :as input]
            [template.interp :as interp]
            [template.json :as json]
            [template.parser :as parser]
            [template.values :as v]))

(defn render
  "Render the template named `main-name` and return the resulting string.

  `templates` maps template names to source strings; the others are available
  to `include` and `extends`. `context` is a map of initial variables (keyword
  or string keys; maps, sequential collections, strings, numbers, booleans and
  nil are converted, see [[template.values/from-clj]])."
  [templates main-name context]
  (let [ctx (v/from-clj (or context {}))]
    (interp/render templates main-name ctx)))

(defn render-string
  "Render a single template given as a string."
  ([source] (render-string source {}))
  ([source context] (render {"main" source} "main" context)))

(defn render-json
  "Render template `main-name` from `templates` with the context given as a
  JSON object string; its member order is the dict iteration order."
  [templates main-name context-json]
  (interp/render templates main-name (json/parse context-json)))

(defn render-input
  "Render a complete program text in the command-line format (JSON context,
  `--`, then `=== name` templates); the first template is rendered."
  [text]
  (let [{:keys [context main templates]} (input/parse-input text)]
    (interp/render templates main context)))

(defn parse-template
  "Parse and check one template source; returns its syntax tree or throws a
  `:syntax` / `:filter` error. Mostly useful for tooling and tests."
  [source]
  (parser/parse source))

(def error-kind
  "The template error kind (`:syntax` ...) of an exception, or nil."
  err/error-kind)
