// SPDX-License-Identifier: MPL-2.0
//! Rasterizes the owner's original SVG into Apple's required icon sizes.
use std::{error::Error, fs, path::PathBuf};
fn main() -> Result<(), Box<dyn Error>> {
    let output = PathBuf::from(
        std::env::args()
            .nth(1)
            .ok_or("Pass the output .iconset directory")?,
    );
    let source = include_bytes!("../../../neutrino.svg");
    let tree = resvg::usvg::Tree::from_data(source, &resvg::usvg::Options::default())?;
    fs::create_dir_all(&output)?;
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale;
            let mut pixmap = resvg::tiny_skia::Pixmap::new(pixels, pixels)
                .ok_or("Could not allocate icon image")?;
            let transform = resvg::tiny_skia::Transform::from_scale(
                pixels as f32 / tree.size().width(),
                pixels as f32 / tree.size().height(),
            );
            resvg::render(&tree, transform, &mut pixmap.as_mut());
            let suffix = if scale == 2 { "@2x" } else { "" };
            pixmap.save_png(output.join(format!("icon_{size}x{size}{suffix}.png")))?;
        }
    }
    Ok(())
}
