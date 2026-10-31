import Foundation
import CryptoKit

func stableID(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
func webURL(_ value: String) -> URL? { guard let url=URL(string:value), let scheme=url.scheme?.lowercased(), ["http","https"].contains(scheme),url.host != nil else{return nil};return url }
func normalized(_ value:String)->String {value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).replacingOccurrences(of:"\\b(uhd|fhd|hd|4k)\\b",with:"",options:.regularExpression).replacingOccurrences(of:"[^\\p{L}\\p{N}]",with:"",options:.regularExpression)}
func jsonString(_ value:Any?) -> String {if let s=value as? String{return s};if let n=value as? NSNumber{return n.stringValue};return ""}
func jsonArray(_ data:Data)throws->[[String:Any]] { guard let rows=try JSONSerialization.jsonObject(with:data) as? [[String:Any]] else{throw TVFailure.invalidData};return rows }

enum TVFailure: LocalizedError {
    case invalidURL,invalidData,tooLarge,noChannels,network,http(Int),storage,unsupported(String)
    var errorDescription:String? {switch self {
    case .invalidURL:return "Enter a valid HTTP or HTTPS URL."
    case .invalidData:return "The source returned an unsupported or incomplete response."
    case .tooLarge:return "The source exceeds this version's size limit. Use a smaller playlist or country-specific guide."
    case .noChannels:return "No playable channel entries were found. Enter a channel playlist, not an HLS media playlist."
    case .network:return "The source could not be reached. Check your connection and source details."
    case .http(let status):return "The server returned HTTP \(status). Check the source or try again later."
    case .storage:return "Private source storage could not be read or saved. Existing data has not been intentionally replaced."
    case .unsupported(let message):return message
    }}
}

enum SourceKind:String,Codable,CaseIterable {case m3u="M3U playlist",xtream="Xtream login"}
struct TVSource:Codable,Identifiable,Equatable {
    var id=UUID().uuidString;var name="";var kind:SourceKind = .m3u
    var address="";var username="";var password="";var guides:[String]=[];var offsetMinutes=0
}
struct TVChannel:Codable,Identifiable,Hashable {
    var id:String;var sourceID:String;var sourceName:String;var name:String;var url:String
    var group:String="Other";var guideID:String="";var logo:String="";var kind:String="live"
    var seriesID:String="";var summary:String="";var headers:[String:String]=[:];var restriction:String=""
}
struct TVTitle:Codable,Identifiable,Hashable {
    var id:String;var kind:String;var name:String;var poster:String="";var backdrop:String="";var year:String="";var plot:String="";var rating:String="";var genres:[String]=[]
}
struct TVProgramme:Codable,Identifiable,Hashable {
    var channelID:String;var title:String;var detail:String;var start:Date;var end:Date;var categories:[String]=[]
    var id:String {channelID+"|"+String(start.timeIntervalSince1970)+"|"+title}
    func shifted(_ minutes:Int)->Self {var copy=self;copy.start=copy.start.addingTimeInterval(Double(minutes)*60);copy.end=copy.end.addingTimeInterval(Double(minutes)*60);return copy}
}
struct TVGuide:Codable {
    var schedules:[String:[TVProgramme]]=[:];var names:[String:[String]]=[:];var icons:[String:String]=[:]
    var count:Int{schedules.values.reduce(0){$0+$1.count}}
    func matchedID(_ channel:TVChannel, override:String?=nil)->String? {
        if let override=override,!override.isEmpty{return schedules[override] == nil ? nil : override}
        if schedules[channel.guideID] != nil{return channel.guideID}
        let target=normalized(channel.name)
        let ids=names.keys.filter{ id in schedules[id] != nil && names[id,default:[]].contains{normalized($0)==target}}
        return ids.count==1 ? ids.first : nil
    }
    func schedule(_ channel:TVChannel,override:String?=nil,offset:Int=0)->[TVProgramme] {guard let key=matchedID(channel,override:override) else{return []};return schedules[key,default:[]].map{$0.shifted(offset)}}
    mutating func merge(_ other:TVGuide) {
        for (id,shows) in other.schedules {var seen=Set(schedules[id,default:[]].map{$0.id});schedules[id,default:[]].append(contentsOf:shows.filter{seen.insert($0.id).inserted});schedules[id]?.sort{$0.start<$1.start}}
        for(id,values)in other.names{names[id]=Array(Set(names[id,default:[]]+values))};icons.merge(other.icons){old,_ in old}
    }
}
struct SportsEvent:Identifiable {var id:String;var programme:TVProgramme;var channels:[TVChannel]}
struct HistoryEntry:Codable,Identifiable {var channel:TVChannel;var position:Double;var duration:Double;var watched:Date;var id:String{channel.id}}
enum ChannelOrder:String,Codable,CaseIterable {case source="Source order",az="A–Z",za="Z–A"}
func sortedChannels(_ channels:[TVChannel],order:ChannelOrder,group:String="All groups")->[TVChannel] {
    let rows=channels.filter{group=="All groups" || $0.group==group}
    switch order {case .source:return rows;case .az:return rows.enumerated().sorted{let c=$0.element.name.localizedCaseInsensitiveCompare($1.element.name);return c == .orderedSame ? $0.offset<$1.offset : c == .orderedAscending}.map{$0.element};case .za:return rows.enumerated().sorted{let c=$0.element.name.localizedCaseInsensitiveCompare($1.element.name);return c == .orderedSame ? $0.offset<$1.offset : c == .orderedDescending}.map{$0.element}}
}
func steppedChannel(_ channels:[TVChannel],current:TVChannel,step:Int)->TVChannel? {guard !channels.isEmpty else{return nil};let at=channels.firstIndex{$0.id==current.id} ?? (step>0 ? -1 : 0);return channels[((at+step)%channels.count+channels.count)%channels.count]}

enum PlaylistParser {
    static func attributes(_ text:String)->[String:String] {
        let regex=try! NSRegularExpression(pattern:"([\\w-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s]+))")
        let ns=text as NSString;var result:[String:String]=[:]
        for m in regex.matches(in:text,range:NSRange(location:0,length:ns.length)){let key=ns.substring(with:m.range(at:1)).lowercased();for i in 2...4 where m.range(at:i).location != NSNotFound{result[key]=ns.substring(with:m.range(at:i));break}}
        return result
    }
    static func parse(_ text:String,source:TVSource)->(channels:[TVChannel],guides:[String]) {
        var rows:[TVChannel]=[];var seen=Set<String>();var attrs:[String:String]=[:];var name="";var group="";var headers:[String:String]=[:];var restriction="";var guides:[String]=[]
        for raw in text.replacingOccurrences(of:"\u{feff}",with:"").components(separatedBy:.newlines) {
            let line=raw.trimmingCharacters(in:.whitespacesAndNewlines);if line.isEmpty{continue}
            if line.hasPrefix("#EXTM3U"){let a=attributes(line);for key in ["x-tvg-url","url-tvg","tvg-url"]{if let value=a[key]{guides += value.split(separator:",").map(String.init).filter{webURL($0) != nil}}}}
            else if line.hasPrefix("#EXTINF:") {
                attrs=attributes(line);headers=[:];restriction="";group=attrs["group-title"] ?? "Other"
                // The display-name comma is outside quoted attribute values.
                var quoted:Character?;var separator:String.Index?
                for index in line.indices{let c=line[index];if c=="\"" || c=="'"{if quoted==c{quoted=nil}else if quoted==nil{quoted=c}}else if c=="," && quoted==nil{separator=index;break}}
                name=separator.map{String(line[line.index(after:$0)...]).trimmingCharacters(in:.whitespaces)} ?? attrs["tvg-name"] ?? "Channel"
            } else if line.hasPrefix("#EXTGRP:"){group=String(line.dropFirst(8))}
            else if line.lowercased().hasPrefix("#extvlcopt:"){let pair=line.dropFirst(11).split(separator:"=",maxSplits:1).map(String.init);if pair.count==2{let key=pair[0].lowercased();if key=="http-user-agent"{headers["User-Agent"]=pair[1]};if key=="http-referrer" || key=="http-referer"{headers["Referer"]=pair[1]}}}
            else if line.lowercased().hasPrefix("#kodiprop:") && (line.lowercased().contains("license") || line.lowercased().contains("widevine") || line.lowercased().contains("clearkey")){restriction="This source declares protected playback. DRM support is not included in this first tvOS release."}
            else if !line.hasPrefix("#"),!name.isEmpty {
                let parts=line.split(separator:"|",maxSplits:1).map(String.init);let address=parts[0]
                if parts.count==2{for part in parts[1].split(separator:"&"){let pair=part.split(separator:"=",maxSplits:1).map(String.init);if pair.count==2{let key=pair[0].removingPercentEncoding ?? pair[0];let value=pair[1].removingPercentEncoding ?? pair[1];if !key.contains("\n") && !value.contains("\r") && !value.contains("\n"){headers[key]=value}}}}
                if let url=URL(string:address,relativeTo:webURL(source.address))?.absoluteURL,webURL(url.absoluteString) != nil {
                    let guideID=attrs["tvg-id"] ?? "";let id=source.id+":"+stableID(guideID+"|"+url.absoluteString)
                    if seen.insert(id).inserted{rows.append(TVChannel(id:id,sourceID:source.id,sourceName:source.name,name:name,url:url.absoluteString,group:group.isEmpty ? "Other":group,guideID:guideID,logo:attrs["tvg-logo"] ?? "",headers:headers,restriction:restriction))}
                }
                name="";attrs=[:];headers=[:];restriction=""
            }
        }
        return(rows,Array(Set(guides)).sorted())
    }
}

final class XMLTVParser:NSObject,XMLParserDelegate {
    private var programmeCount=0
    private static let dateLock=NSLock()
    private static let dateFormats:[DateFormatter] = ["yyyyMMddHHmmss Z","yyyyMMddHHmm Z","yyyyMMddHHmmss","yyyyMMddHHmm"].map{format in let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(secondsFromGMT:0);f.dateFormat=format;f.isLenient=false;return f}
    private var guide=TVGuide();private var declared="";private var current:TVProgramme?;private var buffer="";private var rootSeen=false;private var error:Error?;private let now:Date
    init(now:Date){self.now=now}
    static func date(_ value:String)->Date? {
        dateLock.lock();defer{dateLock.unlock()}
        for f in dateFormats{if let date=f.date(from:value){return date}}
        return nil
    }
    static func expanded(_ data:Data)throws->Data {
        guard data.starts(with:[0x1f,0x8b]) else{return data};var output:UnsafeMutablePointer<UInt8>?;var count=0
        let result=data.withUnsafeBytes{raw in ctv_inflate(raw.bindMemory(to:UInt8.self).baseAddress,data.count,&output,&count,256*1024*1024)}
        guard result==0,let output=output else{throw TVFailure.invalidData};return Data(bytesNoCopy:output,count:count,deallocator:.free)
    }
    static func parse(_ data:Data,now:Date=Date())throws->TVGuide {
        let expanded=try expanded(data);guard expanded.count<=256*1024*1024 else{throw TVFailure.tooLarge}
        let delegate=XMLTVParser(now:now);let parser=XMLParser(data:expanded);parser.shouldResolveExternalEntities=false;parser.externalEntityResolvingPolicy = .never;parser.delegate=delegate
        guard parser.parse(),delegate.rootSeen else{throw delegate.error ?? TVFailure.invalidData};for id in delegate.guide.schedules.keys{delegate.guide.schedules[id]?.sort{$0.start<$1.start}};return delegate.guide
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        buffer="";if name=="tv"{rootSeen=true}
        if name=="channel"{declared=attributes["id"] ?? ""}
        if name=="icon",!declared.isEmpty,let value=attributes["src"],webURL(value) != nil{guide.icons[declared]=value}
        if name=="programme",let id=attributes["channel"],let start=Self.date(attributes["start"] ?? ""),let end=Self.date(attributes["stop"] ?? ""),end>start{current=TVProgramme(channelID:id,title:"",detail:"",start:start,end:end)}
    }
    func parser(_ parser:XMLParser,foundCharacters string:String){buffer += string;if buffer.utf8.count>256*1024{error=TVFailure.tooLarge;parser.abortParsing()}}
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
        let text=buffer.trimmingCharacters(in:.whitespacesAndNewlines)
        if name=="display-name",!declared.isEmpty{guide.names[declared,default:[]].append(text)}
        if name=="channel"{declared=""}
        if current != nil{if name=="title",current!.title.isEmpty{current!.title=text};if name=="desc",current!.detail.isEmpty{current!.detail=text};if name=="category"{current!.categories.append(text)}}
        if name=="programme"{if let show=current,!show.title.isEmpty,show.end>now.addingTimeInterval(-86400),show.start<now.addingTimeInterval(2*86400){if programmeCount>=100000{error=TVFailure.tooLarge;parser.abortParsing()}else{guide.schedules[show.channelID,default:[]].append(show);programmeCount += 1}};current=nil}
        buffer=""
    }
}

struct GuidePreset:Identifiable {var id:String;var name:String;var url:String}
let guidePresets:[GuidePreset] = [
    GuidePreset(id:"UK1",name:"UK",url:"https://epgshare01.online/epgshare01/epg_ripper_UK1.xml.gz"),GuidePreset(id:"FI1",name:"Finland",url:"https://epgshare01.online/epgshare01/epg_ripper_FI1.xml.gz"),
    GuidePreset(id:"IS1",name:"Iceland",url:"https://iptv-epg.org/files/epg-is.xml.gz"),GuidePreset(id:"SE1",name:"Sweden",url:"https://epgshare01.online/epgshare01/epg_ripper_SE1.xml.gz"),
    GuidePreset(id:"LV1",name:"Latvia",url:"https://epgshare01.online/epgshare01/epg_ripper_LV1.xml.gz"),GuidePreset(id:"NL1",name:"Netherlands",url:"https://epgshare01.online/epgshare01/epg_ripper_NL1.xml.gz"),GuidePreset(id:"US2",name:"USA",url:"https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz")]
