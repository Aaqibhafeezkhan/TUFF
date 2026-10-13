import Foundation
import TUFFFormat
import TUFFModelCatalog

/// Bounded conversion of the pinned W4A16 checkpoint. Routed weights already
/// use unsigned little-endian packed nibbles (the source adds eight before
/// packing). Copy them unchanged, convert scales and derive bias = -8 * scale.
/// Resident BF16 matrices are converted to affine Q4, with Q8 routers/gates.
enum CompressedQwenRepackPlanner {
    static func plan(meta: IndexLoader.SourceMetadata, arch: ArchInfo,
                     headers: [Safetensors.Header], outputDir: String) throws -> RepackPlan {
        guard arch.variant == .ornith15_397B, arch.family == .qwen36,
              meta.indexSha256Hex == TUFFModelCatalog.ornith15_397B.source.sourceIndexSHA256,
              meta.baseGroupSize == 32 else {
            throw RepackError.configurationInvalid(detail: "compressed Qwen source is not the qualified contract")
        }
        var registry: [String: SourceTensor] = [:]
        for header in headers {
            for tensor in header.tensors {
                guard registry.updateValue(tensor, forKey: tensor.name) == nil else {
                    throw RepackError.configurationInvalid(detail: "duplicate source tensor")
                }
            }
        }
        func tensor(_ name: String, dtype: SourceTensor.Dtype, shape: [UInt64]) throws -> SourceTensor {
            guard let value = registry[name] else { throw RepackError.missingTensor(name: name) }
            guard value.dtype == dtype, value.shape == shape else {
                throw RepackError.shapeMismatch(name: name, detail: "compressed tensor shape/dtype differs from contract")
            }
            return value
        }
        func canonical(_ name: String) -> String {
            if name == "lm_head.weight" { return "language_model.lm_head.weight" }
            return name.replacingOccurrences(of: "model.language_model.", with: "language_model.model.")
        }
        let sourceResidents = registry.values.filter {
            $0.name == "lm_head.weight" || ($0.name.hasPrefix("model.language_model.") && !$0.name.contains(".mlp.experts."))
        }.sorted { canonical($0.name) < canonical($1.name) }
        var strings: [UInt8] = [], offsets: [UInt32] = []
        for source in sourceResidents {
            offsets.append(UInt32(strings.count)); strings += canonical(source.name).utf8
        }
        let rawIndex = UInt64(GTurboBinary.indexHeaderBytes + sourceResidents.count * GTurboBinary.indexEntryBytes + strings.count)
        let indexBytes = (rawIndex + Layout.pageBytes - 1) / Layout.pageBytes * Layout.pageBytes
        let residentPath = (outputDir as NSString).appendingPathComponent("model_weights.bin")
        var cursor = indexBytes, entries: [ResidentEntry] = [], copies: [RangeCopy] = []
        func copy(_ source: SourceTensor, destination: String, offset: UInt64,
                  transform: RangeCopyTransform = .identity) {
            copies.append(.init(shardID: source.shardPath, sourceOffset: source.absoluteOffset,
                size: source.sizeBytes, destinationPath: destination, destinationOffset: offset, transform: transform))
        }
        for source in sourceResidents {
            guard source.dtype == .bf16 else {
                throw RepackError.dtypeMismatch(name: source.name, detail: "expected BF16 resident source")
            }
            let name = canonical(source.name)
            let matrix = source.shape.count == 2 && name.hasSuffix(".weight")
            let eightBit = name.hasSuffix(".mlp.gate.weight") || name.hasSuffix(".mlp.shared_expert_gate.weight")
            let group = eightBit ? 64 : 32
            let wt: RangeCopyTransform = matrix ? (eightBit ? .bf16Q8Weights : .bf16Q4Weights)
                : (name.hasSuffix(".input_layernorm.weight") || name.hasSuffix(".post_attention_layernorm.weight")
                    || name.hasSuffix(".q_norm.weight") || name.hasSuffix(".k_norm.weight")
                    || name == "language_model.model.norm.weight" ? .bf16NormPlusOne : .identity)
            if matrix {
                guard source.shape[1].isMultiple(of: UInt64(group)) else {
                    throw RepackError.shapeMismatch(name: name, detail: "matrix input width is not group aligned")
                }
            }
            var shape = source.shape
            if name.hasSuffix(".linear_attn.conv1d.weight") {
                guard shape.count == 3, shape[1] == 1, shape[2] == UInt64(arch.linearConvKernelSize) else {
                    throw RepackError.shapeMismatch(name: name, detail: "invalid depthwise convolution shape")
                }
                shape = [shape[0], shape[2], 1]
            }
            guard shape.count <= 4, shape.allSatisfy({ $0 <= UInt64(UInt32.max) }) else {
                throw RepackError.shapeMismatch(name: name, detail: "resident shape is not representable")
            }
            let logical = shape.map(UInt32.init) + Array(repeating: UInt32(0), count: 4 - shape.count)
            let wOffset = cursor, wBytes = try wt.destinationSize(sourceBytes: source.sizeBytes, name: name)
            cursor += wBytes
            let st: RangeCopyTransform = eightBit ? .bf16Q8Scales : .bf16Q4Scales
            let bt: RangeCopyTransform = eightBit ? .bf16Q8Biases : .bf16Q4Biases
            let sOffset = matrix ? cursor : 0
            let companion = matrix ? try st.destinationSize(sourceBytes: source.sizeBytes, name: name) : 0
            cursor += companion
            let bOffset = matrix ? cursor : 0
            cursor += companion
            entries.append(ResidentEntry(name: name, dtype: matrix ? 0 : 1,
                logicalShape4: logical, fileOffset: wOffset, sizeBytes: wBytes,
                scaleOffset: sOffset, scaleSize: companion, biasOffset: bOffset, biasSize: companion,
                quantSpec: matrix ? QuantSpec(bits: eightBit ? 8 : 4, groupSize: group) : nil,
                sourceWeight: source, sourceScales: matrix ? source : nil, sourceBiases: matrix ? source : nil,
                weightTransform: wt, scaleTransform: st, biasTransform: bt))
            copy(source, destination: residentPath, offset: wOffset, transform: wt)
            if matrix {
                copy(source, destination: residentPath, offset: sOffset, transform: st)
                copy(source, destination: residentPath, offset: bOffset, transform: bt)
            }
        }
        let resident = ResidentFilePlan(path: residentPath, entries: entries, stringTable: strings,
            stringTableOffsets: offsets, indexSize: indexBytes, residentSize: cursor - indexBytes)
        var layers: [LayerFilePlan] = []
        for layer in 0..<arch.numLayers {
            let path = (outputDir as NSString).appendingPathComponent("packed_experts/layer_\(String(format: "%02d", layer)).bin")
            var slices: [PerExpertTensorSlice] = [], expertCursor: UInt64 = 0
            for role in ["gate", "up", "down"] {
                let rows = UInt64(role == "down" ? arch.hiddenSize : arch.moeIntermediateSize)
                let columns = UInt64(role == "down" ? arch.moeIntermediateSize : arch.hiddenSize)
                let weightBytes = rows * columns / 2, companionBytes = rows * columns / 32 * 2
                let stem = "model.language_model.layers.\(layer).mlp.experts.0.\(role)_proj"
                let weight = try tensor(stem + ".weight_packed", dtype: .i32, shape: [rows, columns / 8])
                let scale = try tensor(stem + ".weight_scale", dtype: .fp16, shape: [rows, columns / 32])
                _ = try tensor(stem + ".weight_shape", dtype: .i64, shape: [2])
                for (component, bytes, source, dtype, shape, bits) in [
                    ("weights", weightBytes, weight, UInt8(0), [rows, columns], Optional(4)),
                    ("scales", companionBytes, scale, UInt8(1), [rows, columns / 32], nil),
                    ("biases", companionBytes, scale, UInt8(1), [rows, columns / 32], nil),
                ] {
                    slices.append(PerExpertTensorSlice(role: role, component: component, dtype: dtype,
                        logicalShape: shape, offsetInExpertBlob: expertCursor, sizeInExpertBlob: bytes,
                        sourceOffsetPerExpert: 0, sourceTensor: source, bitsForWeights: bits))
                    expertCursor += bytes
                }
            }
            let stride = (expertCursor + Layout.pageBytes - 1) / Layout.pageBytes * Layout.pageBytes
            for expert in 0..<arch.numExperts {
                for slice in slices {
                    let stem = "model.language_model.layers.\(layer).mlp.experts.\(expert).\(slice.role)_proj"
                    let rows = slice.logicalShape[0]
                    let columns = slice.component == "weights" ? slice.logicalShape[1] : slice.logicalShape[1] * 32
                    let source: SourceTensor
                    let transform: RangeCopyTransform
                    if slice.component == "weights" {
                        source = try tensor(stem + ".weight_packed", dtype: .i32, shape: [rows, columns / 8]); transform = .identity
                        _ = try tensor(stem + ".weight_shape", dtype: .i64, shape: [2])
                    } else {
                        source = try tensor(stem + ".weight_scale", dtype: .fp16, shape: [rows, columns / 32])
                        transform = slice.component == "scales" ? .fp16ToBF16 : .fp16SymmetricBias
                    }
                    copy(source, destination: path, offset: UInt64(expert) * stride + slice.offsetInExpertBlob, transform: transform)
                }
            }
            layers.append(.init(layerIndex: layer, path: path, expertsPerLayer: arch.numExperts,
                expertStride: stride, subTensors: slices))
        }
        guard registry.keys.allSatisfy({ $0.hasPrefix("model.language_model.") || $0.hasPrefix("model.visual.") || $0.hasPrefix("mtp.") || $0 == "lm_head.weight" }) else {
            throw RepackError.configurationInvalid(detail: "unrecognized compressed checkpoint tensors")
        }
        var plan = RepackPlan(arch: arch, baseMode: "affine", baseGroupSize: 32,
            bitsOverrideCount: entries.filter { $0.quantSpec?.bits == 8 }.count,
            resident: resident, layers: layers, ngramTable: nil,
            matchedModelID: SourceFingerprint.modelID(forIndexSha256: meta.indexSha256Hex),
            excludedMultimodalTensorNames: registry.keys.filter { $0.hasPrefix("model.visual.") || $0.hasPrefix("mtp.") }.sorted())
        plan.sourceCopies = copies
        return plan
    }
}
