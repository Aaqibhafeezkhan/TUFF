#include <metal_stdlib>
using namespace metal;

// GPT-OSS MXFP4 E2M1 GEMV. One SIMD group computes one row while eight SIMD
// groups share a threadgroup. Each lane owns one value from every 32-value
// block, so the UE8M0 scale is read once per lane and simd_sum completes the
// row reduction.

constant constexpr uint kMXFP4GroupSize = 32;

// E2M1 values for all sixteen codes, sign in bit 3. A table lookup instead of
// a per-value branch: in the decode GEMV the branch, not memory, was the limit.
constant float kMXFP4E2M1[16] = {
     0.0f,  0.5f,  1.0f,  1.5f,  2.0f,  3.0f,  4.0f,  6.0f,
    -0.0f, -0.5f, -1.0f, -1.5f, -2.0f, -3.0f, -4.0f, -6.0f,
};

static inline float mxfp4_e2m1(uint code) {
    return kMXFP4E2M1[code & 15u];
}

kernel void mxfp4_gemv_simd(
    device const uint8_t* weights [[buffer(0)]],
    device const uint8_t* scales  [[buffer(1)]],
    device const half* input      [[buffer(2)]],
    device half* output           [[buffer(3)]],
    constant uint& rows           [[buffer(4)]],
    constant uint& columns        [[buffer(5)]],
    device const bfloat* bias     [[buffer(6)]],
    constant uint& has_bias       [[buffer(7)]],
    uint threadgroupIndex         [[threadgroup_position_in_grid]],
    uint simdgroupIndex           [[simdgroup_index_in_threadgroup]],
    uint lane                     [[thread_index_in_simdgroup]])
{
    constexpr uint rowsPerThreadgroup = 8;
    const uint row = threadgroupIndex * rowsPerThreadgroup + simdgroupIndex;
    if (row >= rows) return;

    const uint groupsPerRow = columns / kMXFP4GroupSize;
    device const uint8_t* rowWeights = weights + row * (columns / 2u);
    device const uint8_t* rowScales = scales + row * groupsPerRow;
    // Each lane takes 8 consecutive values (4 bytes), so a SIMD group reads
    // 128 contiguous weight bytes per step. Loading one nibble per lane per
    // 32-value block left the kernel at about a fifth of the M2's memory
    // bandwidth, which made GPT-OSS decode compute-bound in its experts.
    // Eight values never straddle a 32-value block, so one scale serves them.
    float sum = 0.0f;
    for (uint base = lane * 8u; base < columns; base += 256u) {
        const packed_uchar4 bytes =
            *reinterpret_cast<device const packed_uchar4*>(rowWeights + (base >> 1u));
        device const half* x = input + base;
        float partial = 0.0f;
        for (uint j = 0; j < 4u; ++j) {
            const uint packed = uint(bytes[j]);
            partial = fma(mxfp4_e2m1(packed & 0x0Fu), float(x[2u * j]), partial);
            partial = fma(mxfp4_e2m1(packed >> 4u), float(x[2u * j + 1u]), partial);
        }
        // Production GPT-OSS exponent bytes are finite nonzero UE8M0 values.
        // Reinterpreting them as the FP32 exponent is exactly 2^(e - 127),
        // matching the official Metal reference without an approximation.
        const float scale = as_type<float>(uint(rowScales[base / kMXFP4GroupSize]) << 23u);
        sum = fma(partial, scale, sum);
    }
    sum = simd_sum(sum);
    if (lane == 0u) {
        output[row] = half(sum + (has_bias != 0u ? float(bias[row]) : 0.0f));
    }
}

// GPT-OSS leaves embeddings, attention projections, routers, and the output
// head in BF16. One SIMD group reduces one output row while eight groups share
// a threadgroup. Activations remain FP16, matching the rest of the runtime.
static inline float bf16_gemv_row(
    device const bfloat* weights,
    device const half* input,
    uint row,
    uint columns,
    uint lane
) {
    device const bfloat* rowWeights = weights + row * columns;
    float sum = 0.0f;
    for (uint column = lane; column < columns; column += 32u) {
        sum = fma(float(rowWeights[column]), float(input[column]), sum);
    }
    return simd_sum(sum);
}

kernel void bf16_gemv_half_simd(
    device const bfloat* weights [[buffer(0)]],
    device const half* input [[buffer(1)]],
    device half* output [[buffer(2)]],
    device const bfloat* bias [[buffer(3)]],
    constant uint& rows [[buffer(4)]],
    constant uint& columns [[buffer(5)]],
    constant uint& has_bias [[buffer(6)]],
    uint threadgroupIndex [[threadgroup_position_in_grid]],
    uint simdgroupIndex [[simdgroup_index_in_threadgroup]],
    uint lane [[thread_index_in_simdgroup]]) {
    constexpr uint rowsPerThreadgroup = 8;
    const uint row = threadgroupIndex * rowsPerThreadgroup + simdgroupIndex;
    if (row >= rows) return;
    const float sum = bf16_gemv_row(weights, input, row, columns, lane);
    if (lane == 0u) {
        output[row] = half(sum + (has_bias != 0u ? float(bias[row]) : 0.0f));
    }
}

kernel void bf16_gemv_float_simd(
    device const bfloat* weights [[buffer(0)]],
    device const half* input [[buffer(1)]],
    device float* output [[buffer(2)]],
    device const bfloat* bias [[buffer(3)]],
    constant uint& rows [[buffer(4)]],
    constant uint& columns [[buffer(5)]],
    constant uint& has_bias [[buffer(6)]],
    uint threadgroupIndex [[threadgroup_position_in_grid]],
    uint simdgroupIndex [[simdgroup_index_in_threadgroup]],
    uint lane [[thread_index_in_simdgroup]]) {
    constexpr uint rowsPerThreadgroup = 8;
    const uint row = threadgroupIndex * rowsPerThreadgroup + simdgroupIndex;
    if (row >= rows) return;
    const float sum = bf16_gemv_row(weights, input, row, columns, lane);
    if (lane == 0u) {
        output[row] = sum + (has_bias != 0u ? float(bias[row]) : 0.0f);
    }
}

// Batched resident projections used by bounded prefill and speculative
// verification. The x grid partitions output rows and the y grid partitions
// input rows. One SIMD group still owns one output row, but all rows share one
// encoder and can make better use of the GPU than a chain of tiny GEMVs.
kernel void bf16_gemv_half_rows_simd(
    device const bfloat* weights [[buffer(0)]],
    device const half* input [[buffer(1)]],
    device half* output [[buffer(2)]],
    device const bfloat* bias [[buffer(3)]],
    constant uint& rows [[buffer(4)]],
    constant uint& columns [[buffer(5)]],
    constant uint& has_bias [[buffer(6)]],
    constant uint& input_stride [[buffer(7)]],
    constant uint& output_stride [[buffer(8)]],
    constant uint& batch_count [[buffer(9)]],
    uint2 tg_idx [[threadgroup_position_in_grid]],
    uint simdgroupIndex [[simdgroup_index_in_threadgroup]],
    uint lane [[thread_index_in_simdgroup]]) {
    constexpr uint rowsPerThreadgroup = 8;
    const uint row = tg_idx.x * rowsPerThreadgroup + simdgroupIndex;
    if (tg_idx.y >= batch_count || row >= rows) return;
    const device half* rowInput = input + tg_idx.y * input_stride;
    const float sum = bf16_gemv_row(weights, rowInput, row, columns, lane);
    if (lane == 0u) {
        output[tg_idx.y * output_stride + row] = half(
            sum + (has_bias != 0u ? float(bias[row]) : 0.0f));
    }
}

kernel void bf16_gemv_float_rows_simd(
    device const bfloat* weights [[buffer(0)]],
    device const half* input [[buffer(1)]],
    device float* output [[buffer(2)]],
    device const bfloat* bias [[buffer(3)]],
    constant uint& rows [[buffer(4)]],
    constant uint& columns [[buffer(5)]],
    constant uint& has_bias [[buffer(6)]],
    constant uint& input_stride [[buffer(7)]],
    constant uint& output_stride [[buffer(8)]],
    constant uint& batch_count [[buffer(9)]],
    uint2 tg_idx [[threadgroup_position_in_grid]],
    uint simdgroupIndex [[simdgroup_index_in_threadgroup]],
    uint lane [[thread_index_in_simdgroup]]) {
    constexpr uint rowsPerThreadgroup = 8;
    const uint row = tg_idx.x * rowsPerThreadgroup + simdgroupIndex;
    if (tg_idx.y >= batch_count || row >= rows) return;
    const device half* rowInput = input + tg_idx.y * input_stride;
    const float sum = bf16_gemv_row(weights, rowInput, row, columns, lane);
    if (lane == 0u) {
        output[tg_idx.y * output_stride + row] = sum
            + (has_bias != 0u ? float(bias[row]) : 0.0f);
    }
}

// Batched BF16 output-head argmax. The x grid partitions vocabulary rows and
// the y grid partitions candidate hidden rows. This keeps the target verifier
// to one head dispatch plus one reduction dispatch, rather than one full
// vocabulary GEMV and argmax pair per candidate row.
constant constexpr uint kBF16ArgmaxRowsPerTG = 8;
constant constexpr uint kBF16ArgmaxSummaryStride = 2;
constant constexpr uint kBF16ArgmaxMaxSimdGroups = 8;

[[kernel, max_total_threads_per_threadgroup(256)]]
void bf16_gemv_argmax_rows(
    device const bfloat* weights [[buffer(0)]],
    device const half* input [[buffer(1)]],
    device const bfloat* bias [[buffer(2)]],
    device float* summaries [[buffer(3)]],
    constant uint& rows [[buffer(4)]],
    constant uint& columns [[buffer(5)]],
    constant uint& has_bias [[buffer(6)]],
    constant uint& input_stride [[buffer(7)]],
    constant uint& batch_count [[buffer(8)]],
    uint3 tg_idx [[threadgroup_position_in_grid]],
    uint simd_lane_id [[thread_index_in_simdgroup]],
    uint simd_group_id [[simdgroup_index_in_threadgroup]],
    uint simdgroups [[simdgroups_per_threadgroup]]) {
    threadgroup float partial_value[kBF16ArgmaxRowsPerTG];
    threadgroup uint partial_index[kBF16ArgmaxRowsPerTG];

    const uint batch = tg_idx.y;
    const uint row = tg_idx.x * kBF16ArgmaxRowsPerTG + simd_group_id;
    float best_value = -INFINITY;
    uint best_index = 0xFFFFFFFFu;
    if (batch < batch_count && row < rows) {
        device const half* row_input = input + batch * input_stride;
        const float sum = bf16_gemv_row(weights, row_input, row,
                                        columns, simd_lane_id);
        // `encodeHalf` stores this intermediate as FP16 before the existing
        // argmax reads it. Round here as well so close logits do not change
        // greedy output when this batched path replaces the scalar path.
        const half rounded = half(sum +
            (has_bias != 0u ? float(bias[row]) : 0.0f));
        const float value = float(rounded);
        if (simd_lane_id == 0u && isfinite(value)) {
            best_value = value;
            best_index = row;
        }
    }

    if (simd_lane_id == 0u) {
        partial_value[simd_group_id] = best_value;
        partial_index[simd_group_id] = best_index;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (simd_group_id == 0u) {
        const bool active = simd_lane_id < simdgroups;
        const float value = active ? partial_value[simd_lane_id] : -INFINITY;
        const uint index = active ? partial_index[simd_lane_id] : 0xFFFFFFFFu;
        const float all_value = simd_max(value);
        const uint all_index = (value == all_value)
            ? index : 0xFFFFFFFFu;
        const uint all_index_min = simd_min(all_index);
        if (simd_lane_id == 0u) {
            device float* slot = summaries
                + (batch * ((rows + kBF16ArgmaxRowsPerTG - 1u)
                            / kBF16ArgmaxRowsPerTG)
                   + tg_idx.x) * kBF16ArgmaxSummaryStride;
            slot[0] = all_value;
            slot[1] = as_type<float>(all_index_min);
        }
    }
}

[[kernel, max_total_threads_per_threadgroup(256)]]
void bf16_gemv_argmax_rows_reduce(
    device const float* summaries [[buffer(0)]],
    device uint* out_tokens [[buffer(1)]],
    constant uint& row_groups [[buffer(2)]],
    uint batch [[threadgroup_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint lsize [[threads_per_threadgroup]],
    uint simd_lane_id [[thread_index_in_simdgroup]],
    uint simd_group_id [[simdgroup_index_in_threadgroup]],
    uint simdgroups [[simdgroups_per_threadgroup]]) {
    threadgroup float partial_value[kBF16ArgmaxMaxSimdGroups];
    threadgroup uint partial_index[kBF16ArgmaxMaxSimdGroups];
    const device float* base = summaries
        + batch * row_groups * kBF16ArgmaxSummaryStride;

    float best_value = -INFINITY;
    uint best_index = 0xFFFFFFFFu;
    for (uint i = lid; i < row_groups; i += lsize) {
        const device float* slot = base + i * kBF16ArgmaxSummaryStride;
        const float value = slot[0];
        const uint index = as_type<uint>(slot[1]);
        if (value > best_value
            || (value == best_value && index < best_index)) {
            best_value = value;
            best_index = index;
        }
    }

    const float simd_value = simd_max(best_value);
    const uint simd_index = (best_value == simd_value)
        ? best_index : 0xFFFFFFFFu;
    const uint simd_index_min = simd_min(simd_index);
    if (simd_lane_id == 0u) {
        partial_value[simd_group_id] = simd_value;
        partial_index[simd_group_id] = simd_index_min;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (simd_group_id == 0u) {
        const bool active = simd_lane_id < simdgroups;
        const float value = active ? partial_value[simd_lane_id] : -INFINITY;
        const uint index = active ? partial_index[simd_lane_id] : 0xFFFFFFFFu;
        const float all_value = simd_max(value);
        const uint all_index = (value == all_value)
            ? index : 0xFFFFFFFFu;
        const uint all_index_min = simd_min(all_index);
        if (simd_lane_id == 0u) {
            out_tokens[batch] = all_index_min == 0xFFFFFFFFu ? 0u : all_index_min;
        }
    }
}

kernel void bf16_embedding_lookup_half(
    device const bfloat* table [[buffer(0)]],
    device half* output [[buffer(1)]],
    constant uint& token [[buffer(2)]],
    constant uint& hidden_size [[buffer(3)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= hidden_size) return;
    output[gid] = half(table[token * hidden_size + gid]);
}

kernel void bf16_embedding_lookup_float(
    device const bfloat* table [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& token [[buffer(2)]],
    constant uint& hidden_size [[buffer(3)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= hidden_size) return;
    output[gid] = float(table[token * hidden_size + gid]);
}
