(ns chip8.rng
  "The deterministic 32-bit linear congruential generator used by `CXNN`.")

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def seed
  "Initial generator state."
  0x12345678)

(defn next-state
  "Advance the generator state `s` (an unsigned 32-bit value) once."
  ^long [^long s]
  (bit-and (+ (* s 1103515245) 12345) 0xFFFFFFFF))

(defn state->byte
  "The random byte derived from generator state `s`."
  ^long [^long s]
  (bit-and (bit-shift-right s 16) 0xFF))

(defn sequence-of-bytes
  "A lazy sequence of the random bytes the generator yields from the seed."
  ([] (sequence-of-bytes seed))
  ([s]
   (map state->byte (rest (iterate next-state s)))))
