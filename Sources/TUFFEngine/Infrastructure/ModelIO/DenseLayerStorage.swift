import Foundation
import Darwin
import Metal

/// One reusable layer allocation. Views remain stable, but their contents are
/// valid only between prepare(layer:) and the next preparation. The runner
/// must finish GPU work before it calls prepare again.
final class DenseLayerStorage {
    struct Slice: Equatable {
        let name: String
        let sourceOffset: UInt64
        let size: UInt64
        let destinationOffset: UInt64
    }
    struct Plan: Equatable {
        let layers: [Int: [Slice]]
        let stagingBytes: UInt64
    }
    let plan: Plan
    let buffer: MTLBuffer
    private let fd: Int32
    private let slicesByName: [String: Slice]
    private var preparedLayer: Int?
    private(set) var logicalBytesRead: UInt64 = 0

    static func layerNumber(_ name: String) -> Int? {
        let prefix = "language_model.model.layers."
        guard name.hasPrefix(prefix) else { return nil }
        let tail = name.dropFirst(prefix.count)
        guard let dot = tail.firstIndex(of: ".") else { return nil }
        return Int(tail[..<dot])
    }

    static func makePlan(index: ResidentIndex, residentLayers: Set<Int>,
                         numLayers: Int, maximumBytes: UInt64) throws -> Plan {
        guard residentLayers.allSatisfy({ $0 >= 0 && $0 < numLayers }) else {
            throw ModelError.indexCorrupt(detail: "invalid resident dense layer")
        }
        var layers: [Int: [Slice]] = [:]
        var maximum: UInt64 = 0
        let grouped = Dictionary(grouping: index.entries.values.filter {
            guard let layer = layerNumber($0.name) else { return false }
            return !residentLayers.contains(layer)
        }, by: { layerNumber($0.name)! })
        for (layer, entries) in grouped {
            guard layer >= 0 && layer < numLayers else {
                throw ModelError.indexCorrupt(detail: "dense layer index out of range")
            }
            // Validate complete tensor ranges with the existing index planner.
            let regions = try ResidentBufferSet.planRegions(
                entries: entries, payloadOffset: index.header.indexSize,
                payloadSize: index.header.residentSize,
                maximumLength: 1, hardMaximumLength: maximumBytes)
            var slices: [Slice] = []
            var cursor: UInt64 = 0
            for region in regions {
                let rounded = cursor.addingReportingOverflow(255)
                guard !rounded.overflow else { throw ModelError.residentBufferWrapFailed }
                cursor = rounded.partialValue / 256 * 256
                let end = cursor.addingReportingOverflow(region.size)
                guard !end.overflow, end.partialValue <= maximumBytes else {
                    throw ModelError.indexCorrupt(detail: "dense layer staging exceeds buffer limit")
                }
                for name in region.tensorNames {
                    slices.append(Slice(name: name, sourceOffset: region.fileOffset,
                                        size: region.size, destinationOffset: cursor))
                }
                cursor = end.partialValue
            }
            layers[layer] = slices
            maximum = max(maximum, cursor)
        }
        return Plan(layers: layers, stagingBytes: maximum)
    }

    init(index: ResidentIndex, residentLayers: Set<Int>, numLayers: Int,
         device: MTLDevice, fileDescriptor: Int32) throws {
        plan = try Self.makePlan(index: index, residentLayers: residentLayers,
                                 numLayers: numLayers,
                                 maximumBytes: UInt64(device.maxBufferLength))
        guard plan.stagingBytes > 0,
              let allocation = device.makeBuffer(length: Int(plan.stagingBytes),
                                                 options: .storageModeShared) else {
            throw ModelError.residentBufferWrapFailed
        }
        buffer = allocation
        buffer.label = "dense.layer-staging"
        slicesByName = Dictionary(uniqueKeysWithValues: plan.layers.values.flatMap { $0 }.map { ($0.name, $0) })
        fd = fcntl(fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw ModelError.posixFailed(call: "dup dense weights", errno: errno) }
        // Staging already owns a bounded copy. A second file-system cache
        // of a large streamed payload can displace other apps into swap.
        if index.header.residentSize > ProcessInfo.processInfo.physicalMemory / 4 {
            _ = fcntl(fd, F_NOCACHE, 1)
        }
    }

    deinit { close(fd) }

    func resolve(_ name: String) -> ResidentBufferSet.ResolvedEntry? {
        guard let slice = slicesByName[name] else { return nil }
        return .init(buffer: buffer,
                     regionFileOffset: slice.sourceOffset, bufferOffset: slice.destinationOffset)
    }

    func prepare(layer: Int) throws {
        guard preparedLayer != layer, let slices = plan.layers[layer] else { return }
        preparedLayer = nil
        for slice in slices {
            var done: UInt64 = 0
            while done < slice.size {
                try Task.checkCancellation()
                let count = Int(min(slice.size - done, 1 << 20))
                let result = pread(fd, buffer.contents().advanced(by: Int(slice.destinationOffset + done)),
                                   count, off_t(slice.sourceOffset + done))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else {
                    throw ModelError.posixFailed(call: "pread dense layer", errno: result == 0 ? EIO : errno)
                }
                done += UInt64(result)
                logicalBytesRead &+= UInt64(result)
            }
        }
        preparedLayer = layer
    }
}
