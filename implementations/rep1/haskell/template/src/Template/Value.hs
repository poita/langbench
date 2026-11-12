{-# LANGUAGE OverloadedStrings #-}
-- | Runtime values, scopes and their textual forms.
module Template.Value
  ( Value (..)
  , Dict (..)
  , Macro (..)
  , Scope (..)
  , dictFromList
  , dictToList
  , dictSize
  , dictLookup
  , isUndefined
  , display
  , repr
  , formatFloat
  , sequenceView
  , newScope
  , bindVar
  , lookupVar
  ) where

import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (floatToDigits)

import Template.Error
import Template.Syntax (Param, Stmt)

-- | A template value.
data Value
  = VInt !Integer
  | VFloat !Double
  | VBool !Bool
  | VNone
  | VStr !Text
  | VList !(Seq Value)
  | VDict !Dict
  | VMacro !Macro
  | VRange                 -- ^ the built-in @range@ function
  | VSuper !(IO Text)      -- ^ the @super@ function inside a block body
  | VUndefined

-- | An insertion-ordered dictionary with string keys.
data Dict = Dict
  { dictMap  :: !(Map Text Value)
  , dictKeys :: !(Seq Text)
  }

-- | A macro closed over the scope it was defined in.
data Macro = Macro
  { macroName   :: Text
  , macroParams :: [Param]
  , macroBody   :: [Stmt]
  , macroScope  :: Scope
  }

-- | A mutable mapping from names to values with a parent scope.
data Scope = Scope
  { scopeVars   :: !(IORef (Map Text Value))
  , scopeParent :: !(Maybe Scope)
  }

instance Show Value where
  show v = T.unpack (repr v)

-- | Build a dictionary; keys keep their order of first appearance.
dictFromList :: [(Text, Value)] -> Dict
dictFromList kvs = Dict (Map.fromList kvs) (Seq.fromList (dedup Map.empty (map fst kvs)))
  where
    dedup _ [] = []
    dedup seen (k : ks)
      | Map.member k seen = dedup seen ks
      | otherwise = k : dedup (Map.insert k () seen) ks

-- | The members of a dictionary in insertion order.
dictToList :: Dict -> [(Text, Value)]
dictToList d = [(k, v) | k <- toList (dictKeys d), Just v <- [Map.lookup k (dictMap d)]]

dictSize :: Dict -> Int
dictSize = Map.size . dictMap

dictLookup :: Text -> Dict -> Maybe Value
dictLookup k = Map.lookup k . dictMap

isUndefined :: Value -> Bool
isUndefined VUndefined = True
isUndefined _ = False

-- | The string form of a value, as used by @{{ }}@, @~@ and string filters.
-- The undefined value has none.
display :: Value -> Either ErrorKind Text
display v = case v of
  VStr t -> Right t
  VUndefined -> Left ErrUndefined
  _ -> Right (repr v)

-- | The repr of a value: like 'display' except that strings are quoted.
repr :: Value -> Text
repr v = case v of
  VInt n -> T.pack (show n)
  VFloat d -> formatFloat d
  VBool True -> "True"
  VBool False -> "False"
  VNone -> "None"
  VStr t -> reprString t
  VList xs -> T.concat ["[", T.intercalate ", " (map repr (toList xs)), "]"]
  VDict d -> T.concat
    [ "{"
    , T.intercalate ", " [T.concat [reprString k, ": ", repr x] | (k, x) <- dictToList d]
    , "}" ]
  VMacro m -> T.concat ["<macro ", macroName m, ">"]
  VRange -> "<built-in range>"
  VSuper _ -> "<built-in super>"
  VUndefined -> "<undefined>"

reprString :: Text -> Text
reprString t = T.concat [T.singleton q, T.concatMap esc t, T.singleton q]
  where
    q = if T.any (== '\'') t && not (T.any (== '"') t) then '"' else '\''
    esc c = case c of
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _ | c == q && c == '\'' -> "\\'"
        | otherwise -> T.singleton c

-- | Format a double like Python's @repr@.
formatFloat :: Double -> Text
formatFloat d
  | isNaN d = "nan"
  | isInfinite d = if d > 0 then "inf" else "-inf"
  | d == 0 = if isNegativeZero d then "-0.0" else "0.0"
  | d < 0 = T.cons '-' (formatFloat (negate d))
  | otherwise = T.pack layout
  where
    (ds, e0) = floatToDigits 10 d
    e = e0 - 1
    digits = map (toEnum . (+ 48)) ds :: String
    layout
      | e >= -4 && e < 16 =
          if e >= 0
            then let (ip, fp) = splitAt (e + 1) (digits ++ replicate (e + 1 - length digits) '0')
                 in ip ++ "." ++ (if null fp then "0" else fp)
            else "0." ++ replicate (negate e - 1) '0' ++ digits
      | otherwise =
          let mant = case digits of
                [c] -> [c]
                (c : cs) -> c : '.' : cs
                [] -> "0"
              sign = if e < 0 then '-' else '+'
              ex = show (abs e)
          in mant ++ "e" ++ [sign] ++ (if length ex < 2 then '0' : ex else ex)

-- | The sequence view of a value, if it has one.
sequenceView :: Value -> Maybe (Seq Value)
sequenceView v = case v of
  VList xs -> Just xs
  VDict d -> Just (fmap VStr (dictKeys d))
  VStr t -> Just (Seq.fromList (map (VStr . T.singleton) (T.unpack t)))
  _ -> Nothing

newScope :: Maybe Scope -> IO Scope
newScope parent = do
  ref <- newIORef Map.empty
  pure (Scope ref parent)

bindVar :: Scope -> Text -> Value -> IO ()
bindVar sc k v = modifyIORef' (scopeVars sc) (Map.insert k v)

-- | Look a name up through the scope chain; unbound names are undefined.
lookupVar :: Scope -> Text -> IO Value
lookupVar sc k = do
  m <- readIORef (scopeVars sc)
  case Map.lookup k m of
    Just v -> pure v
    Nothing -> maybe (pure VUndefined) (`lookupVar` k) (scopeParent sc)
