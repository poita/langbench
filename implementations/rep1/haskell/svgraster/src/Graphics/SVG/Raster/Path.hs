-- | Paths: path-data parsing, elliptical arc conversion, shape-to-path
-- conversion and curve flattening (SPEC §7.3 – §7.6).
module Graphics.SVG.Raster.Path
  ( -- * Paths
    Seg (..)
  , Path
  , Subpath (..)
    -- * Path data
  , parsePathData
    -- * Shapes
  , rectPath
  , ellipsePath
  , linePath
  , polyPath
    -- * Arcs
  , arcToSegs
    -- * Flattening
  , flattenPath
  , flattenTolerance
  ) where

import Graphics.SVG.Raster.Geometry
import Graphics.SVG.Raster.Parse (scanNumber, skipSeparators)

-- | A path segment. Quadratic curves and arcs are expressed as cubics.
data Seg
  = MoveTo !Point
  | LineTo !Point
  | CubicTo !Point !Point !Point
  | ClosePath
  deriving (Eq, Show)

-- | A path is a list of segments.
type Path = [Seg]

-- | A flattened subpath: a polyline and whether it was explicitly closed.
data Subpath = Subpath
  { spPoints :: [Point]
  , spClosed :: Bool
  }
  deriving (Eq, Show)

------------------------------------------------------------------------
-- Path data

data PState = PState
  { psCur :: !Point
  , psStart :: !Point
  , psLastC :: !(Maybe Point) -- ^ previous cubic's second control point
  , psLastQ :: !(Maybe Point) -- ^ previous quadratic's control point
  }

-- | Parse the @d@ attribute. Parsing stops at the first token that is not
-- what the grammar expects; segments parsed before it are kept.
parsePathData :: String -> Path
parsePathData s = case skipSeparators s of
  c : rest
    | c == 'M' || c == 'm' -> command (PState (Point 0 0) (Point 0 0) Nothing Nothing) c rest
  _ -> []

isCommandLetter :: Char -> Bool
isCommandLetter = (`elem` "MmLlHhVvCcSsQqTtAaZz")

-- | Handle one command letter followed by its parameters.
command :: PState -> Char -> String -> Path
command st 'Z' rest = ClosePath : next st {psCur = psStart st, psLastC = Nothing, psLastQ = Nothing} rest
command st 'z' rest = command st 'Z' rest
command st c rest = case c of
  'M' -> p2 $ \x y -> let p = Point x y in ([MoveTo p], moved p)
  'm' -> p2 $ \x y -> let p = off x y in ([MoveTo p], moved p)
  'L' -> p2 $ \x y -> line (Point x y)
  'l' -> p2 $ \x y -> line (off x y)
  'H' -> p1 $ \x -> line (Point x cy)
  'h' -> p1 $ \x -> line (Point (cx + x) cy)
  'V' -> p1 $ \y -> line (Point cx y)
  'v' -> p1 $ \y -> line (Point cx (cy + y))
  'C' -> p6 $ \a b c' d e f -> cubic (Point a b) (Point c' d) (Point e f)
  'c' -> p6 $ \a b c' d e f -> cubic (off a b) (off c' d) (off e f)
  'S' -> p4 $ \a b e f -> cubic reflC (Point a b) (Point e f)
  's' -> p4 $ \a b e f -> cubic reflC (off a b) (off e f)
  'Q' -> p4 $ \a b e f -> quad (Point a b) (Point e f)
  'q' -> p4 $ \a b e f -> quad (off a b) (off e f)
  'T' -> p2 $ \e f -> quad reflQ (Point e f)
  't' -> p2 $ \e f -> quad reflQ (off e f)
  'A' -> arcParams False
  'a' -> arcParams True
  _ -> []
  where
    Point cx cy = psCur st
    off x y = Point (cx + x) (cy + y)
    moved p = st {psCur = p, psStart = p, psLastC = Nothing, psLastQ = Nothing}
    plain p = st {psCur = p, psLastC = Nothing, psLastQ = Nothing}
    reflect (Point px py) = Point (2 * cx - px) (2 * cy - py)
    reflC = maybe (psCur st) reflect (psLastC st)
    reflQ = maybe (psCur st) reflect (psLastQ st)
    line p = ([LineTo p], plain p)
    cubic p1' p2' p3' = ([CubicTo p1' p2' p3'], (plain p3') {psLastC = Just p2'})
    quad q@(Point qx qy) e@(Point ex ey) =
      let p1' = Point (cx + 2 / 3 * (qx - cx)) (cy + 2 / 3 * (qy - cy))
          p2' = Point (ex + 2 / 3 * (qx - ex)) (ey + 2 / 3 * (qy - ey))
       in ([CubicTo p1' p2' e], (plain e) {psLastQ = Just q})
    -- After M/m further coordinate pairs are implicit L/l.
    nextCmd = case c of
      'M' -> 'L'
      'm' -> 'l'
      _ -> c
    -- Read n numbers, build the segments and the new state, then continue
    -- with the next command or another parameter group.
    params :: Int -> ([Double] -> ([Seg], PState)) -> Path
    params n build = case numbers n rest of
      Nothing -> []
      Just (vs, rest') ->
        let (segs, st') = build vs
         in segs ++ afterGroup st' nextCmd rest'
    none = ([], st)
    p1 f = params 1 $ \vs -> case vs of [a] -> f a; _ -> none
    p2 f = params 2 $ \vs -> case vs of [a, b] -> f a b; _ -> none
    p4 f = params 4 $ \vs -> case vs of [a, b, c', d] -> f a b c' d; _ -> none
    p6 f = params 6 $ \vs -> case vs of [a, b, c', d, e, g] -> f a b c' d e g; _ -> none
    arcParams rel = case arcGroup rest of
      Nothing -> []
      Just ((rx, ry, rot, large, sweep, x, y), rest') ->
        let e = if rel then Point (cx + x) (cy + y) else Point x y
         in arcToSegs (psCur st) rx ry rot large sweep e ++ afterGroup (plain e) c rest'

-- | After a parameter group: another command letter, another group for the
-- same command, or the end.
afterGroup :: PState -> Char -> String -> Path
afterGroup st c rest = case skipSeparators rest of
  [] -> []
  s@(x : xs)
    | isCommandLetter x -> command st x xs
    | otherwise -> command st c s

next :: PState -> String -> Path
next st rest = case skipSeparators rest of
  x : xs | isCommandLetter x -> command st x xs
  _ -> []

numbers :: Int -> String -> Maybe ([Double], String)
numbers 0 s = Just ([], s)
numbers n s = do
  (v, s1) <- scanNumber (skipSeparators s)
  (vs, s2) <- numbers (n - 1) s1
  Just (v : vs, s2)

arcGroup :: String -> Maybe ((Double, Double, Double, Bool, Bool, Double, Double), String)
arcGroup s = do
  (rx, s1) <- scanNumber (skipSeparators s)
  (ry, s2) <- scanNumber (skipSeparators s1)
  (rot, s3) <- scanNumber (skipSeparators s2)
  (large, s4) <- flag s3
  (sweep, s5) <- flag s4
  (x, s6) <- scanNumber (skipSeparators s5)
  (y, s7) <- scanNumber (skipSeparators s6)
  Just ((rx, ry, rot, large, sweep, x, y), s7)
  where
    flag str = case skipSeparators str of
      '0' : r -> Just (False, r)
      '1' : r -> Just (True, r)
      _ -> Nothing

------------------------------------------------------------------------
-- Arcs

-- | Convert an endpoint-parameterised elliptical arc (SVG implementation
-- notes F.6.5, F.6.6) into path segments: nothing if the endpoints coincide,
-- a line if a radius is zero, otherwise cubic Béziers of at most 45° each.
--
-- Arguments: start point, @rx@, @ry@, x-axis rotation in degrees,
-- large-arc flag, sweep flag, end point.
arcToSegs :: Point -> Double -> Double -> Double -> Bool -> Bool -> Point -> [Seg]
arcToSegs (Point x1 y1) rx0 ry0 rotDeg large sweep p1@(Point x2 y2)
  | x1 == x2 && y1 == y2 = []
  | rx0' == 0 || ry0' == 0 = [LineTo p1]
  | otherwise = segments
  where
    rx0' = abs rx0
    ry0' = abs ry0
    phi = rotDeg * pi / 180
    cosP = cos phi
    sinP = sin phi
    dx2 = (x1 - x2) / 2
    dy2 = (y1 - y2) / 2
    x1' = cosP * dx2 + sinP * dy2
    y1' = -sinP * dx2 + cosP * dy2
    lam = x1' * x1' / (rx0' * rx0') + y1' * y1' / (ry0' * ry0')
    (rx, ry) = if lam > 1 then (rx0' * sqrt lam, ry0' * sqrt lam) else (rx0', ry0')
    num = rx * rx * ry * ry - rx * rx * y1' * y1' - ry * ry * x1' * x1'
    den = rx * rx * y1' * y1' + ry * ry * x1' * x1'
    coef0 = sqrt (max 0 (num / den))
    coef = if large == sweep then negate coef0 else coef0
    cxp = coef * rx * y1' / ry
    cyp = -coef * ry * x1' / rx
    cx = cosP * cxp - sinP * cyp + (x1 + x2) / 2
    cy = sinP * cxp + cosP * cyp + (y1 + y2) / 2
    ux = (x1' - cxp) / rx
    uy = (y1' - cyp) / ry
    vx = (-x1' - cxp) / rx
    vy = (-y1' - cyp) / ry
    theta1 = atan2 uy ux
    dtheta0 = atan2 (ux * vy - uy * vx) (ux * vx + uy * vy)
    dtheta
      | sweep && dtheta0 < 0 = dtheta0 + 2 * pi
      | not sweep && dtheta0 > 0 = dtheta0 - 2 * pi
      | otherwise = dtheta0
    n = max 1 (ceiling (abs dtheta / (pi / 4) - 1e-9)) :: Int
    delta = dtheta / fromIntegral n
    k = 4 / 3 * tan (delta / 4)
    pointAt t = Point (cx + rx * cos t * cosP - ry * sin t * sinP) (cy + rx * cos t * sinP + ry * sin t * cosP)
    derivAt t = Point (-rx * sin t * cosP - ry * cos t * sinP) (-rx * sin t * sinP + ry * cos t * cosP)
    segments =
      [ CubicTo c1 c2 e
      | i <- [0 .. n - 1]
      , let t0 = theta1 + fromIntegral i * delta
            t1 = t0 + delta
            Point ax ay = pointAt t0
            Point dx0 dy0 = derivAt t0
            Point bx by = pointAt t1
            Point dx1 dy1 = derivAt t1
            c1 = Point (ax + k * dx0) (ay + k * dy0)
            c2 = Point (bx - k * dx1) (by - k * dy1)
            e = if i == n - 1 then p1 else Point bx by
      ]

------------------------------------------------------------------------
-- Shapes

-- | A rectangle: @x y width height@ and optional @rx@, @ry@ (SPEC §7.3).
rectPath :: Double -> Double -> Double -> Double -> Maybe Double -> Maybe Double -> Path
rectPath x y w h mrx mry
  | w <= 0 || h <= 0 = []
  | rx <= 0 || ry <= 0 =
      [ MoveTo (Point x y), LineTo (Point (x + w) y), LineTo (Point (x + w) (y + h))
      , LineTo (Point x (y + h)), ClosePath ]
  | otherwise =
      [MoveTo (Point (x + rx) y), LineTo (Point (x + w - rx) y)]
        ++ arc (Point (x + w - rx) y) (Point (x + w) (y + ry))
        ++ [LineTo (Point (x + w) (y + h - ry))]
        ++ arc (Point (x + w) (y + h - ry)) (Point (x + w - rx) (y + h))
        ++ [LineTo (Point (x + rx) (y + h))]
        ++ arc (Point (x + rx) (y + h)) (Point x (y + h - ry))
        ++ [LineTo (Point x (y + ry))]
        ++ arc (Point x (y + ry)) (Point (x + rx) y)
        ++ [ClosePath]
  where
    (rx0, ry0) = case (mrx, mry) of
      (Nothing, Nothing) -> (0, 0)
      (Just a, Nothing) -> (a, a)
      (Nothing, Just b) -> (b, b)
      (Just a, Just b) -> (a, b)
    rx = min (max 0 rx0) (w / 2)
    ry = min (max 0 ry0) (h / 2)
    arc from to = arcToSegs from rx ry 0 False True to

-- | An ellipse (or circle, with @rx == ry@): centre and radii.
ellipsePath :: Double -> Double -> Double -> Double -> Path
ellipsePath cx cy rx ry
  | rx <= 0 || ry <= 0 = []
  | otherwise =
      MoveTo (Point (cx + rx) cy)
        : arc (Point (cx + rx) cy) (Point cx (cy + ry))
        ++ arc (Point cx (cy + ry)) (Point (cx - rx) cy)
        ++ arc (Point (cx - rx) cy) (Point cx (cy - ry))
        ++ arc (Point cx (cy - ry)) (Point (cx + rx) cy)
        ++ [ClosePath]
  where
    arc from to = arcToSegs from rx ry 0 False True to

-- | A line segment.
linePath :: Double -> Double -> Double -> Double -> Path
linePath x1 y1 x2 y2 = [MoveTo (Point x1 y1), LineTo (Point x2 y2)]

-- | A polyline (@False@) or polygon (@True@) from a flat coordinate list; an
-- odd trailing number is discarded.
polyPath :: Bool -> [Double] -> Path
polyPath close coords = case pairs coords of
  [] -> []
  p : ps -> MoveTo p : map LineTo ps ++ [ClosePath | close]
  where
    pairs (a : b : r) = Point a b : pairs r
    pairs _ = []

------------------------------------------------------------------------
-- Flattening

-- | Flattening tolerance in device pixels.
flattenTolerance :: Double
flattenTolerance = 0.01

-- | Flatten a path into polylines.
--
-- The number of steps per cubic is chosen from the control points as they
-- appear after applying the given transformation (so the tolerance of
-- 'flattenTolerance' holds in the transformed space), but the returned points
-- are in the path's own coordinate system. A subpath is a run starting at a
-- @MoveTo@; a @MoveTo@ with nothing after it yields no subpath.
flattenPath :: Affine -> Path -> [Subpath]
flattenPath m = go Nothing Nothing
  where
    -- open: Maybe (reversed points, has drawing command)
    go :: Maybe ([Point], Bool) -> Maybe Point -> Path -> [Subpath]
    go open start segs = case segs of
      [] -> emit open False []
      MoveTo p : rest -> emit open False (go (Just ([p], False)) (Just p) rest)
      LineTo p : rest -> withOpen start open $ \pts -> go (Just (p : pts, True)) start rest
      CubicTo p1 p2 p3 : rest -> withOpen start open $ \pts ->
        let cur = case pts of { c : _ -> c; [] -> p1 }
            new = reverse (flattenCubic m cur p1 p2 p3)
         in go (Just (new ++ pts, True)) start rest
      ClosePath : rest -> case open of
        Just (pts, _) -> Subpath (reverse pts) True : go Nothing start rest
        Nothing -> go Nothing start rest
    withOpen start open k = case open of
      Just (pts, _) -> k pts
      Nothing -> case start of
        Just s -> k [s]
        Nothing -> []
    emit (Just (pts, True)) closed rest = Subpath (reverse pts) closed : rest
    emit _ _ rest = rest

-- | Points of the flattened cubic after the start point.
flattenCubic :: Affine -> Point -> Point -> Point -> Point -> [Point]
flattenCubic m p0 p1 p2 p3 = [at (fromIntegral i / fromIntegral n) | i <- [1 .. n - 1]] ++ [p3]
  where
    Point ax ay = applyAffine m p0
    Point bx by = applyAffine m p1
    Point cx cy = applyAffine m p2
    Point dx dy = applyAffine m p3
    d1x = ax - 2 * bx + cx
    d1y = ay - 2 * by + cy
    d2x = bx - 2 * cx + dx
    d2y = by - 2 * cy + dy
    mm = max (d1x * d1x + d1y * d1y) (d2x * d2x + d2y * d2y)
    nRaw = sqrt (0.75 * sqrt mm / flattenTolerance)
    n :: Int
    n
      | isNaN nRaw || isInfinite nRaw = 1000
      | otherwise = max 1 (min 1000 (ceiling nRaw))
    at t =
      let u = 1 - t
          w0 = u * u * u
          w1 = 3 * u * u * t
          w2 = 3 * u * t * t
          w3 = t * t * t
          Point x0 y0 = p0
          Point x1 y1 = p1
          Point x2 y2 = p2
          Point x3 y3 = p3
       in Point (w0 * x0 + w1 * x1 + w2 * x2 + w3 * x3) (w0 * y0 + w1 * y1 + w2 * y2 + w3 * y3)
