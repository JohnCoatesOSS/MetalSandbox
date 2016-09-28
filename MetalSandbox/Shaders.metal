#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position;
    float2 textureCoordinates [[user(texturecoord)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 textureCoordinates [[user(texturecoord)]];
};

// passthrough

vertex VertexOut vertex_passthrough(device VertexIn *vertices [[buffer(0)]],
                                    uint vertexId [[vertex_id]]) {
    VertexOut out;
    out.position = vertices[vertexId].position;
    out.textureCoordinates = vertices[vertexId].textureCoordinates;
    return out;
}

fragment half4 fragment_passthrough(VertexOut fragmentIn [[stage_in]],
                                    texture2d<half> tex [[ texture(0) ]]
                                    ) {
    constexpr sampler qsampler;
    half4 color = tex.sample(qsampler, fragmentIn.textureCoordinates);
    return color;
}
