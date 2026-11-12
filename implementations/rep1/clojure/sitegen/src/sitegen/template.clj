(ns sitegen.template
  "A Jinja2-style template engine for a well-defined subset of the language:
  `{{ expr }}`, `{% if %}`, `{% for %}`, `{% set %}`, `{% macro %}`,
  `{% include %}`, `{% extends %}` / `{% block %}` with `super()`, comments,
  whitespace control (`{%-`, `-%}`) and thirteen filters (`upper lower trim
  escape replace length int join first last reverse sort default`).

  Autoescaping is off.  Undefined values are strict: using one (other than
  with `is defined` or `|default`) is an error.

      (require '[sitegen.template :as tpl])
      (def env (tpl/make-env {\"hello\" \"Hello {{ name|upper }}!\"}))
      (tpl/render env \"hello\" {\"name\" \"ada\"})
      ;; => \"Hello ADA!\"

  Template values are plain JVM values (see `sitegen.template.value`):
  `Long`, `Double`, `Boolean`, `nil`, `String`, `java.util.List` and
  `java.util.Map`.  Errors are thrown as `ex-info` whose data has
  `:type :sitegen.template/error` and `:kind` one of `:syntax`, `:filter`,
  `:undefined`, `:template`, `:type`."
  (:require [sitegen.template.eval :as eval]))

(defn make-env
  "Creates a template environment from `templates`, either a map from
  template name to source text or a function from name to source (or nil).
  Each template is parsed and checked at most once, when first needed."
  [templates]
  (eval/make-env (if (fn? templates) templates (fn [name] (get templates name)))))

(defn render
  "Renders the template `name` with `context`, a map from variable names
  (strings) to values, and returns the resulting string."
  [env name context]
  (eval/render env name context))

(defn error-kind
  "The kind (:syntax, :filter, :undefined, :template or :type) of a template
  exception, or nil when `e` is not one."
  [e]
  (let [d (ex-data e)]
    (when (= :sitegen.template/error (:type d)) (:kind d))))
