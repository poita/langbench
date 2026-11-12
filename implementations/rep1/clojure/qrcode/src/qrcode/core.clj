(ns qrcode.core
  "Public API: encode text as a QR Code Model 2 symbol (ISO/IEC 18004).

      (require '[qrcode.core :as qr])

      (def sym (qr/encode \"HELLO WORLD\" :m))
      (:version sym) ;=> 1
      (:mask sym)    ;=> 0
      (qr/dark? sym 0 0) ;=> true
      (qr/rows sym)  ;=> [\"#######...#.#.#######\" ...]

  Text is encoded as a single segment in the first applicable mode (numeric,
  alphanumeric, byte) using its UTF-8 bytes, in the smallest version that
  holds it. No ECI header is emitted."
  (:require [qrcode.codewords :as codewords]
            [qrcode.mask :as mask]
            [qrcode.matrix :as matrix]
            [qrcode.penalty :as penalty]
            [qrcode.segment :as segment]
            [qrcode.tables :as tables])
  (:import (java.nio.charset StandardCharsets)
           (qrcode.matrix Grid)))

(set! *warn-on-reflection* true)

(defn- choose-mask
  "Returns [mask grid] for the lowest-penalty mask (lowest number on ties)."
  [^Grid base ecl]
  (loop [m 0, best-score Long/MAX_VALUE, best nil]
    (if (== m 8)
      best
      (let [g (-> (matrix/copy-grid base)
                  (mask/apply-mask! m)
                  (matrix/draw-format! ecl m))
            score (penalty/penalty g)]
        (if (< score best-score)
          (recur (inc m) score [m g])
          (recur (inc m) best-score best))))))

(defn encode-bytes
  "Like [[encode]] but takes the payload as a byte array."
  [^bytes data ecl mask-choice]
  (tables/check-ecl ecl)
  (when-not (or (= mask-choice :auto)
                (and (integer? mask-choice) (<= 0 mask-choice 7)))
    (throw (ex-info "Mask must be an integer in 0..7 or :auto" {:mask mask-choice})))
  (when (zero? (alength data))
    (throw (ex-info "Payload must not be empty" {})))
  (let [mode (segment/select-mode data)
        version (or (segment/choose-version mode (alength data) ecl)
                    (throw (ex-info "Payload too large for any version"
                                    {:ecl ecl :mode mode :length (alength data)})))
        cw (-> (codewords/data-codewords mode data version ecl)
               (codewords/interleave-blocks version ecl))
        base (-> (matrix/function-patterns version)
                 (matrix/place-data! cw))
        [m ^Grid g] (if (= mask-choice :auto)
                      (choose-mask base ecl)
                      [mask-choice
                       (-> base
                           (mask/apply-mask! mask-choice)
                           (matrix/draw-format! ecl mask-choice))])]
    {:version version
     :ecl ecl
     :mode mode
     :mask m
     :size (.-size g)
     :grid g}))

(defn encode
  "Encodes the string `text` (as UTF-8) at error correction level `ecl`
  (:l :m :q :h). `mask-choice` is a mask number 0..7 or :auto (the default
  when omitted) to pick the lowest-penalty mask.

  Returns a map with :version (1..40), :ecl, :mode (:numeric, :alphanumeric
  or :byte), :mask (0..7), :size (modules per side) and :grid (opaque; use
  [[dark?]], [[rows]] or [[matrix]]). Throws ex-info if the text is empty or
  does not fit in version 40."
  ([text ecl] (encode text ecl :auto))
  ([^String text ecl mask-choice]
   (encode-bytes (.getBytes text StandardCharsets/UTF_8) ecl mask-choice)))

(defn dark?
  "True when module (x, y) of the encoded symbol is dark. Row 0 is the top,
  column 0 the left."
  [symbol x y]
  (matrix/dark? (:grid symbol) x y))

(defn matrix
  "The symbol as a vector of rows, each a vector of booleans (true = dark)."
  [{:keys [size] :as symbol}]
  (vec (for [y (range size)]
         (vec (for [x (range size)] (dark? symbol x y))))))

(defn rows
  "The symbol as a vector of strings, `#` for dark and `.` for light."
  [{:keys [size] :as symbol}]
  (vec (for [y (range size)]
         (apply str (for [x (range size)] (if (dark? symbol x y) \# \.))))))
