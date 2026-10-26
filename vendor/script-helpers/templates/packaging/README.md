# Packaging

This folder contains cross-distribution packaging metadata and helper files.

## Layout

- `../debian/` - Debian packaging (dpkg-buildpackage, Launchpad PPA).
- `rpm/` - RPM spec and build output.
- `arch/` - PKGBUILD for Arch Linux.
- `brew/` - Homebrew formula template.
- `packaging.env` - shared metadata values used by templates.

## Build commands

Commands assume script-helpers is a submodule at `scripts/script-helpers`, where script-helpers' own README installs it; change the path if this repository keeps it elsewhere.

From the repo root:

- Debian: `./scripts/script-helpers/scripts/build_deb_artifacts.sh --repo .`
- RPM: `./scripts/script-helpers/scripts/build_rpm_artifacts.sh --repo .`
- Arch: `./scripts/script-helpers/scripts/build_arch_artifacts.sh --repo .`

## Homebrew

Render a formula with the current version and a SHA256:

```
./scripts/script-helpers/scripts/render_brew_formula.sh --repo . --url <tarball_url> --sha256 <sha>
```

## Notes

- Edit `packaging.env` first; rerun `packaging_init.sh` to regenerate files.
- For PPA uploads, use `ppa_upload.sh` and provide a Launchpad key + passphrase.
