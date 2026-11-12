//! The RGBA canvas, compositing operations and PPM output.

/// A `width x height` canvas of RGBA pixels held in double precision.
///
/// Colour channels are stored multiplied by alpha (that is what the
/// source-over recurrences of the specification produce), and every pixel
/// starts fully transparent.
#[derive(Clone, Debug)]
pub struct Canvas {
    width: usize,
    height: usize,
    data: Vec<f64>,
}

impl Canvas {
    /// Creates a transparent canvas.
    pub fn new(width: usize, height: usize) -> Canvas {
        Canvas { width, height, data: vec![0.0; width * height * 4] }
    }

    /// Width in pixels.
    pub fn width(&self) -> usize {
        self.width
    }

    /// Height in pixels.
    pub fn height(&self) -> usize {
        self.height
    }

    /// The `[r, g, b, a]` value of a pixel (colour premultiplied by alpha).
    pub fn pixel(&self, x: usize, y: usize) -> [f64; 4] {
        let i = (y * self.width + x) * 4;
        [self.data[i], self.data[i + 1], self.data[i + 2], self.data[i + 3]]
    }

    /// Source-over composites a run of pixels of row `y` starting at column
    /// `x0`, using `coverage[k] * opacity` as the alpha of pixel `x0 + k`.
    pub fn blend_row(&mut self, y: usize, x0: usize, coverage: &[f64], color: [f64; 3], opacity: f64) {
        let base = (y * self.width + x0) * 4;
        let px = &mut self.data[base..base + coverage.len() * 4];
        for (p, &cov) in px.chunks_exact_mut(4).zip(coverage) {
            let alpha = cov * opacity;
            if alpha <= 0.0 {
                continue;
            }
            let inv = 1.0 - alpha;
            p[0] = color[0] * alpha + p[0] * inv;
            p[1] = color[1] * alpha + p[1] * inv;
            p[2] = color[2] * alpha + p[2] * inv;
            p[3] = alpha + p[3] * inv;
        }
    }

    /// Composites `layer` (same size) onto this canvas with the given group
    /// opacity.
    pub fn draw_layer(&mut self, layer: &Canvas, opacity: f64) {
        assert_eq!((self.width, self.height), (layer.width, layer.height));
        for (d, s) in self.data.chunks_exact_mut(4).zip(layer.data.chunks_exact(4)) {
            if s[3] == 0.0 {
                continue;
            }
            let inv = 1.0 - s[3] * opacity;
            d[0] = s[0] * opacity + d[0] * inv;
            d[1] = s[1] * opacity + d[1] * inv;
            d[2] = s[2] * opacity + d[2] * inv;
            d[3] = s[3] * opacity + d[3] * inv;
        }
    }

    /// Composites the canvas over opaque white and encodes it as a binary
    /// PPM (`P6`) file.
    pub fn to_ppm(&self) -> Vec<u8> {
        let mut out = format!("P6\n{} {}\n255\n", self.width, self.height).into_bytes();
        out.reserve(self.width * self.height * 3);
        for p in self.data.chunks_exact(4) {
            let white = 1.0 - p[3];
            for &c in &p[..3] {
                out.push(((c + white).clamp(0.0, 1.0) * 255.0 + 0.5).floor() as u8);
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ppm_header_and_white_background() {
        let c = Canvas::new(2, 1);
        let ppm = c.to_ppm();
        assert_eq!(&ppm[..11], b"P6\n2 1\n255\n");
        assert_eq!(&ppm[11..], &[255; 6]);
    }

    #[test]
    fn half_coverage_blue_rounds_up() {
        let mut c = Canvas::new(1, 1);
        c.blend_row(0, 0, &[0.5], [0.0, 0.0, 1.0], 1.0);
        let ppm = c.to_ppm();
        assert_eq!(&ppm[ppm.len() - 3..], &[128, 128, 255]);
    }

    #[test]
    fn group_opacity_layer() {
        let mut layer = Canvas::new(1, 1);
        layer.blend_row(0, 0, &[1.0], [1.0, 0.0, 0.0], 1.0);
        let mut c = Canvas::new(1, 1);
        c.draw_layer(&layer, 0.5);
        let p = c.pixel(0, 0);
        assert_eq!((p[0], p[3]), (0.5, 0.5));
    }
}
