import Foundation
import MeowIPC
import MeowModels
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct MvpLogExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] {
        [.plainText]
    }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum MvpLogExporter: Sendable {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meow-ios", category: "mvp-log-exporter")

    static func collectCombinedLogs() async -> String {
        return await Task.detached {
            let osLogs = collectOSLogs()
            let tunnelLogs = collectTunnelFileLog()
            log.info("Combined log collection completed (oslog length: \(osLogs.count, privacy: .public), tunnel log length: \(tunnelLogs.count, privacy: .public))")
            return """
            ===== App process — OSLog, last hour =====
            \(osLogs)

            ===== Packet Tunnel + engine — \(AppGroup.tunnelLogURL.lastPathComponent) =====
            \(tunnelLogs)
            """
        }.value
    }

    private static func collectTunnelFileLog() -> String {
        let maxBytes = 512 * 1024
        var data = Data()
        
        func readLastBytes(from url: URL, max: Int) -> Data {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return Data() }
            let readSize = min(size, UInt64(max))
            try? handle.seek(toOffset: size - readSize)
            return (try? handle.readToEnd()) ?? Data()
        }
        
        let activeData = readLastBytes(from: AppGroup.tunnelLogURL, max: maxBytes)
        if activeData.count < maxBytes {
            let remaining = maxBytes - activeData.count
            let rotatedData = readLastBytes(from: AppGroup.tunnelLogURL.appendingPathExtension("1"), max: remaining)
            data.append(rotatedData)
        }
        data.append(activeData)

        if data.isEmpty {
            log.warning("No packet-tunnel log file found at \(AppGroup.tunnelLogURL.path, privacy: .public)")
            return """
            No packet-tunnel log file at \(AppGroup.tunnelLogURL.path).
            Connect the tunnel at least once — the engine writes this file while running.
            """
        }

        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }

    private static func collectOSLogs() -> String {
        var lines: [String] = []
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-3600))
            let entries = try store.getEntries(at: since)
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                let ts = log.date.formatted(.iso8601)
                let lvl = switch log.level {
                case .debug: "DEBUG"
                case .info: "INFO"
                case .notice: "NOTICE"
                case .error: "ERROR"
                case .fault: "FAULT"
                default: "LOG"
                }
                lines.append("[\(ts)] [\(lvl)] [\(log.subsystem)/\(log.category)] \(log.composedMessage)")
            }
        } catch {
            log.error("Failed to read OSLogStore: \(error.localizedDescription, privacy: .public)")
            lines.append("Failed to read OSLogStore: \(error.localizedDescription)")
        }
        if lines.isEmpty {
            lines.append("No log entries found in the last hour.")
        }
        return lines.joined(separator: "\n")
    }
}
