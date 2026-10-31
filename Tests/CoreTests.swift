import XCTest
import Security
@testable import ContentTV

final class CoreTests:XCTestCase {
    let source=TVSource(id:"test-source",name:"Example",kind:.m3u,address:"https://example.invalid/list/channels.m3u")
    func channel(_ id:String,_ name:String,group:String="Other",guide:String="")->TVChannel{TVChannel(id:id,sourceID:"test-source",sourceName:"Example",name:name,url:"https://example.invalid/\(id).m3u8",group:group,guideID:guide)}
    func testPlaylistQuotedCommaRelativeURLAndGuide(){
        let text="""
        #EXTM3U x-tvg-url="https://example.invalid/guide.xml.gz"
        #EXTINF:-1 tvg-id="one" tvg-name="One, HD" group-title="News, World",News One
        ../one.m3u8
        """
        let result=PlaylistParser.parse(text,source:source)
        XCTAssertEqual(result.channels.count,1);XCTAssertEqual(result.channels[0].name,"News One")
        XCTAssertEqual(result.channels[0].group,"News, World");XCTAssertEqual(result.channels[0].url,"https://example.invalid/one.m3u8")
        XCTAssertEqual(result.guides,["https://example.invalid/guide.xml.gz"])
    }
    func testPlaylistHeadersAndDRMNotDiscarded(){
        let text="""
        #EXTM3U
        #EXTINF:-1,Protected
        #KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha
        #EXTVLCOPT:http-user-agent=ExampleAgent
        https://example.invalid/live.m3u8|Referer=https%3A%2F%2Fexample.invalid
        """
        let c=PlaylistParser.parse(text,source:source).channels[0]
        XCTAssertFalse(c.restriction.isEmpty);XCTAssertEqual(c.headers["User-Agent"],"ExampleAgent");XCTAssertEqual(c.headers["Referer"],"https://example.invalid")
    }
    func testPlaylistDedupAndNonHTTPRejection(){
        let text="#EXTM3U\n#EXTINF:-1,One\nhttps://example.invalid/one\n#EXTINF:-1,One\nhttps://example.invalid/one\n#EXTINF:-1,Local\nfile:///etc/passwd"
        XCTAssertEqual(PlaylistParser.parse(text,source:source).channels.count,1)
    }
    func testHLSMediaPlaylistIsNotChannelList(){XCTAssertTrue(PlaylistParser.parse("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts",source:source).channels.isEmpty)}
    func testStableChannelIDsAcrossRefresh(){let text="#EXTM3U\n#EXTINF:-1 tvg-id=one,One\nhttps://example.invalid/one";XCTAssertEqual(PlaylistParser.parse(text,source:source).channels[0].id,PlaylistParser.parse(text,source:source).channels[0].id)}
    func testSortingGroupsAndWrap(){let rows=[channel("a","Zulu",group:"News"),channel("b","Alpha"),channel("c","Beta",group:"News")];XCTAssertEqual(sortedChannels(rows,order:.az).map(\.id),["b","c","a"]);XCTAssertEqual(sortedChannels(rows,order:.za,group:"News").map(\.id),["a","c"]);XCTAssertEqual(steppedChannel(rows,current:rows[2],step:1)?.id,"a");XCTAssertEqual(steppedChannel(rows,current:rows[0],step:-1)?.id,"c");XCTAssertNil(steppedChannel([],current:rows[0],step:1))}
    func testGuideTimeZones(){XCTAssertEqual(XMLTVParser.date("20260101120000 +0200"),XMLTVParser.date("20260101100000 +0000"));XCTAssertNil(XMLTVParser.date("invalid"))}
    func testXMLTVWindowMatchingAndShift()throws{
        let data=Data("""
        <tv><channel id="news"><display-name>News HD</display-name></channel>
        <programme channel="news" start="20260101100000 +0000" stop="20260101110000 +0000"><title>Football &amp; news</title><desc>Details</desc><category>Sports</category></programme>
        <programme channel="news" start="20251201100000 +0000" stop="20251201110000 +0000"><title>Old</title></programme></tv>
        """.utf8)
        let guide=try XMLTVParser.parse(data,now:XMLTVParser.date("20260101103000 +0000")!)
        XCTAssertEqual(guide.count,1);let row=channel("a","News")
        XCTAssertEqual(guide.matchedID(row),"news");XCTAssertEqual(guide.schedule(row).first?.title,"Football & news")
        XCTAssertEqual(guide.schedule(row,offset:30).first?.start.timeIntervalSince1970,(guide.schedule(row).first?.start.timeIntervalSince1970 ?? 0)+1800)
    }
    func testAmbiguousGuideNamesNeedExplicitID(){let show=TVProgramme(channelID:"a",title:"Show",detail:"",start:Date(),end:Date().addingTimeInterval(60));let guide=TVGuide(schedules:["a":[show],"b":[show]],names:["a":["News"],"b":["News HD"]]);XCTAssertNil(guide.matchedID(channel("one","News")));XCTAssertEqual(guide.matchedID(channel("one","News",guide:"a")),"a");XCTAssertEqual(guide.matchedID(channel("one","News"),override:"b"),"b")}
    func testGuideMergeDeduplicatesAndSorts(){let show=TVProgramme(channelID:"a",title:"Show",detail:"",start:Date(),end:Date().addingTimeInterval(60));var guide=TVGuide(schedules:["a":[show]]);guide.merge(TVGuide(schedules:["a":[show]]));XCTAssertEqual(guide.count,1)}
    func testInvalidXMLAndGzipRejected(){XCTAssertThrowsError(try XMLTVParser.parse(Data("<html>not XMLTV</html>".utf8)));XCTAssertThrowsError(try XMLTVParser.parse(Data([0x1f,0x8b,0,0])))}
    func testGzipXMLTVExpansion()throws{let data=Data(base64Encoded:"H4sIAAAAAAACCrMpKbOzSc5IzMtLzVHITLFVys9LVbKzScksLshJrNTNS8xNtfPPS7XRRxGx0YdqAbKABgAAC7/X/EUAAAA=")!;let guide=try XMLTVParser.parse(data);XCTAssertEqual(guide.names["one"],["One"])}
    func testPrivateSourceKeychainRoundTrip()throws{
        let key="unit-test-source"
        defer{SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"tv.content.private",kSecAttrAccount as String:key] as CFDictionary)}
        try PrivateStore.write(key,[source]);let restored=try PrivateStore.read(key,as:[TVSource].self)
        XCTAssertEqual(restored,[source])
    }
    func testSevenRequestedGuideCountries(){XCTAssertEqual(Set(guidePresets.map(\.name)),Set(["UK","Finland","Iceland","Sweden","Latvia","Netherlands","USA"]))}
    func testXtreamEscapingAndStreamPaths()throws{
        var s=source;s.kind = .xtream;s.address="https://example.invalid/player_api.php";s.username="demo user";s.password="fake&pass/word"
        let endpoint=try Xtream.endpoint(s,action:"get_live_streams")
        let parts=URLComponents(string:endpoint)!
        XCTAssertEqual(parts.path,"/player_api.php");XCTAssertEqual(parts.queryItems?.first{$0.name=="password"}?.value,s.password)
        let url=Xtream.stream(s,kind:"live",id:"12",extension:"m3u8")
        XCTAssertTrue(url.contains("/live/demo%20user/fake%26pass%2Fword/12.m3u8"));XCTAssertNil(URLComponents(string:url)?.query)
    }
    func testXtreamParseCategoriesAndSeriesIDs()throws{
        let groups=Data("[{\"category_id\":1,\"category_name\":\"Sports\"}]".utf8)
        let live=try Xtream.parse(Data("[{\"stream_id\":42,\"name\":\"Sport\",\"category_id\":1,\"epg_channel_id\":\"sport.id\"}]".utf8),categories:groups,source:source,kind:"live")
        XCTAssertEqual(live.first?.group,"Sports");XCTAssertEqual(live.first?.guideID,"sport.id");XCTAssertTrue(live.first?.url.hasSuffix("/42.m3u8") ?? false)
        let series=try Xtream.parse(Data("[{\"series_id\":7,\"name\":\"Series\"}]".utf8),categories:groups,source:source,kind:"series")
        XCTAssertEqual(series.first?.seriesID,"7");XCTAssertEqual(series.first?.url,"")
    }
    func testXtreamInvalidHostRejectedBeforeParsing()throws{var bad=source;bad.address="invalid";XCTAssertThrowsError(try Xtream.parse(Data("[]".utf8),categories:Data("[]".utf8),source:bad,kind:"live"))}
    func testCatalogueMetadataValidationAndDedup()throws{let data=Data("{\"metas\":[{\"id\":\"tt123\",\"name\":\"Example\"},{\"id\":\"tt123\",\"name\":\"Duplicate\"},{\"id\":\"invalid\",\"name\":\"Skip\"}]}".utf8);let rows=try Catalogues.titles(data,kind:"movie");XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].name,"Example")}
    func testProviderConfigurationContainsRegionWithoutAPIKey(){let url=Catalogues.providerBase(["nfx","dnp"],region:"GB");let encoded=String(url.dropFirst(Catalogues.publicBase.count+1)).removingPercentEncoding!;XCTAssertEqual(String(data:Data(base64Encoded:encoded)!,encoding:.utf8),"nfx,dnp::GB");XCTAssertGreaterThan(Catalogues.providers.count,7)}
    func testHLSQualitiesComeFromAdvertisedVariants(){let qualities=Quality.parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n720.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n1080.m3u8");XCTAssertEqual(qualities.map(\.height),[720,1080]);XCTAssertEqual(qualities.first?.label,"Up to 720p");XCTAssertTrue(Quality.parse("#EXTM3U\n#EXTINF:6,\nsegment.ts").isEmpty)}
}
