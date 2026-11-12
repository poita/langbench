{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : OrderedMap.Command
-- Description : The command language of the @ordered-map-cli@ tool
--
-- Pure types and parsing for the line-oriented command language:
--
-- > insert <key> <value>   delete <key>   get <key>   size   min   max
-- > floor <key>   ceil <key>   succ <key>   pred <key>
-- > rank <key>    select <k>   range <lo> <hi>
--
-- Keys are decimal 'Int's (64-bit on supported platforms); values are
-- opaque non-empty tokens containing no spaces.
module OrderedMap.Command
  ( Command (..)
  , parseCommand
  ) where

import qualified Data.ByteString.Char8 as B

-- | One parsed command.
data Command
  = Insert !Int !B.ByteString
  | Delete !Int
  | Get !Int
  | Size
  | Min
  | Max
  | Floor !Int
  | Ceil !Int
  | Succ !Int
  | Pred !Int
  | Rank !Int
  | Select !Int
  | Range !Int !Int
  deriving (Eq, Show)

-- | Parse one command line (without its line terminator). Tokens are
-- separated by single spaces. Returns an error message for an unknown
-- command, a wrong number of arguments or a malformed integer.
parseCommand :: B.ByteString -> Either String Command
parseCommand line = case B.split ' ' line of
  ["insert", k, v] | not (B.null v) -> (`Insert` v) <$> int k
  ["delete", k] -> Delete <$> int k
  ["get", k] -> Get <$> int k
  ["size"] -> Right Size
  ["min"] -> Right Min
  ["max"] -> Right Max
  ["floor", k] -> Floor <$> int k
  ["ceil", k] -> Ceil <$> int k
  ["succ", k] -> Succ <$> int k
  ["pred", k] -> Pred <$> int k
  ["rank", k] -> Rank <$> int k
  ["select", k] -> Select <$> int k
  ["range", lo, hi] -> Range <$> int lo <*> int hi
  _ -> Left ("malformed command: " ++ show (B.unpack line))
  where
    int t = case B.readInt t of
      Just (n, rest) | B.null rest -> Right n
      _ -> Left ("malformed integer: " ++ show (B.unpack t))
