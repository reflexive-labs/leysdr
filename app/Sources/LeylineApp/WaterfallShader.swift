// SPDX-License-Identifier: Apache-2.0

// The waterfall's shader, as source compiled at launch. `swift build` does not compile a
// `.metal` resource into a library the way Xcode does, and a shader that silently fails to load
// is a dark panel with no words; compiling from source works under both builds and fails with a
// compiler message that the window can show (docs/plans/app.md, APP-2).
//
// One byte a bin in a ring texture, newest row at the top, one row per pixel, coloured through
// the six-stop ramp between the floor and floor + range. A pixel column that covers several
// bins takes the loudest, so a carrier one bin wide is never lost between two pixels.

enum WaterfallShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        uint head;          // ring slot of the newest row
        uint rowsWritten;   // rows in the ring, at most capacity
        uint capacity;
        uint bins;
        float viewLo;       // the left edge, as a fraction of the capture's span
        float viewHi;       // the right edge
        float floorU8;      // the ramp's cold end, in DB_U8 units
        float rangeU8;      // how far above the floor the ramp reaches, in DB_U8 units
        float width;        // drawable size, pixels
        float height;
        float rowsPerPixel;
        float pad;
    };

    struct VertexOut {
        float4 position [[position]];
    };

    vertex VertexOut waterfall_vertex(uint vid [[vertex_id]]) {
        // One triangle that covers the drawable.
        const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VertexOut out;
        out.position = float4(corners[vid], 0.0, 1.0);
        return out;
    }

    static float3 ramp(float frac, constant float4 *stops) {
        float x = clamp(frac, 0.0, 1.0) * 5.0;
        uint i = min(uint(x), 4u);
        float t = x - float(i);
        return mix(stops[i].rgb, stops[i + 1].rgb, t);
    }

    fragment float4 waterfall_fragment(VertexOut in [[stage_in]],
                                       texture2d<uint, access::read> rows [[texture(0)]],
                                       constant Uniforms &u [[buffer(0)]],
                                       constant float4 *stops [[buffer(1)]]) {
        const float3 ground = float3(0x0B / 255.0, 0x0D / 255.0, 0x0F / 255.0);
        // Age in rows: y = 0 is the newest row. Past what has been written there is nothing yet.
        uint age = uint(in.position.y * u.rowsPerPixel);
        if (age >= u.rowsWritten || u.bins == 0) {
            return float4(ground, 1.0);
        }
        uint slot = (u.head + u.capacity - age) % u.capacity;
        // The bins under this pixel column: the loudest wins.
        float x0 = in.position.x / u.width;
        float x1 = (in.position.x + 1.0) / u.width;
        float b0f = mix(u.viewLo, u.viewHi, x0) * float(u.bins);
        float b1f = mix(u.viewLo, u.viewHi, x1) * float(u.bins);
        uint b0 = uint(clamp(b0f, 0.0, float(u.bins - 1)));
        uint b1 = uint(clamp(b1f, 0.0, float(u.bins - 1)));
        uint hi = min(b1, b0 + 16u);
        uint loudest = 0;
        for (uint b = b0; b <= hi; b++) {
            loudest = max(loudest, rows.read(uint2(b, slot)).r);
        }
        float frac = (float(loudest) - u.floorU8) / max(u.rangeU8, 1.0);
        return float4(ramp(frac, stops), 1.0);
    }
    """
}
