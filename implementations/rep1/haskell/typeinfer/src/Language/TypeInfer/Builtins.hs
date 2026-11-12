-- | The initial environment.
module Language.TypeInfer.Builtins
  ( builtinTypes
  ) where

import Language.TypeInfer.Type

-- | The built-in names with their polymorphic types. Type variables
-- @'TVar' 0@, @'TVar' 1@ are universally quantified.
builtinTypes :: [(String, Type)]
builtinTypes =
  [ ("not", TFun TBool TBool)
  , ("fst", TFun (TTuple [a, b]) a)
  , ("snd", TFun (TTuple [a, b]) b)
  , ("hd", TFun (TList a) a)
  , ("tl", TFun (TList a) (TList a))
  , ("null", TFun (TList a) TBool)
  , ("length", TFun (TList a) TInt)
  , ("map", TFun (TFun a b) (TFun (TList a) (TList b)))
  , ("fold", TFun (TFun a (TFun b a)) (TFun a (TFun (TList b) a)))
  ]
  where
    a = TVar 0
    b = TVar 1
