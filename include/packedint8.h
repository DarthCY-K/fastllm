#ifndef FASTLLM_PACKEDINT8_H
#define FASTLLM_PACKEDINT8_H
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <cmath>
#include <limits>

namespace fastllm {
// A layout-only adapter: Q8_0 has 32 signed integers and an FP16 scale.
// Four adjacent blocks share each source group128 scale. No rounding of weights
// or scales is permitted. compressed-tensors stores q+128, NOT two's complement.
inline uint16_t PackedInt8ExactHalfScale(uint16_t bf16) {
    unsigned exp = (bf16 >> 7) & 255, mant = bf16 & 127;
    if (!(bf16 & 0x8000)) {
        if (bf16 == 0) return 0;
        if (exp >= 113 && exp <= 142)
            return static_cast<uint16_t>(((exp - 112) << 10) | (mant << 3));
        if (exp >= 103 && exp < 113) {
            unsigned significand = 128 + mant;
            if (exp >= 110) return static_cast<uint16_t>(significand << (exp - 110));
            unsigned shift = 110 - exp;
            if ((significand & ((1u << shift) - 1)) == 0)
                return static_cast<uint16_t>(significand >> shift);
        }
    }
    throw std::runtime_error("Packed INT8 scale is not exactly representable as nonnegative finite FP16");
}
inline void RepackPackedInt8Group128ToQ8_0(
        const uint8_t *packed, size_t packedBytes,
        const uint16_t *bf16Scales, size_t scaleCount,
        uint8_t *output, size_t outputBytes) {
    if (!packed || !bf16Scales || !output || packedBytes == 0 ||
        packedBytes % 128 || scaleCount != packedBytes / 128 ||
        outputBytes / 136 != scaleCount || outputBytes % 136) {
        throw std::runtime_error("Invalid packed INT8 group128 buffer sizes");
    }
    // Validate every scale before changing caller-owned storage.
    for (size_t group = 0; group < scaleCount; group++)
        (void)PackedInt8ExactHalfScale(bf16Scales[group]);
    for (size_t group = 0; group < scaleCount; group++) {
        uint16_t scale = PackedInt8ExactHalfScale(bf16Scales[group]);
        for (size_t block = 0; block < 4; block++) {
            uint8_t *dst = output + (group * 4 + block) * 34;
            std::memcpy(dst, &scale, sizeof(scale));
            for (size_t j = 0; j < 32; j++) {
                dst[2+j] = packed[group * 128 + block * 32 + j] ^ 0x80;
            }
        }
    }
}
// Portable native reference kernel. Keeps the checkpoint's byte-offset INT8
// weights and BF16 group scales in place; only scalar operands are converted.
// This component is not registered as a FastLLM device operator yet.
inline void PackedInt8Group128LinearF16(
        const uint16_t *input, const uint8_t *packed, const uint16_t *scales,
        const float *bias, float *output, size_t batch, size_t rows, size_t cols) {
    if (!input || !packed || !scales || !output || !batch || !rows || !cols ||
        cols % 128 || rows > SIZE_MAX / cols || batch > SIZE_MAX / cols ||
        batch > SIZE_MAX / rows) {
        throw std::runtime_error("Invalid native packed INT8 group128 linear shape");
    }
    for (size_t b = 0; b < batch; b++) {
        for (size_t r = 0; r < rows; r++) {
            float sum = bias ? bias[r] : 0.0f;
            for (size_t g = 0; g < cols / 128; g++) {
                uint32_t bits = uint32_t(scales[r * (cols / 128) + g]) << 16;
                float scale; std::memcpy(&scale, &bits, sizeof(scale));
                float dot = 0.0f;
                for (size_t j = 0; j < 128; j++) {
                    size_t c = g * 128 + j;
                    uint16_t h = input[b * cols + c];
                    int exp = (h >> 10) & 31, mant = h & 1023;
                    float a;
                    if (exp == 31) a = mant ? std::numeric_limits<float>::quiet_NaN() : std::numeric_limits<float>::infinity();
                    else a = exp ? std::ldexp(float(1024 + mant), exp - 25) : std::ldexp(float(mant), -24);
                    if (h & 0x8000) a = -a;
                    dot += a * (int(packed[r * cols + c]) - 128);
                }
                sum += dot * scale;
            }
            output[b * rows + r] = sum;
        }
    }
}
// Runtime group-interleaved layout: [128 offset-binary bytes][BF16 scale].
// Activation/output scratch is allowed; there is never a float weight tensor.
inline void PackedInt8InterleavedLinearF32(
        const float *input, const uint8_t *weight, const float *bias,
        float *output, size_t batch, size_t rows, size_t cols) {
    if (!input || !weight || !output || !batch || !rows || !cols || cols % 128 ||
        cols / 128 > SIZE_MAX / 130 || rows > SIZE_MAX / (cols / 128 * 130) ||
        batch > SIZE_MAX / cols || batch > SIZE_MAX / rows)
        throw std::runtime_error("Invalid interleaved packed INT8 shape");
    size_t groups = cols / 128;
    for (size_t b = 0; b < batch; b++) for (size_t r = 0; r < rows; r++) {
        float sum = bias ? bias[r] : 0.0f;
        for (size_t g = 0; g < groups; g++) {
            const uint8_t *block = weight + (r * groups + g) * 130;
            uint16_t bf16; std::memcpy(&bf16, block + 128, 2);
            uint32_t bits = uint32_t(bf16) << 16;
            float scale; std::memcpy(&scale, &bits, 4);
            float dot = 0.0f;
            for (size_t j = 0; j < 128; j++)
                dot += input[b * cols + g * 128 + j] * (int(block[j]) - 128);
            sum += dot * scale;
        }
        output[b * rows + r] = sum;
    }
}
}
#endif
