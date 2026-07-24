import Foundation
import GRDB

enum TimeshiftStyle: String {
    case path
    case php
}

struct ResolvedCatchupStream: Equatable {
    let url: URL
    let style: TimeshiftStyle
}

enum CatchupURLError: LocalizedError {
    case notAvailable
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .notAvailable: return L("epg.catchup.error.unavailable")
        case .network(let err): return L("epg.error.network", err.localizedDescription)
        }
    }
}

/// Resolves a working Xtream timeshift URL before playback, so we never tear down
/// and rebuild the player chain on a bad URL. Probes candidate shapes (path-style,
/// then legacy PHP) with a ranged GET and a media magic-byte check — a `200` HTML
/// error page is rejected. The winning shape is cached on the playlist.
enum CatchupURLResolver {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func resolve(playlist: Playlist,
                        streamId: Int,
                        startUTC: Date,
                        durationMinutes: Int,
                        panelTimeZone: TimeZone,
                        allowedFormats: [String]?) async throws -> ResolvedCatchupStream {
        let builder = PlaybackURLBuilder(playlist: playlist)
        let ext = preferredExtension(allowedFormats)

        // Candidate order: cached style first, then the other.
        let cached = playlist.timeshiftStyle.flatMap { TimeshiftStyle(rawValue: $0) }
        let order: [TimeshiftStyle] = cached == .php ? [.php, .path] : [.path, .php]

        var lastError: Error?
        for style in order {
            let url: URL?
            switch style {
            case .path:
                url = builder.timeshiftPathURL(streamId: streamId, startUTC: startUTC,
                                               durationMinutes: durationMinutes,
                                               panelTimeZone: panelTimeZone, extension: ext)
            case .php:
                url = builder.timeshiftPHPURL(streamId: streamId, startUTC: startUTC,
                                              durationMinutes: durationMinutes,
                                              panelTimeZone: panelTimeZone)
            }
            guard let url else { continue }
            do {
                if try await probe(url: url) {
                    await persistStyle(style, playlist: playlist)
                    return ResolvedCatchupStream(url: url, style: style)
                }
            } catch is CancellationError {
                throw CatchupURLError.notAvailable
            } catch {
                lastError = error
            }
        }
        if let lastError { throw CatchupURLError.network(lastError) }
        throw CatchupURLError.notAvailable
    }

    static func preferredExtension(_ allowedFormats: [String]?) -> String {
        // Prefer seekable HLS when advertised; plain `.ts` timeshift is frequently
        // non-seekable.
        if let formats = allowedFormats?.map({ $0.lowercased() }), formats.contains("m3u8") {
            return "m3u8"
        }
        return "ts"
    }

    /// True when the URL returns media (TS sync byte 0x47 or an `#EXTM3U` playlist),
    /// false for HTML/error bodies.
    private static func probe(url: URL) async throws -> Bool {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-7", forHTTPHeaderField: "Range")

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return false
        }
        var head: [UInt8] = []
        for try await b in bytes {
            head.append(b)
            if head.count >= 7 { break }
        }
        guard let first = head.first else { return false }
        if first == 0x47 { return true }                     // MPEG-TS sync byte
        if Array(head.prefix(7)) == Array("#EXTM3U".utf8) { return true }
        return false                                          // HTML / error page
    }

    private static func persistStyle(_ style: TimeshiftStyle, playlist: Playlist) async {
        guard playlist.timeshiftStyle != style.rawValue else { return }
        var updated = playlist
        updated.timeshiftStyle = style.rawValue
        try? await AppDatabase.shared.write { db in try updated.save(db) }
    }
}
