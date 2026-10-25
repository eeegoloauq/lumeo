#version 440

// The washes that turn a frame we do not control into a page, and the grain
// over them, in one pass: stacked gradients and a grain layer stuttered
// scrolling on laptop GPUs. A horizontal wash gives the type a ground, a
// light one on the right dims the frame's brightest half, and a vertical one
// hands the page an edge.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    // Tokens.page, which the washes fade into.
    vec4 ground;
};

// A ramp of opacity between two stops, flat outside them.
float ramp(float t, float from, float to, float a, float b) {
    return mix(a, b, clamp((t - from) / (to - from), 0.0, 1.0));
}

// Per-pixel white noise in [0, 1) without sin(), which loses precision on
// some GPUs at large coordinates.
float noise(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    vec2 uv = qt_TexCoord0;

    // The horizontal wash under the type, from the left edge.
    float left = uv.x > 0.28 ? ramp(uv.x, 0.28, 0.58, 0.70, 0.0)
                             : ramp(uv.x, 0.0, 0.28, 0.94, 0.70);
    // The right-hand edge, lightly.
    float right = ramp(uv.x, 0.72, 1.0, 0.0, 0.34);
    // The fall into the page: a shade at the top under the bar, clear through
    // the picture, then a smoothstep, because a linear ramp's knee reads as a
    // line on black. It reaches the page at the banner's own edge.
    float fall = uv.y < 0.26 ? ramp(uv.y, 0.0, 0.26, 0.50, 0.0)
                             : smoothstep(0.45, 0.995, uv.y);
    float alpha = 1.0 - (1.0 - left) * (1.0 - right) * (1.0 - fall);

    // Eight bits cannot express a fall this long on black, so one part in
    // forty of grain turns the bands into texture, only where the fall has
    // bands, per device pixel.
    float mask = uv.y < 0.92 ? ramp(uv.y, 0.30, 0.50, 0.0, 1.0)
                             : ramp(uv.y, 0.92, 1.0, 1.0, 0.0);
    float grain = 0.025 * mask * noise(floor(gl_FragCoord.xy));

    // Premultiplied ground at `alpha` plus the grain as light: blended over
    // the artwork the grain adds to it, so it never darkens the picture and
    // solid black stays black.
    fragColor = vec4(ground.rgb * alpha + grain, alpha) * qt_Opacity;
}
