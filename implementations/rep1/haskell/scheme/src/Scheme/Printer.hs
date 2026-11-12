-- |
-- Module      : Scheme.Printer
-- Description : The @write@ and @display@ external representations.
module Scheme.Printer
  ( writeString
  , displayString
  ) where

import qualified Scheme.BigInt as B
import Scheme.Types

-- | The /write/ form: strings are quoted and escaped.
writeString :: Value -> String
writeString v = render True v ""

-- | The /display/ form: strings appear raw, at any depth.
displayString :: Value -> String
displayString v = render False v ""

render :: Bool -> Value -> ShowS
render quoted = go
  where
    go v = case v of
      VInt n -> showString (B.toDecimal n)
      VBool True -> showString "#t"
      VBool False -> showString "#f"
      VStr s | quoted -> showChar '"' . foldr ((.) . escape) id s . showChar '"'
             | otherwise -> showString s
      VSym s -> showString (symName s)
      VNil -> showString "()"
      VVoid -> showString "#<void>"
      VClosure _ -> showString "#<procedure>"
      VPrim _ -> showString "#<procedure>"
      VPair _ a d -> showChar '(' . go a . tailOf d . showChar ')'
    tailOf VNil = id
    tailOf (VPair _ a d) = showChar ' ' . go a . tailOf d
    tailOf x = showString " . " . go x
    escape '\\' = showString "\\\\"
    escape '"' = showString "\\\""
    escape '\n' = showString "\\n"
    escape '\t' = showString "\\t"
    escape c = showChar c
