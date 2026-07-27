# Demo assets

## `portside-logo.six`

The Portside app icon as a [Sixel](https://en.wikipedia.org/wiki/Sixel) image.
`cat` it into a terminal that supports Sixel and you get the sailboat:

```sh
cat portside-logo.six
```

Useful as a quick check of whether a terminal — Portside or anything else —
actually renders inline images, without installing `libsixel` or ImageMagick
first.

Regenerate it from the app icon with:

```sh
sips -s format png Portside.app/Contents/Resources/AppIcon.icns --out icon.png
sips -Z 240 icon.png --out icon-240.png
python3 ../../Scripts/make_sixel.py --trim icon-240.png > portside-logo.six
```

`Scripts/make_sixel.py` is dependency-free — it decodes the PNG with `zlib` and
nothing else — so regenerating this needs no tooling beyond Python and the
`sips` that ships with macOS.

Two properties of the generated file are deliberate:

- **Every band is terminated**, including the last. SwiftTerm 1.15.0 crashes on
  a final band wider than every terminated band before it. Portside repairs
  that on the way in (`SixelStreamGuard`), but a file published for people to
  `cat` into *other* terminals should not depend on the workaround.
- **Transparent pixels are left unpainted**, so the icon's rounded corners take
  the terminal's own background instead of arriving inside a white box.
