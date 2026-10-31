import XCTest
import AVFoundation
import CoreVideo
@testable import ContentTV

final class TransportTests:XCTestCase {
    let kid="00112233445566778899aabbccddeeff"
    let key="ffeeddccbbaa99887766554433221100"
    func testRangesAndRejection()throws{
        XCTAssertEqual(try ByteRange.parse("bytes=20-29",size:100),ByteRange(start:20,end:29))
        XCTAssertEqual(try ByteRange.parse("bytes=-10",size:100),ByteRange(start:90,end:99))
        XCTAssertEqual(try ByteRange.parse("bytes=95-",size:100),ByteRange(start:95,end:99))
        for value in ["bytes=100-","bytes=5-2","bytes=0-1,3-4","bytes=-0","invalid"]{XCTAssertThrowsError(try ByteRange.parse(value,size:100))}
    }
    func testNestedHLSURIsAndFairPlayPreservation()throws{
        let text="#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio/a.m3u8\"\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://asset-id\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n../video/720.m3u8?x=1"
        var urls:[String]=[]
        let result=try HLSRewrite.rewrite(text,base:URL(string:"https://example.invalid/live/master.m3u8")!){url in urls.append(url.absoluteString);return "http://127.0.0.1/local/"+String(urls.count)}
        XCTAssertEqual(urls,["https://example.invalid/live/audio/a.m3u8","https://example.invalid/video/720.m3u8?x=1"])
        XCTAssertTrue(result.contains("skd://asset-id"));XCTAssertTrue(result.contains("http://127.0.0.1/local/2"))
    }
    func testClearKeyInputFormsAndValidation()throws{
        XCTAssertEqual(try DRMConfig.clearKeys(kid+":"+key),[kid:key])
        let k=DRMConfig.bytes(key)!.base64EncodedString(),id=DRMConfig.bytes(kid)!.base64EncodedString()
        let json="{\"keys\":[{\"kty\":\"oct\",\"kid\":\"\(id)\",\"k\":\"\(k)\"}]}"
        XCTAssertEqual(try DRMConfig.clearKeys(json),[kid:key]);XCTAssertEqual(try DRMConfig.clearKeys("data:application/json;base64,"+Data(json.utf8).base64EncodedString()),[kid:key])
        XCTAssertThrowsError(try DRMConfig.clearKeys("abcd:1234"));XCTAssertNil(DRMConfig.bytes("too short"))
    }
    func testClearKeyRewriteSelectsAdvertisedKID()throws{
        let config=DRMConfig(scheme:"clearkey",keys:[kid:key])
        let manifest="#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"https://example.invalid/key\",KEYID=0x\(kid),KEYFORMAT=\"org.w3.clearkey\"\nsegment.ts"
        let result=try HLSRewrite.rewrite(manifest,base:URL(string:"https://example.invalid/master.m3u8")!,drm:config){$0.absoluteString}
        XCTAssertTrue(result.contains("ctvkey://"+kid));XCTAssertFalse(result.contains("KEYFORMAT="));XCTAssertTrue(result.contains("KEYID="))
        XCTAssertThrowsError(try config.keyID("11223344556677889900aabbccddeeff00"))
    }
    func testWidevineDiagnosticAndPlaylistLicenseHeaders(){
        let wide=DRMConfig.declaration(["inputstream.adaptive.license_type":"com.widevine.alpha"],attributes:[:])
        XCTAssertEqual(wide?.scheme,"widevine");XCTAssertFalse(wide?.supported ?? true);XCTAssertTrue(wide?.failure.contains("tvOS") ?? false)
        let config=DRMConfig.declaration(["inputstream.adaptive.license_type":"clearkey","inputstream.adaptive.license_key":"https://example.invalid/license|Authorization=Bearer%20example"],attributes:[:])
        XCTAssertEqual(config?.headers["Authorization"],"Bearer example")
    }
    func testPlaylistPreservesClearKeyAndFairPlayDefaults(){
        var source=TVSource(name:"Example",address:"https://example.invalid/list")
        source.fairPlay=DRMConfig(scheme:"fairplay",licenseURL:"https://example.invalid/license",certificateURL:"https://example.invalid/cert")
        let text="#EXTM3U\n#EXTINF:-1,Clear example\n#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)\nhttps://example.invalid/live.m3u8\n#EXTINF:-1,FairPlay example\n#KODIPROP:inputstream.adaptive.license_type=com.apple.fps\nhttps://example.invalid/fps.m3u8"
        let rows=PlaylistParser.parse(text,source:source).channels
        XCTAssertEqual(rows.count,2);XCTAssertEqual(rows[0].drm?.keys,[kid:key]);XCTAssertEqual(rows[0].restriction,"");XCTAssertEqual(rows[1].drm?.certificateURL,"https://example.invalid/cert")
    }
    func testDaddyDirectoryAndScheduleParsing(){
        let directory="<a class=\"card\" href=\"/watch.php?id=60\"><div class=\"card__title\">Example Sports &amp; HD</div></a>"
        let rows=DaddyLive.channels(directory);XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].name,"Example Sports & HD");XCTAssertEqual(rows[0].transport,"daddy");XCTAssertEqual(rows[0].group,"Sports")
        let schedule="<div class=\"schedule__dayTitle\">Saturday - UK GMT</div><div class=\"schedule__category is-expanded\"><div class=\"card__meta\">Football</div><div class=\"schedule__categoryBody\"><div class=\"schedule__event\"><span class=\"schedule__time\">12:00</span><span class=\"schedule__eventTitle\">Team A vs Team B</span><div class=\"schedule__channels\"><a href=\"/watch.php?id=60\">Channel 60</a></div></div></div>"
        let events=DaddyLive.events(schedule);XCTAssertEqual(events.count,1);XCTAssertEqual(events.first?.category,"Football");XCTAssertEqual(events.first?.channels.first?.id,"daddy:60");XCTAssertEqual(events.first?.time,"12:00")
    }
    func testDaddyRawAndPNGTrailingMedia()throws{
        var ts=Data(repeating:0,count:376);ts[0]=0x47;ts[188]=0x47
        XCTAssertEqual(try DaddyTransport.unwrap(ts),ts)
        var png=Data([137,80,78,71,13,10,26,10,0,0,0,0,73,69,78,68,0,0,0,0]);png.append(ts)
        XCTAssertEqual(try DaddyTransport.unwrap(png),ts)
        XCTAssertEqual(try DaddyTransport.unwrap(Data("TIKTIKRAW".utf8)+ts),ts)
    }
    func testDaddyPixelPNGAndWebPExifCarriers()throws{
        var ts=Data(repeating:0,count:376);ts[0]=0x47;ts[188]=0x47
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAIAAAA8r+mnAAAAL0lEQVR4nGMI8fQGooAIBgYGGfluDgYQYOIqTmeQ2HWglmO3LMOGqmDfCkYGCgAA2M4JX8ryIJUAAAAASUVORK5CYII=")!
        XCTAssertEqual(try DaddyTransport.unwrap(png),ts)
        var webp=Data("RIFF".utf8);webp.append(contentsOf:[0x84,1,0,0]);webp.append(Data("WEBPEXIF".utf8));webp.append(contentsOf:[0x78,1,0,0]);webp.append(ts)
        XCTAssertEqual(try DaddyTransport.unwrap(webp),ts)
    }
    func testOldHistoryAndSourcesDecodeWithoutNewFields()throws{
        let source=TVSource(name:"Previous source",address:"https://example.invalid/list")
        let channel=TVChannel(id:"old",sourceID:source.id,sourceName:source.name,name:"Previous channel",url:"https://example.invalid/live.m3u8")
        let restored=try JSONDecoder().decode(TVChannel.self,from:JSONEncoder().encode(channel));XCTAssertNil(restored.drm);XCTAssertNil(restored.transport)
        XCTAssertEqual(try JSONDecoder().decode(TVSource.self,from:JSONEncoder().encode(source)),source)
    }
    func testLoopbackRelayRewritesAndDeliversConfiguredKey()async throws{
        let upstream=LocalHTTPServer();let base=try await upstream.start();defer{upstream.stop()}
        upstream.handler={request in
            XCTAssertEqual(request.headers["referer"],"https://example.invalid/")
            if request.path=="/master.m3u8"{return LocalReply(type:"application/vnd.apple.mpegurl",data:Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:6,\nsegment.ts".utf8))}
            if request.path=="/segment.ts"{return LocalReply(type:"video/mp2t",data:Data([0x47,1,2,3]))}
            XCTFail("Upstream key should be replaced by configured key");return LocalReply(status:404)
        }
        let relay=MediaRelay(headers:["Referer":"https://example.invalid/"],drm:DRMConfig(scheme:"clearkey",keys:[kid:key]))
        let url=try await relay.start(base.appendingPathComponent("master.m3u8"))
        do{
            let payload=try await HTTP.request(url);let text=String(data:payload.data,encoding:.utf8)!
            let keyURL=HTML.matches(#"URI="([^"]+)""#,text)[0][1]
            let keyData=try await HTTP.request(URL(string:keyURL)!).data
            XCTAssertEqual(keyData,DRMConfig.bytes(key))
            let segment=text.components(separatedBy:.newlines).last!
            let segmentData=try await HTTP.request(URL(string:segment)!).data;XCTAssertEqual(segmentData,Data([0x47,1,2,3]))
            let bad=URL(string:"/unknown/test.m3u8",relativeTo:url)!.absoluteURL
            let(_,response)=try await URLSession.shared.data(from:bad);XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,404)
        }catch{await relay.stop();throw error};await relay.stop()
    }
    func testNativeTorrentPeerTransferOverLoopback()async throws{
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("ContentTV-test-"+UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:folder)}
        let result=await Task.detached{ctv_torrent_loopback_test(folder.path)}.value
        XCTAssertEqual(result,0,"Native local peer transfer and selected-file read must succeed")
    }
    func testDaddyRangesApplyAfterUnwrapping()async throws{
        var ts=Data(repeating:0,count:376);ts[0]=0x47;ts[188]=0x47
        let expected=ts.subdata(in:188..<376)
        var carrier=Data([137,80,78,71,13,10,26,10,0,0,0,0,73,69,78,68,0,0,0,0]);carrier.append(ts)
        let upstream=LocalHTTPServer();let base=try await upstream.start();defer{upstream.stop()}
        upstream.handler={request in XCTAssertNil(request.headers["range"]);return LocalReply(type:"image/png",data:carrier)}
        let source=base.appendingPathComponent("segment.png")
        let relay=MediaRelay(headers:[:],daddy:DaddySession(stream:source,headers:[:]))
        let url=try await relay.start(source)
        do{let payload=try await HTTP.request(url,headers:["Range":"bytes=188-375"]);XCTAssertEqual(payload.response.statusCode,206);XCTAssertEqual(payload.data,expected);XCTAssertEqual(payload.response.value(forHTTPHeaderField:"Content-Range"),"bytes 188-375/376")}catch{await relay.stop();throw error};await relay.stop()
    }
    @MainActor func testConfiguredKeyDecryptsAndDecodesSyntheticHLS()async throws{
        let bundle=Bundle(for:TransportTests.self)
        guard let manifest=bundle.url(forResource:"master",withExtension:"m3u8",subdirectory:"Fixtures/ClearHLS")else{XCTFail("Missing synthetic HLS fixture");return}
        let directory=manifest.deletingLastPathComponent(),server=LocalHTTPServer()
        let base=try await server.start();defer{server.stop()}
        server.handler={request in
            let name=String(request.path.dropFirst());guard ["master.m3u8","segment0.ts","segment1.ts","segment2.ts"].contains(name)else{return LocalReply(status:404)}
            return LocalReply(type:name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl":"video/mp2t",data:try Data(contentsOf:directory.appendingPathComponent(name)))
        }
        let relay=MediaRelay(headers:[:],drm:DRMConfig(scheme:"clearkey",keys:[kid:key]))
        let url=try await relay.start(base.appendingPathComponent("master.m3u8"))
        let item=AVPlayerItem(url:url),player=AVPlayer()
        let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);item.add(output)
        player.replaceCurrentItem(with:item);player.isMuted=true;player.play()
        var decoded=false;let deadline=Date().addingTimeInterval(25)
        while Date()<deadline && item.status != .failed{
            if output.copyPixelBuffer(forItemTime:player.currentTime(),itemTimeForDisplay:nil) != nil{decoded=true;break}
            try await Task.sleep(for:.milliseconds(100))
        }
        player.pause();player.replaceCurrentItem(with:nil);await relay.stop()
        XCTAssertTrue(decoded,"AVPlayer must decrypt and decode the synthetic AES-128 HLS video through the configured ClearKey relay. Status: \(item.status.rawValue)")
    }
}
