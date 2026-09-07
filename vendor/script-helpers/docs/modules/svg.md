# svg

SVG-to-PNG rasterization helpers for application artwork and icon sets.

Functions
---------

- `svg_rasterizer`
  - Purpose: Print the first available supported rasterizer.
  - Returns: 0 and `inkscape`, `magick`, or `convert`; 1 if none is installed.
  - Dependencies: Inkscape or ImageMagick on `PATH`.

- `svg_rasterize in.svg out.png [size=1024]`
  - Purpose: Render an SVG on a transparent, square PNG canvas.
  - Args:
    - `in.svg` — existing source SVG.
    - `out.png` — destination PNG; its parent directory is created as needed.
    - `size` — positive integer width and height in pixels; defaults to 1024.
  - Returns: 0 on success; 1 on a render failure; 2 for missing or invalid arguments; 3 when no supported rasterizer is available.
  - Dependencies: Inkscape or ImageMagick on `PATH`. The logging module is optional; plain messages are used when it has not been imported.
  - Example: `svg_rasterize assets/logo.svg build/logo.png 512`

- `svg_rasterize_sizes in.svg out_dir basename size [size...]`
  - Purpose: Render multiple square PNGs named `out_dir/basename-size.png`.
  - Args: Source SVG, output directory, output basename, and one or more sizes.
  - Returns: 0 when every render succeeds; 1 if any render fails; 2 for missing arguments.
  - Dependencies: Same as `svg_rasterize`.
  - Example: `svg_rasterize_sizes assets/logo.svg build/icons logo 64 128 512`

Environment
-----------

No environment variables are required.
