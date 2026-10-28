import Foundation

/// 상태 기록 — ~/Library/Logs/DynamicNotch.log. 권한·이벤트 탭·센서처럼 화면에 안 보이는 실패를 남긴다.
/// 같은 문장이 연달아 오면 한 번만 쓴다.
enum DNLog {
    nonisolated(unsafe) private static var last = ""
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DynamicNotch.log")

    static func note(_ s: String) {
        guard s != last else { return }
        last = s
        let line = "[\(Date())] \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
