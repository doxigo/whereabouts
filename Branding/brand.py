"""Whereabouts brand sources: writes the app icon and wordmark SVGs next to this file.

The mark is a passport entry stamp: a tilted, double-bordered violet stamp on a
guilloché visa page. Lettering is built from strokes on a 10-unit cap grid so the
mark ships no font. Run through build.sh, which also rasterizes the .icns.
"""
import math
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))

INK = "#4A36A3"         # violet: the brand at rest
INK_DARK = "#B9ADFF"    # the same ink read on a dark ground
ADMITTED = "#1E7A4C"    # green: a past entry
PAPER_TOP, PAPER, PAPER_BOTTOM = "#E6F2EB", "#DCEBE3", "#CFE3D8"
GUILLOCHE, GUILLOCHE_2 = "#B9D7C8", "#C7DBE6"
TILT = -7

# ---------------------------------------------------------------- lettering
# Centerline strokes on a cap height of 10 units, stroke weight S. Diagonal
# letters overshoot the band and are clipped flat, like cut rubber type.
S = 1.75
a = S / 2
r = 1.825  # bowl radius: half the inner width of a 5.4-unit letter


def _letters():
    R = 5.4 - a
    L = {}
    L["H"] = (5.4, False, [f"M{a},0 V10", f"M{R},0 V10", f"M{a},5 H{R}"])
    L["E"] = (4.9, False, [f"M4.9,{a} H{a} V{10 - a} H4.9", f"M{a},5 H4.5"])
    L["T"] = (5.4, False, [f"M0,{a} H5.4", f"M2.7,{a} V10"])
    L["I"] = (S, False, [f"M{a},0 V10"])
    L["O"] = (5.4, False, [f"M{a},2.7 A{r},{r} 0 0 1 {R},2.7 V7.3 A{r},{r} 0 0 1 {a},7.3 Z"])
    L["U"] = (5.4, False, [f"M{a},0 V7.3 A{r},{r} 0 0 0 {R},7.3 V0"])
    L["D"] = (5.4, False, [f"M{a},0 V10", f"M{a},{a} H{R - r} A{r},{r} 0 0 1 {R},{a + r} V{10 - a - r} A{r},{r} 0 0 1 {R - r},{10 - a} H{a}"])
    L["B"] = (5.4, False, [f"M{a},0 V10",
                           f"M{a},{a} H2.15 A2.04,2.04 0 0 1 2.15,4.95 H{a}",
                           f"M{a},4.95 H2.43 A2.0875,2.0875 0 0 1 2.43,{10 - a} H{a}"])
    L["R"] = (5.4, True, [f"M{a},10 V{a} H2.2 A2.3125,2.3125 0 0 1 2.2,5.5 H{a}", "M2.3,5.5 L4.9,11.2"])
    L["L"] = (4.6, False, [f"M{a},0 V{10 - a} H4.6"])
    L["P"] = (5.4, False, [f"M{a},10 V{a} H2.2 A2.3125,2.3125 0 0 1 2.2,5.5 H{a}"])
    L["N"] = (5.4, True, [f"M{a},11 V0.2 L{R},9.8 V-1"])
    L["K"] = (5.4, True, [f"M{a},0 V10", "M5.3,-0.9 L1.0,6.3", "M2.5,4.3 L5.5,10.9"])
    L["Y"] = (5.8, True, ["M0.25,-0.9 L2.9,5.2 L5.55,-0.9", "M2.9,5.2 V10"])
    L["?"] = (5.4, False, [f"M{a},3.3 V2.7 A{r},{r} 0 0 1 {R},2.7 V3.5 Q{R},4.7 2.7,5.5 V7.3", "M2.7,8.25 V10"])
    L["S"] = (5.4, False, [f"M{R},3.5 V2.7 A{r},{r} 0 0 0 2.7,{a} A{r},{r} 0 0 0 {a},2.7 V3.175 "
                           f"A{r},{r} 0 0 0 2.7,5 A{r},{r} 0 0 1 {R},6.825 V7.3 A{r},{r} 0 0 1 2.7,{10 - a} "
                           f"A{r},{r} 0 0 1 {a},7.3 V6.5"])

    def legs(top, bottom_l, bottom_r):
        return f"M{bottom_l[0]},{bottom_l[1]} L{top[0]},{top[1]} L{bottom_r[0]},{bottom_r[1]}"

    # A: pointed apex cut flat by the clip; crossbar placed on the leg centerlines
    ax, ay, lx, rx_, by = 3.2, 0.9, 0.3, 6.1, 11.2
    bar_y = 6.9
    t = (bar_y - ay) / (by - ay)
    L["A"] = (6.4, True, [legs((ax, ay), (lx, by), (rx_, by)),
                          f"M{ax + (lx - ax) * t:.3f},{bar_y} H{ax + (rx_ - ax) * t:.3f}"])
    L["W"] = (7.6, True, [f"M0.2,-1.2 L2.15,9.0 L3.8,0.9 L5.45,9.0 L7.4,-1.2"])
    L["M"] = (6.6, True, [f"M{a},11 V0.9 L3.3,7.4 L{6.6 - a},0.9 V11"])
    return L


LETTERS = _letters()
SPACING = {" ": 3.0, "·": 1.9}


def lettering(text, x, y, cap, color, tracking=1.5, anchor="middle", opacity=None):
    """SVG group for `text` with its cap-height top at y. Returns (svg, width_px)."""
    k = cap / 10
    units = sum(SPACING.get(c) or LETTERS[c][0] for c in text) + tracking * (len(text) - 1)
    width = units * k
    x0 = x - width / 2 if anchor == "middle" else x
    out, cx = [], 0.0
    for c in text:
        if c == " ":
            cx += SPACING[c] + tracking
            continue
        if c == "·":
            out.append(f'<circle cx="{cx + 0.95:.3f}" cy="5" r="0.95" fill="{color}" stroke="none"/>')
            cx += SPACING[c] + tracking
            continue
        w, clipped, paths = LETTERS[c]
        d = f'<path d="{" ".join(paths)}"/>'
        if clipped:  # CoreSVG resolves clips in the parent's space: clip an untransformed inner group
            d = f'<g clip-path="url(#band)">{d}</g>'
        out.append(f'<g transform="translate({cx:.3f} 0)">{d}</g>')
        cx += w + tracking
    op = f' opacity="{opacity}"' if opacity is not None else ""
    svg = (f'<g transform="translate({x0:.2f} {y:.2f}) scale({k:.4f})" fill="none" stroke="{color}" '
           f'stroke-width="{S}" stroke-linecap="butt" stroke-linejoin="miter" stroke-miterlimit="12"{op}>'
           + "".join(out) + "</g>")
    return svg, width


BAND_CLIP = '<clipPath id="band" clipPathUnits="userSpaceOnUse"><rect x="-2" y="0" width="12" height="10"/></clipPath>'

# ---------------------------------------------------------------- geometry


def squircle(x=100, y=100, size=824, radius=185.4):
    """macOS icon body: Apple's continuous-corner rounded rect on the 824-in-1024 grid."""
    r, x1, y1 = radius, x + size, y + size
    # One corner as cubic segments (constants from UIKit's continuous corner curve),
    # expressed in a local frame and rotated to each corner.
    seg = [((1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600)),
           ((0.37282108, 0.19213336), (0.19213309, 0.37282138), (0.06549569, 0.66993493)),
           ((0, 0.86840701), (0, 1.08849299), (0, 1.52866483))]
    corners = [((x1, y), (-1, 0), (0, 1)), ((x1, y1), (0, -1), (-1, 0)),
               ((x, y1), (1, 0), (0, -1)), ((x, y), (0, 1), (1, 0))]
    d = f"M{x + 1.52866483 * r:.3f},{y}"
    for (cx, cy), u, v in corners:  # u points back along the incoming edge, v along the outgoing one
        p = lambda a, b: f"{cx + (u[0] * a + v[0] * b) * r:.3f},{cy + (u[1] * a + v[1] * b) * r:.3f}"
        d += f" L{p(1.52866483, 0)}"
        for c1, c2, end in seg:
            d += f" C{p(*c1)} {p(*c2)} {p(*end)}"
    return d + " Z"


def guilloche(color, width, phase, lines=58, amp=26, step=6, width_px=1024):
    """Interfering wave lines, the security print on a visa page."""
    out = []
    for i in range(lines):
        y0 = -40 + i * 19
        pts = []
        for x in range(-20, width_px + 21, step):
            y = (y0 + amp * math.sin(x / 61 + i * 0.31 + phase)
                 + amp * 0.55 * math.sin(x / 23 - i * 0.17 + phase * 2))
            pts.append(f"{x},{y:.1f}")
        out.append(f'M{" L".join(pts)}')
    return f'<path d="{" ".join(out)}" fill="none" stroke="{color}" stroke-width="{width}"/>'


def arrow_into_point(x0, x1, cy, thick, dot_r, gap, color):
    """The mark: an entry arrow arriving at a point."""
    head_len, head_half = thick * 1.65, thick * 1.3
    tip = x1 - dot_r * 2 - gap
    shaft_end = tip - head_len
    dot_cx = x1 - dot_r
    return (f'<path d="M{x0},{cy - thick / 2} H{shaft_end} V{cy - head_half} L{tip},{cy} '
            f'L{shaft_end},{cy + head_half} V{cy + thick / 2} H{x0} Z" fill="{color}"/>'
            f'<circle cx="{dot_cx}" cy="{cy}" r="{dot_r}" fill="{color}"/>')


def voids(seed, regions, count, color, rmin, rmax, light=None, reach=1.0):
    """Paper showing through the ink: irregular gaps kept inside the inked regions.
    With `light` (a point), gaps thin out with distance from that under-inked corner."""
    rng = random.Random(seed)
    out = []
    while len(out) < count:
        x0, y0, x1, y1 = rng.choice(regions)
        x, y = rng.uniform(x0, x1), rng.uniform(y0, y1)
        if light and rng.random() > 0.2 + 0.8 * max(0.0, 1 - math.hypot(x - light[0], y - light[1]) / reach):
            continue
        size, sides = rng.uniform(rmin, rmax), rng.randint(5, 8)
        stretch, turn = rng.uniform(1.0, 2.3), rng.uniform(0, math.pi)
        pts = []
        for i in range(sides):
            t = 2 * math.pi * i / sides + rng.uniform(-0.35, 0.35)
            px, py = math.cos(t) * size * rng.uniform(0.5, 1.0) * stretch, math.sin(t) * size * rng.uniform(0.5, 1.0)
            pts.append(f"{x + px * math.cos(turn) - py * math.sin(turn):.1f},{y + px * math.sin(turn) + py * math.cos(turn):.1f}")
        out.append(f'<path d="M{" L".join(pts)}Z" fill="{color}"/>')
    return "".join(out)


# ---------------------------------------------------------------- the stamp

def stamp(cx, cy, w, h, color, detail, ink_grad=None):
    """Entry stamp centred on (cx, cy), untilted. detail: 'full' or 'small'."""
    x0, y0, x1, y1 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
    paint = f"url(#{ink_grad})" if ink_grad else color
    if detail == "small":
        bw = h * 0.125
        out = f'<rect x="{x0}" y="{y0}" width="{w}" height="{h}" rx="{h * 0.2}" fill="none" stroke="{paint}" stroke-width="{bw}"/>'
        out += arrow_into_point(x0 + w * 0.17, x1 - w * 0.15, cy, h * 0.17, h * 0.15, h * 0.06, paint)
        return out
    bw, inset, iw = h * 0.058, h * 0.08, h * 0.018
    ix0, iy0, ix1, iy1 = x0 + inset, y0 + inset, x1 - inset, y1 - inset
    rule1, rule2 = y0 + h * 0.30, y1 - h * 0.25
    out = (f'<rect x="{x0}" y="{y0}" width="{w}" height="{h}" rx="{h * 0.13}" fill="none" stroke="{paint}" stroke-width="{bw}"/>'
           f'<rect x="{ix0}" y="{iy0}" width="{ix1 - ix0}" height="{iy1 - iy0}" rx="{h * 0.065}" fill="none" stroke="{paint}" stroke-width="{iw}"/>'
           f'<path d="M{ix0},{rule1} H{ix1} M{ix0},{rule2} H{ix1}" stroke="{paint}" stroke-width="{iw}"/>')
    top_cap = h * 0.118
    t, _ = lettering("WHEREABOUTS", cx, (iy0 + rule1) / 2 - top_cap / 2, top_cap, paint, tracking=1.6)
    bottom_cap = h * 0.088
    b, _ = lettering("ADMITTED", cx, (rule2 + iy1) / 2 - bottom_cap / 2, bottom_cap, paint, tracking=2.2)
    mid = (rule1 + rule2) / 2
    out += t + b + arrow_into_point(ix0 + w * 0.12, ix1 - w * 0.12, mid, h * 0.095, h * 0.085, h * 0.04, paint)
    return out


def ink_gradient(gid, color, x0, y0, w, h):
    """Uneven stamp pressure: full ink near the top-left, an under-inked bottom-right corner."""
    return (f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="{x0 + w * 0.15}" cy="{y0 + h * 0.2}" r="{w * 1.02}">'
            f'<stop offset="0" stop-color="{color}"/><stop offset="0.5" stop-color="{color}" stop-opacity="0.95"/>'
            f'<stop offset="0.82" stop-color="{color}" stop-opacity="0.72"/>'
            f'<stop offset="1" stop-color="{color}" stop-opacity="0.52"/></radialGradient>')


# ---------------------------------------------------------------- outputs

def icon(detail):
    sq = squircle()
    defs = [BAND_CLIP, f'<clipPath id="sq"><path d="{sq}"/></clipPath>',
            '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="9"/></filter>',
            f'<linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{PAPER_TOP}"/>'
            f'<stop offset="0.5" stop-color="{PAPER}"/><stop offset="1" stop-color="{PAPER_BOTTOM}"/></linearGradient>',
            '<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.75"/>'
            '<stop offset="0.35" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>']
    body = ['<rect width="1024" height="1024" fill="url(#paper)"/>']
    cx, cy = 512, 516
    if detail == "full":
        w, h = 664, 470
        body.append(guilloche(GUILLOCHE_2, 1.3, phase=1.9))
        body.append(guilloche(GUILLOCHE, 1.5, phase=0.0))
        # earlier impressions, both admissions in green: where this Mac was seen before
        g = f'<g opacity="0.26" transform="rotate(16 214 214)">'
        g += f'<circle cx="214" cy="214" r="150" fill="none" stroke="{ADMITTED}" stroke-width="17"/>'
        g += f'<circle cx="214" cy="214" r="121" fill="none" stroke="{ADMITTED}" stroke-width="6"/>'
        g += f'<path d="M140,176 H288 M140,252 H288" stroke="{ADMITTED}" stroke-width="5"/>'
        g += lettering("PT · LIS", 214, 192, 44, ADMITTED, tracking=1.4)[0] + "</g>"
        g += f'<g opacity="0.2" transform="rotate(21 850 880)">'
        g += f'<rect x="660" y="760" width="380" height="240" rx="28" fill="none" stroke="{ADMITTED}" stroke-width="16"/>'
        g += f'<rect x="686" y="786" width="328" height="188" rx="14" fill="none" stroke="{ADMITTED}" stroke-width="5"/>'
        g += lettering("NL · AMS", 850, 850, 60, ADMITTED, tracking=1.4)[0] + "</g>"
        body.append(g)
        x0, y0, x1, y1 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
        defs.append(ink_gradient("ink", INK, x0, y0, w, h))
        s = stamp(cx, cy, w, h, INK, "full", "ink")
        bw, e = h * 0.058, 3.0
        # eroded frame: bites straddling the outer and inner edges of the heavy border
        edges = []
        for off in (-bw / 2, bw / 2):
            edges += [(x0 + 60, y0 + off - e, x1 - 60, y0 + off + e), (x0 + 60, y1 - off - e, x1 - 60, y1 - off + e),
                      (x0 + off - e, y0 + 60, x0 + off + e, y1 - 60), (x1 - off - e, y0 + 60, x1 - off + e, y1 - 60)]
        s += voids(5, edges, 300, PAPER, 1.6, 5.5)
        band = bw * 1.1
        inked = [(x0 - band / 2, y0 - band / 2, x1 + band / 2, y0 + band / 2),
                 (x0 - band / 2, y1 - band / 2, x1 + band / 2, y1 + band / 2),
                 (x0 - band / 2, y0, x0 + band / 2, y1), (x1 - band / 2, y0, x1 + band / 2, y1),
                 (cx - 230, cy - 160, cx + 230, cy - 100), (cx - 250, cy - 50, cx + 250, cy + 50),
                 (cx - 140, cy + 140, cx + 140, cy + 180)]
        s += voids(11, inked, 620, PAPER, 0.8, 3.4, light=(x1, y1), reach=w * 0.95)
    else:
        w, h = 700, 500
        s = stamp(cx, cy, w, h, INK, "small")
    body.append(f'<g transform="rotate({TILT} {cx} {cy})">{s}</g>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{"".join(defs)}</defs>'
            f'<path d="{sq}" transform="translate(0 10)" fill="#0E2A1E" opacity="0.26" filter="url(#shadow)"/>'
            f'<g clip-path="url(#sq)">{"".join(body)}</g>'
            f'<path d="{sq}" fill="none" stroke="url(#rim)" stroke-width="5" clip-path="url(#sq)"/>'
            f'<path d="{sq}" fill="none" stroke="#0E2A1E" stroke-opacity="0.10" stroke-width="2"/></svg>')


def wordmark(color):
    cap = 96
    text, tw = lettering("WHEREABOUTS", 0, 0, cap, color, tracking=1.3, anchor="start")
    mw, mh = 214, 152
    gap = 54
    pad = 24
    W, H = pad * 2 + mw + gap + tw, 220
    mark = f'<g transform="rotate({TILT} {pad + mw / 2} {H / 2})">' + stamp(pad + mw / 2, H / 2, mw, mh, color, "small") + "</g>"
    word = f'<g transform="translate({pad + mw + gap} {(H - cap) / 2})">{text}</g>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H}" width="{W:.0f}" height="{H}">'
            f'<title>Whereabouts</title><defs>{BAND_CLIP}</defs>{mark}{word}</svg>')


def banner():
    """1400x560 README banner: lockup, headline and lede on the visa page, the stamp at right."""
    W, H = 1400, 560
    defs = [BAND_CLIP,
            f'<linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{PAPER_TOP}"/>'
            f'<stop offset="1" stop-color="{PAPER_BOTTOM}"/></linearGradient>']
    body = [f'<rect width="{W}" height="{H}" fill="url(#paper)"/>',
            guilloche(GUILLOCHE_2, 1.3, phase=1.9, lines=34, width_px=W),
            guilloche(GUILLOCHE, 1.5, phase=0.0, lines=34, width_px=W)]
    # an older admission bleeding off the bottom edge
    body.append(f'<g opacity="0.2" transform="rotate(-14 760 560)">'
                f'<circle cx="760" cy="560" r="120" fill="none" stroke="{ADMITTED}" stroke-width="14"/>'
                f'<circle cx="760" cy="560" r="96" fill="none" stroke="{ADMITTED}" stroke-width="5"/>'
                + lettering("PT · LIS", 760, 470, 34, ADMITTED, tracking=1.4)[0] + "</g>")
    x = 112
    mark = f'<g transform="rotate({TILT} {x + 33} 120)">' + stamp(x + 33, 120, 66, 47, INK, "small") + "</g>"
    word, _ = lettering("WHEREABOUTS", x + 88, 106, 28, INK, tracking=1.3, anchor="start")
    l1, _ = lettering("WHERE DOES THE INTERNET", x, 198, 48, INK, tracking=1.0, anchor="start")
    l2, _ = lettering("THINK YOU ARE?", x, 264, 48, INK, tracking=1.0, anchor="start")
    lede = ['A Mac menu-bar app that checks where your IP',
            'appears to be, warns you the moment it\'s wrong,',
            'and can cut the network until it isn\'t.']
    text = "".join(f'<text x="{x}" y="{376 + i * 32}" font-family="Helvetica Neue" font-size="22" fill="#2E3B35">{t}</text>'
                   for i, t in enumerate(lede))
    sw, sh = 446, 316
    scx, scy = 1086, 280
    x0, y0, x1, y1 = scx - sw / 2, scy - sh / 2, scx + sw / 2, scy + sh / 2
    defs.append(ink_gradient("ink", INK, x0, y0, sw, sh))
    s = stamp(scx, scy, sw, sh, INK, "full", "ink")
    bw, e = sh * 0.058, 2.4
    edges = []
    for off in (-bw / 2, bw / 2):
        edges += [(x0 + 44, y0 + off - e, x1 - 44, y0 + off + e), (x0 + 44, y1 - off - e, x1 - 44, y1 - off + e),
                  (x0 + off - e, y0 + 44, x0 + off + e, y1 - 44), (x1 - off - e, y0 + 44, x1 - off + e, y1 - 44)]
    s += voids(5, edges, 220, PAPER, 1.2, 4.0)
    band = bw * 1.1
    inked = [(x0 - band / 2, y0 - band / 2, x1 + band / 2, y0 + band / 2), (x0 - band / 2, y1 - band / 2, x1 + band / 2, y1 + band / 2),
             (x0 - band / 2, y0, x0 + band / 2, y1), (x1 - band / 2, y0, x1 + band / 2, y1),
             (scx - 165, scy - 113, scx + 165, scy - 71), (scx - 177, scy - 35, scx + 177, scy + 35)]
    s += voids(11, inked, 440, PAPER, 0.6, 2.5, light=(x1, y1), reach=sw * 0.95)
    body += [mark, word, l1, l2, text, f'<g transform="rotate({TILT} {scx} {scy})">{s}</g>']
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">'
            f'<title>Whereabouts: where does the internet think you are?</title>'
            f'<defs>{"".join(defs)}</defs>{"".join(body)}</svg>')


def main():
    files = {"icon.svg": icon("full"), "icon-small.svg": icon("small"),
             "wordmark.svg": wordmark(INK), "wordmark-dark.svg": wordmark(INK_DARK), "banner.svg": banner()}
    for name, svg in files.items():
        with open(os.path.join(HERE, name), "w") as f:
            f.write(svg)
    print("wrote", ", ".join(files))


if __name__ == "__main__":
    main()
