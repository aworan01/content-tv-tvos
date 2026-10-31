import Foundation
import ImageIO
import CoreGraphics

enum HTML {
    static func matches(_ pattern:String,_ text:String)->[[String]]{
        guard let regex=try? NSRegularExpression(pattern:pattern,options:[.dotMatchesLineSeparators])else{return []}
        let value=text as NSString
        return regex.matches(in:text,range:NSRange(location:0,length:value.length)).map{match in (0..<match.numberOfRanges).map{index in let range=match.range(at:index);return range.location==NSNotFound ? "":value.substring(with:range)}}
    }
    static func plain(_ text:String)->String{
        var result=text.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression)
        for pair in [("&amp;","&"),("&quot;","\""),("&#039;","'"),("&apos;","'"),("&lt;","<"),("&gt;",">"),("&nbsp;"," ")]{result=result.replacingOccurrences(of:pair.0,with:pair.1)}
        for row in matches("&#(x[0-9a-fA-F]+|[0-9]+);",result){let hex=row[1].hasPrefix("x");if let n=UInt32(hex ? String(row[1].dropFirst()):row[1],radix:hex ? 16:10),let scalar=UnicodeScalar(n){result=result.replacingOccurrences(of:row[0],with:String(scalar))}}
        return result.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func field(_ name:String,_ text:String)->String{plain(matches("class=\""+NSRegularExpression.escapedPattern(for:name)+"\"[^>]*>(.*?)</(?:div|span)>",text).first?[1] ?? "")}
}
struct DaddyEvent:Identifiable,Codable {var id:String;var name:String;var category:String;var time:String;var scheduleDate:String;var channels:[TVChannel]}
enum DaddyLive {
    static let home="https://thedaddy.pk"
    static func channels(_ html:String)->[TVChannel]{
        var seen=Set<String>()
        return HTML.matches(#"<a\s+class="card"(.*?)</a>"#,html).compactMap{row in
            guard let id=HTML.matches(#"href="/watch\.php\?id=([1-9][0-9]{0,5})""#,row[1]).first?[1],seen.insert(id).inserted else{return nil}
            let name=HTML.field("card__title",row[1]);guard !name.isEmpty else{return nil}
            let image=HTML.matches(#"<img[^>]+src="([^"]+)""#,row[1]).first?[1] ?? ""
            let group=["sport","espn","bein","tennis","cricket","golf","racing","nfl","nba","football","ufc","arena"].contains(where:name.lowercased().contains) ? "Sports":"DaddyLive"
            return channel(id,name,group:group,logo:image)
        }
    }
    static func channel(_ id:String,_ name:String,group:String="DaddyLive",logo:String="")->TVChannel{
        TVChannel(id:"daddy:"+id,sourceID:"daddylive",sourceName:"DaddyLive",name:name,url:home+"/stream/stream-"+id+".php",group:group,logo:logo.isEmpty ? "":URL(string:logo,relativeTo:URL(string:home))?.absoluteString ?? "",transport:"daddy")
    }
    static func events(_ html:String)->[DaddyEvent]{
        let date=HTML.field("schedule__dayTitle",html)
        var result:[DaddyEvent]=[]
        let divided=html.replacingOccurrences(of:#"<div class="schedule__category(?: [^"]*)?">"#,with:"\u{1e}",options:.regularExpression)
        for category in divided.components(separatedBy:"\u{1e}").dropFirst(){
            let label=HTML.field("card__meta",category)
            for block in category.components(separatedBy:"<div class=\"schedule__event\">").dropFirst(){
                let name=HTML.field("schedule__eventTitle",block),time=HTML.field("schedule__time",block)
                var seen=Set<String>();let channels=HTML.matches(#"<a\b[^>]*href="/(?:watch\.php\?id=|stream/stream-)([1-9][0-9]{0,5})(?:\.php)?"[^>]*>(.*?)</a>"#,block).compactMap{row ->TVChannel? in guard seen.insert(row[1]).inserted else{return nil};return channel(row[1],HTML.plain(row[2]),group:"Sports")}
                if !name.isEmpty && !channels.isEmpty{result.append(DaddyEvent(id:stableID(date+time+name),name:name,category:label,time:time,scheduleDate:date,channels:channels))}
            }
        };return result
    }
    static func loadChannels(force:Bool=false)async throws->[TVChannel]{let data=try await HTTP.cached(home+"/24-7-channels.php",age:3600,force:force);guard let html=String(data:data,encoding:.utf8)else{throw TVFailure.invalidData};let values=channels(html);guard !values.isEmpty else{throw TVFailure.unsupported("DaddyLive’s directory format changed or returned no channels.")};return values}
    static func loadEvents(force:Bool=false)async throws->[DaddyEvent]{let data=try await HTTP.cached(home+"/",age:900,force:force);guard let html=String(data:data,encoding:.utf8)else{throw TVFailure.invalidData};return events(html)}
    static func resolve(_ channel:TVChannel)async throws->(URL,[String:String],DaddySession){
        guard channel.url.hasPrefix(home+"/stream/stream-"),channel.url.range(of:#"/stream/stream-[1-9][0-9]{0,5}\.php$"#,options:.regularExpression) != nil,let url=webURL(channel.url)else{throw TVFailure.invalidURL}
        let page=try await HTTP.request(url,headers:["Referer":home+"/"])
        guard let html=String(data:page.data,encoding:.utf8),let embed=HTML.matches(#"<iframe[^>]*src="(https://[^"]+)""#,html).first?[1],let embedded=webURL(embed)else{throw TVFailure.unsupported("DaddyLive’s channel player is unavailable or changed format.")}
        let player=try await HTTP.request(embedded,headers:["Referer":home+"/"])
        guard let text=String(data:player.data,encoding:.utf8),let src=HTML.matches(#"const\s+SRC\s*=\s*"(https://[^"]+)""#,text).first?[1],let stream=webURL(src)else{throw TVFailure.unsupported("DaddyLive’s stream resolver changed. Try another channel or refresh.")}
        let origin=embedded.scheme!+"://"+embedded.host!+(embedded.port.map{":"+String($0)} ?? "")
        let headers=["Referer":embed,"Origin":origin,"User-Agent":"Mozilla/5.0"]
        return(stream,headers,DaddySession(stream:stream,headers:headers))
    }
}
actor DaddySession {
    private let stream:URL;private let headers:[String:String];private var token="";private var expires=Date.distantPast
    init(stream:URL,headers:[String:String]){self.stream=stream;self.headers=headers}
    func authorized(_ url:URL)async throws->URL{
        guard url.pathExtension.lowercased()=="m3u8"else{return url}
        if Date()>=expires{
            let slug=stream.pathComponents.filter{$0 != "/"}.first ?? ""
            var parts=URLComponents(url:stream,resolvingAgainstBaseURL:false)!;parts.path="/api/playlist-token";parts.queryItems=[URLQueryItem(name:"slug",value:slug)]
            let payload=try await HTTP.request(parts.url!,headers:headers,limit:128*1024)
            guard let root=try JSONSerialization.jsonObject(with:payload.data) as? [String:Any],let value=root["token"] as? String,!value.isEmpty else{throw TVFailure.unsupported("DaddyLive did not return a playlist token.")}
            token=value;let ttl=(root["ttl"] as? NSNumber)?.doubleValue ?? 120;expires=Date().addingTimeInterval(max(5,min(ttl/2,300)))
        }
        var parts=URLComponents(url:url,resolvingAgainstBaseURL:false)!
        parts.queryItems=(parts.queryItems ?? []).filter{!["t","_"].contains($0.name)}+[URLQueryItem(name:"t",value:token),URLQueryItem(name:"_",value:String(Int(Date().timeIntervalSince1970*1000)))]
        return parts.url!
    }
    func invalidate(){expires = .distantPast}
}

enum DaddyTransport {
    private static func match(_ data:Data,_ at:Int,_ text:String)->Bool{let value=Data(text.utf8);return at>=0 && at+value.count<=data.count && data.subdata(in:at..<at+value.count)==value}
    private static func number(_ data:Data,_ at:Int)->Int{guard at>=0,at+4<=data.count else{return -1};return data[at..<at+4].reduce(0){($0<<8)|Int($1)}}
    private static func expand(_ data:Data)throws->Data{guard data.count>0 else{throw TVFailure.invalidData};var output:UnsafeMutablePointer<UInt8>?;var count=0;let result=data.withUnsafeBytes{ctv_inflate($0.bindMemory(to:UInt8.self).baseAddress,data.count,&output,&count,24*1024*1024)};guard result==0,let pointer=output else{throw TVFailure.invalidData};return Data(bytesNoCopy:pointer,count:count,deallocator:.free)}
    static func unwrap(_ raw:Data)throws->Data{
        guard raw.count>=8,!raw.starts(with:Data("#EXTM3U".utf8)),raw.first != 0x47 else{return raw}
        if raw[0]==137 && match(raw,1,"PNG"){
            var p=8
            while p+12<=raw.count{let n=number(raw,p);guard n>=0,n<=raw.count-p-12 else{break};let last=match(raw,p+4,"IEND");p += n+12;if last{if p<raw.count,raw[p]==0x47{return raw.subdata(in:p..<raw.count)};break}}
            guard let source=CGImageSourceCreateWithData(raw as CFData,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,width>0,height>0,width<=8192,height<=8192,width*height<=8*1024*1024,let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary)else{throw TVFailure.invalidData}
            var pixels=[UInt8](repeating:0,count:width*height*4)
            let rendered=pixels.withUnsafeMutableBytes{buffer ->Bool in guard let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)else{return false};context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true}
            guard rendered else{throw TVFailure.invalidData};var rgb=Data();rgb.reserveCapacity(width*height*3);for i in stride(from:0,to:pixels.count,by:4){rgb.append(contentsOf:pixels[i..<i+3])}
            guard match(rgb,0,"TIKTIKPX"),rgb.count>=12 else{throw TVFailure.invalidData};let length=number(rgb,8);guard length>0,length<=rgb.count-12 else{throw TVFailure.invalidData};return try expand(rgb.subdata(in:12..<12+length))
        }
        if match(raw,0,"RIFF") && match(raw,8,"WEBP"){
            var p=12;while p+8<=raw.count{let value=number(raw,p+4);let n=Int(UInt32(value).byteSwapped);guard n>=0,n<=raw.count-p-8 else{break};if match(raw,p,"EXIF"),n>=188,raw[p+8]==0x47{return raw.subdata(in:p+8..<p+8+n)};p += 8+n+(n&1)}
        }
        for marker in ["TIKTIKRAW","TIKTIKTSGZ"]{if let range=raw.range(of:Data(marker.utf8)){let tail=raw.subdata(in:range.upperBound..<raw.count);return marker=="TIKTIKTSGZ" ? try expand(tail):tail}}
        return raw
    }
}
