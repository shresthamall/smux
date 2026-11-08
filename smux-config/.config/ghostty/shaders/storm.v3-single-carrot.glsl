// Storm: light rain, occasional lightning (multi-stroke flicker + branches,
// lit clouds), and very rare red sprites high above the storm.
// Text pixels are left untouched; only the background is painted.

// Tuning ---------------------------------------------------------------------
const float WINDOW = 6.0;          // seconds per lightning "chance"
const float STRIKE_CHANCE = 0.45;  // chance of a strike in each window (~1 per 13s)
const float SPRITE_CHANCE = 0.45;  // TEMP for tuning: every strike gets sprites (v1 was 0.04)
const float SPRITE_DECAY = 4.0;    // fade speed; higher = shorter (v1 was 7.0)
const float RAIN = 0.16;           // rain brightness
const float FLASH = 0.22;          // full-screen flash brightness
const bool  FLIP_Y = true;         // cmux/Ghostty puts y=0 at the top; flip so y points up

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

// Red sprite -----------------------------------------------------------------
// One "carrot" sprite: a bright head, fine streamers fanning upward, and a
// dense curtain of tendrils hanging down. Tendrils fork off a set of primary
// strands; the whole sprite and every strand narrow toward the bottom, and
// the color shifts from red to violet with depth.
// p: screen coords (y up), c: head position, size: (half-width, height).
const int SPRITE_STRANDS = 12;     // primary strands
const int SPRITE_FORKS = 4;        // strands per primary incl. itself -> 48 tendrils

vec3 redSprite(vec2 p, vec2 c, vec2 size, float seed) {
    const vec3 RED = vec3(1.0, 0.22, 0.16);
    const vec3 CORE = vec3(1.0, 0.55, 0.45);
    const vec3 VIOLET = vec3(0.45, 0.25, 1.0);
    vec3 col = vec3(0.0);
    vec2 q = (p - c) / size;       // q.x: -1..1 across the head; q.y: -1 at the tips
    float down = -q.y;             // 0 at the head, 1 at the longest tips
    float taper = 1.0 - 0.6 * clamp(down, 0.0, 1.0); // carrot outline

    // Head: bright core in a soft red glow, faint halo just above.
    col += CORE * 0.6 * exp(-(q.x * q.x * 6.0 + q.y * q.y * 400.0));
    col += RED * 0.22 * exp(-(q.x * q.x * 2.0 + q.y * q.y * 120.0));
    float hy = q.y - 0.18;
    col += RED * 0.07 * exp(-(q.x * q.x * 0.6 + hy * hy * 300.0));

    // Faint diffuse glow filling the tendril curtain.
    float bx = q.x / taper;
    col += RED * 0.05 * exp(-bx * bx * 1.5) * smoothstep(0.0, 0.05, down) * (1.0 - smoothstep(0.3, 0.9, down));

    // Crown: fine streamers fanning upward, thinning toward their tops.
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        float h = hash11(seed + fi * 3.1);
        float top = 0.08 + 0.14 * h;
        float u = clamp(q.y / top, 0.0, 1.0);
        float x = (h - 0.5) * 0.9 * (0.3 + u) + 0.04 * sin(u * 6.0 + fi);
        float d = (q.x - x) * size.x;
        float w = mix(0.003, 0.0006, u);
        float m = smoothstep(-0.01, 0.01, q.y) * (1.0 - smoothstep(0.6 * top, top, q.y));
        col += RED * 0.45 * m * exp(-d * d / (w * w));
    }

    // Tendrils: primaries hang from the head; forks split off at random depths
    // and drift sideways. Thick and red at the top, hair-thin and violet at the tip.
    for (int i = 0; i < SPRITE_STRANDS; i++) {
        float fi = float(i);
        float h = hash11(seed + 17.0 + fi * 5.3);
        float base = (fi + 0.5) / float(SPRITE_STRANDS) * 1.6 - 0.8 + (h - 0.5) * 0.08;
        float start = 0.03 * hash11(seed + 23.0 + fi);  // ragged top edge, no flat shelf
        for (int j = 0; j < SPRITE_FORKS; j++) {
            float fj = float(j);
            float hj = hash11(seed + fi * 7.7 + fj * 1.9 + 41.0);
            float fork = j == 0 ? 0.0 : 0.08 + 0.4 * hj;   // depth where this strand splits off
            float len = j == 0 ? 0.8 + 0.2 * h : min(1.0, fork + 0.3 + 0.5 * hj);
            float div = (hj - 0.5) * 0.9;                   // sideways drift after the fork
            float x = (base + max(0.0, down - fork) * div) * taper
                    + 0.025 * sin(down * 11.0 + fi * 1.7 + fj * 2.3);
            float d = (q.x - x) * size.x;
            float u = clamp(down / len, 0.0, 1.0);          // 0 at the head, 1 at the tip
            float w = mix(j == 0 ? 0.0035 : 0.0022, 0.0005, u);
            float m = smoothstep(start - 0.01, start + 0.04, down)
                    * smoothstep(fork, fork + 0.04, down)
                    * (1.0 - smoothstep(0.55 * len, len, down));
            vec3 tc = mix(RED, VIOLET, smoothstep(0.25, 0.9, down));
            float bright = (j == 0 ? 0.5 : 0.35) * (1.0 - 0.5 * u);
            col += tc * bright * m * (exp(-d * d / (w * w)) + 0.06 * exp(-d * d / (16.0 * w * w)));
        }
    }
    return col;
}

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

    vec3 col = vec3(0.0);

    // Storm clouds along the top: nearly invisible until lightning lights them.
    float cloud = smoothstep(0.35, 0.8, fbm(p * 2.5 + vec2(iTime * 0.01, 0.0)))
                * smoothstep(0.4, 1.0, p.y);
    col += cloud * (vec3(0.015, 0.018, 0.03) + vec3(0.55, 0.58, 0.75) * env * (0.3 + 0.7 * nearBolt));

    // Rain (three depth layers), catching the light during flashes.
    float rain = rainLayer(p, 60.0, 1.4, 0.25, 1.0)
               + 0.6 * rainLayer(p, 90.0, 1.0, 0.2, 2.0)
               + 0.35 * rainLayer(p, 140.0, 0.7, 0.15, 3.0);
    col += vec3(0.55, 0.62, 0.8) * rain * RAIN * (1.0 + 3.0 * env);

    // Lightning: main channel plus a few forks.
    if (env > 0.002) {
        float seed = n * 3.3;
        float yEnd = 0.1 + 0.35 * hash21(vec2(n, 4.0));
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
        col += vec3(0.8, 0.85, 1.0) * bolt * env;
        col += vec3(0.35, 0.38, 0.5) * FLASH * env * (0.4 + 0.6 * nearBolt);
    }

    // Red sprite: rare, one sprite anywhere across the sky right after a strike.
    float spriteEvent = hasStrike * step(hash21(vec2(n, 14.0)), SPRITE_CHANCE / STRIKE_CHANCE);
    if (spriteEvent > 0.5 && t > 0.0 && t < 1.5) {
        float k = hash21(vec2(n, 20.0));
        vec2 size = vec2(0.12 + 0.06 * k, 0.66 + 0.06 * k);  // tips reach ~0.1 from the bottom
        vec2 c = vec2((0.1 + 0.8 * hash21(vec2(n, 30.0))) * aspect,
                      0.76 + 0.08 * hash21(vec2(n, 40.0)));
        float ts = t - 0.03;
        float e = ts > 0.0 ? smoothstep(0.0, 0.02, ts) * exp(-ts * SPRITE_DECAY) : 0.0;
        col += redSprite(p, c, size, n * 7.0) * e * 1.4;
    }

    // Only paint the background: fade the effect out as pixels get brighter.
    float lum = dot(term.rgb, vec3(0.299, 0.587, 0.114));
    float bgMask = 1.0 - smoothstep(0.08, 0.35, lum);
    fragColor = vec4(term.rgb + min(col, vec3(1.0)) * bgMask, term.a);
}
