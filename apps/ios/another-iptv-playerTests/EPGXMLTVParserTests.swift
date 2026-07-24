import Foundation
import Testing
@testable import another_iptv_player

@Suite("EPGXMLTVParser")
struct EPGXMLTVParserTests {

    // MARK: - Timestamp parsing

    @Test
    func parsesFullTimestampWithPositiveOffset() {
        // 2026-07-22 14:30:00 +0300 → 2026-07-22 11:30:00 UTC
        let ts = EPGXMLTVParser.parseXMLTVTimestamp("20260722143000 +0300", defaultOffsetSeconds: 0)
        #expect(ts == 1_784_719_800)
    }

    @Test
    func parsesNegativeOffset() {
        // 2026-07-22 14:30:00 -0500 → 2026-07-22 19:30:00 UTC
        let ts = EPGXMLTVParser.parseXMLTVTimestamp("20260722143000 -0500", defaultOffsetSeconds: 0)
        let utc = EPGXMLTVParser.parseXMLTVTimestamp("20260722193000 +0000", defaultOffsetSeconds: 0)
        #expect(ts == utc)
    }

    @Test
    func offsetlessUsesDefault() {
        // No offset in the string → apply defaultOffsetSeconds (+2h here).
        let withDefault = EPGXMLTVParser.parseXMLTVTimestamp("20260722143000", defaultOffsetSeconds: 7200)
        let explicit = EPGXMLTVParser.parseXMLTVTimestamp("20260722143000 +0200", defaultOffsetSeconds: 0)
        #expect(withDefault == explicit)
    }

    @Test
    func parsesTruncatedToMinute() {
        // Missing seconds → treated as :00
        let truncated = EPGXMLTVParser.parseXMLTVTimestamp("202607221430", defaultOffsetSeconds: 0)
        let full = EPGXMLTVParser.parseXMLTVTimestamp("20260722143000", defaultOffsetSeconds: 0)
        #expect(truncated == full)
    }

    @Test
    func rejectsGarbageAndTooShort() {
        #expect(EPGXMLTVParser.parseXMLTVTimestamp("nope", defaultOffsetSeconds: 0) == nil)
        #expect(EPGXMLTVParser.parseXMLTVTimestamp("2026", defaultOffsetSeconds: 0) == nil)
        #expect(EPGXMLTVParser.parseXMLTVTimestamp(nil, defaultOffsetSeconds: 0) == nil)
    }

    @Test
    func rejectsOutOfRangeComponents() {
        #expect(EPGXMLTVParser.parseXMLTVTimestamp("20261322143000", defaultOffsetSeconds: 0) == nil) // month 13
        #expect(EPGXMLTVParser.parseXMLTVTimestamp("20260722253000", defaultOffsetSeconds: 0) == nil) // hour 25
    }

    @Test
    func daysFromCivilEpochAnchor() {
        #expect(EPGXMLTVParser.daysFromCivil(year: 1970, month: 1, day: 1) == 0)
        #expect(EPGXMLTVParser.daysFromCivil(year: 1970, month: 1, day: 2) == 1)
        #expect(EPGXMLTVParser.daysFromCivil(year: 1969, month: 12, day: 31) == -1)
    }

    // MARK: - End-to-end parse + filtering

    private func makeOptions(ids: Set<String>, names: Set<String> = []) -> EPGXMLTVParser.Options {
        EPGXMLTVParser.Options(
            wantedChannelIds: ids,
            wantedDisplayNames: names,
            pastCutoffTs: 0,
            futureCutoffTs: Int64.max,
            defaultUTCOffsetSeconds: 0,
            batchSize: 100
        )
    }

    private func runParse(_ xml: String, options: EPGXMLTVParser.Options)
        -> (channels: [XMLTVChannel], programmes: [XMLTVProgramme], diag: XMLTVParseDiagnostics) {
        var channels: [XMLTVChannel] = []
        var programmes: [XMLTVProgramme] = []
        let parser = EPGXMLTVParser(
            options: options,
            onChannelBatch: { channels.append(contentsOf: $0); return true },
            onProgrammeBatch: { programmes.append(contentsOf: $0); return true }
        )
        let diag = (try? parser.parse(data: Data(xml.utf8))) ?? XMLTVParseDiagnostics()
        return (channels, programmes, diag)
    }

    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="BBC.One.uk"><display-name>BBC One</display-name><icon src="http://x/bbc.png"/></channel>
      <channel id="Other.tv"><display-name>Other Channel</display-name></channel>
      <programme start="20260722140000 +0000" stop="20260722150000 +0000" channel="BBC.One.uk">
        <title>News</title><desc>Headlines</desc><category>News</category>
      </programme>
      <programme start="20260722150000 +0000" stop="20260722160000 +0000" channel="bbc.one.uk">
        <title>Weather</title>
      </programme>
      <programme start="20260722140000 +0000" stop="20260722150000 +0000" channel="Other.tv">
        <title>Unwanted</title>
      </programme>
    </tv>
    """

    @Test
    func matchesByIdCaseInsensitively() {
        // Wanted id lowercased; feed uses mixed case on both channel and programme.
        let result = runParse(sample, options: makeOptions(ids: ["bbc.one.uk"]))
        #expect(result.channels.map(\.id) == ["bbc.one.uk"])
        #expect(result.programmes.count == 2) // News + Weather; "Other.tv" excluded
        #expect(result.programmes.contains { $0.title == "News" })
        #expect(result.programmes.contains { $0.title == "Weather" })
        #expect(!result.programmes.contains { $0.title == "Unwanted" })
    }

    @Test
    func matchesByDisplayNameFallback() {
        // No wanted id, but the display name matches → channel accepted and its
        // programmes are kept under the feed's channel id.
        let result = runParse(sample, options: makeOptions(ids: [], names: ["bbc one"]))
        #expect(result.channels.map(\.id) == ["bbc.one.uk"])
        #expect(result.programmes.contains { $0.title == "News" })
        #expect(result.programmes.contains { $0.title == "Weather" })
    }

    @Test
    func filtersOutOfWindow() {
        var opts = makeOptions(ids: ["bbc.one.uk"])
        // Window entirely before the programmes → all skipped.
        opts.pastCutoffTs = 0
        opts.futureCutoffTs = 100
        let result = runParse(sample, options: opts)
        #expect(result.programmes.isEmpty)
        #expect(result.diag.skippedOutOfWindow >= 2)
    }

    @Test
    func abortWhenBatchReturnsFalse() {
        var programmes: [XMLTVProgramme] = []
        let parser = EPGXMLTVParser(
            options: makeOptions(ids: ["bbc.one.uk"]),
            onChannelBatch: { _ in true },
            onProgrammeBatch: { programmes.append(contentsOf: $0); return false } // abort on first batch
        )
        #expect(throws: (any Error).self) {
            _ = try parser.parse(data: Data(sample.utf8))
        }
    }
}
