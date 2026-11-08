// Storm: light rain, occasional lightning (multi-stroke flicker + branches,
// lit clouds), and very rare red sprites high above the storm.
// Text pixels are left untouched; only the background is painted.

// Tuning ---------------------------------------------------------------------
const float WINDOW = 6.0;          // seconds per lightning "chance"
const float STRIKE_CHANCE = 0.45;  // chance of a strike in each window (~1 per 13s)
const float SPRITE_CHANCE = 0.45;  // TEMP for tuning: every strike gets sprites (v1 was 0.04)
const float SPRITE_DECAY = 4.0;    // fade speed; higher = shorter (v1 was 7.0)
const int   SPRITE_TYPE = -1;      // -1 random, 0 jellyfish, 1 carrot cluster, 2 columns
const float SPRITE_SLOWMO = 3.0;   // TEMP for tuning: plays sprites 3x slower (1.0 = real speed)
const float RAIN = 0.16;           // rain brightness
const float FLASH = 0.22;          // full-screen flash brightness
const bool  FLIP_Y = true;         // cmux/Ghostty puts y=0 at the top; flip so y points up
const float FRONT_CHANCE = 0.5;    // share of strikes / sprites in front of the mountains
const float MOUNTAIN_RISE = 6.0;   // seconds for the mountains to rise into view

// Noise ----------------------------------------------------------------------
float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

// Linear-interpolated value noise: piecewise straight segments = jagged bolts.
float noise1(float x) {
    float i = floor(x);
    return mix(hash11(i), hash11(i + 1.0), fract(x));
}

float noise2(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * noise2(p);
        p *= 2.03;
        a *= 0.5;
    }
    return v;
}

// Rain -----------------------------------------------------------------------
// Columns of sparse falling streaks; bright head at the bottom, fading tail.
float rainLayer(vec2 p, float cols, float speed, float len, float seed) {
    p.x += p.y * 0.12;                                    // wind slant
    float col = floor(p.x * cols);
    float h = hash11(col * 1.37 + seed);
    float fx = fract(p.x * cols) - 0.5 - (h - 0.5) * 0.6;
    float y = (p.y + iTime * speed * (0.8 + 0.4 * h)) * cols * 0.08 + h * 17.0;
    float seg = floor(y);
    float f = fract(y);
    float exists = step(0.6, hash11(col * 7.13 + seg * 3.7 + seed)); // sparse = light rain
    float streak = (1.0 - f / len) * step(f, len);
    return exists * streak * exp(-fx * fx / 0.004);
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

float farRidge(float x) { return ridge(x, 11.0, 0.15, 0.22, 1.3); }   // peaks up to ~35%
float nearRidge(float x) { return ridge(x, 37.0, 0.04, 0.18, 2.0); }  // peaks up to ~20%

// Main -----------------------------------------------------------------------
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 term = texture(iChannel0, uv);

    vec2 suv = uv;
    if (FLIP_Y) suv.y = 1.0 - suv.y;
    float aspect = iResolution.x / iResolution.y;
    vec2 p = vec2(suv.x * aspect, suv.y);                 // y up, 0 at bottom

    // Which lightning window are we in, and does it strike?
    float n = floor(iTime / WINDOW);
    float hasStrike = step(hash21(vec2(n, 1.0)), STRIKE_CHANCE);
    float t = iTime - n * WINDOW - hash21(vec2(n, 2.0)) * (WINDOW - 1.5);
    float env = hasStrike * strokes(t);
    float x0 = (0.15 + 0.7 * hash21(vec2(n, 3.0))) * aspect;
    float nearBolt = exp(-abs(p.x - x0) * 2.5);
    bool boltFront = hash21(vec2(n, 60.0)) < FRONT_CHANCE;
    bool spriteFront = hash21(vec2(n, 61.0)) < FRONT_CHANCE;

    // Mountains rise into view over the first few seconds of a terminal.
    float rise = (1.0 - smoothstep(0.0, MOUNTAIN_RISE, iTime)) * 0.4;
    float farH = farRidge(p.x) - rise;
    float nearH = nearRidge(p.x) - rise;
    float px1 = 1.0 / iResolution.y;                      // one pixel: crisp, antialiased edges
    float farM = clamp((farH - p.y) / px1, 0.0, 1.0);
    float nearM = clamp((nearH - p.y) / px1, 0.0, 1.0);

    vec3 sky = vec3(0.0);       // behind the mountains (added to the theme background)
    vec3 front = vec3(0.0);     // in front of the mountains
    float backLight = 0.0;      // lightning behind the ridges: rim-lights them
    float faceLight = 0.0;      // lightning in front: lights the slopes
    vec3 redRim = vec3(0.0);    // sprite light on ridges / slopes
    vec3 redFace = vec3(0.0);

    // Faint glow low in the sky so the dark silhouettes read against it.
    sky += vec3(0.02, 0.025, 0.045) * (1.0 - smoothstep(0.1, 0.55, p.y));

    // Storm clouds along the top: nearly invisible until lightning lights them.
    float cloud = smoothstep(0.35, 0.8, fbm(p * 2.5 + vec2(iTime * 0.01, 0.0)))
                * smoothstep(0.4, 1.0, p.y);
    sky += cloud * (vec3(0.015, 0.018, 0.03) + vec3(0.55, 0.58, 0.75) * env * (0.3 + 0.7 * nearBolt));

    // Rain (three depth layers), catching the light during flashes. Always in front.
    float rain = rainLayer(p, 60.0, 1.4, 0.25, 1.0)
               + 0.6 * rainLayer(p, 90.0, 1.0, 0.2, 2.0)
               + 0.35 * rainLayer(p, 140.0, 0.7, 0.15, 3.0);
    front += vec3(0.55, 0.62, 0.8) * rain * RAIN * (1.0 + 3.0 * env);

    // Lightning: main channel plus a few forks. Strikes in front of the
    // mountains hit the near slope; strikes behind them end out of sight.
    if (env > 0.002) {
        float seed = n * 3.3;
        float yEnd;
        if (boltFront) {
            float xe = boltX(nearRidge(x0), x0, seed);
            yEnd = nearRidge(xe) - rise - 0.02 - 0.05 * hash21(vec2(n, 4.0));
        } else {
            yEnd = 0.05 + 0.15 * hash21(vec2(n, 4.0));
        }
        float bolt = boltGlow(abs(p.x - boltX(p.y, x0, seed)), 0.0025)
                   * smoothstep(yEnd - 0.02, yEnd + 0.03, p.y);
        for (int b = 0; b < 3; b++) {
            float fb = float(b);
            float yb = mix(0.95, yEnd + 0.1, hash21(vec2(n, 5.0 + fb)));
            float len = 0.1 + 0.2 * hash21(vec2(n, 8.0 + fb));
            float dir = (hash21(vec2(n, 11.0 + fb)) - 0.5) * 1.6;
            float bx = boltX(yb, x0, seed) + (yb - p.y) * dir
                     + (noise1(p.y * 30.0 + fb * 11.0 + seed) - 0.5) * 0.02;
            float along = (yb - p.y) / len;               // 0 at the fork, 1 at the tip
            float m = step(0.0, along) * (1.0 - smoothstep(0.6, 1.0, along));
            bolt += 0.6 * (1.0 - along) * m * boltGlow(abs(p.x - bx), 0.0015);
        }
        vec3 boltCol = vec3(0.8, 0.85, 1.0) * bolt * env;
        sky += vec3(0.35, 0.38, 0.5) * FLASH * env * (0.4 + 0.6 * nearBolt);
        if (boltFront) {
            front += boltCol;
            vec2 di = (p - vec2(boltX(yEnd, x0, seed), yEnd)) / vec2(0.03, 0.015);
            front += vec3(0.9, 0.92, 1.0) * 0.5 * env * exp(-dot(di, di));   // impact flash
            faceLight = env * (0.25 + 0.75 * nearBolt);
        } else {
            sky += boltCol;
            backLight = env * (0.3 + 0.7 * nearBolt);
        }
    }

    // Red sprite: one sprite anywhere across the sky right after a strike.
    float spriteEvent = hasStrike * step(hash21(vec2(n, 14.0)), SPRITE_CHANCE / STRIKE_CHANCE);
    if (spriteEvent > 0.5 && t > 0.0 && t < 2.0 * SPRITE_SLOWMO) {
        float ts = (t - 0.03) / SPRITE_SLOWMO;
        float grow = smoothstep(0.0, 0.12, ts);                // tendrils shoot down over ~0.1s
        float seed = n * 7.0;
        float halfW = 0.2 + 0.08 * hash21(vec2(n, 20.0));
        vec2 sc = vec2((0.2 + 0.6 * hash21(vec2(n, 30.0))) * aspect,
                       0.72 + 0.06 * hash21(vec2(n, 40.0)));
        float depth = sc.y - 0.08;                             // tips reach near the bottom

        int type = SPRITE_TYPE;
        if (type < 0) {
            float r = hash21(vec2(n, 50.0));
            type = r < 0.5 ? 0 : (r < 0.8 ? 1 : 2);
        }
        vec3 sp;
        if (type == 0) sp = jellyfishSprite(p, sc, halfW, depth, seed, grow, ts);
        else if (type == 1) sp = carrotCluster(p, sc, halfW, depth, seed, grow, ts);
        else sp = columnSprites(p, sc, halfW, depth, seed, grow, ts);

        // Red light on the clouds around it and a faint glow low in the sky.
        float spriteGlow = elemEnv(ts * 0.6, 0.5);
        float spriteNear = spriteGlow * exp(-abs(p.x - sc.x) * 2.0);
        sky += cloud * SP_RED * 0.6 * spriteGlow * exp(-abs(p.x - sc.x) * 3.0);
        float gx = (p.x - sc.x) / (halfW * 2.0);
        float gy = (p.y - 0.06) / 0.06;
        sky += SP_RED * 0.05 * spriteGlow * exp(-gx * gx - gy * gy);

        if (spriteFront) {
            front += sp * 1.3;
            redFace = SP_RED * 0.12 * spriteNear;
        } else {
            sky += sp * 1.3;
            redRim = SP_RED * 0.5 * spriteNear;
        }
    }

    // Mountain shading: dark silhouettes, rim-lit along the ridge by light from
    // behind, craggy slopes lit by strikes in front.
    float rock = 0.25 + 0.75 * fbm(p * vec2(9.0, 16.0));
    float rimFar = exp(-max(farH - p.y, 0.0) / 0.004);    // clamped: no overflow above the ridge
    float rimNear = exp(-max(nearH - p.y, 0.0) / 0.004);
    vec3 farCol = vec3(0.022, 0.025, 0.04)
                + (vec3(0.5, 0.55, 0.75) * backLight + redRim) * rimFar * 0.8
                + (vec3(0.3, 0.33, 0.45) * faceLight + redFace) * rock * 0.5;
    vec3 nearCol = vec3(0.006, 0.007, 0.012)
                 + (vec3(0.5, 0.55, 0.75) * backLight + redRim) * rimNear * 0.5
                 + (vec3(0.3, 0.33, 0.45) * faceLight + redFace) * rock * 0.8;

    vec3 scene = term.rgb + sky;
    scene = mix(scene, farCol, farM);
    scene = mix(scene, nearCol, nearM);
    scene += front;

    // Only paint the background: text pixels are left untouched.
    float lum = dot(term.rgb, vec3(0.299, 0.587, 0.114));
    float bgMask = 1.0 - smoothstep(0.08, 0.35, lum);
    fragColor = vec4(mix(term.rgb, min(scene, vec3(1.0)), bgMask), term.a);
}
