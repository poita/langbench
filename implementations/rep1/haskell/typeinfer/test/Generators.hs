-- | QuickCheck generators for syntax trees.
module Generators
  ( genExpr
  , genProgram
  ) where

import Test.QuickCheck

import Language.TypeInfer

varNames :: [Name]
varNames = ["x", "y", "z", "f", "g", "map", "fst", "hd", "id1"]

genName :: Gen Name
genName = elements varNames

genLit :: Gen Lit
genLit = oneof
  [ LInt <$> listOf1 (elements ['0' .. '9'])
  , LBool <$> arbitrary
  , pure LUnit
  ]

-- | A random expression; most are ill-typed, which is fine for properties that
-- must hold for failures too.
genExpr :: Gen Expr
genExpr = sized go
  where
    go 0 = oneof [EVar <$> genName, ELit <$> genLit]
    go n =
      let sub = go (n `div` 2)
      in frequency
        [ (2, EVar <$> genName)
        , (2, ELit <$> genLit)
        , (3, EApp <$> sub <*> sub)
        , (3, EFun <$> genName <*> sub)
        , (2, ELet <$> genName <*> sub <*> sub)
        , (1, ELetRec <$> genName <*> genName <*> sub <*> sub)
        , (1, EIf <$> sub <*> sub <*> sub)
        , (1, ETuple <$> ((:) <$> sub <*> ((:) <$> sub <*> resize 2 (listOf sub))))
        , (1, EList <$> resize 3 (listOf sub))
        , (1, ECons <$> sub <*> sub)
        , (2, EBin <$> elements [minBound .. maxBound] <*> sub <*> sub)
        ]

genDecl :: Gen Decl
genDecl = oneof
  [ DLet <$> genName <*> genExpr
  , DLetRec <$> genName <*> genName <*> genExpr
  , DExpr <$> genExpr
  ]

genProgram :: Gen Program
genProgram = resize 6 (listOf genDecl)
