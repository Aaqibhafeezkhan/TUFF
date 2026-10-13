import Foundation
import Testing
@testable import TUFFRepackCore

@Suite struct BoundedQuantizationConversionTests {
    private func converted(_ values: [Float], transform: RangeCopyTransform) throws -> [UInt8] {
        var source = values.map { UInt16(truncatingIfNeeded: $0.bitPattern >> 16).littleEndian }
        return try source.withUnsafeMutableBytes { bytes in
            let count = try WriterCore.convertInPlace(bytes.baseAddress!, byteCount: bytes.count, transform: transform)
            return Array(bytes.prefix(count))
        }
    }
    private func bf16(_ bytes: [UInt8], _ offset: Int = 0) -> Float {
        Float(bitPattern: (UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8) << 16)
    }

    @Test(arguments: [false, true]) func affineConversionReconstructsEveryGroup(eightBit: Bool) throws {
        let group = eightBit ? 64 : 32
        let values = (0..<(group * 3)).map { Float(($0 * 13) % 71 - 35) / 8 }
        let weights = try converted(values, transform: eightBit ? .bf16Q8Weights : .bf16Q4Weights)
        let scales = try converted(values, transform: eightBit ? .bf16Q8Scales : .bf16Q4Scales)
        let biases = try converted(values, transform: eightBit ? .bf16Q8Biases : .bf16Q4Biases)
        #expect(weights.count == values.count / (eightBit ? 1 : 2))
        #expect(scales.count == 6 && biases.count == 6)
        for index in values.indices {
            let scale = bf16(scales, index / group * 2)
            let bias = bf16(biases, index / group * 2)
            let code = eightBit ? weights[index] : ((weights[index / 2] >> (index % 2 * 4)) & 15)
            let reconstructed = Float(code) * scale + bias
            #expect(abs(reconstructed - values[index]) <= scale * 0.51 + 0.02)
        }
    }

    @Test func sourceSymmetricPackingKeepsUnsignedNibblesAndDerivesBias() throws {
        var scales = [Float16(0.125).bitPattern, Float16(0.75).bitPattern, Float16(0.03125).bitPattern]
        let source = scales
        let scaleData = try scales.withUnsafeMutableBytes { bytes -> [UInt8] in
            let count = try WriterCore.convertInPlace(bytes.baseAddress!, byteCount: bytes.count, transform: .fp16ToBF16)
            return Array(bytes.prefix(count))
        }
        scales = source
        let biasData = try scales.withUnsafeMutableBytes { bytes -> [UInt8] in
            let count = try WriterCore.convertInPlace(bytes.baseAddress!, byteCount: bytes.count, transform: .fp16SymmetricBias)
            return Array(bytes.prefix(count))
        }
        for group in source.indices {
            let scale = bf16(scaleData, group * 2), bias = bf16(biasData, group * 2)
            for unsignedCode in 0..<16 {
                // Reference source dequantization uses signed values -8...7.
                let expected = Float(unsignedCode - 8) * Float(Float16(bitPattern: source[group]))
                #expect(Float(unsignedCode) * scale + bias == expected)
            }
        }
    }

    @Test func conversionsRejectNonFiniteWeightsAndUnalignedGroups() throws {
        #expect(throws: RepackError.self) { try converted([.infinity] + Array(repeating: 1, count: 31), transform: .bf16Q4Weights) }
        #expect(throws: RepackError.self) { try converted([1, 2, 3], transform: .bf16Q4Weights) }
        #expect(throws: RepackError.self) {
            _ = try RangeCopyPlanner.coalesce(copies: [.init(shardID: "x", sourceOffset: 0, size: 64,
                destinationPath: "/out/w", destinationOffset: 0, transform: .bf16Q4Weights)], rangeChunkBytes: 32)
        }
    }

    @Test func repeatedQuantizationInputsAreDownloadedOnceAndSplitOnGroups() throws {
        let copies: [RangeCopy] = [
            .init(shardID: "x", sourceOffset: 0, size: 256, destinationPath: "/out/w", destinationOffset: 0, transform: .bf16Q4Weights),
            .init(shardID: "x", sourceOffset: 0, size: 256, destinationPath: "/out/s", destinationOffset: 0, transform: .bf16Q4Scales),
            .init(shardID: "x", sourceOffset: 0, size: 256, destinationPath: "/out/b", destinationOffset: 0, transform: .bf16Q4Biases),
        ]
        let ranges = try RangeCopyPlanner.coalesce(copies: copies, rangeChunkBytes: 100)
        #expect(ranges.reduce(0) { $0 + $1.size } == 256)
        #expect(ranges.allSatisfy { $0.sourceOffset.isMultiple(of: 64) && $0.size.isMultiple(of: 64) })
        #expect(ranges.flatMap(\.destinations).filter { $0.destinationPath == "/out/s" }.map(\.destinationOffset) == [0, 2, 4, 6])
    }
}
