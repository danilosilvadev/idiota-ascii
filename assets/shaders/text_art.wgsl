// Screen-space text mosaic.
// The 3D scene is a texture. Each cell becomes one glyph from Part 1 Chapter 1,
// colored by that cell, heavier where the pixel is bright, absent where it is dark.

#import bevy_sprite::mesh2d_vertex_output::VertexOutput

// a: cell_w, cell_h, frame_w, frame_h
// b: glyph_w, glyph_h, atlas_w, atlas_h
// c: text_w, text_h, text_len, cols
// d: rows_per_bank, bold_cut, threshold, boost
// e: bloom, gap, enabled, flip_y
struct TextArtParams {
    a: vec4<f32>,
    b: vec4<f32>,
    c: vec4<f32>,
    d: vec4<f32>,
    e: vec4<f32>,
}

@group(2) @binding(0) var scene_tex: texture_2d<f32>;
@group(2) @binding(1) var scene_samp: sampler;
@group(2) @binding(2) var atlas_tex: texture_2d<f32>;
@group(2) @binding(3) var atlas_samp: sampler;
@group(2) @binding(4) var text_tex: texture_2d<f32>;
@group(2) @binding(5) var text_samp: sampler;
@group(2) @binding(6) var<uniform> params: TextArtParams;

fn scene_linear(uv_in: vec2<f32>) -> vec3<f32> {
    let uv = clamp(uv_in, vec2<f32>(0.001), vec2<f32>(0.999));
    return textureSampleLevel(scene_tex, scene_samp, uv, 0.0).rgb;
}

fn to_srgb(linear: vec3<f32>) -> vec3<f32> {
    // Identity through the midtones. Only values past the knee compress,
    // so a lamp pool stays amber instead of blowing out to white.
    let x = max(linear, vec3<f32>(0.0));
    let knee = 0.78;
    let over = max(x - vec3<f32>(knee), vec3<f32>(0.0));
    let mapped = min(x, vec3<f32>(knee)) + (1.0 - knee) * (over / (over + 0.7));
    return pow(clamp(mapped, vec3<f32>(0.0), vec3<f32>(1.0)), vec3<f32>(0.454545));
}

fn luma(srgb: vec3<f32>) -> f32 {
    return dot(srgb, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn grade(srgb: vec3<f32>, boost: f32) -> vec3<f32> {
    let y = luma(srgb);
    // Cool the snow. Leave pixels that are already warm (windows, lamp, lantern) alone.
    let warmth = smoothstep(0.0, 0.12, srgb.r - srgb.b);
    let cool = srgb * vec3<f32>(0.82, 0.92, 1.14);
    let kept = mix(cool, srgb, max(smoothstep(0.08, 0.5, y), warmth));
    return max(kept * boost, vec3<f32>(0.0));
}

fn glow_of(linear: vec3<f32>) -> vec3<f32> {
    let s = to_srgb(linear);
    let y = luma(s);
    let w = smoothstep(0.42, 0.92, y);
    return s * w * w;
}

fn bloom(uv: vec2<f32>) -> vec3<f32> {
    let dims = vec2<f32>(textureDimensions(scene_tex));
    let px = vec2<f32>(12.0, 8.0) / dims;
    var acc = vec3<f32>(0.0);
    acc += glow_of(scene_linear(uv + vec2<f32>(px.x, 0.0)));
    acc += glow_of(scene_linear(uv - vec2<f32>(px.x, 0.0)));
    acc += glow_of(scene_linear(uv + vec2<f32>(0.0, px.y)));
    acc += glow_of(scene_linear(uv - vec2<f32>(0.0, px.y)));
    acc += glow_of(scene_linear(uv + px)) * 0.85;
    acc += glow_of(scene_linear(uv - px)) * 0.85;
    acc += glow_of(scene_linear(uv + vec2<f32>(px.x, -px.y))) * 0.85;
    acc += glow_of(scene_linear(uv + vec2<f32>(-px.x, px.y))) * 0.85;
    let px2 = px * 2.15;
    acc += glow_of(scene_linear(uv + vec2<f32>(px2.x, 0.0))) * 0.55;
    acc += glow_of(scene_linear(uv - vec2<f32>(px2.x, 0.0))) * 0.55;
    acc += glow_of(scene_linear(uv + vec2<f32>(0.0, px2.y))) * 0.55;
    acc += glow_of(scene_linear(uv - vec2<f32>(0.0, px2.y))) * 0.55;
    return acc * 0.11;
}

fn cell_color(uv: vec2<f32>, cell_uv: vec2<f32>) -> vec3<f32> {
    let o = cell_uv * 0.28;
    return (
        scene_linear(uv)
        + scene_linear(uv + vec2<f32>(o.x, 0.0))
        + scene_linear(uv - vec2<f32>(o.x, 0.0))
        + scene_linear(uv + vec2<f32>(0.0, o.y))
        + scene_linear(uv - vec2<f32>(0.0, o.y))
    ) * 0.2;
}

@fragment
fn fragment(in: VertexOutput) -> @location(0) vec4<f32> {
    let cell_size = max(params.a.xy, vec2<f32>(2.0, 2.0));
    let frame = max(params.a.zw, vec2<f32>(1.0, 1.0));
    let pix = in.position.xy;

    // Frag coords and this render target share a top-left origin.
    // F10 (params.e.w) flips the sample if a target comes out inverted.
    var uv = pix / frame;
    if (params.e.w > 0.5) {
        uv.y = 1.0 - uv.y;
    }

    let linear = cell_color(uv, cell_size / frame);
    if (params.e.z < 0.5) {
        return vec4<f32>(linear, 1.0);
    }

    let srgb = to_srgb(linear);
    let y = luma(srgb);
    let boost = params.d.w;
    let graded = grade(srgb, boost);
    let glow = bloom(uv) * params.e.x;

    let cell = vec2<i32>(floor(pix / cell_size));
    let cells_x = max(i32(floor(frame.x / cell_size.x)), 1);
    let linear_i = cell.y * cells_x + cell.x;
    let text_len = max(i32(params.c.z), 1);
    let wrapped = linear_i % text_len;
    let text_w = max(i32(params.c.x), 1);
    let tx = wrapped % text_w;
    let ty = wrapped / text_w;
    let sample = textureLoad(text_tex, vec2<i32>(tx, ty), 0);
    let idx = i32(round(sample.r * 255.0));

    let cols = max(i32(params.c.w), 1);
    let rows_bank = max(i32(params.d.x), 1);
    let bold = y >= params.d.y;
    let col = idx % cols;
    var row = idx / cols;
    if (bold) {
        row = row + rows_bank;
    }

    let glyph = params.b.xy;
    let atlas = max(params.b.zw, vec2<f32>(1.0, 1.0));
    let local = clamp(fract(pix / cell_size), vec2<f32>(0.04), vec2<f32>(0.96));
    let origin = vec2<f32>(f32(col) * glyph.x, f32(row) * glyph.y);
    let atlas_uv = (origin + local * glyph) / atlas;
    let cov_raw = textureSampleLevel(atlas_tex, atlas_samp, atlas_uv, 0.0).r;

    var cov = smoothstep(0.03, 0.32, cov_raw);
    if (bold) {
        cov = smoothstep(0.015, 0.2, cov_raw);
    }
    if (y < params.d.z || idx == 0) {
        cov = 0.0;
    }

    let night = vec3<f32>(0.035, 0.05, 0.12);
    let gap = mix(night, graded, params.e.y);
    var rgb = mix(gap, graded, cov) + glow;

    let vig_uv = pix / frame;
    let vig = smoothstep(1.18, 0.42, length((vig_uv - vec2<f32>(0.5, 0.46)) * vec2<f32>(1.15, 1.05)));
    rgb = rgb * mix(0.78, 1.0, vig);

    let out_srgb = clamp(rgb, vec3<f32>(0.0), vec3<f32>(1.0));
    return vec4<f32>(pow(out_srgb, vec3<f32>(2.2)), 1.0);
}
