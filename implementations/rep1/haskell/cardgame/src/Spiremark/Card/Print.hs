-- |
-- Module      : Spiremark.Card.Print
-- Description : The @CARD@ inspection block (SPEC.md 23.4).
module Spiremark.Card.Print
  ( cardBlock
  , typeName
  ) where

import Data.List (sort)
import qualified Data.Map.Strict as M

import Spiremark.Card.Types
import Spiremark.SExpr (render)

typeName :: CardType -> String
typeName Unit = "unit"
typeName Rite = "rite"
typeName Relic = "relic"

-- | The lines of the @CARD@ block for a card id (known or not).
cardBlock :: CardDb -> String -> [String]
cardBlock db cid =
  ["CARD BEGIN " ++ cid] ++ body ++ ["CARD END"]
  where
    body = case M.lookup cid db of
      Nothing -> ["unknown"]
      Just c -> known c
    known c =
      [ "name " ++ cardName c
      , "type " ++ typeName (cardType c)
      , "cost " ++ show (cardCost c)
      ]
        ++ [ "body " ++ show e ++ "/" ++ show k | Just (e, k) <- [cardBody c] ]
        ++ [ "tags " ++ listOrDash (cardTags c)
           , "keywords " ++ listOrDash (sort (map renderKw (cardKeywords c)))
           ]
        ++ map abilityLine (cardAbilities c)
    listOrDash [] = "-"
    listOrDash xs = commaSep xs
    commaSep = foldr1 (\a b -> a ++ "," ++ b)

abilityLine :: Ability -> String
abilityLine ab = "ability " ++ show (abIndex ab) ++ " " ++ unwords parts
  where
    tspec = maybe "-" render (abTargetsRaw ab)
    effs = map render (abRaw ab)
    parts = case abKind ab of
      AKResolve -> "resolve" : tspec : effs
      AKOn ev -> "on" : eventName ev : tspec : effs
      AKAct -> "act" : maybe "-" render (abCostRaw ab) : tspec : effs
      AKAura -> "aura" : effs
