---
name: Whereabouts
description: A passport entry stamp that says where the internet thinks this Mac is.
colors:
  ink-violet: "#4A36A3"
  ink-violet-dark: "#B9ADFF"
  ink-admitted: "#1E7A4C"
  paper-top: "#E6F2EB"
  paper: "#DCEBE3"
  paper-bottom: "#CFE3D8"
  guilloche-mint: "#B9D7C8"
  guilloche-blue: "#C7DBE6"
  page-shade: "#0E2A1E"
typography:
  stamp-title:
    fontFamily: "Whereabouts stroke lettering (built from strokes in Branding/brand.py; no font file)"
    fontSize: "55.46px"
    letterSpacing: "0.16em"
  stamp-verdict:
    fontFamily: "Whereabouts stroke lettering (built from strokes in Branding/brand.py; no font file)"
    fontSize: "41.36px"
    letterSpacing: "0.22em"
  place-code:
    fontFamily: "Whereabouts stroke lettering (built from strokes in Branding/brand.py; no font file)"
    fontSize: "44px"
    letterSpacing: "0.14em"
  wordmark:
    fontFamily: "Whereabouts stroke lettering (built from strokes in Branding/brand.py; no font file)"
    fontSize: "96px"
    letterSpacing: "0.13em"
rounded:
  icon-body: "185.4px"
  stamp-full-outer: "61.1px"
  stamp-full-inner: "30.55px"
  stamp-small: "100px"
  wordmark-stamp: "30.4px"
  glyph: "3px"
spacing:
  wordmark-pad: "24px"
  wordmark-gap: "54px"
components:
  app-icon:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink-violet}"
    rounded: "{rounded.icon-body}"
    size: "1024px"
    width: "824px"
  stamp-full:
    textColor: "{colors.ink-violet}"
    rounded: "{rounded.stamp-full-outer}"
    width: "664px"
    height: "470px"
  stamp-small:
    textColor: "{colors.ink-violet}"
    rounded: "{rounded.stamp-small}"
    width: "700px"
    height: "500px"
  ghost-stamp:
    textColor: "{colors.ink-admitted}"
    typography: "{typography.place-code}"
  menubar-glyph:
    rounded: "{rounded.glyph}"
    width: "21px"
    height: "16px"
  wordmark:
    textColor: "{colors.ink-violet}"
    typography: "{typography.wordmark}"
    rounded: "{rounded.wordmark-stamp}"
    height: "220px"
  wordmark-dark:
    textColor: "{colors.ink-violet-dark}"
    typography: "{typography.wordmark}"
    rounded: "{rounded.wordmark-stamp}"
    height: "220px"
---

# Design System: Whereabouts

## Overview

**Creative North Star: "The Port of Entry"**

Every location check is an entry stamp: the internet admits this Mac somewhere, and Whereabouts inks where. The mark is a tilted, double-bordered violet rubber stamp on a pale mint visa page with guilloché security print. It holds an entry arrow arriving at a point, with WHEREABOUTS across the top and ADMITTED beneath. The ink is uneven, as a real stamp's would be: heavy at one corner, thin at the far one, eroded at the edges, with paper showing through. Two faint, older green impressions carrying place codes bleed off the page edges. They are the history of where this Mac has been seen.

The brand world covers three carriers and nothing else: the app icon (`Resources/AppIcon.icns`), the menu-bar status glyph (`StampGlyph.swift`), and the wordmark lockup (`Branding/wordmark*.svg`). All three are drawn from one measured geometry in `Branding/brand.py`. The glyph reuses the icon's stamp proportions, its arrow-into-point mark, and its -7° tilt. The in-app SwiftUI windows (Settings, Status) are deliberately not part of this world. They follow native macOS conventions: system colors, SF Symbols, and grouped forms. No app-UI tokens exist, so don't invent any.

The mark refuses the category defaults (shield, padlock, globe with a pin on a blue gradient) and makes a clean break from GeoMeister's metal compass and teal.

**Key Characteristics:**
- One stamp, three carriers: icon, menu-bar glyph, and wordmark all share the stamp's frame ratio (about 1.41:1), its -7° tilt, and the arrow-into-point mark.
- Ink carries meaning; color is never decoration.
- Lettering is stroke-built condensed monoline caps on a 10-unit grid. The mark ships with no font.
- Two detail levels: full (lettering, guilloché, ghost stamps, ink texture) at 128px and up; small (frame plus mark only) at 64px and below.
- Calm states draw light and alarms draw heavy: in the menu bar, a problem always looks heavier than an all-clear.

## Colors

The palette is one violet stamp ink and one green admission ink on a pale mint security paper.

### Primary
- **Visa Violet** (ink-violet): the brand at rest. It inks the main stamp in the icon (both detail levels) and the light-ground wordmark.
- **Night Violet** (ink-violet-dark): the same ink when it is read on a dark ground. Used only for `wordmark-dark.svg`.

### Secondary
- **Admission Green** (ink-admitted): means admitted. It inks the ghost impressions (PT · LIS, NL · AMS) at 26% and 20% opacity in the full icon. It is never the main stamp.

### Neutral
- **Visa Paper** (paper-top, paper, paper-bottom): a three-stop vertical gradient that fills the squircle. The mid stop also fills the erosion voids, which is how paper shows through the ink.
- **Guilloché Mint and Guilloché Blue** (guilloche-mint, guilloche-blue): two interfering wave weaves of 58 lines, 1.5px and 1.3px stroke. Full detail only.
- **Page Shade** (page-shade): a dark green-black used only for the icon's blurred drop shadow (26%) and its 2px hairline edge (10%).

### Named Rules
**The One Ink, One Law Rule.** Each ink has one meaning. Violet is the brand at rest. Green means admitted. In the menu bar, system red means refused or blocked, system orange means leak, and system gray means unknown, offline, or checking. Never use an ink for a meaning it does not carry.

**The System Colors in the Menu Bar Rule.** The status glyph never uses brand hexes. In colored mode it uses `systemGreen`, `systemRed`, `systemOrange`, and `systemGray`. Otherwise it is a template image that follows the menu bar's appearance.

## Typography

**Display Font:** none. All lettering is stroke-built in `Branding/brand.py`.

**Character:** condensed monoline customs caps, like cut rubber type. Each letter is built from centerline strokes on a cap height of 10 units with a stroke weight of 1.75 units, butt caps, and miter joins. Diagonal letters (A, M, N, R, W) overshoot the band and are clipped flat at the cap and baseline. Word spaces are 3.0 units and the interpunct (·) is 1.9 units. Tracking is given in grid units: the `em` values in the frontmatter are tracking divided by the 10-unit cap height, and `fontSize` is the cap height in px on the 1024 canvas.

### Hierarchy
- **Stamp title** (cap 0.118 of stamp height, tracking 1.6 units): WHEREABOUTS, between the top border and the upper rule.
- **Stamp verdict** (cap 0.088 of stamp height, tracking 2.2 units): ADMITTED, between the lower rule and the bottom border. It is smaller and more open than the title.
- **Place code** (44px and 60px caps, tracking 1.4 units): country and city codes joined by an interpunct, on the ghost stamps only.
- **Wordmark** (96px cap, tracking 1.3 units): WHEREABOUTS beside the small stamp.

### Named Rules
**The No-Font Rule.** The mark is never set in a system or web font. New lettering adds glyphs to the stroke grid (10-unit cap, 1.75 stroke, flat-clipped diagonals) instead of substituting a typeface.

## Layout

The icon uses Apple's macOS grid: an 824px body inset 100px on a 1024px canvas. The stamp is centred at (512, 516) and rotated -7°.

**The Legibility Scale Rule.** The full stamp is 664 × 470px, about 80% of the squircle width (81%). Its tilted bounds are about 87% (716px). The surface brief records that as 85%; the build measures 87%. The stamp was enlarged from the contract's 70% so the lettering stays legible at the 128px slot. Don't shrink it back toward 70%. The small stamp is 700 × 500px (85% of the body width) so the frame stays heavy at 16-64px.

**The Two Detail Levels Rule.** The `.icns` 16, 32 and 64px slots use `icon-small.svg`: frame and arrow-into-point only, with no lettering, guilloché, ghosts, or ink texture. The 128px slot and larger use `icon.svg`. `Branding/build.sh` enforces this split.

Inside the full stamp, the outer border is 0.058h. The inner border sits 0.08h inside it at 0.018h stroke. The rules sit at 30% and 75% of the height. The arrow spans the inner width less 12% on each side.

The wordmark lockup is 220px tall: the small stamp at 214 × 152px, tilted -7°, then a 54px gap before the word. There is 24px of padding on both ends.

## Elevation & Depth

Depth comes from the physical impression, not from layered surfaces. The squircle has one blurred macOS-style drop shadow (page-shade, 26%, Gaussian blur 9, offset 10px down) and a white rim highlight that fades from 75% to 0 over the top 35%. The stamp itself shows depth through ink pressure. A radial falloff centred near the top-left corner runs from full ink to 95% at 0.5, 72% at 0.82, and 52% at the under-inked bottom-right corner. About 300 erosion bites straddle the heavy border's edges, and about 620 voids thin out with distance from the light corner.

**The Imperfect Impression Rule.** Pressure falloff, erosion, and voids belong to the full-detail stamp only. Small sizes and the menu-bar glyph are clean, solid ink.

## Shapes

The icon body is Apple's continuous-corner rounded rectangle (185.4px radius on the 824px body), built from UIKit's corner-curve constants rather than a plain circular arc. Stamps are rounded rectangles with a frame ratio of about 1.41:1. The full stamp has a double border (outer radius 0.13h, inner 0.065h). The small stamp has a single heavy border (radius 0.2h, stroke 0.125h). The mark is an entry arrow arriving at a point: a shaft and a head 1.65 × the shaft thickness long and 2.6 × as wide, a small gap, then a dot. The ghost stamps are one double circle and one double rounded rectangle, each with its own tilt (16° and 21°).

## Components

### App Icon
The visa page with a fresh entry stamp. At full detail it carries the guilloché, both ghost stamps, and the inked stamp with title, mark, and verdict. At small detail it is paper, the heavy frame, and the mark. Both levels share the squircle shadow, rim, and hairline.

### Menu-Bar Glyph (signature)
A 21 × 16pt image containing a 17 × 12 stamp frame (radius 3, stroke 1.6), tilted to match the icon. It has seven states:
- **Admitted:** outline frame holding the arrow into a point.
- **Unknown:** outline frame holding a stroked "?".
- **Refused:** solid stamp with a knocked-out "!".
- **Leak:** solid stamp with a knocked-out drop.
- **Blocked (kill switch):** solid stamp with a knocked-out "×".
- **Offline:** dashed empty frame (2.4 / 1.6 dash).
- **Checking:** empty frame at 45% ink, a half-inked stamp.

Each state carries an accessibility description, "Whereabouts: <state>" (for example, "location leak detected").

**The Heavier-When-Wrong Rule.** Calm states are an inked outline. Alarms are a solid stamp with the mark cut out. An empty frame means there is nothing to attest yet.

**The Kill Switch Outranks Rule.** State precedence is kill switch, then leak, then geo state. While a leak is active, the glyph never shows admitted.

### Wordmark
The small stamp followed by WHEREABOUTS in stroke lettering, in one ink. Use `wordmark.svg` (Visa Violet) on light grounds and `wordmark-dark.svg` (Night Violet) on dark grounds.

### In-App Windows
The Settings and Status windows are stock SwiftUI with system colors, SF Symbols, and grouped forms. They follow macOS conventions and carry no brand tokens.

## Do's and Don'ts

### Do:
- **Do** derive every brand asset from `Branding/brand.py` and regenerate through `Branding/build.sh`. Never hand-edit the SVGs or the `.icns`.
- **Do** keep the full stamp at about 80% of the squircle width so the lettering reads at 128px.
- **Do** use the small detail level at 64px and below.
- **Do** keep the -7° tilt and the arrow-into-point mark consistent across icon, glyph, and wordmark.
- **Do** use system colors (or a template image) for the menu-bar glyph, and give every state its accessibility label.
- **Do** keep the in-app windows native macOS.

### Don't:
- **Don't** use shields, padlocks, globes with pins, or blue gradients, and don't bring back the GeoMeister compass or teal.
- **Don't** set the mark's lettering in a font.
- **Don't** use a brand ink for a meaning it does not carry, or put brand hexes in the menu bar.
- **Don't** show an all-clear glyph while a leak, violation, or kill switch is active.
- **Don't** apply guilloché, ghost stamps, lettering, or ink erosion below 128px.
- **Don't** replace the custom status glyph with SF Symbols.
