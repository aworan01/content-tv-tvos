import Foundation
import Security

actor ResponseCache {
    static let shared=ResponseCache()
    private let root=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ContentTV",isDirectory:true)
    private func file(_ key:String)->URL{root.appendingPathComponent(stableID(key)+".data")}
    func get(_ key:String,maxAge:TimeInterval?=nil)->Data?{
        let path=file(key)
        if let age=maxAge,let date=(try? FileManager.default.attributesOfItem(atPath:path.path)[.modificationDate]) as? Date,Date().timeIntervalSince(date)>age{return nil}
        return try? Data(contentsOf:path)
    }
    func put(_ data:Data,key:String){try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try? data.write(to:file(key),options:.atomic)}
}

enum HTTP {
    static func data(_ address:String,limit:Int=32*1024*1024)async throws->Data {
        guard let url=webURL(address)else{throw TVFailure.invalidURL}
        var request=URLRequest(url:url);request.timeoutInterval=30;request.setValue("ContentTV-tvOS/0.2",forHTTPHeaderField:"User-Agent")
        do {
            let (bytes,response)=try await URLSession.shared.bytes(for:request)
            guard let response=response as? HTTPURLResponse else{throw TVFailure.network}
            guard (200..<300).contains(response.statusCode)else{throw TVFailure.http(response.statusCode)}
            if response.expectedContentLength>Int64(limit){throw TVFailure.tooLarge}
            var data=Data();data.reserveCapacity(min(max(Int(response.expectedContentLength),0),limit))
            for try await byte in bytes{try Task.checkCancellation();if data.count>=limit{throw TVFailure.tooLarge};data.append(byte)}
            return data
        }catch is CancellationError{throw CancellationError()}catch let failure as TVFailure{throw failure}catch{throw TVFailure.network}
    }
    static func cached(_ address:String,age:TimeInterval=86400,force:Bool=false)async throws->Data {
        if !force,let data=await ResponseCache.shared.get(address,maxAge:age){return data}
        do{let data=try await self.data(address);await ResponseCache.shared.put(data,key:address);return data}
        catch is CancellationError{throw CancellationError()}catch{if let old=await ResponseCache.shared.get(address){return old};throw error}
    }
}

enum PrivateStore {
    private static let service="tv.content.private"
    static func read<T:Decodable>(_ key:String,as:T.Type)throws->T?{
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:key,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result)
        if status==errSecItemNotFound{return nil};guard status==errSecSuccess,let data=result as? Data else{throw TVFailure.storage}
        do{return try JSONDecoder().decode(T.self,from:data)}catch{throw TVFailure.storage}
    }
    static func write<T:Encodable>(_ key:String,_ value:T)throws{
        let data=try JSONEncoder().encode(value);let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:key]
        let attrs:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status=SecItemUpdate(query as CFDictionary,attrs as CFDictionary)
        if status==errSecItemNotFound{var insert=query;insert.merge(attrs){_,new in new};status=SecItemAdd(insert as CFDictionary,nil)}
        guard status==errSecSuccess else{throw TVFailure.storage}
    }
}

struct Shelf:Identifiable,Hashable {var id:String;var name:String;var kind:String;var genre:String?=nil;var provider:String?=nil}
enum Catalogues {
    static let publicBase="https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club"
    static let providers:[(String,String)]=[("nfx","Netflix"),("hbm","HBO Max"),("dnp","Disney+"),("amp","Prime Video"),("atp","Apple TV+"),("pmp","Paramount+"),("hlu","Hulu"),("pcp","Peacock"),("cru","Crunchyroll"),("stz","Starz"),("dpe","Discovery+"),("mbi","Mubi"),("shd","Shudder"),("bbo","BritBox"),("act","Acorn TV"),("hay","Hayu"),("sst","SkyShowtime"),("cpd","Canal+"),("itv","ITVX"),("bbc","BBC iPlayer"),("al4","Channel 4"),("cts","Curiosity Stream"),("mgl","MagellanTV"),("nfk","Netflix Kids"),("clv","Clarovideo"),("gop","Globoplay"),("jhs","JioHotstar"),("zee","Zee5"),("nlz","NLZIET"),("vil","Videoland"),("vik","Rakuten Viki"),("sgo","Sky Go"),("sonyliv","Sony Liv"),("mp9","Movistar+"),("crc","Criterion Channel"),("iqi","iQIYI"),("sha","Shahid VIP")]
    static let standard:[Shelf]=[Shelf(id:"trending",name:"Trending movies",kind:"movie"),Shelf(id:"series",name:"Popular series",kind:"series"),Shelf(id:"anime",name:"Anime",kind:"series",genre:"Anime"),Shelf(id:"scifi",name:"Sci-Fi",kind:"movie",genre:"Sci-Fi"),Shelf(id:"thriller",name:"Thrillers",kind:"movie",genre:"Thriller"),Shelf(id:"action",name:"Action",kind:"movie",genre:"Action"),Shelf(id:"comedy",name:"Comedy",kind:"movie",genre:"Comedy")]
    static func component(_ value:String)->String{value.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? ""}
    static func providerBase(_ ids:[String],region:String)->String{let config=(ids.joined(separator:",")+"::"+region).data(using:.utf8)!.base64EncodedString();return publicBase+"/"+component(config)}
    static func titles(_ data:Data,kind:String)throws->[TVTitle]{
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw TVFailure.invalidData}
        let items=(root["metas"] as? [[String:Any]]) ?? (root["meta"] as? [String:Any]).map{[$0]} ?? []
        var seen=Set<String>();return items.compactMap{j in
            let id=jsonString(j["imdb_id"]).isEmpty ? jsonString(j["id"]) : jsonString(j["imdb_id"])
            guard id.range(of:"^tt[0-9]+$",options:.regularExpression) != nil,seen.insert(id).inserted else{return nil}
            let name=jsonString(j["name"]);guard !name.isEmpty else{return nil}
            return TVTitle(id:id,kind:kind,name:name,poster:jsonString(j["poster"]),backdrop:jsonString(j["background"]),year:jsonString(j["releaseInfo"]),plot:jsonString(j["description"]),rating:jsonString(j["imdbRating"]),genres:j["genres"] as? [String] ?? [])
        }
    }
    static func fetch(_ shelf:Shelf,region:String,force:Bool=false)async throws->[TVTitle]{
        let address:String
        if let provider=shelf.provider{address=providerBase([provider],region:region)+"/catalog/\(shelf.kind)/\(provider).json"}
        else if shelf.genre=="Anime"{address="https://anime-kitsu.strem.fun/catalog/series/kitsu-anime-trending.json"}
        else{address="https://cinemeta-catalogs.strem.io/top/catalog/\(shelf.kind)/top"+(shelf.genre.map{"/genre="+component($0)} ?? "")+".json"}
        if shelf.genre=="Anime"{
            let data=try await HTTP.cached(address,force:force)
            guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw TVFailure.invalidData}
            return (root["metas"] as? [[String:Any]] ?? []).compactMap{j in
                let id=jsonString(j["id"]),name=jsonString(j["name"])
                guard id.hasPrefix("kitsu:"),!name.isEmpty else{return nil}
                return TVTitle(id:id,kind:"series",name:name,poster:jsonString(j["poster"]),plot:jsonString(j["description"]))
            }
        }
        return try titles(await HTTP.cached(address,force:force),kind:shelf.kind)
    }
    static func search(_ query:String,kind:String)async throws->[TVTitle]{try titles(await HTTP.cached("https://v3-cinemeta.strem.io/catalog/\(kind)/top/search=\(component(query)).json",age:1800),kind:kind)}
    static func detail(_ title:TVTitle)async throws->TVTitle{if title.id.hasPrefix("kitsu:"){return title};return try titles(await HTTP.cached("https://v3-cinemeta.strem.io/meta/\(title.kind)/\(title.id).json"),kind:title.kind).first ?? title}
}

enum Xtream {
    static func endpoint(_ source:TVSource,action:String,extra:[URLQueryItem]=[])throws->String {
        guard var parts=URLComponents(string:source.address.trimmingCharacters(in:.whitespacesAndNewlines)),let host=parts.host,["http","https"].contains(parts.scheme?.lowercased() ?? ""),!host.isEmpty else{throw TVFailure.invalidURL}
        var path=parts.path;while path.hasSuffix("/"){path.removeLast()};if path.hasSuffix("/get.php"){path=String(path.dropLast(8))};if path.hasSuffix("/player_api.php"){path=String(path.dropLast(15))}
        parts.path=path+"/player_api.php";parts.queryItems=[URLQueryItem(name:"username",value:source.username),URLQueryItem(name:"password",value:source.password),URLQueryItem(name:"action",value:action)]+extra
        guard let url=parts.url else{throw TVFailure.invalidURL};return url.absoluteString
    }
    static func stream(_ source:TVSource,kind:String,id:String,extension ext:String)->String {
        var parts=URLComponents(string:source.address)!;var path=parts.percentEncodedPath;while path.hasSuffix("/"){path.removeLast()};for suffix in ["/get.php","/player_api.php"] where path.hasSuffix(suffix){path=String(path.dropLast(suffix.count))}
        let safe=ext.range(of:"^[A-Za-z0-9]{1,8}$",options:.regularExpression) != nil ? ext : "mp4"
        parts.percentEncodedPath=path+"/"+kind+"/"+Catalogues.component(source.username)+"/"+Catalogues.component(source.password)+"/"+Catalogues.component(id)+"."+safe;parts.query=nil
        return parts.url!.absoluteString
    }
    static func parse(_ data:Data,categories:Data,source:TVSource,kind:String)throws->[TVChannel]{
        _ = try endpoint(source,action:"get_live_streams")
        let groups=Dictionary(try jsonArray(categories).map{(jsonString($0["category_id"]),jsonString($0["category_name"]))},uniquingKeysWith:{old,_ in old})
        let rows=try jsonArray(data);var seen=Set<String>()
        return rows.compactMap{j in let identifier=jsonString(j[kind=="series" ? "series_id":"stream_id"]);guard !identifier.isEmpty else{return nil};let id=source.id+":"+kind+":"+identifier;guard seen.insert(id).inserted else{return nil}
            let address=kind=="series" ? "" : stream(source,kind:kind=="live" ? "live":"movie",id:identifier,extension:kind=="live" ? "m3u8":jsonString(j["container_extension"]))
            return TVChannel(id:id,sourceID:source.id,sourceName:source.name,name:jsonString(j["name"]),url:address,group:groups[jsonString(j["category_id"])] ?? "Other",guideID:jsonString(j["epg_channel_id"]),logo:jsonString(j[kind=="series" ? "cover":"stream_icon"]),kind:kind,seriesID:kind=="series" ? identifier:"",summary:jsonString(j["plot"]))
        }
    }
    static func fetch(_ source:TVSource,kind:String,force:Bool=false)async throws->[TVChannel]{
        let action=kind=="live" ? "get_live_streams" : kind=="series" ? "get_series":"get_vod_streams"
        let category=kind=="live" ? "get_live_categories" : kind=="series" ? "get_series_categories":"get_vod_categories"
        async let rows=HTTP.cached(try endpoint(source,action:action),age:6*3600,force:force)
        async let groups=HTTP.cached(try endpoint(source,action:category),age:6*3600,force:force)
        return try await parse(rows,categories:groups,source:source,kind:kind)
    }
    static func episodes(_ source:TVSource,series:TVChannel)async throws->[TVChannel]{
        let data=try await HTTP.cached(endpoint(source,action:"get_series_info",extra:[URLQueryItem(name:"series_id",value:series.seriesID)]),age:3600)
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],let seasons=root["episodes"] as? [String:Any] else{throw TVFailure.invalidData}
        var result:[TVChannel]=[]
        for season in seasons.keys.sorted(by:{($0 as NSString).integerValue<($1 as NSString).integerValue}){for j in seasons[season] as? [[String:Any]] ?? []{let identifier=jsonString(j["id"]);guard !identifier.isEmpty else{continue};let info=j["info"] as? [String:Any] ?? [:];result.append(TVChannel(id:source.id+":episode:"+identifier,sourceID:source.id,sourceName:source.name,name:"S\(season) · "+jsonString(j["title"]),url:stream(source,kind:"series",id:identifier,extension:jsonString(j["container_extension"])),group:"Season "+season,logo:jsonString(info["movie_image"]),kind:"episode",summary:jsonString(info["plot"])))} }
        return result
    }
}
