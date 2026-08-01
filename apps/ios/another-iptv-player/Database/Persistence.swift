import Foundation
import GRDB

/// `localized_contains` her satır için çağrılır (100k+ satır); sorgu kelimelerini satır
/// başına değil, sorgu değiştiğinde bir kez normalize etmek için son-sorgu önbelleği.
/// `nonisolated`: runs inside GRDB's DatabaseFunction callbacks on DB queues (a
/// DatabasePool serves concurrent readers), so all state is guarded by the lock.
private nonisolated final class NormalizedQueryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var lastQuery: String?
    private var lastWords: [String] = []

    func words(for query: String, normalize: (String) -> String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if lastQuery == query { return lastWords }
        let words = query
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map(normalize)
        lastQuery = query
        lastWords = words
        return words
    }
}

nonisolated extension AppDatabase {
    static let shared = makeShared()

    /// True: disk DB açılamadı, oturum bellek-içi çalışıyor — bu oturumda yazılan hiçbir
    /// veri kalıcı olmaz. Root view kullanıcıyı bir kez uyarır.
    nonisolated(unsafe) private(set) static var isEphemeral = false
    /// True: bozuk DB dosyası kenara alınıp diskte sıfırdan oluşturuldu — veriler
    /// sıfırlandı ama bundan sonrası kalıcı. Root view kullanıcıyı bir kez uyarır.
    nonisolated(unsafe) private(set) static var didResetCorruptStore = false

    private static func databaseFileURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

        // Use Bundle Identifier for a unique subfolder (crucial on macOS)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ogosko.another-iptv-player"
        let appDirectoryURL = appSupportURL.appendingPathComponent(bundleID, isDirectory: true)
        let directoryURL = appDirectoryURL.appendingPathComponent("Database", isDirectory: true)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("db.sqlite")
    }

    private static func makeShared() -> AppDatabase {
        do {
            // Eski db.sqlite + çoklu migration geçmişi yerine tek şema dosyası (yerel veri sıfırlanır).
            let databaseURL = try databaseFileURL()
            let dbPool = try DatabasePool(path: databaseURL.path, configuration: databaseConfiguration())
            return try AppDatabase(dbPool)
        } catch {
            Log.error("Persistence", "DB pool init failed (disk/sandbox/corrupt?): \(error.localizedDescription)")

            // Bozuk dosya olasılığı: dosyayı kenara alıp diskte SIFIRDAN dene. Bellek-içi
            // fallback'ten iyidir — veri sıfırlanır ama bundan sonrası kalıcı olur; eski
            // (geçici açılamayan) dosya .corrupt olarak saklanır.
            if let databaseURL = try? databaseFileURL() {
                let fm = FileManager.default
                if fm.fileExists(atPath: databaseURL.path) {
                    let backup = databaseURL.deletingPathExtension().appendingPathExtension("corrupt.sqlite")
                    try? fm.removeItem(at: backup)
                    try? fm.moveItem(at: databaseURL, to: backup)
                    try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
                    try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
                    if let pool = try? DatabasePool(path: databaseURL.path, configuration: databaseConfiguration()),
                       let db = try? AppDatabase(pool) {
                        didResetCorruptStore = true
                        Log.error("Persistence", "bozuk DB kenara alındı (db.corrupt.sqlite), yeni disk DB oluşturuldu")
                        return db
                    }
                }
            }

            // Disk dolu, sandbox sorunu → app'i öldürmek yerine in-memory fallback.
            // Veri kaybolur ama uygulama açık kalır; root view kullanıcıyı uyarır.
            do {
                let queue = try DatabaseQueue(configuration: databaseConfiguration())
                Log.error("Persistence", "in-memory DB fallback aktif — kullanıcı verisi bu oturumda kaybolacak")
                isEphemeral = true
                return try AppDatabase(queue)
            } catch {
                // Bellekte bile DB açılamıyorsa cihaz kritik durumda; net bir mesajla son çare.
                Log.error("Persistence", "in-memory DB fallback başarısız: \(error.localizedDescription)")
                fatalError("DB tamamen başarısız: \(error.localizedDescription)")
            }
        }
    }
    
    static func empty() -> AppDatabase {
        let dbQueue = try! DatabaseQueue(configuration: databaseConfiguration())
        return try! AppDatabase(dbQueue)
    }
    
    private static func databaseConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            let foldLocale = Locale(identifier: "en_US_POSIX")
            let alphanumericSet = CharacterSet.alphanumerics

            // Must stay in sync with CatalogTextSearch.normalize (see rationale there):
            // locale-invariant case fold + "ı"→"i" so lowercase queries match ALL-CAPS
            // names in both English ("HISTORY") and Turkish ("IŞIK") catalogs.
            let normalize: @Sendable (String) -> String = { s in
                let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldLocale)
                return folded
                    .replacingOccurrences(of: "ı", with: "i")
                    .components(separatedBy: alphanumericSet.inverted)
                    .joined()
            }

            let queryCache = NormalizedQueryCache()
            let containsFunc = DatabaseFunction("localized_contains", argumentCount: 2, pure: true) { (dbValues: [DatabaseValue]) -> DatabaseValueConvertible? in
                guard dbValues.count == 2,
                      let text = String.fromDatabaseValue(dbValues[0]),
                      let query = String.fromDatabaseValue(dbValues[1]) else { return nil }

                let normalizedText = normalize(text)
                let queryWords = queryCache.words(for: query, normalize: normalize)
                if queryWords.isEmpty { return false }

                // Every word in the query must be found in the normalized text
                return queryWords.allSatisfy { word in
                    normalizedText.contains(word)
                }
            }
            db.add(function: containsFunc)
            
            let startsWithFunc = DatabaseFunction("localized_starts_with", argumentCount: 2, pure: true) { (dbValues: [DatabaseValue]) -> DatabaseValueConvertible? in
                guard dbValues.count == 2,
                      let text = String.fromDatabaseValue(dbValues[0]),
                      let query = String.fromDatabaseValue(dbValues[1]) else { return nil }
                return normalize(text).hasPrefix(normalize(query))
            }
            db.add(function: startsWithFunc)
            
            let equalsFunc = DatabaseFunction("localized_equals", argumentCount: 2, pure: true) { (dbValues: [DatabaseValue]) -> DatabaseValueConvertible? in
                guard dbValues.count == 2,
                      let text = String.fromDatabaseValue(dbValues[0]),
                      let query = String.fromDatabaseValue(dbValues[1]) else { return nil }
                return normalize(text) == normalize(query)
            }
            db.add(function: equalsFunc)
        }
        return config
    }
}
