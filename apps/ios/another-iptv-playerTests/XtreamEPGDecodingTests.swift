import Foundation
import Testing
@testable import another_iptv_player

@Suite("XtreamEPGDecoding")
struct XtreamEPGDecodingTests {

    @Test
    func base64TitleDecodes() {
        // "News" → base64
        #expect("TmV3cw==".epgDecodedBase64OrSelf == "News")
    }

    @Test
    func plainTextReturnedAsSelf() {
        #expect("Hello".epgDecodedBase64OrSelf == "Hello")          // length 5, not %4
        #expect("News at Ten".epgDecodedBase64OrSelf == "News at Ten")
    }

    @Test
    func base64ishButNotUTF8ReturnsSelf() {
        // Valid base64 alphabet + length, but decodes to control bytes → keep raw.
        let raw = "AAAA" // decodes to 3 NUL bytes → control → return self
        #expect(raw.epgDecodedBase64OrSelf == raw)
    }

    @Test
    func emptyStringSafe() {
        #expect("".epgDecodedBase64OrSelf == "")
    }

    @Test
    func decodesListingsWithMixedTimestampTypes() throws {
        let json = """
        { "epg_listings": [
            { "id": "1", "title": "TmV3cw==", "description": "SGVhZGxpbmVz",
              "channel_id": "BBC.One", "start_timestamp": "1784892600", "stop_timestamp": 1784896200,
              "has_archive": 1, "now_playing": 0 },
            { "id": "2", "title": "V2VhdGhlcg==", "start_timestamp": 1784896200, "stop_timestamp": "1784899800" }
        ] }
        """
        let response = try JSONDecoder().decode(XtreamEPGListingsResponse.self, from: Data(json.utf8))
        #expect(response.epgListings.count == 2)

        let first = response.epgListings[0]
        #expect(first.decodedTitle == "News")
        #expect(first.decodedDescription == "Headlines")
        #expect(first.startTimestamp == 1_784_892_600)   // parsed from string
        #expect(first.stopTimestamp == 1_784_896_200)    // parsed from int
        #expect(first.hasArchive == 1)

        let second = response.epgListings[1]
        #expect(second.decodedTitle == "Weather")
        #expect(second.startTimestamp == 1_784_896_200)  // from int
        #expect(second.stopTimestamp == 1_784_899_800)   // from string
    }

    @Test
    func toleratesMissingListings() throws {
        let response = try JSONDecoder().decode(XtreamEPGListingsResponse.self, from: Data("{}".utf8))
        #expect(response.epgListings.isEmpty)
    }
}
