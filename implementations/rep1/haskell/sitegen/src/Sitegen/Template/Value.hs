{-# LANGUAGE OverloadedStrings #-}

-- | Values of the template language and their string forms.
module Sitegen.Template.Value
  ( Value (..)
  , Dict
  , Macro (..)
  , mkDict
  , mkList
  , dictLookup
  , dictKeys
  , dictSize
  , dictToList
  , isDefined
  , displayValue
  , reprValue
  , formatFloat
  ) where

import Data.Char (intToDigit)
import Data.Foldable (toList)
import qualified Data.Map.Lazy as Map
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (floatToDigits)

import Sitegen.Template.Syntax (Expr, Node)

-- | A template value.
--
-- Booleans take part in arithmetic as the integers 0 and 1. 'VUndefined' is
-- the result of a failed lookup; most uses of it are errors.
data Value
  = VUndefined
  | VNone
  | VBool !Bool
  | VInt !Integer
  | VFloat !Double
  | VString !Text
  | VList !(Seq Value)
  | VDict !Dict
  | VMacro Macro
  | VRange
  -- ^ The built-in @range@ function.
  | VSuper !Text !Int
  -- ^ The @super@ function of block @name@ rendered as chain entry @k@.

-- | An insertion-ordered dictionary with string keys. Values are lazy, so a
-- dictionary can be built cheaply and its members computed on demand.
data Dict = Dict [Text] (Map.Map Text Value)

-- | A macro closure. The scope is identified by an id registered by the
-- evaluator.
data Macro = Macro
  { macroName :: Text
  , macroParams :: [(Text, Maybe Expr)]
  , macroBody :: [Node]
  , macroScope :: Int
  }

-- | Build a dictionary value; members keep the given order.
mkDict :: [(Text, Value)] -> Value
mkDict kvs = VDict (Dict (map fst kvs) (Map.fromList kvs))

-- | Build a list value.
mkList :: [Value] -> Value
mkList = VList . Seq.fromList

dictLookup :: Text -> Dict -> Maybe Value
dictLookup k (Dict _ m) = Map.lookup k m

dictKeys :: Dict -> [Text]
dictKeys (Dict ks _) = ks

dictSize :: Dict -> Int
dictSize (Dict _ m) = Map.size m

dictToList :: Dict -> [(Text, Value)]
dictToList d@(Dict _ m) = [(k, m Map.! k) | k <- dictKeys d, Map.member k m]

-- | Is the value anything but the undefined value?
isDefined :: Value -> Bool
isDefined VUndefined = False
isDefined _ = True

-- | The string form used when printing. 'Nothing' for values that cannot be
-- printed (the undefined value, macros and built-in functions).
displayValue :: Value -> Maybe Text
displayValue v = case v of
  VString s -> Just s
  VUndefined -> Nothing
  VMacro _ -> Nothing
  VRange -> Nothing
  VSuper _ _ -> Nothing
  _ -> reprValue v

-- | The repr form: like the string form but strings are quoted. 'Nothing'
-- for values that cannot be printed.
reprValue :: Value -> Maybe Text
reprValue v = case v of
  VNone -> Just "None"
  VBool True -> Just "True"
  VBool False -> Just "False"
  VInt i -> Just (T.pack (show i))
  VFloat d -> Just (formatFloat d)
  VString s -> Just (quote s)
  VList xs -> do
    parts <- mapM reprValue (toList xs)
    Just ("[" <> T.intercalate ", " parts <> "]")
  VDict d -> do
    parts <- mapM (\(k, x) -> (\r -> quote k <> ": " <> r) <$> reprValue x) (dictToList d)
    Just ("{" <> T.intercalate ", " parts <> "}")
  _ -> Nothing

quote :: Text -> Text
quote s = T.concat [q, T.concatMap esc s, q]
  where
    useDouble = T.any (== '\'') s && not (T.any (== '"') s)
    q = if useDouble then "\"" else "'"
    esc c = case c of
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      '\'' | not useDouble -> "\\'"
      _ -> T.singleton c

-- | Format a float the way Python does: the shortest digits that round-trip,
-- positional notation for exponents in [-4, 16), scientific otherwise.
formatFloat :: Double -> Text
formatFloat x
  | x == 0 = if isNegativeZero x then "-0.0" else "0.0"
  | isInfinite x = if x > 0 then "inf" else "-inf"
  | isNaN x = "nan"
  | otherwise = T.pack (sign ++ body)
  where
    sign = if x < 0 then "-" else ""
    (ds, e) = floatToDigits 10 (abs x)
    digits = map intToDigit ds
    ex = e - 1
    body
      | ex >= -4 && ex < 16 = positional
      | otherwise = scientific
    positional
      | ex >= 0 =
          let (ip, fp) = splitAt (ex + 1) (digits ++ replicate (ex + 1 - length digits) '0')
           in ip ++ "." ++ (if null fp then "0" else fp)
      | otherwise = "0." ++ replicate (negate ex - 1) '0' ++ digits
    scientific =
      let mant = case digits of
            [d] -> [d]
            (d : rest) -> d : '.' : rest
            [] -> "0"
          expAbs = show (abs ex)
       in mant ++ "e" ++ (if ex < 0 then "-" else "+") ++ (if length expAbs < 2 then '0' : expAbs else expAbs)
