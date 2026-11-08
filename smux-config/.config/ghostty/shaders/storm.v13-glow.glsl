// Storm: occasional lightning (multi-stroke flicker + branches,
// lit clouds), and very rare red sprites high above the storm.
// Text pixels are left untouched; only the background is painted.

// Tuning ---------------------------------------------------------------------
const float WINDOW = 6.0;          // seconds per lightning "chance"
const float STRIKE_CHANCE = 0.45;  // chance of a strike in each window (~1 per 13s)
const float SPRITE_EVERY = 270.0;  // average seconds between sprites (one per ~4.5 min block, 3-6 min apart)
const float SPRITE_DECAY = 4.0;    // fade speed; higher = shorter (v1 was 7.0)
const int   SPRITE_TYPE = -1;      // -1 random, 0 jellyfish, 1 carrot cluster, 2 columns
const float SPRITE_SLOWMO = 3.0;   // TEMP for tuning: plays sprites 3x slower (1.0 = real speed)
const float FLASH = 0.22;          // full-screen flash brightness
const float AFTERGLOW = 0.25;      // lingering light after a strike (0 = snaps off)
const float GLOW = 1.0;            // neon text glow strength (0 = off, ~1 = soft, ~2 = strong)
const float GLOW_RADIUS = 10.0;    // glow reach in pixels
const float GLOW_GAP = 2.5;        // crisp dark gap between a glyph and its halo, in pixels
const bool  FLIP_Y = true;         // cmux/Ghostty puts y=0 at the top; flip so y points up
const int   BOLT_SLOT = -1;        // strike depth: -1 random, 0 behind all ranges ... 4 in front of all
const int   SPRITE_SLOT = -1;      // sprite depth, same scale
const float MIST = 1.0;            // valley mist strength
const float MOUNTAIN_RISE = 6.0;   // seconds for the mountains to rise into view

// Noise ----------------------------------------------------------------------
float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

// Linear-interpolated value noise: piecewise straight segments = jagged bolts.
float noise1(float x) {
    float i = floor(x);
    return mix(hash11(i), hash11(i + 1.0), fract(x));
}

// The lattice repeats every 256 cells, so time-driven inputs can be wrapped
// at a multiple of 256 with no visible seam.
float noise2(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    vec2 a = mod(i, 256.0);
    vec2 b = mod(i + 1.0, 256.0);
    return mix(mix(hash21(a), hash21(vec2(b.x, a.y)), f.x),
               mix(hash21(vec2(a.x, b.y)), hash21(b), f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * noise2(p);
        p = p * 2.0 + vec2(17.0, 31.0);              // whole-number steps keep the 256 period
        a *= 0.5;
    }
    return v;
}

// Lightning ------------------------------------------------------------------
float boltX(float y, float x0, float seed) {
    float x = x0;
    float amp = 0.09;
    float freq = 5.0;
    for (int o = 0; o < 4; o++) {
        x += (noise1(y * freq + seed * 13.0 + float(o) * 7.0) - 0.5) * amp;
        amp *= 0.5;
        freq *= 2.3;
    }
    return x;
}

// Hot core plus soft falloff glow.
float boltGlow(float d, float width) {
    return (1.0 - smoothstep(0.0, width, d)) + 0.0015 / (d + 0.0015) * 0.35;
}

float pulse(float t, float start, float decay) {
    return t < start ? 0.0 : exp(-(t - start) * decay);
}

// A strike is several return strokes down the same channel: flash, flicker, flicker.
float strokes(float t) {
    return pulse(t, 0.0, 22.0) + 0.75 * pulse(t, 0.09, 26.0) + 0.5 * pulse(t, 0.21, 20.0);
}

// Red sprites ----------------------------------------------------------------
// Built from "elements", as in photos of real sprites: a bright knot (head),
// thin straight streamers shooting up, and a cone of fine, branching, beaded
// tendrils below that propagate downward, thin out, and fade from the tips up.
// All coordinates are screen units (y up); widths are half-widths.
const vec3 SP_RED = vec3(1.0, 0.16, 0.10);
const vec3 SP_HOT = vec3(1.0, 0.72, 0.45);    // orange-white cores and beads
const vec3 SP_DEEP = vec3(0.6, 0.05, 0.14);   // deep crimson at the tips

// Brightness over time for one part of a sprite: fast onset, decay at a
// per-part rate, slight flicker, so the sprite fades unevenly.
float elemEnv(float ts, float h) {
    return smoothstep(0.0, 0.015, ts)
         * exp(-ts * SPRITE_DECAY * (0.7 + 0.6 * h))
         * (0.85 + 0.15 * sin(ts * 55.0 + h * 20.0));
}

// Jagged sideways jitter, like a small lightning channel.
float jag(float y, float s) {
    return (noise1(y * 40.0 + s) - 0.5) * 0.005 + (noise1(y * 130.0 + s * 1.3) - 0.5) * 0.0015;
}

// Horizontal offset of a tendril from its head at a given depth. The main
// strand fans out in a cone; forks follow it down to `fork`, then drift away.
float strandX(float down, float len, float width, float dir, float fork, float drift, float si, float sj) {
    float u = clamp(down / len, 0.0, 1.0);
    float split = clamp((down - fork) / 0.02, 0.0, 1.0);
    return dir * width * (0.3 + 0.7 * pow(u, 0.7))
         + drift * width * max(0.0, down - fork) / len
         + jag(down, si) + jag(down, sj) * split;
}

// 10 strands x 5 forks of beaded tendrils hanging from `head`.
// grow: 0..1 how far they have propagated down; ts: time since onset.
vec3 tendrils(vec2 p, vec2 head, float width, float len, float seed, float grow, float ts) {
    vec3 col = vec3(0.0);
    float down = head.y - p.y;
    if (down < -0.01 || down > len + 0.01 || abs(p.x - head.x) > width * 2.0 + 0.02) return col;
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        float si = seed + fi * 3.7;
        float dir = (hash11(si) - 0.5) * 2.0;
        float lenI = len * (0.65 + 0.35 * hash11(si + 1.3));
        if (down > lenI + 0.01) continue;
        // Skip the whole strand family when the pixel is far from it.
        float px = head.x + dir * width * (0.3 + 0.7 * pow(clamp(down / lenI, 0.0, 1.0), 0.7));
        if (abs(p.x - px) > width * 0.9 + 0.012) continue;
        for (int j = 0; j < 5; j++) {
            float fj = float(j);
            float sj = si * 1.7 + fj * 11.3;
            float hj = hash11(sj);
            float fork = j == 0 ? 0.0 : lenI * (0.08 + 0.55 * hj);
            if (down < fork - 0.005) continue;
            float lenJ = j == 0 ? lenI : fork + (lenI - fork) * (0.5 + 0.5 * hash11(sj + 2.1));
            if (down > lenJ) continue;
            // Each strand propagates at its own speed, so the front is ragged.
            float gj = clamp(grow / (0.6 + 0.4 * hash11(sj + 4.4)), 0.0, 1.0);
            float reachJ = lenJ * gj;
            float drift = j == 0 ? 0.0 : (hj - 0.5) * 1.6;
            float x = head.x + strandX(down, lenI, width, dir, fork, drift, si, sj);
            float d = abs(p.x - x);
            float u = down / lenJ;
            float w = mix(j == 0 ? 0.0018 : 0.0012, 0.0004, u);
            float m = smoothstep(fork - 0.004, fork + 0.006, down)
                    * (1.0 - smoothstep(lenJ * 0.7, lenJ, down))
                    * (1.0 - smoothstep(reachJ - 0.008, reachJ, down));
            float bead = pow(noise1(down * 70.0 + sj), 6.0);
            float fade = exp(-ts * 3.0 * u);                     // tips fade first
            vec3 tc = mix(SP_RED, SP_DEEP, u);
            col += tc * m * fade * (0.45 * exp(-d * d / (w * w))
                                  + 1.2 * bead * exp(-d * d / (4.0 * w * w))
                                  + 0.04 * exp(-d * d / (25.0 * w * w)));
            // Bright knot at the leading tip, brightest while still growing.
            float tipDown = min(reachJ, lenJ * 0.9);
            if (abs(down - tipDown) < 0.006 && tipDown > fork + 0.01) {
                vec2 tip = vec2(head.x + strandX(tipDown, lenI, width, dir, fork, drift, si, sj), head.y - tipDown);
                vec2 dt = p - tip;
                col += SP_HOT * (gj < 1.0 ? 0.45 : 0.25) * fade * exp(-dot(dt, dt) / 0.000006);
            }
        }
    }
    return col;
}

// One element: round glowing head, streamers shooting up (upLen, upBright),
// tendrils below (len).
vec3 spriteElement(vec2 p, vec2 head, float width, float len, float upLen, float upBright,
                   float seed, float grow, float ts) {
    vec3 col = vec3(0.0);
    vec2 dh = (p - head) / vec2(0.007 + width * 0.1, 0.009);
    col += SP_HOT * 0.7 * exp(-dot(dh, dh));
    vec2 dg = (p - head) / vec2(width * 1.2, 0.05);
    col += SP_RED * 0.15 * exp(-dot(dg, dg));

    float up = p.y - head.y;
    if (upLen > 0.0 && up > -0.01 && up < upLen + 0.01 && abs(p.x - head.x) < width * 1.5 + 0.01) {
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float h = hash11(seed + 90.0 + fi * 2.3);
            float top = upLen * (0.5 + 0.5 * h);
            float u = clamp(up / top, 0.0, 1.0);
            float x = head.x + (h - 0.5) * width * (0.3 + 0.5 * u) + jag(up, seed + fi) * 0.3;
            float d = abs(p.x - x);
            float w = mix(0.0028, 0.0005, u);
            col += mix(SP_HOT, SP_RED, u) * upBright * (1.0 - u) * smoothstep(-0.004, 0.004, up)
                 * (exp(-d * d / (w * w)) + 0.08 * exp(-d * d / (25.0 * w * w)));
        }
    }
    if (len > 0.0) col += tendrils(p, head, width, len, seed, grow, ts);
    return col;
}

// Jellyfish (Image 4 style): broad red canopy, white-hot central trunk, a row
// of elements under the canopy with the middle ones hanging deepest, and a few
// lone filaments trailing from the edges.
vec3 jellyfishSprite(vec2 p, vec2 c, float halfW, float depth, float seed, float grow, float ts) {
    vec3 col = vec3(0.0);
    float env = elemEnv(ts, 0.3);
    float glowEnv = elemEnv(ts * 0.6, 0.3);                     // canopy glow lingers

    // Canopy: bright flattened dome plus a wider haze, with faint striations.
    vec2 dc = (p - c - vec2(0.0, 0.07)) / vec2(halfW * 1.3, 0.09);
    vec2 dh = (p - c - vec2(0.0, 0.06)) / vec2(halfW * 2.0, 0.16);
    float stri = 0.75 + 0.5 * noise1(p.x * 90.0 + seed);
    col += SP_RED * glowEnv * (0.5 * stri * exp(-dot(dc, dc)) + 0.12 * exp(-dot(dh, dh)));

    // Central trunk: wide white-hot column from below the heads up into the canopy.
    float dx = p.x - c.x;
    float ty = clamp((p.y - (c.y - 0.08)) / 0.2, 0.0, 1.0);
    float inTrunk = smoothstep(c.y - 0.12, c.y - 0.06, p.y) * (1.0 - smoothstep(c.y + 0.08, c.y + 0.14, p.y));
    float tw = mix(0.010, 0.003, ty) + jag(p.y, seed) * 0.0;
    col += (SP_HOT * exp(-dx * dx / (tw * tw)) + SP_RED * 0.4 * exp(-dx * dx / (16.0 * tw * tw)))
         * inTrunk * env;

    for (int e = 0; e < 7; e++) {
        float fe = float(e);
        float h = hash11(seed + fe * 4.3);
        float rel = fe / 6.0 * 2.0 - 1.0;                       // -1..1 across the canopy
        vec2 head = vec2(c.x + rel * halfW * 0.85 + (h - 0.5) * halfW * 0.12,
                         c.y + 0.03 * rel * rel + (h - 0.5) * 0.015);
        float len = depth * (1.0 - 0.45 * rel * rel) * (0.85 + 0.2 * h);
        col += spriteElement(p, head, halfW / 7.0 * 2.2, len, 0.03 + 0.03 * h, 0.5, seed + fe * 17.0, grow, ts)
             * elemEnv(ts, h);
    }

    for (int k = 0; k < 4; k++) {
        float fk = float(k);
        float h = hash11(seed + 60.0 + fk * 2.9);
        float side = k < 2 ? -1.0 : 1.0;
        float down = c.y + 0.01 - p.y;
        float len = max(0.001, depth * (0.5 + 0.35 * h) * grow);
        float x = c.x + side * halfW * (0.95 + 0.25 * h) + side * down * 0.05 + jag(down, fk * 9.0 + seed);
        float d = abs(p.x - x);
        float m = smoothstep(0.0, 0.01, down) * (1.0 - smoothstep(len * 0.7, len, down));
        float bead = pow(noise1(down * 70.0 + fk * 3.0 + seed), 6.0);
        col += SP_RED * 0.35 * m * env * (exp(-d * d / 0.0000006) + 2.0 * bead * exp(-d * d / 0.000002));
    }
    return col;
}

// Carrot cluster (Image 5 style): 3-6 separate elements side by side, each with
// a bright column shooting up and a bushy beaded tendril cone below.
vec3 carrotCluster(vec2 p, vec2 c, float halfW, float depth, float seed, float grow, float ts) {
    vec3 col = vec3(0.0);
    vec2 dg = (p - c) / vec2(halfW * 1.3, 0.09);
    col += SP_RED * 0.15 * exp(-dot(dg, dg)) * elemEnv(ts * 0.6, 0.5);
    int count = 3 + int(hash11(seed + 3.3) * 4.0);
    for (int e = 0; e < 6; e++) {
        if (e >= count) break;
        float fe = float(e);
        float h = hash11(seed + fe * 4.3);
        float rel = (fe + 0.5) / float(count) * 2.0 - 1.0;
        vec2 head = vec2(c.x + rel * halfW + (h - 0.5) * halfW * 0.2, c.y + (h - 0.5) * 0.06);
        float len = depth * (0.4 + 0.35 * hash11(seed + fe * 6.1));
        col += spriteElement(p, head, halfW / float(count) * 1.1, len, 0.12 + 0.1 * h, 1.0, seed + fe * 17.0, grow, ts)
             * elemEnv(ts, h);
    }
    return col;
}

// Column sprites: 4-8 long, thin, straight vertical lines, white-hot at the
// knot, red above, crimson below, with beads along them.
vec3 columnSprites(vec2 p, vec2 c, float halfW, float depth, float seed, float grow, float ts) {
    vec3 col = vec3(0.0);
    int count = 4 + int(hash11(seed + 5.5) * 5.0);
    for (int e = 0; e < 8; e++) {
        if (e >= count) break;
        float fe = float(e);
        float h = hash11(seed + fe * 4.3);
        vec2 head = vec2(c.x + (hash11(seed + fe * 2.7) * 2.0 - 1.0) * halfW, c.y + (h - 0.5) * 0.1);
        float upLen = 0.08 + 0.12 * h;
        float downLen = max(0.001, (0.12 + 0.18 * hash11(seed + fe * 8.9)) * grow);
        float dy = p.y - head.y;
        if (dy > upLen + 0.01 || dy < -downLen - 0.01) continue;
        float x = head.x + jag(dy, seed + fe) * 0.4;
        float d = abs(p.x - x);
        float along = dy > 0.0 ? dy / upLen : -dy / downLen;
        float m = 1.0 - smoothstep(0.6, 1.0, along);
        float w = mix(0.0022, 0.0005, clamp(along, 0.0, 1.0));
        float bead = pow(noise1(dy * 70.0 + seed + fe * 5.0), 6.0);
        vec3 lc = dy > 0.0 ? mix(SP_HOT, SP_RED, along) : mix(SP_RED, SP_DEEP, along);
        vec2 dk = (p - head) / vec2(0.006, 0.012);
        col += (lc * m * (0.8 * exp(-d * d / (w * w)) + 1.5 * bead * exp(-d * d / (4.0 * w * w))
                          + 0.06 * exp(-d * d / (25.0 * w * w)))
                + SP_HOT * 0.6 * exp(-dot(dk, dk))) * elemEnv(ts, h);
    }
    return col;
}

// Mountains ------------------------------------------------------------------
// LAYERS ranges, 0 = farthest. Farther ranges are taller on screen, lighter
// and bluer (aerial perspective); nearer ranges are lower and darker. They
// rise into view one after another, farthest first.
const int LAYERS = 4;
const float MOUNTAIN_TOP = 0.41;   // highest any ridge can reach: 0.20 + 0.15 * 1.94 / 1.4 (layer 0)
const vec3 FAR_COL = vec3(0.055, 0.06, 0.085);
const vec3 NEAR_COL = vec3(0.008, 0.009, 0.014);

// Sharp ridgelines from piecewise-linear noise: each octave is a row of
// straight-sided peaks, so the silhouette has crisp, jagged edges.
float ridge(float x, float seed, float base, float amp, float freq) {
    float h = 0.0;
    float a = 1.0;
    float f = freq;
    for (int i = 0; i < 5; i++) {
        float v = 1.0 - abs(noise1(x * f + seed) * 2.0 - 1.0);
        h += a * v * v;                                  // squared: concave flanks, pointed peaks
        a *= 0.5;
        f *= 2.3;
    }
    return base + amp * h / 1.4;
}

// Ridgeline height of layer k at x, including its rise-in offset.
float layerH(int k, float x) {
    float fk = float(k);
    float start = fk * 0.15 * MOUNTAIN_RISE;
    float rise = (1.0 - smoothstep(start, start + 0.5 * MOUNTAIN_RISE, iTime)) * 0.45;
    return ridge(x, 11.0 + fk * 26.0, 0.20 - 0.055 * fk, 0.15 - 0.005 * fk, 1.0 + 0.55 * fk) - rise;
}

// Neon text glow -------------------------------------------------------------
// Modeled on Synthwave '84's "Neon Dreams": only saturated colors glow (white
// and gray text never do), glyphs themselves are left untouched, and the halo
// starts GLOW_GAP pixels away from any glyph so letter edges stay crisp.
float glowSource(vec3 c) {
    float hi = max(c.r, max(c.g, c.b));
    float sat = (hi - min(c.r, min(c.g, c.b))) / max(hi, 1e-3);
    return smoothstep(0.4, 0.7, hi) * smoothstep(0.5, 0.8, sat);
}

// Returns the halo color; `near` is how close (0..1) this pixel is to a glyph.
vec3 textGlow(vec2 uv, out float near) {
    vec2 px = 1.0 / iResolution.xy;
    near = 0.0;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 0.7853982;
        vec3 c = texture(iChannel0, uv + vec2(cos(a), sin(a)) * GLOW_GAP * px).rgb;
        near = max(near, smoothstep(0.35, 0.6, max(c.r, max(c.g, c.b))));
    }
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 16; i++) {
        float fi = float(i);
        float r = GLOW_RADIUS * sqrt((fi + 0.5) / 16.0);
        float a = fi * 2.3999632;                      // golden angle
        vec3 c = texture(iChannel0, uv + vec2(cos(a), sin(a)) * r * px).rgb;
        float w = exp(-2.0 * (r / GLOW_RADIUS) * (r / GLOW_RADIUS));
        sum += c * glowSource(c) * w;
        wsum += w;
    }
    return sum / wsum;
}

// Main -----------------------------------------------------------------------
// Depth slots: slot 0 is behind every range, slot k sits between range k-1
// and range k, slot LAYERS is in front of them all. Ranges in front of a
// strike are backlit (dark silhouette, bright rim); ranges behind it have
// their slopes lit; valley mist near the strike's depth glows.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 term = texture(iChannel0, uv);

    vec2 suv = uv;
    if (FLIP_Y) suv.y = 1.0 - suv.y;
    float aspect = iResolution.x / iResolution.y;
    vec2 p = vec2(suv.x * aspect, suv.y);                 // y up, 0 at bottom
    float px1 = 1.0 / iResolution.y;                      // one pixel: crisp, antialiased edges

    // Which lightning window are we in, and does it strike?
    float n = floor(iTime / WINDOW);
    float nh = mod(n, 997.0);                            // small hash input: stays precise
    // Sprites: exactly one per block of ~SPRITE_EVERY seconds, in a window a
    // third to two thirds of the way through, so consecutive sprites land
    // 3-6 minutes apart. A sprite always rides on a strike early in its
    // window, leaving the rest of the window for it to play out.
    float blockLen = floor(SPRITE_EVERY / WINDOW);
    float blk = floor(n / blockLen);
    float spriteWin = blk * blockLen + floor(blockLen / 3.0)
                    + floor(hash21(vec2(mod(blk, 997.0), 72.0)) * floor(blockLen / 3.0));
    bool spriteNow = n == spriteWin;
    // Unfocused frames (no animation loop) stay calm, so the last frame drawn
    // when the window loses focus can never freeze mid-flash.
    float focused = iFocus != 0 ? 1.0 : 0.0;
    float hasStrike = focused * (spriteNow ? 1.0 : step(hash21(vec2(nh, 1.0)), STRIKE_CHANCE));
    float t = iTime - n * WINDOW - (spriteNow ? 0.3 : WINDOW - 1.5) * hash21(vec2(nh, 2.0));
    float env = hasStrike * strokes(t);
    // Scene lighting = the flicker plus a ~1s afterglow, so the sky, clouds and
    // mountains ease back to dark instead of snapping off.
    float light = env + AFTERGLOW * hasStrike * (t > 0.0 ? exp(-t * 3.0) : 0.0);
    float x0 = (0.15 + 0.7 * hash21(vec2(nh, 3.0))) * aspect;
    float nearBolt = exp(-abs(p.x - x0) * 2.5);
    int boltSlot = BOLT_SLOT >= 0 ? BOLT_SLOT : int(hash21(vec2(nh, 60.0)) * float(LAYERS + 1));
    int spriteSlot = SPRITE_SLOT >= 0 ? SPRITE_SLOT : int(hash21(vec2(nh, 61.0)) * float(LAYERS + 1));
    float boltDepth = float(boltSlot) - 0.5;             // in layer units; -0.5 = behind all

    // Pixels above the tallest possible peak skip all mountain math.
    bool inMountains = p.y < MOUNTAIN_TOP;
    float h[LAYERS + 1];
    for (int k = 0; k < LAYERS; k++) h[k] = inMountains ? layerH(k, p.x) : -1.0;
    h[LAYERS] = -1.0;

    vec3 sky = vec3(0.0);

    // Faint glow low in the sky so the dark silhouettes read against it.
    sky += vec3(0.02, 0.025, 0.045) * (1.0 - smoothstep(0.1, 0.55, p.y));

    // Storm clouds along the top: nearly invisible until lightning lights them.
    float cloud = smoothstep(0.35, 0.8, fbm(p * 2.5 + vec2(mod(iTime * 0.01, 256.0), 0.0)))
                * smoothstep(0.4, 1.0, p.y);
    sky += cloud * (vec3(0.015, 0.018, 0.03) + vec3(0.55, 0.58, 0.75) * light * (0.3 + 0.7 * nearBolt));

    // Lightning: main channel plus a few forks. A strike in slot k > 0 comes
    // down onto the slope of range k-1, just behind it; farther strikes are
    // dimmer, as if seen through more rain and haze.
    vec3 boltCol = vec3(0.0);
    if (env > 0.002) {
        float seed = hash21(vec2(nh, 70.0)) * 50.0;        // small: keeps bolt hashes precise
        float yEnd;
        if (boltSlot > 0) {
            float xe = boltX(layerH(boltSlot - 1, x0), x0, seed);
            yEnd = layerH(boltSlot - 1, xe) - 0.015 - 0.04 * hash21(vec2(nh, 4.0));
        } else {
            yEnd = 0.05 + 0.15 * hash21(vec2(nh, 4.0));
        }
        float bolt = boltGlow(abs(p.x - boltX(p.y, x0, seed)), 0.0025)
                   * smoothstep(yEnd - 0.02, yEnd + 0.03, p.y);
        for (int b = 0; b < 3; b++) {
            float fb = float(b);
            float yb = mix(0.95, yEnd + 0.1, hash21(vec2(nh, 5.0 + fb)));
            float len = 0.1 + 0.2 * hash21(vec2(nh, 8.0 + fb));
            float dir = (hash21(vec2(nh, 11.0 + fb)) - 0.5) * 1.6;
            float bx = boltX(yb, x0, seed) + (yb - p.y) * dir
                     + (noise1(p.y * 30.0 + fb * 11.0 + seed) - 0.5) * 0.02;
            float along = (yb - p.y) / len;               // 0 at the fork, 1 at the tip
            float m = step(0.0, along) * (1.0 - smoothstep(0.6, 1.0, along));
            bolt += 0.6 * (1.0 - along) * m * boltGlow(abs(p.x - bx), 0.0015);
        }
        float depthDim = mix(0.45, 1.0, float(boltSlot) / float(LAYERS));
        boltCol = vec3(0.8, 0.85, 1.0) * bolt * env * depthDim;
        if (boltSlot > 0) {
            vec2 di = (p - vec2(boltX(yEnd, x0, seed), yEnd)) / vec2(0.03, 0.015);
            boltCol += vec3(0.9, 0.92, 1.0) * 0.5 * env * depthDim * exp(-dot(di, di));  // impact flash
        }
    }
    sky += vec3(0.35, 0.38, 0.5) * FLASH * light * (0.4 + 0.6 * nearBolt);

    // Red sprite: one sprite anywhere across the sky right after a strike.
    vec3 spriteCol = vec3(0.0);
    float spriteNear = 0.0;
    float spriteEvent = spriteNow ? focused : 0.0;
    if (spriteEvent > 0.5 && t > 0.0 && t < 2.0 * SPRITE_SLOWMO) {
        float ts = (t - 0.03) / SPRITE_SLOWMO;
        float grow = smoothstep(0.0, 0.12, ts);                // tendrils shoot down over ~0.1s
        float seed = hash21(vec2(nh, 71.0)) * 100.0;       // small: keeps sprite hashes precise
        float halfW = 0.2 + 0.08 * hash21(vec2(nh, 20.0));
        vec2 sc = vec2((0.2 + 0.6 * hash21(vec2(nh, 30.0))) * aspect,
                       0.72 + 0.06 * hash21(vec2(nh, 40.0)));
        float depth = sc.y - 0.08;                             // tips reach near the bottom

        int type = SPRITE_TYPE;
        if (type < 0) {
            float r = hash21(vec2(nh, 50.0));
            type = r < 0.5 ? 0 : (r < 0.8 ? 1 : 2);
        }
        if (type == 0) spriteCol = jellyfishSprite(p, sc, halfW, depth, seed, grow, ts);
        else if (type == 1) spriteCol = carrotCluster(p, sc, halfW, depth, seed, grow, ts);
        else spriteCol = columnSprites(p, sc, halfW, depth, seed, grow, ts);
        spriteCol *= 1.3;

        // Red light on the clouds around it and a faint glow low in the sky.
        float spriteGlow = elemEnv(ts * 0.6, 0.5);
        spriteNear = spriteGlow * exp(-abs(p.x - sc.x) * 2.0);
        sky += cloud * SP_RED * 0.6 * spriteGlow * exp(-abs(p.x - sc.x) * 3.0);
        float gx = (p.x - sc.x) / (halfW * 2.0);
        float gy = (p.y - 0.06) / 0.06;
        sky += SP_RED * 0.05 * spriteGlow * exp(-gx * gx - gy * gy);
    }

    // Composite back to front: sky, then each range, inserting the strike and
    // the sprite at their depth slots.
    float rock = inMountains ? 0.25 + 0.75 * fbm(p * vec2(9.0, 16.0)) : 0.0;
    vec3 scene = term.rgb + sky;
    if (boltSlot == 0) scene += boltCol;
    if (spriteSlot == 0) scene += spriteCol;
    float cover = 0.0;
    for (int k = 0; k < (inMountains ? LAYERS : 0); k++) {
        float fk = float(k);
        float m = clamp((h[k] - p.y) / px1, 0.0, 1.0);
        float rim = exp(-max(h[k] - p.y, 0.0) / 0.004);         // clamped: no overflow above the ridge
        float mist = exp(-max(p.y - h[k + 1], 0.0) / 0.035);    // pools at the foot of each range
        vec3 c = mix(FAR_COL, NEAR_COL, fk / float(LAYERS - 1));

        // Valley mist in front of this range glows when the strike is near its depth.
        float mistLight = light * exp(-abs(fk + 0.5 - boltDepth) * 1.2) * (0.3 + 0.7 * nearBolt);
        c += (vec3(0.03, 0.035, 0.05) + vec3(0.35, 0.38, 0.5) * mistLight) * mist * MIST;

        // Strike behind this range: rim-light its ridge. In front: light its slopes.
        if (k >= boltSlot) {
            c += vec3(0.5, 0.55, 0.75) * light * (0.3 + 0.7 * nearBolt) * rim / (1.0 + (fk - boltDepth - 0.5) * 0.8);
        } else {
            c += vec3(0.5, 0.55, 0.72) * light * (0.25 + 0.75 * nearBolt) * rock / (1.0 + (boltDepth - 0.5 - fk) * 1.5);
        }
        // Same for the sprite's red light.
        if (k >= spriteSlot) {
            c += SP_RED * 0.5 * spriteNear * rim / (1.0 + float(k - spriteSlot) * 0.8);
        } else {
            c += SP_RED * 0.12 * spriteNear * rock / (1.0 + float(spriteSlot - 1 - k) * 1.5);
        }

        scene = mix(scene, c, m);
        cover = max(cover, m);
        if (boltSlot == k + 1) scene += boltCol;
        if (spriteSlot == k + 1) scene += spriteCol;
    }
    if (!inMountains) {                                  // no ranges here: add what they'd have layered
        if (boltSlot > 0) scene += boltCol;
        if (spriteSlot > 0) scene += spriteCol;
    }

    // Only paint the background: text pixels are left untouched. Mountains and
    // bright effects are drawn opaque, so a translucent window doesn't wash
    // them out.
    // Background = dark, neutral pixels (the terminal's near-black). Text and
    // colored cells (themed prompt bars, diff lines, selections) stay as drawn.
    float lum = dot(term.rgb, vec3(0.299, 0.587, 0.114));
    float chroma = max(term.r, max(term.g, term.b)) - min(term.r, min(term.g, term.b));
    float bgMask = (1.0 - smoothstep(0.08, 0.35, lum)) * (1.0 - smoothstep(0.04, 0.10, chroma));
    vec3 fx = boltCol + spriteCol;
    float fxA = clamp(max(fx.r, max(fx.g, fx.b)) * 2.0, 0.0, 1.0);
    vec3 outRGB = mix(term.rgb, min(scene, vec3(1.0)), bgMask);
    float outA = max(term.a, max(cover, fxA) * bgMask);
    if (GLOW > 0.0) {
        // Halo only on empty background, never on glyphs, and not right at their edges.
        float near;
        vec3 g = textGlow(uv, near) * GLOW * bgMask * (1.0 - near);
        outRGB = min(outRGB + g, vec3(1.0));
        outA = max(outA, min(max(g.r, max(g.g, g.b)) * 2.0, 1.0));
    }
    fragColor = vec4(outRGB, outA);
}
