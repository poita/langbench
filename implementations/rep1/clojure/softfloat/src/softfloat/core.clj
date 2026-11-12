(ns softfloat.core
  "Software IEEE-754 binary32 arithmetic with round-to-nearest-even and full
  gradual underflow.

  Values are raw 32-bit patterns held in a `long` (0 .. 0xFFFFFFFF), e.g.
  `0x3f800000` for 1.0.  All arithmetic is bounded-width integer arithmetic;
  no host floating point is used.  Any NaN operand or invalid operation gives
  the canonical quiet NaN `0x7fc00000`.

      (require '[softfloat.core :as sf])
      (sf/add 0x3f800000 0x3f800000)  ;=> 0x40000000
      (sf/eval-op \"sqrt\" [0x40000000]) ;=> 0x3fb504f3"
  (:require [softfloat.add :as fadd]
            [softfloat.div :as fdiv]
            [softfloat.mul :as fmul]
            [softfloat.sqrt :as fsqrt]))

(set! *warn-on-reflection* true)

(defn add "Pattern of a + b." ^long [^long a ^long b] (fadd/add a b))
(defn sub "Pattern of a - b." ^long [^long a ^long b] (fadd/sub a b))
(defn mul "Pattern of a * b." ^long [^long a ^long b] (fmul/mul a b))
(defn div "Pattern of a / b." ^long [^long a ^long b] (fdiv/div a b))
(defn sqrt "Pattern of the square root of a." ^long [^long a] (fsqrt/sqrt a))

(def binary-ops
  "Map of operation name to two-argument function."
  {"add" add "sub" sub "mul" mul "div" div})

(defn eval-op
  "Evaluate operation `op` (\"add\" \"sub\" \"mul\" \"div\" \"sqrt\") on the
  operand patterns `args` (one for sqrt, otherwise two).  Throws
  `ex-info` for an unknown operation."
  ^long [^String op args]
  (if (= op "sqrt")
    (sqrt (first args))
    (if-let [f (get binary-ops op)]
      (f (first args) (second args))
      (throw (ex-info (str "unknown operation: " op) {:op op})))))
