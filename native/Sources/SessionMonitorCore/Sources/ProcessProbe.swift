import Darwin
import Foundation

public protocol DarwinProcessSyscalls: Sendable {
    func kill(_ pid: Int32, _ signal: Int32) -> Int32
    var errorNumber: Int32 { get }
}

public struct DarwinProcessSystemCalls: DarwinProcessSyscalls, Sendable {
    public init() {}

    public func kill(_ pid: Int32, _ signal: Int32) -> Int32 {
        Darwin.kill(pid, signal)
    }

    public var errorNumber: Int32 { errno }
}

public struct DarwinProcessProbe: Sendable {
    private let syscalls: any DarwinProcessSyscalls

    public init(syscalls: any DarwinProcessSyscalls = DarwinProcessSystemCalls()) {
        self.syscalls = syscalls
    }

    public func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if syscalls.kill(pid, 0) == 0 {
            return true
        }
        return syscalls.errorNumber == EPERM
    }
}
