import Foundation

public struct FileCursor: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let offset: UInt64

    public init(device: UInt64, inode: UInt64, offset: UInt64) {
        self.device = device
        self.inode = inode
        self.offset = offset
    }
}

public enum FileRotationReason: String, Hashable, Sendable {
    case inodeChanged
    case truncated
}

public enum IncrementalFileIssue: Hashable, Sendable {
    case lineTooLong(limitBytes: Int)
    case pollLimitReached(limitBytes: Int)
    case fileUnavailable(path: String)
}

public struct IncrementalFileReadResult: Hashable, Sendable {
    public let lines: [Data]
    public let cursor: FileCursor
    public let bytesRead: Int
    public let bufferedByteCount: Int
    public let rotation: FileRotationReason?
    public let issues: [IncrementalFileIssue]

    public init(
        lines: [Data],
        cursor: FileCursor,
        bytesRead: Int,
        bufferedByteCount: Int,
        rotation: FileRotationReason?,
        issues: [IncrementalFileIssue]
    ) {
        self.lines = lines
        self.cursor = cursor
        self.bytesRead = bytesRead
        self.bufferedByteCount = bufferedByteCount
        self.rotation = rotation
        self.issues = issues
    }
}

public actor IncrementalFileReader {
    public static let maximumLineBytes = 1_048_576
    public static let maximumPollBytes = 4_194_304

    private var states: [String: BufferedState] = [:]

    public init() {}

    public func readLines(
        at fileURL: URL,
        since cursor: FileCursor?
    ) -> IncrementalFileReadResult {
        let path = fileURL.standardizedFileURL.path
        guard let metadata = fileMetadata(at: fileURL) else {
            return unavailableResult(path: path, cursor: cursor)
        }

        let prepared = prepareState(
            path: path,
            metadata: metadata,
            cursor: cursor
        )
        var state = prepared.state
        let readOffset = state.readOffset
        let remainingBytes = metadata.size > readOffset
            ? metadata.size - readOffset
            : 0
        let bytesToRead = Int(
            min(UInt64(Self.maximumPollBytes), remainingBytes)
        )

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: readOffset)
            data = try handle.read(upToCount: bytesToRead) ?? Data()
        } catch {
            return unavailableResult(path: path, cursor: cursor)
        }

        var lines: [Data] = []
        var issues: [IncrementalFileIssue] = []
        consume(
            data,
            from: readOffset,
            state: &state,
            lines: &lines,
            issues: &issues
        )
        state.readOffset = readOffset + UInt64(data.count)

        if remainingBytes > UInt64(Self.maximumPollBytes) {
            issues.append(.pollLimitReached(limitBytes: Self.maximumPollBytes))
        }

        states[path] = state
        return IncrementalFileReadResult(
            lines: lines,
            cursor: FileCursor(
                device: metadata.device,
                inode: metadata.inode,
                offset: state.committedOffset
            ),
            bytesRead: data.count,
            bufferedByteCount: state.buffer.count,
            rotation: prepared.rotation,
            issues: issues
        )
    }

    private func prepareState(
        path: String,
        metadata: FileMetadata,
        cursor: FileCursor?
    ) -> (state: BufferedState, rotation: FileRotationReason?) {
        guard let cursor else {
            return (
                BufferedState(
                    device: metadata.device,
                    inode: metadata.inode,
                    committedOffset: 0,
                    readOffset: 0
                ),
                nil
            )
        }

        guard cursor.device == metadata.device,
              cursor.inode == metadata.inode else {
            return (
                BufferedState(
                    device: metadata.device,
                    inode: metadata.inode,
                    committedOffset: 0,
                    readOffset: 0
                ),
                .inodeChanged
            )
        }

        let cached = states[path]
        let matchingCachedState = cached.flatMap { state -> BufferedState? in
            guard state.device == metadata.device,
                  state.inode == metadata.inode,
                  state.committedOffset == cursor.offset else {
                return nil
            }
            return state
        }
        if metadata.size < cursor.offset
            || matchingCachedState.map({ metadata.size < $0.readOffset }) == true {
            return (
                BufferedState(
                    device: metadata.device,
                    inode: metadata.inode,
                    committedOffset: 0,
                    readOffset: 0
                ),
                .truncated
            )
        }

        if let matchingCachedState {
            return (matchingCachedState, nil)
        }

        return (
            BufferedState(
                device: metadata.device,
                inode: metadata.inode,
                committedOffset: cursor.offset,
                readOffset: cursor.offset
            ),
            nil
        )
    }

    private func consume(
        _ data: Data,
        from readOffset: UInt64,
        state: inout BufferedState,
        lines: inout [Data],
        issues: inout [IncrementalFileIssue]
    ) {
        for (index, byte) in data.enumerated() {
            let absoluteOffset = readOffset + UInt64(index)
            if state.discardingOversizedLine {
                if byte == 0x0A {
                    state.discardingOversizedLine = false
                    state.committedOffset = absoluteOffset + 1
                }
                continue
            }

            if byte == 0x0A {
                var line = state.buffer
                if line.last == 0x0D {
                    line.removeLast()
                }
                lines.append(line)
                state.buffer.removeAll(keepingCapacity: true)
                state.committedOffset = absoluteOffset + 1
                continue
            }

            state.buffer.append(byte)
            if state.buffer.count > Self.maximumLineBytes {
                state.buffer.removeAll(keepingCapacity: false)
                state.discardingOversizedLine = true
                issues.append(.lineTooLong(limitBytes: Self.maximumLineBytes))
            }
        }
    }

    private func fileMetadata(at fileURL: URL) -> FileMetadata? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        ),
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
        let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return nil
        }
        return FileMetadata(device: device, inode: inode, size: size)
    }

    private func unavailableResult(
        path: String,
        cursor: FileCursor?
    ) -> IncrementalFileReadResult {
        IncrementalFileReadResult(
            lines: [],
            cursor: cursor ?? FileCursor(device: 0, inode: 0, offset: 0),
            bytesRead: 0,
            bufferedByteCount: 0,
            rotation: nil,
            issues: [.fileUnavailable(path: path)]
        )
    }
}

private struct FileMetadata {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
}

private struct BufferedState {
    let device: UInt64
    let inode: UInt64
    var committedOffset: UInt64
    var readOffset: UInt64
    var buffer = Data()
    var discardingOversizedLine = false
}
