// Dark iridescent wave behind terminal text.
// Background pixels get a slowly drifting thin-film rainbow, darkened so every
// hue is a deep shade of itself. Bright pixels (text) are left untouched.

const float SPEED = 0.08;    // overall drift speed
const float DARKNESS = 0.22; // peak brightness of the wave (0..1)

// Thin-film style rainbow: phase-shifted cosines per channel.
vec3 iridescence(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 term = texture(iChannel0, uv);

    // Aspect-correct coordinates so the waves aren't stretched.
    vec2 p = uv * vec2(iResolution.x / iResolution.y, 1.0);
    float time = iTime * SPEED;

    // Layered interference pattern = "film thickness".
    float film = sin(p.x * 2.1 + time * 3.0)
               + sin(p.y * 2.7 - time * 2.0)
               + sin((p.x + p.y) * 1.6 + time * 2.5)
               + 0.5 * sin(length(p - vec2(0.8 + 0.3 * sin(time), 0.5)) * 6.0 - time * 4.0);

    vec3 wave = iridescence(film * 0.18 + time) * DARKNESS;

    // Only paint the background: fade the wave out as pixels get brighter.
    float lum = dot(term.rgb, vec3(0.299, 0.587, 0.114));
    float bgMask = 1.0 - smoothstep(0.08, 0.35, lum);

    fragColor = vec4(mix(term.rgb, max(term.rgb, wave), bgMask), term.a);
}
