import Foundation
import MeowIPC
import MeowModels
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct MvpLogExportDocument: FileDocument {
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

enum MvpLogExporter {
    static func collectCombinedLogs() -> String {
        """
        ===== App process — OSLog, last hour =====
        \(collectOSLogs())

        ===== Packet Tunnel + engine — \(AppGroup.tunnelLogURL.lastPathComponent) =====
        \(collectTunnelFileLog())
        """
    }

    private static func collectTunnelFileLog() -> String {
        let maxBytes = 512 * 1024
        var data = Data()
        if let rotated = try? Data(contentsOf: AppGroup.tunnelLogURL.appendingPathExtension("1")) {
            data.append(rotated)
        }
        if let active = try? Data(contentsOf: AppGroup.tunnelLogURL) {
            data.append(active)
        }
        if data.isEmpty {
            return """
            No packet-tunnel log file at \(AppGroup.tunnelLogURL.path).
            Connect the tunnel at least once — the engine writes this file while running.
            """
        }
        if data.count > maxBytes {
            data = data.suffix(maxBytes)
        }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }

    private static func collectOSLogs() -> String {
        var lines: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-3600))
            let entries = try store.getEntries(at: since)
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                let ts = df.string(from: log.date)
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
            lines.append("Failed to read OSLogStore: \(error.localizedDescription)")
        }
        if lines.isEmpty {
            lines.append("No log entries found in the last hour.")
        }
        return lines.joined(separator: "\n")
    }
}
