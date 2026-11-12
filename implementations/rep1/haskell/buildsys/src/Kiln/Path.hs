-- | Workspace path validation and the reserved names of the workspace.
module Kiln.Path
  ( isWorkspacePath
  , isIdentifierShaped
  , firstComponent
  , isGenerated
  , stateFilePath
  , buildFilePath
  , isPhonyRef
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word8)

-- | Is the string a valid workspace path?  Components are 1–255 bytes drawn
-- from @A-Za-z0-9_.+-@, are never @.@ or @..@, and the whole path is at most
-- 1024 bytes.
isWorkspacePath :: BS.ByteString -> Bool
isWorkspacePath p =
  not (BS.null p)
    && BS.length p <= 1024
    && all okComponent (BS.split slash p)
  where
    okComponent c =
      let n = BS.length c
       in n >= 1 && n <= 255 && c /= "." && c /= ".." && BS.all pchar c

slash :: Word8
slash = 0x2f

pchar :: Word8 -> Bool
pchar c =
  (c >= 0x41 && c <= 0x5a)
    || (c >= 0x61 && c <= 0x7a)
    || (c >= 0x30 && c <= 0x39)
    || c == 0x5f
    || c == 0x2e
    || c == 0x2b
    || c == 0x2d

-- | @[A-Za-z_][A-Za-z0-9_]*@
isIdentifierShaped :: BS.ByteString -> Bool
isIdentifierShaped s = case BC.uncons s of
  Nothing -> False
  Just (c, rest) -> identStart c && BC.all identChar rest
  where
    identStart c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
    identChar c = identStart c || (c >= '0' && c <= '9')

-- | The first @/@-separated component of a path.
firstComponent :: BS.ByteString -> BS.ByteString
firstComponent = BS.takeWhile (/= slash)

-- | Is the path in the reserved, generated @out@ tree?
isGenerated :: BS.ByteString -> Bool
isGenerated p = firstComponent p == "out"

-- | The state file's workspace path.
stateFilePath :: BS.ByteString
stateFilePath = ".kiln-state"

-- | The root build file's workspace path.
buildFilePath :: BS.ByteString
buildFilePath = "main.kiln"

-- | Does a target reference start with @\@@ (a phony reference)?
isPhonyRef :: BS.ByteString -> Bool
isPhonyRef = BS.isPrefixOf "@"
