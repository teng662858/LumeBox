#include <flutter/runtime_effect.glsl>

// The image-filter API supplies these two uniforms. Canvas tests supply them
// explicitly, exercising the same optical code on the Skia test renderer.
uniform vec2 u_size;
uniform float u_strength;
uniform float u_dispersion;
uniform float u_highlight;
// Capsule bounds in the input canvas, updated with layout and pixel density.
uniform vec4 u_lens;
// Directional stretch, vertical grip and pressure, sampled from the gesture.
uniform vec3 u_motion;
uniform sampler2D u_backdrop;

out vec4 fragColor;

vec2 textureUV(vec2 uv) {
  vec2 halfPixel = vec2(0.5) / u_size;
  uv = clamp(uv, halfPixel, vec2(1.0) - halfPixel);
  // BackdropFilter already supplies an oriented backdrop on the GLES path.
  // Flipping again samples the page header instead of the dock's live glyphs.
  return uv;
}

void main() {
  vec2 coord = FlutterFragCoord().xy;
  vec2 uv = (coord - u_lens.xy) / u_lens.zw;
  float aspect = max(u_lens.z / u_lens.w, 1.0);
  vec2 p = (uv - 0.5) * 2.0 * vec2(aspect, 1.0);
  vec2 axis = vec2(clamp(p.x, -aspect + 1.0, aspect - 1.0), 0.0);
  vec2 radial = p - axis;
  float radius = clamp(length(radial), 0.0, 1.0);
  vec2 normal = radial / max(length(radial), 0.0001);
  vec2 metric = vec2(1.0 / aspect, 1.0);
  float rim = smoothstep(0.50, 1.0, radius);

  // A curved lens magnifies the center and bends the sample increasingly near
  // its rim. Horizontal/vertical displacement has the same physical scale.
  float zoom = 1.0 + u_strength * (1.0 - 0.38 * radius * radius);
  vec2 refracted = 0.5 + (uv - 0.5) / zoom;
  refracted -= normal * metric * u_strength * rim * rim * 0.16;
  // Vary curvature near the rim while keeping the center sharp and stable.
  float edgeBend = u_strength * rim * rim;
  refracted.x -= u_motion.x * edgeBend * 0.10 * (1.0 - abs(normal.y) * 0.35);
  refracted.y -= u_motion.y * u_motion.z * edgeBend * 0.08;
  vec2 chroma = normal * metric * u_dispersion * rim * rim;

  vec2 sampleUV = (u_lens.xy + refracted * u_lens.zw) / u_size;
  chroma *= u_lens.zw / u_size;
  vec4 color = texture(u_backdrop, textureUV(sampleUV));
  color.r = texture(u_backdrop, textureUV(sampleUV + chroma)).r;
  color.b = texture(u_backdrop, textureUV(sampleUV - chroma)).b;

  // Restrained top-left rim light, preserving premultiplied alpha.
  float light = max(dot(normal, normalize(vec2(-0.45, -0.90))), 0.0);
  float sheen = smoothstep(0.78, 1.0, radius) * light * u_highlight;
  color.rgb = min(vec3(color.a), color.rgb + vec3(sheen * color.a));
  fragColor = color;
}
