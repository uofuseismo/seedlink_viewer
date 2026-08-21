# SLV app icon

Seismogram trace lifted from the UUSS mark, set on black with the SLV wordmark.

## Colors

All three are official University of Utah brand colors.

| Role | Color | Hex |
| --- | --- | --- |
| Background | Black | `#000000` |
| Trace | Utah Red | `#BE0000` |
| Wordmark | White | `#FFFFFF` |

Type is TeX Gyre Heros Bold (a Helvetica clone), converted to outlines — the SVG has no font dependency.

## Files

| File | Use |
| --- | --- |
| `slv_icon.svg` | Vector master, 1024×1024 full bleed. Edit this, regenerate the rest. |
| `slv_icon_1024.png` | iOS app icon source. No alpha, no rounded corners — iOS applies its own mask. |
| `slv_icon_adaptive_foreground.png` | Android adaptive foreground. Transparent, content inside the 66% safe zone. |
| `slv_icon_adaptive_background.png` | Android adaptive background. Solid black. |
| `slv_icon_monochrome.png` | Android 13+ themed icon. White on transparent; the launcher tints it. |
| `slv_icon_maskable_512.png` | Web/PWA maskable icon. |
| `slv_icon_512.png` | Web favicon / general purpose. |
| `slv_icon_48.png`, `slv_icon_96.png` | Small-size proofs. |

## flutter_launcher_icons

```yaml
dev_dependencies:
  flutter_launcher_icons: ^0.14.1

flutter_launcher_icons:
  image_path: "assets/icon/slv_icon_1024.png"
  android: true
  ios: true
  remove_alpha_ios: true
  adaptive_icon_background: "assets/icon/slv_icon_adaptive_background.png"
  adaptive_icon_foreground: "assets/icon/slv_icon_adaptive_foreground.png"
  adaptive_icon_monochrome: "assets/icon/slv_icon_monochrome.png"
  web:
    generate: true
    image_path: "assets/icon/slv_icon_1024.png"
    background_color: "#000000"
    theme_color: "#BE0000"
```

Then:

```
dart run flutter_launcher_icons
```

## Notes

- `adaptive_icon_background` can be replaced with the string `"#000000"` if you'd rather not ship the background PNG.
- Utah Red on black sits at about 3.2:1 contrast. That clears the 3:1 WCAG minimum for graphical objects, but it's not far above it — if the trace ever needs to read on a lighter surface, invert to the black-on-white variant rather than lightening the red.
- The trace is a synthetic waveform: flat pre-event noise, P arrival, brief lull, S arrival, exponential coda decay. It's shaped for legibility at 48px, not physical accuracy.
