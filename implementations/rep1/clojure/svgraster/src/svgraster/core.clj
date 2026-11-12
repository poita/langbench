(ns svgraster.core
  "Public API of svgraster, a small SVG 1.1 subset rasteriser.

  Typical use:

      (require '[svgraster.core :as svg])
      (def img (svg/render-svg \"<svg viewBox='0 0 8 4'><rect width='4' height='4'/></svg>\" 8 4))
      (svg/image->ppm img)          ;=> byte[] holding a binary P6 file
      (svg/render-file \"in.svg\" 64 64 \"out.ppm\")
      (svg/render-directory \"in-dir\" \"out-dir\")

  An *image* is a map `{:width w :height h :pixels bytes}` where `:pixels`
  holds `w*h*3` RGB bytes, rows top to bottom (the picture composited over
  an opaque white background)."
  (:require [clojure.string :as str]
            [svgraster.raster :as raster]
            [svgraster.render :as render]
            [svgraster.xml :as xml])
  (:import (java.nio.charset StandardCharsets)
           (java.nio.file Files Path Paths OpenOption)))

(set! *warn-on-reflection* true)

(defn render-svg
  "Renders the SVG text `svg-text` at `width` x `height` pixels (1..4096).
  Returns an image map. Throws `ex-info` if the text has no document element."
  [^String svg-text width height]
  (let [text (if (.startsWith svg-text "﻿") (subs svg-text 1) svg-text)
        root (xml/parse text)
        canvas (render/render-document root (long width) (long height))]
    {:width (long width)
     :height (long height)
     :pixels (raster/->rgb-bytes canvas)}))

(defn image->ppm
  "The contents of the binary PPM (P6) file for `image`, as a `byte[]`."
  ^bytes [{:keys [width height ^bytes pixels]}]
  (let [header (.getBytes (str "P6\n" width " " height "\n255\n") StandardCharsets/US_ASCII)
        out (byte-array (+ (alength header) (alength pixels)))]
    (System/arraycopy header 0 out 0 (alength header))
    (System/arraycopy pixels 0 out (alength header) (alength pixels))
    out))

(defn- path-of ^Path [^String s] (Paths/get s (make-array String 0)))

(defn render-file
  "Reads the SVG file `svg-path`, renders it at `width` x `height` and writes
  a PPM to `ppm-path` (creating parent directories)."
  [svg-path width height ppm-path]
  (let [text (String. (Files/readAllBytes (path-of svg-path)) StandardCharsets/UTF_8)
        out (path-of ppm-path)]
    (when-let [parent (.getParent (.toAbsolutePath out))]
      (Files/createDirectories parent (into-array java.nio.file.attribute.FileAttribute [])))
    (Files/write out ^bytes (image->ppm (render-svg text width height))
                 ^"[Ljava.nio.file.OpenOption;" (into-array OpenOption []))
    ppm-path))

(defn parse-render-list
  "Parses the text of a `render.txt` file into a vector of
  `{:name \"a.svg\" :width w :height h}` maps. Blank lines and lines whose
  first non-space character is `#` are ignored; a trailing `\\r` is dropped."
  [^String text]
  (into []
        (comp (map #(str/replace % #"\r$" ""))
              (map str/trim)
              (remove #(or (empty? %) (str/starts-with? % "#")))
              (map #(str/split % #"\s+"))
              (filter #(= 3 (count %)))
              (map (fn [[name w h]]
                     {:name name
                      :width (Long/parseLong w)
                      :height (Long/parseLong h)})))
        (str/split text #"\n")))

(defn render-directory
  "Renders every file named in `<in-dir>/render.txt` into `out-dir` (created
  if needed) as `<name without .svg>.ppm`. A file that fails to render is
  reported through `on-error` (called with the entry and the exception;
  default: rethrow) and skipped. Returns the vector of output paths written."
  ([in-dir out-dir] (render-directory in-dir out-dir (fn [_ e] (throw e))))
  ([in-dir out-dir on-error]
   (let [in (path-of in-dir)
         out (path-of out-dir)
         text (String. (Files/readAllBytes (.resolve in "render.txt")) StandardCharsets/UTF_8)]
     (Files/createDirectories out (into-array java.nio.file.attribute.FileAttribute []))
     (into []
           (keep (fn [{:keys [name width height] :as entry}]
                   (let [target (str (.resolve out (str (str/replace name #"\.svg$" "") ".ppm")))]
                     (try
                       (render-file (str (.resolve in ^String name)) width height target)
                       (catch Exception e
                         (on-error entry e)
                         nil)))))
           (parse-render-list text)))))
