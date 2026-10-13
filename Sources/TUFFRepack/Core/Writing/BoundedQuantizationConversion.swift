import Foundation

extension WriterCore {
    /// Input and output share one bounded tile. Every transform writes no more
    /// bytes than it reads, and quantization loads a complete group before
    /// overwriting any of that group's source values.
    static func convertInPlace(_ buffer: UnsafeMutableRawPointer, byteCount: Int,
                               transform: RangeCopyTransform) throws -> Int {
        guard byteCount > 0, UInt64(byteCount).isMultiple(of: transform.sourceAlignment) else {
            throw RepackError.configurationInvalid(detail: "conversion tile is not group aligned")
        }
        if transform == .identity { return byteCount }
        if transform == .fp32ToBF16 { return convertFP32ToBF16InPlace(buffer, byteCount: byteCount) }
        let input = buffer.assumingMemoryBound(to: UInt16.self)
        func bf16(_ value: Float) throws -> UInt16 {
            guard value.isFinite else { throw RepackError.configurationInvalid(detail: "nonfinite quantization input") }
            let bits = value.bitPattern
            return UInt16(truncatingIfNeeded: (bits &+ 0x7fff &+ ((bits >> 16) & 1)) >> 16).littleEndian
        }
        if [.fp16ToBF16, .fp16SymmetricBias, .bf16NormPlusOne].contains(transform) {
            for index in 0..<(byteCount / 2) {
                let bits = UInt16(littleEndian: input[index])
                let value: Float
                if transform == .bf16NormPlusOne { value = Float(bitPattern: UInt32(bits) << 16) + 1 }
                else { value = Float(Float16(bitPattern: bits)) * (transform == .fp16SymmetricBias ? -8 : 1) }
                input[index] = try bf16(value)
            }
            return byteCount
        }
        let group = Int(transform.sourceAlignment / 2)
        let fourBit = group == 32
        let levels: Float = fourBit ? 15 : 255
        let outputWeights = transform == .bf16Q4Weights || transform == .bf16Q8Weights
        let outputScales = transform == .bf16Q4Scales || transform == .bf16Q8Scales
        let raw = buffer.assumingMemoryBound(to: UInt8.self)
        var values = [Float](repeating: 0, count: group)
        var output = 0
        for start in stride(from: 0, to: byteCount / 2, by: group) {
            var low = Float.infinity, high = -Float.infinity
            for index in 0..<group {
                let value = Float(bitPattern: UInt32(UInt16(littleEndian: input[start + index])) << 16)
                guard value.isFinite else { throw RepackError.configurationInvalid(detail: "nonfinite resident matrix") }
                values[index] = value
                low = min(low, value); high = max(high, value)
            }
            let scale = (high - low) / levels
            // Quantize against the actual BF16 affine parameters the engine
            // receives, so rounding metadata cannot invalidate the code range.
            let scaleBits = try bf16(scale), biasBits = try bf16(low)
            let storedScale = Float(bitPattern: UInt32(UInt16(littleEndian: scaleBits)) << 16)
            let storedBias = Float(bitPattern: UInt32(UInt16(littleEndian: biasBits)) << 16)
            if outputWeights {
                func code(_ index: Int) -> UInt8 {
                    guard storedScale > 0 else { return 0 }
                    return UInt8(min(levels, max(0, ((values[index] - storedBias) / storedScale).rounded(.toNearestOrEven))))
                }
                if fourBit {
                    for index in stride(from: 0, to: group, by: 2) {
                        raw[output] = code(index) | (code(index + 1) << 4); output += 1
                    }
                } else {
                    for index in 0..<group { raw[output] = code(index); output += 1 }
                }
            } else {
                let bits = outputScales ? scaleBits : biasBits
                raw[output] = UInt8(truncatingIfNeeded: bits)
                raw[output + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                output += 2
            }
        }
        return output
    }
}
