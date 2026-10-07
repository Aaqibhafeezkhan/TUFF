#include <metal_stdlib>
using namespace metal;

// ============================================================================
// activation — math shared by kernels in more than one kernel group.
//
// Compiled ahead of every group's own modules, like quant_group, so a group
// such as the core utilities does not need the mixture-of-experts module
// compiled beside it just for this function. The body is unchanged from when
// it lived in moe.metal.
// ============================================================================

constant constexpr float kGeluSqrt2OverPi = 0.7978845608028654f;
constant constexpr float kGeluCubicCoeff = 0.044715f;

static inline float gelu_pytorch_tanh(float x) {
    const float x3 = x * x * x;
    float inner = kGeluSqrt2OverPi * (x + kGeluCubicCoeff * x3);
    // Clamping avoids Metal tanh producing NaN at large magnitudes while being
    // equivalent to the saturated result at FP32 precision.
    inner = clamp(inner, -20.0f, 20.0f);
    return 0.5f * x * (1.0f + tanh(inner));
}
