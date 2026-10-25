# Design tokens

`tokens.json` holds the colours, radii, fonts and type sizes the desktop client and the share site
share, written once. What each one is for, and why the palette is what it is, is in
[docs/decisions/interface.md](../docs/decisions/interface.md).

- The Qt client's build makes it the `Tokens` QML singleton (`desktop/cmake/tokens.cmake`); the
  `Theme` singleton builds on it.
- `site/build.sh` makes it `tokens.css`, one custom property each, named in kebab case
  (`radiusControl` is `--radius-control`).

A colour is `#rrggbb` or `#rrggbbaa`, the alpha last as CSS writes it; a number is in pixels.
