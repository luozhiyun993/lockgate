import Darwin
import Foundation
import LockgateCore

/// 在子进程里运行覆写。用户脚本可能写出死循环，放在子进程里才能超时后直接结束它。
enum OverrideRunner {
    static let workerFlag = "--override-worker"
    static let timeout: TimeInterval = 15
    /// 为 false 时在当前进程内运行（没有超时保护），仅用于测试。
    static var useWorker = true

    private struct Reply: Codable {
        var output: OverrideOutput?
        var error: String?
    }

    static func run(_ request: OverrideRequest) async throws -> OverrideOutput {
        guard useWorker, let executable = Bundle.main.executableURL else {
            return try await Task.detached { try OverrideEngine.run(request) }.value
        }
        let input = try JSONEncoder().encode(request)
        return try await Task.detached {
            let process = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            process.executableURL = executable
            process.arguments = [workerFlag]
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            var timedOut = false
            let watchdog = DispatchWorkItem {
                guard process.isRunning else { return }
                timedOut = true
                kill(process.processIdentifier, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            if timedOut { throw OverrideError("覆写运行超过 \(Int(timeout)) 秒，已中止。请检查脚本里是否有死循环。") }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                throw OverrideError("覆写进程异常退出（状态 \(process.terminationStatus)）。")
            }
            if let error = reply.error { throw OverrideError(error) }
            guard let output = reply.output else { throw OverrideError("覆写进程没有返回结果。") }
            return output
        }.value
    }

    /// 子进程入口：从标准输入读请求，把结果写到标准输出。
    static func workerMain() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var reply = Reply()
        do {
            reply.output = try OverrideEngine.run(try JSONDecoder().decode(OverrideRequest.self, from: input))
        } catch {
            reply.error = error.localizedDescription
        }
        FileHandle.standardOutput.write((try? JSONEncoder().encode(reply)) ?? Data())
        exit(0)
    }
}
