import math, random, os
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.misc.transform import Transform
import cairosvg

RED   = "#BE0000"
BLACK = "#000000"
WHITE = "#FFFFFF"
FONT  = "/usr/share/texmf/fonts/opentype/public/tex-gyre/texgyreheros-bold.otf"
OUT   = "/home/claude/out"
os.makedirs(OUT, exist_ok=True)

# ---------- seismic trace ----------
def trace(x0, x1, cy, amp, n=49, seed=5):
    rnd = random.Random(seed)
    pts = []
    for i in range(n):
        t = i / (n - 1)
        if t < 0.30:                      # pre-event noise
            env = 0.05
        elif t < 0.42:                    # P arrival
            env = 0.46 * math.exp(-(t - 0.30) * 8) + 0.12
        elif t < 0.48:                    # brief lull
            env = 0.16
        else:                             # S arrival + coda decay
            env = 1.00 * math.exp(-(t - 0.48) * 4.6) + 0.04
        osc = (1 if i % 2 else -1) * rnd.uniform(0.72, 1.0)
        y = cy - env * osc * amp
        pts.append((x0 + t * (x1 - x0), y))
    pts[0] = (x0, cy)
    pts[-1] = (x1, cy)
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)

# ---------- lettering: SLV as outlines ----------
def letters(text, cap_target, tracking, cx, baseline):
    f = TTFont(FONT)
    gs = f.getGlyphSet()
    cmap = f.getBestCmap()
    upm = f["head"].unitsPerEm
    cap = f["OS/2"].sCapHeight if hasattr(f["OS/2"], "sCapHeight") else 0.7 * upm
    s = cap_target / cap
    adv, glyphs = 0, []
    for ch in text:
        gn = cmap[ord(ch)]
        glyphs.append((gn, gs[gn].width * s))
        adv += gs[gn].width * s + tracking
    total = adv - tracking
    x = cx - total / 2
    d = []
    for gn, w in glyphs:
        pen = SVGPathPen(gs)
        gs[gn].draw(TransformPen(pen, Transform(s, 0, 0, -s, x, baseline)))
        d.append(pen.getCommands())
        x += w + tracking
    return " ".join(d)

# ---------- composition ----------
CY, AMP, SW = 400, 232, 22
TRACE = trace(100, 924, CY, AMP)
SLV   = letters("SLV", 152, 34, 512, 858)

def core(color_trace=RED, color_text=WHITE):
    return (f'<path d="{TRACE}" fill="none" stroke="{color_trace}" stroke-width="{SW}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>'
            f'<path d="{SLV}" fill="{color_text}"/>')

def svg(body, size=1024):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 1024 1024">{body}</svg>')

full   = svg(f'<rect width="1024" height="1024" fill="{BLACK}"/>' + core())
# android adaptive / maskable: content scaled into the central 66% safe zone
inset  = 'transform="translate(512,512) scale(0.64) translate(-512,-512)"'
fg     = svg(f'<g {inset}>{core()}</g>')
mask   = svg(f'<rect width="1024" height="1024" fill="{BLACK}"/><g {inset}>{core()}</g>')
bg     = svg(f'<rect width="1024" height="1024" fill="{BLACK}"/>')
mono   = svg(f'<g {inset}>{core(WHITE, WHITE)}</g>')

files = {
    "slv_icon.svg": full,
    "slv_icon_adaptive_foreground.svg": fg,
}
for name, data in files.items():
    open(f"{OUT}/{name}", "w").write(data)

png = {
    "slv_icon_1024.png": (full, 1024),
    "slv_icon_512.png": (full, 512),
    "slv_icon_adaptive_foreground.png": (fg, 1024),
    "slv_icon_adaptive_background.png": (bg, 1024),
    "slv_icon_maskable_512.png": (mask, 512),
    "slv_icon_monochrome.png": (mono, 1024),
    "slv_icon_48.png": (full, 48),
    "slv_icon_96.png": (full, 96),
}
for name, (data, px) in png.items():
    cairosvg.svg2png(bytestring=data.encode(), write_to=f"{OUT}/{name}",
                     output_width=px, output_height=px)
print("\n".join(sorted(os.listdir(OUT))))
