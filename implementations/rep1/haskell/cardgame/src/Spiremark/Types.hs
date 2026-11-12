-- |
-- Module      : Spiremark.Types
-- Description : Small types shared by the match-file parser and the engine.
module Spiremark.Types
  ( Player (..)
  , other
  , playerName
  , Target (..)
  , renderTarget
  , ZoneKind (..)
  ) where

-- | The two players.
data Player = A | B
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The opposing player.
other :: Player -> Player
other A = B
other B = A

playerName :: Player -> String
playerName A = "A"
playerName B = "B"

-- | A target token: a player, an object id (@#n@) or a Chain entry id (@~n@).
data Target = TgtPlayer Player | TgtObj Int | TgtEntry Int
  deriving (Eq, Ord, Show)

renderTarget :: Target -> String
renderTarget (TgtPlayer p) = playerName p
renderTarget (TgtObj n) = '#' : show n
renderTarget (TgtEntry n) = '~' : show n

-- | The five private zones a setup line can fill.
data ZoneKind = ZDeck | ZHand | ZField | ZAsh | ZRift
  deriving (Eq, Ord, Show, Enum, Bounded)
