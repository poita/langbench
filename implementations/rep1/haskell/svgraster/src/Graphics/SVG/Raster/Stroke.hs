-- | Stroke outlining (SPEC §8.2).
--
-- A stroke is built as a set of /pieces/ — one rectangle per segment, one
-- join piece per joint, one cap piece per open end — that are meant to be
-- filled together with the non-zero rule, which takes their union.
module Graphics.SVG.Raster.Stroke
  ( LineCap (..)
  , LineJoin (..)
  , StrokeStyle (..)
  , strokePieces
  ) where

import Graphics.SVG.Raster.Geometry
import Graphics.SVG.Raster.Path (Subpath (..))

-- | @stroke-linecap@.
data LineCap = CapButt | CapRound | CapSquare
  deriving (Eq, Show)

-- | @stroke-linejoin@.
data LineJoin = JoinMiter | JoinRound | JoinBevel
  deriving (Eq, Show)

-- | Stroke parameters.
data StrokeStyle = StrokeStyle
  { ssWidth :: !Double
  , ssCap :: !LineCap
  , ssJoin :: !LineJoin
  , ssMiterLimit :: !Double
  , ssTolerance :: !Double
  -- ^ Maximum deviation of round joins and caps from the true circle, in the
  -- coordinate system of the subpaths.
  }
  deriving (Show)

-- | Outline the given (already flattened) subpaths. Every returned polygon is
-- oriented with positive 'polygonArea'; degenerate pieces are dropped.
strokePieces :: StrokeStyle -> [Subpath] -> [[Point]]
strokePieces st = concatMap (orientAll . subpathPieces st)

orientAll :: [[Point]] -> [[Point]]
orientAll = concatMap f
  where
    f poly = case polygonArea poly of
      a
        | a > 0 -> [poly]
        | a < 0 -> [reverse poly]
        | otherwise -> []

subpathPieces :: StrokeStyle -> Subpath -> [[Point]]
subpathPieces st (Subpath pts0 closed) = case pts of
  [] -> []
  [p] -> pointPiece st p
  first : rest ->
    let lastPt = last rest
        segs = zip pts rest ++ [(lastPt, first) | closed]
        dirs = map (uncurry unitDir) segs
        starts = map fst segs
        joints
          | closed = zip3 starts (last dirs : dirs) dirs
          | otherwise = zip3 (drop 1 starts) dirs (drop 1 dirs)
        caps = case (dirs, reverse dirs) of
          (d0 : _, dn : _) | not closed -> [capPiece st first (neg d0), capPiece st lastPt dn]
          _ -> []
     in [segRect r a b d | ((a, b), d) <- zip segs dirs]
          ++ concat [joinPiece st p d0 d1 | (p, d0, d1) <- joints]
          ++ concat caps
  where
    r = ssWidth st / 2
    pts1 = dedupe pts0
    pts = case pts1 of
      first : _ : _ | closed, last pts1 == first -> init pts1
      _ -> pts1

dedupe :: [Point] -> [Point]
dedupe (a : b : rest)
  | a == b = dedupe (a : rest)
  | otherwise = a : dedupe (b : rest)
dedupe xs = xs

unitDir :: Point -> Point -> Point
unitDir (Point ax ay) (Point bx by) = Point (dx / l) (dy / l)
  where
    dx = bx - ax
    dy = by - ay
    l = sqrt (dx * dx + dy * dy)

neg :: Point -> Point
neg (Point x y) = Point (-x) (-y)

add :: Point -> Point -> Point
add (Point a b) (Point c d) = Point (a + c) (b + d)

sub :: Point -> Point -> Point
sub (Point a b) (Point c d) = Point (a - c) (b - d)

mul :: Double -> Point -> Point
mul k (Point a b) = Point (k * a) (k * b)

-- | The unit direction rotated a quarter turn (the @(d.y, -d.x)@ of SPEC §8.2).
perp :: Point -> Point
perp (Point x y) = Point y (-x)

-- | Rectangle around the segment @a -> b@ with unit direction @d@.
segRect :: Double -> Point -> Point -> Point -> [Point]
segRect r a b d = [add a n, add b n, sub b n, sub a n]
  where
    n = mul r (perp d)

-- | Angular step so that a polygonal circle of radius @r@ stays within the
-- tolerance.
stepAngle :: StrokeStyle -> Double
stepAngle st
  | r <= 0 = pi
  | otherwise = max 1e-3 (2 * acos (1 - min 1 (ssTolerance st / r)))
  where
    r = ssWidth st / 2

-- | Points along a circular arc, from angle @a0@ sweeping by @sweep@.
arcPoints :: StrokeStyle -> Point -> Double -> Double -> [Point]
arcPoints st (Point cx cy) a0 sweep =
  [ Point (cx + r * cos a) (cy + r * sin a)
  | i <- [0 .. n]
  , let a = a0 + sweep * fromIntegral i / fromIntegral n
  ]
  where
    r = ssWidth st / 2
    n = max 1 (ceiling (abs sweep / stepAngle st)) :: Int

-- | What a subpath consisting of a single distinct point draws.
pointPiece :: StrokeStyle -> Point -> [[Point]]
pointPiece st p@(Point x y) = case ssCap st of
  CapButt -> []
  CapRound -> [arcPoints st p 0 (2 * pi)]
  CapSquare -> [[Point (x - r) (y - r), Point (x + r) (y - r), Point (x + r) (y + r), Point (x - r) (y + r)]]
  where
    r = ssWidth st / 2

-- | Cap at point @p@, with @u@ the unit direction pointing out of the subpath.
capPiece :: StrokeStyle -> Point -> Point -> [[Point]]
capPiece st p u@(Point ux uy) = case ssCap st of
  CapButt -> []
  CapSquare -> [[add p n, add (add p n) ur, add (sub p n) ur, sub p n]]
  CapRound -> [arcPoints st p (atan2 uy ux - pi / 2) pi]
  where
    r = ssWidth st / 2
    n = mul r (perp u)
    ur = mul r u

-- | Join pieces at point @p@ between unit directions @d0@ (incoming) and
-- @d1@ (outgoing).
joinPiece :: StrokeStyle -> Point -> Point -> Point -> [[Point]]
joinPiece st p d0@(Point d0x d0y) d1@(Point d1x d1y)
  | cross == 0 && dot > 0 = []
  | otherwise = case ssJoin st of
      JoinRound -> [p : arcPoints st p a0 sweep]
      JoinMiter
        | dot > -1 && cross /= 0 && ratio <= max 1 (ssMiterLimit st) -> [[p, pa, m, pb]]
        | otherwise -> bevel
      JoinBevel -> bevel
  where
    r = ssWidth st / 2
    cross = d0x * d1y - d0y * d1x
    dot = d0x * d1x + d0y * d1y
    s = if cross > 0 then 1 else -1
    ua = mul s (perp d0)
    ub = mul s (perp d1)
    pa = add p (mul r ua)
    pb = add p (mul r ub)
    bevel = [[p, pa, pb]]
    Point ax ay = ua
    a0 = atan2 ay ax
    sweep = if cross == 0 then s * pi else atan2 cross dot
    ratio = 1 / sqrt ((1 + dot) / 2)
    m = add p (mul (r / (1 + dot)) (add ua ub))
