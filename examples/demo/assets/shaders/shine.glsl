// Shine: a bright band sweeping across the sprite every few seconds (used by prefabs/big_coin.scene).
// PARAMS.x = seconds between sweeps, PARAMS.y = band width (in frames), PARAM_COLOR = band color (alpha = strength).
vec4 effect(vec4 color, vec2 uv) {
    vec4 c = texel(uv) * color;
    vec2 local = (uv - FRAME_RECT.xy) / (FRAME_RECT.zw - FRAME_RECT.xy); // 0..1 inside the current frame
    float period = max(PARAMS.x, 0.1);
    float t = mod(TIME, period) / period * 3.0 - 1.0; // the band crosses the frame in the first third
    float d = abs(local.x + local.y * 0.5 - t);
    float band = 1.0 - smoothstep(0.0, max(PARAMS.y, 0.01), d);
    c.rgb = mix(c.rgb, PARAM_COLOR.rgb, band * PARAM_COLOR.a);
    return c;
}
