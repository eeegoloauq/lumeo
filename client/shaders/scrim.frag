#version 460 core

// ArtworkScrim in one pass: the three washes and the grain over them.
// Stacked as widgets they were four full-banner draws and an offscreen layer
// on every frame the banner moved, which a laptop GPU cannot afford.

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
// Palette.page, which the washes fade into.
uniform vec3 uGround;

out vec4 fragColor;

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
  vec2 pos = FlutterFragCoord().xy;
  vec2 uv = pos / uSize;

  // The horizontal wash under the type, from the left edge.
  float left = uv.x > 0.28 ? ramp(uv.x, 0.28, 0.58, 0.70, 0.0)
                           : ramp(uv.x, 0.0, 0.28, 0.94, 0.70);
  // The right-hand edge, lightly.
  float right = ramp(uv.x, 0.72, 1.0, 0.0, 0.34);
  // The fall into the page: a shade at the top under the bar, clear through
  // the picture, then a smoothstep that reaches the page at the banner's edge.
  float fall = uv.y < 0.26 ? ramp(uv.y, 0.0, 0.26, 0.50, 0.0)
                           : smoothstep(0.45, 0.995, uv.y);
  float alpha = 1.0 - (1.0 - left) * (1.0 - right) * (1.0 - fall);

  // The grain: one part in forty, only where the fall has bands to break up.
  float mask = uv.y < 0.92 ? ramp(uv.y, 0.30, 0.50, 0.0, 1.0)
                           : ramp(uv.y, 0.92, 1.0, 1.0, 0.0);
  float grain = 0.025 * mask * noise(floor(pos));

  // Premultiplied ground at `alpha` plus the grain as light: under
  // source-over the grain adds to whatever is below, which is what keeps it
  // from ever darkening the artwork.
  fragColor = vec4(uGround * alpha + grain, alpha);
}
