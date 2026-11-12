//! End-to-end tests against the worked examples in the specification and a
//! few structural invariants.

use qrcode::{Ecl, Error, MaskChoice, QrCode};

const HELLO_WORLD_M0: &str = "\
#######...#.#.#######
#.....#.###...#.....#
#.###.#...#.#.#.###.#
#.###.#...#.#.#.###.#
#.###.#.#.###.#.###.#
#.....#..###..#.....#
#######.#.#.#.#######
.....................
#.#.#.#..#..#...#..#.
.####...#..#....#...#
...#######.#..#.##...
####.#.##..###.#.###.
.#..####.#.#..###.#.#
........#.#...#...#.#
#######.....#..#.##..
#.....#..##...##.#...
#.###.#.##..#.#######
#.###.#...##.#.#...#.
#.###.#.####.###.#..#
#.....#....###...#.##
#######.##.#.###....#
";

#[test]
fn example_hello_world_fixed_mask() {
    let qr = QrCode::encode_text("HELLO WORLD", Ecl::Medium, MaskChoice::Fixed(0)).unwrap();
    assert_eq!(qr.version().number(), 1);
    assert_eq!(qr.mask(), 0);
    assert_eq!(qr.to_text(), HELLO_WORLD_M0);
}

#[test]
fn example_hello_world_penalties_and_auto() {
    let expected = [311, 406, 442, 463, 367, 528, 395, 445];
    for (m, &want) in expected.iter().enumerate() {
        let qr =
            QrCode::encode_text("HELLO WORLD", Ecl::Medium, MaskChoice::Fixed(m as u8)).unwrap();
        assert_eq!(qr.penalty_score(), want, "mask {m}");
    }
    let auto = QrCode::encode_text("HELLO WORLD", Ecl::Medium, MaskChoice::Auto).unwrap();
    assert_eq!(auto.mask(), 0);
    assert_eq!(auto.to_text(), HELLO_WORLD_M0);
}

#[test]
fn example_numeric_auto() {
    let qr = QrCode::encode_text("01234567", Ecl::Low, MaskChoice::Auto).unwrap();
    assert_eq!((qr.version().number(), qr.mask()), (1, 3));
    let text = qr.to_text();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], "#######.##..#.#######");
    assert_eq!(lines[8], "####..#.#.#..#..###.#");
    assert_eq!(lines[20], "#######.##.##..#...#.");
}

#[test]
fn example_utf8_bytes() {
    let qr = QrCode::encode_text("h\u{e9}llo", Ecl::High, MaskChoice::Fixed(5)).unwrap();
    assert_eq!((qr.version().number(), qr.mask()), (1, 5));
    let text = qr.to_text();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], "#######.####..#######");
    assert_eq!(lines[10], ".####.#####..#..##.##");
    assert_eq!(lines[20], "#######...#.#.#.#..#.");
}

#[test]
fn symbol_shape_for_every_version() {
    // Build a payload that lands exactly in each version at level L.
    for v in 1..=40usize {
        let version = qrcode::Version::new(v as u8).unwrap();
        let cap_bytes =
            (version.data_codewords(Ecl::Low) * 8 - 4 - if v < 10 { 8 } else { 16 }) / 8;
        let qr = QrCode::encode(&vec![b'x'; cap_bytes], Ecl::Low, MaskChoice::Fixed(2)).unwrap();
        assert_eq!(qr.version(), version);
        assert_eq!(qr.size(), 4 * v + 17);
        let text = qr.to_text();
        assert_eq!(text.lines().count(), qr.size());
        assert!(text.lines().all(|l| l.len() == qr.size()));
        // Dark module and finder corner.
        assert!(qr.get(8, qr.size() - 8));
        assert!(qr.get(0, 0));
    }
}

#[test]
fn too_long_is_an_error() {
    let err = QrCode::encode(&vec![b'a'; 2954], Ecl::Low, MaskChoice::Auto).unwrap_err();
    assert_eq!(err, Error::DataTooLong);
}

#[test]
fn auto_matches_lowest_fixed_penalty() {
    let data = b"The quick brown fox jumps over the lazy dog";
    let scores: Vec<u32> = (0..8)
        .map(|m| {
            QrCode::encode(data, Ecl::Quartile, MaskChoice::Fixed(m))
                .unwrap()
                .penalty_score()
        })
        .collect();
    let best = scores
        .iter()
        .enumerate()
        .min_by_key(|&(i, &s)| (s, i))
        .unwrap()
        .0;
    let auto = QrCode::encode(data, Ecl::Quartile, MaskChoice::Auto).unwrap();
    assert_eq!(auto.mask() as usize, best);
}
