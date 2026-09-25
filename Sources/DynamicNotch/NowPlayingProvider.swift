import AppKit
import SwiftUI
import NotchKit

/// Music / Spotify 재생 정보.
/// macOS 15.4+ 에서 서드파티의 MediaRemote 접근이 막혀서, 두 앱이 뿌리는 분산 알림을 듣고
/// 앨범아트·재생 위치·제어는 AppleScript 로 처리한다 (처음 한 번 자동화 권한을 묻는다).
@MainActor
final class NowPlayingProvider: NotchControls {
    enum Player: String {
        case music = "Music", spotify = "Spotify"
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
        var notification: String { self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged" }
    }

    private let model: NotchModel
    private let queue = DispatchQueue(label: "dynamicnotch.applescript")
    private var current: Player?
    private var artworkFor = ""

    init(model: NotchModel) {
        self.model = model
        for p in [Player.music, .spotify] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(p.notification), object: nil, queue: .main
            ) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.handle(info, from: p) }
            }
        }
        // 이미 재생 중인 앱이 있으면 상태를 가져온다 (실행 중이 아니면 절대 띄우지 않음)
        for p in [Player.spotify, .music] where isRunning(p) { poll(p) }
    }

    private func isRunning(_ p: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).isEmpty
    }

    private func handle(_ info: [AnyHashable: Any], from p: Player) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" || info["Name"] == nil {
            if current == p || current == nil { model.nowPlaying = nil; current = nil }
            return
        }
        let playing = state == "Playing"
        // 다른 플레이어가 재생 중이면 멈춰있는 쪽 알림은 무시
        if let cur = current, cur != p, model.nowPlaying?.isPlaying == true, !playing { return }

        let durMs = (info["Total Time"] as? NSNumber ?? info["Duration"] as? NSNumber)?.doubleValue ?? 0
        let pos = (info["Playback Position"] as? NSNumber)?.doubleValue
        var np = NowPlaying(title: info["Name"] as? String ?? "",
                            artist: info["Artist"] as? String ?? "",
                            album: info["Album"] as? String ?? "",
                            source: p.rawValue, isPlaying: playing,
                            duration: durMs / 1000, elapsed: pos ?? 0, elapsedAt: Date())
        let old = model.nowPlaying
        if let old, old.trackKey == np.trackKey {
            np.artwork = old.artwork; np.artworkKey = old.artworkKey; np.tint = old.tint
            if pos == nil { np.elapsed = old.position(at: Date()) }
        }
        current = p
        model.nowPlaying = np
        if np.artworkKey != np.trackKey { fetchArtwork(p, key: np.trackKey) }
        if pos == nil { refreshPosition() }
    }

    // MARK: AppleScript

    private func run(_ source: String, _ done: (@MainActor (NSAppleEventDescriptor?) -> Void)? = nil) {
        queue.async {
            var err: NSDictionary?
            let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err { NSLog("DynamicNotch AppleScript: \(err)") }
            nonisolated(unsafe) let result = r
            DispatchQueue.main.async { MainActor.assumeIsolated { done?(result) } }
        }
    }

    private func poll(_ p: Player) {
        let app = p.rawValue
        let src = """
        tell application "\(app)"
          if player state is stopped then return {}
          set t to current track
          return {name of t, artist of t, album of t, (player state as text), duration of t, player position}
        end tell
        """
        run(src) { [weak self] d in
            guard let self, let d, d.numberOfItems >= 6 else { return }
            let dur = d.atIndex(5)?.doubleValue ?? 0
            self.handle([
                "Name": d.atIndex(1)?.stringValue ?? "",
                "Artist": d.atIndex(2)?.stringValue ?? "",
                "Album": d.atIndex(3)?.stringValue ?? "",
                "Player State": (d.atIndex(4)?.stringValue ?? "").capitalized,
                // Music 은 초, Spotify 는 ms 로 duration 을 준다
                "Duration": NSNumber(value: p == .music ? dur * 1000 : dur),
                "Playback Position": NSNumber(value: d.atIndex(6)?.doubleValue ?? 0),
            ], from: p)
        }
    }

    func refreshPosition() {
        guard let p = current, isRunning(p) else { return }
        run("tell application \"\(p.rawValue)\" to return player position") { [weak self] d in
            guard let self, let v = d?.doubleValue, var np = self.model.nowPlaying else { return }
            np.elapsed = v; np.elapsedAt = Date()
            self.model.nowPlaying = np
        }
    }

    private func fetchArtwork(_ p: Player, key: String) {
        guard artworkFor != key else { return }
        artworkFor = key
        let apply: @MainActor (Data?) -> Void = { [weak self] data in
            guard let self, var np = self.model.nowPlaying, np.trackKey == key else { return }
            np.artworkKey = key
            if let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
               let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: 300,
               ] as CFDictionary) {
                np.artwork = img
                np.tint = ArtworkTint.color(of: img)
            } else {
                np.artwork = nil
                np.tint = p == .spotify ? Color(red: 0.12, green: 0.84, blue: 0.38) : Color(red: 0.98, green: 0.24, blue: 0.35)
            }
            self.model.nowPlaying = np
        }
        switch p {
        case .music:
            run("tell application \"Music\" to if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track") { d in
                apply(d?.data)
            }
        case .spotify:
            run("tell application \"Spotify\" to return artwork url of current track") { d in
                guard let s = d?.stringValue, let url = URL(string: s) else { apply(nil); return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    let data = data
                    DispatchQueue.main.async { MainActor.assumeIsolated { apply(data) } }
                }.resume()
            }
        }
    }

    // MARK: NotchControls

    private var target: Player? {
        current ?? [Player.spotify, .music].first(where: isRunning)
    }

    func playPause() {
        guard let p = target else { return }
        run("tell application \"\(p.rawValue)\" to playpause")
    }

    func nextTrack() {
        guard let p = target else { return }
        run("tell application \"\(p.rawValue)\" to next track")
    }

    func previousTrack() {
        guard let p = target else { return }
        run("tell application \"\(p.rawValue)\" to previous track")
    }
}
