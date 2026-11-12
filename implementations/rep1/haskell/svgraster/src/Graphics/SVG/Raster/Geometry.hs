-- | Points and 2-D affine transformations.
module Graphics.SVG.Raster.Geometry
  ( Point (..)
  , Affine (..)
  , identity
  , compose
  , translation
  , scaling
  , rotationDeg
  , skewXDeg
  , skewYDeg
  , applyAffine
  , maxScale
  , polygonArea
  ) where

-- | A point (or vector) in the plane.
data Point = Point {-# UNPACK #-} !Double {-# UNPACK #-} !Double
  deriving (Eq, Show)

-- | An affine transformation, the matrix
--
-- > [ a c e ]
-- > [ b d f ]
--
-- as in SVG's @matrix(a b c d e f)@.
data Affine = Affine !Double !Double !Double !Double !Double !Double
  deriving (Eq, Show)

-- | The identity transformation.
identity :: Affine
identity = Affine 1 0 0 1 0 0

-- | @compose m n@ is the matrix product @m * n@: @n@ is applied to a point
-- first, then @m@.
compose :: Affine -> Affine -> Affine
compose (Affine a1 b1 c1 d1 e1 f1) (Affine a2 b2 c2 d2 e2 f2) =
  Affine
    (a1 * a2 + c1 * b2)
    (b1 * a2 + d1 * b2)
    (a1 * c2 + c1 * d2)
    (b1 * c2 + d1 * d2)
    (a1 * e2 + c1 * f2 + e1)
    (b1 * e2 + d1 * f2 + f1)

-- | @translation tx ty@.
translation :: Double -> Double -> Affine
translation = Affine 1 0 0 1

-- | @scaling sx sy@.
scaling :: Double -> Double -> Affine
scaling sx sy = Affine sx 0 0 sy 0 0

-- | Rotation about the origin by an angle in degrees (positive turns the
-- @+x@ axis towards the @+y@ axis).
rotationDeg :: Double -> Affine
rotationDeg deg = Affine c s (-s) c 0 0
  where
    r = deg * pi / 180
    c = cos r
    s = sin r

-- | @skewXDeg a@: shear along the x axis by an angle in degrees.
skewXDeg :: Double -> Affine
skewXDeg deg = Affine 1 0 (tan (deg * pi / 180)) 1 0 0

-- | @skewYDeg a@: shear along the y axis by an angle in degrees.
skewYDeg :: Double -> Affine
skewYDeg deg = Affine 1 (tan (deg * pi / 180)) 0 1 0 0

-- | Transform a point.
applyAffine :: Affine -> Point -> Point
applyAffine (Affine a b c d e f) (Point x y) =
  Point (a * x + c * y + e) (b * x + d * y + f)
{-# INLINE applyAffine #-}

-- | The largest factor by which the linear part of the transformation can
-- stretch a vector (its largest singular value).
maxScale :: Affine -> Double
maxScale (Affine a b c d _ _) = sqrt (0.5 * (t + sqrt (max 0 (t * t - 4 * det * det))))
  where
    t = a * a + b * b + c * c + d * d
    det = a * d - b * c

-- | Signed (shoelace) area of the polygon, positive when its vertices run
-- clockwise on screen, i.e. counter-clockwise in a y-up system.
polygonArea :: [Point] -> Double
polygonArea [] = 0
polygonArea ps@(p0 : _) = 0.5 * go ps
  where
    go (Point x0 y0 : rest@(Point x1 y1 : _)) = (x0 * y1 - x1 * y0) + go rest
    go [Point x0 y0] = let Point x1 y1 = p0 in x0 * y1 - x1 * y0
    go [] = 0
