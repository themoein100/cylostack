//
//  Logger.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import Foundation

class Logger {
    static let shared = Logger()
    
    private let fileManager = FileManager.default
    private let logQueue = DispatchQueue(label: "com.circlestack.logger", qos: .background)
    
    private var logFileURL: URL? {
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logsDirectory = documentsDirectory.appendingPathComponent("logs", isDirectory: true)
        
        // Create logs directory if not exists
        if !fileManager.fileExists(atPath: logsDirectory.path) {
            try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true, attributes: nil)
        }
        
        return logsDirectory.appendingPathComponent("app_logs.txt")
    }
    
    enum Level: String {
        case debug = "🛠️ DEBUG"
        case info = "ℹ️ INFO "
        case warning = "⚠️ WARN "
        case error = "❌ ERROR"
    }
    
    private init() {
        // Print log location on startup
        if let url = logFileURL {
            print("[Logger Init]: Logs file path: \(url.path)")
            rotateLogFileIfNeeded()
        }
    }
    
    // Log formatting and dispatch
    private func log(level: Level, category: String, message: String) {
        let timestamp = getTimestamp()
        let logLine = "[\(timestamp)] [\(level.rawValue)] [\(category)] \(message)"
        
        // Print to console
        print(logLine)
        
        // Write to file asynchronously to avoid blocking main thread
        logQueue.async {
            self.writeLogToFile(logLine)
        }
    }
    
    // Public APIs
    func d(_ category: String, _ message: String) {
        log(level: .debug, category: category, message: message)
    }
    
    func i(_ category: String, _ message: String) {
        log(level: .info, category: category, message: message)
    }
    
    func w(_ category: String, _ message: String) {
        log(level: .warning, category: category, message: message)
    }
    
    func e(_ category: String, _ message: String) {
        log(level: .error, category: category, message: message)
    }
    
    // Internal Helper Methods
    private func getTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
    
    private func writeLogToFile(_ text: String) {
        guard let fileURL = logFileURL else { return }
        
        let lineToWrite = text + "\n"
        if let data = lineToWrite.data(using: .utf8) {
            if fileManager.fileExists(atPath: fileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
    
    // Manage log file size to avoid storage leaks (max 1.5MB)
    private func rotateLogFileIfNeeded() {
        guard let fileURL = logFileURL else { return }
        
        if fileManager.fileExists(atPath: fileURL.path),
           let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? UInt64 {
            
            let maxSize: UInt64 = 1500 * 1024 // 1.5 MB
            if fileSize > maxSize {
                print("[Logger]: Log file size \(fileSize) bytes exceeds limit. Rotating log file.")
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }
}
