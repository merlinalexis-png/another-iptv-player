import Foundation

struct PlaybackURLBuilder {
    let playlist: Playlist
    
    // nonisolated: pure string massaging over the (Sendable) playlist value; needed
    // by `xmltvURL()`/`queryAuthURL` which run on the EPG refresh background path.
    nonisolated private var cleanBaseURL: String {
        var baseString = playlist.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !baseString.lowercased().hasPrefix("http://") && !baseString.lowercased().hasPrefix("https://") {
            baseString = "http://\(baseString)"
        }
        
        // Remove trailing slash
        if baseString.hasSuffix("/") {
            baseString.removeLast()
        }
        
        // Remove player_api.php if user entered it
        if baseString.lowercased().hasSuffix("/player_api.php") {
            baseString = String(baseString.dropLast(15))
        } else if baseString.lowercased().hasSuffix("player_api.php") {
            baseString = String(baseString.dropLast(14))
        }
        
        return baseString.replacingOccurrences(of: " ", with: "")
    }
    
    /// Path segmenti için izinli karakterler: `urlPathAllowed` eksi segment ayırıcı `/`.
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    private var authPath: String {
        // Ham birleştirme, '#'/'?'/'/'/'%' içeren hesaplarda URL'yi sessizce bozuyordu
        // (login query-item kodlamasından geçtiği için çalışıyor, oynatma çalışmıyordu).
        let u = playlist.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = playlist.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let eu = u.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? u
        let ep = p.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? p
        return "\(eu)/\(ep)"
    }
    
    /// Builds URL for a live stream. Xtream API direct playback format uses server/u/p/id.
    func liveURL(streamId: Int, extension: String? = nil) -> URL? {
        var urlString = "\(cleanBaseURL)/\(authPath)/\(streamId)"
        if let ext = `extension`, !ext.isEmpty {
            urlString += ".\(ext)"
        }
        return URL(string: urlString)
    }
    
    /// Builds URL for a VOD (Movie).
    func movieURL(streamId: Int, containerExtension: String?) -> URL? {
        if let mock = MockFixture.demoPlaybackURL(playlistId: playlist.id) { return mock }
        let ext = containerExtension ?? "mp4"
        let urlString = "\(cleanBaseURL)/movie/\(authPath)/\(streamId).\(ext)"
        return URL(string: urlString)
    }

    /// Builds URL for a series episode.
    func seriesURL(streamId: String, containerExtension: String?) -> URL? {
        if let mock = MockFixture.demoPlaybackURL(playlistId: playlist.id) { return mock }
        let ext = containerExtension ?? "mp4"
        let urlString = "\(cleanBaseURL)/series/\(authPath)/\(streamId).\(ext)"
        return URL(string: urlString)
    }

    // MARK: - EPG / Catch-up

    /// Full XMLTV guide URL: `{host}/xmltv.php?username=&password=`. Credentials go
    /// as query items (not path segments), so the `'+' → %2B` PHP `$_GET` fix that
    /// `XtreamAPIClient` applies is replicated here.
    nonisolated func xmltvURL() -> URL? {
        queryAuthURL(path: "/xmltv.php", extraQuery: [])
    }

    /// Xtream timeshift `start` parameter — panel-LOCAL wall clock, minute
    /// granularity: "yyyy-MM-dd:HH-mm". Formatted in the panel's timezone, never
    /// the device's.
    static func timeshiftStartString(for date: Date, panelTimeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = panelTimeZone
        f.dateFormat = "yyyy-MM-dd:HH-mm"
        return f.string(from: date)
    }

    /// Path-style timeshift (XUI.one): `{host}/timeshift/{user}/{pass}/{minutes}/{start}/{id}.{ext}`.
    /// Reuses `authPath` so credentials with `#/?/%` are percent-encoded correctly.
    func timeshiftPathURL(streamId: Int, startUTC: Date, durationMinutes: Int,
                          panelTimeZone: TimeZone, extension ext: String = "ts") -> URL? {
        let start = Self.timeshiftStartString(for: startUTC, panelTimeZone: panelTimeZone)
        let urlString = "\(cleanBaseURL)/timeshift/\(authPath)/\(durationMinutes)/\(start)/\(streamId).\(ext)"
        return URL(string: urlString)
    }

    /// Legacy PHP timeshift: `{host}/streaming/timeshift.php?username=&password=&stream=&start=&duration=`.
    func timeshiftPHPURL(streamId: Int, startUTC: Date, durationMinutes: Int,
                         panelTimeZone: TimeZone) -> URL? {
        let start = Self.timeshiftStartString(for: startUTC, panelTimeZone: panelTimeZone)
        return queryAuthURL(path: "/streaming/timeshift.php", extraQuery: [
            URLQueryItem(name: "stream", value: String(streamId)),
            URLQueryItem(name: "start", value: start),
            URLQueryItem(name: "duration", value: String(durationMinutes))
        ])
    }

    /// Builds a `{cleanBaseURL}{path}?username=&password=[&extra]` URL, applying the
    /// PHP `$_GET` `'+' → %2B` fix (URLComponents leaves `+` unencoded, but PHP turns
    /// it into a space, silently corrupting credentials).
    nonisolated private func queryAuthURL(path: String, extraQuery: [URLQueryItem]) -> URL? {
        guard var comps = URLComponents(string: cleanBaseURL + path) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "username", value: playlist.username.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "password", value: playlist.password.trimmingCharacters(in: .whitespacesAndNewlines))
        ] + extraQuery
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }
}
