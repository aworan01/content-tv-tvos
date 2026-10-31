import Foundation
import AVFoundation

struct DRMConfig:Codable,Hashable {
    var scheme:String
    var licenseURL=""
    var certificateURL=""
    var contentID=""
    var headers:[String:String]=[:]
    var keys:[String:String]=[:]
    var requestFormat="raw"
    var responseFormat="raw"
    var failure=""
    var supported:Bool{["fairplay","clearkey"].contains(scheme) && failure.isEmpty}
    static func bytes(_ input:String)->Data?{
        let text=input.replacingOccurrences(of:"-",with:"").replacingOccurrences(of:"0x",with:"")
        if text.range(of:"^[0-9a-fA-F]{32}$",options:.regularExpression) != nil{
            var result=Data();var i=text.startIndex;while i<text.endIndex{let end=text.index(i,offsetBy:2);guard let n=UInt8(text[i..<end],radix:16)else{return nil};result.append(n);i=end};return result
        }
        var value=input.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");value += String(repeating:"=",count:(4-value.count%4)%4)
        guard let data=Data(base64Encoded:value),data.count==16 else{return nil};return data
    }
    static func hex(_ value:String)throws->String{guard let bytes=bytes(value)else{throw TVFailure.unsupported("A ClearKey ID or key is invalid. Each must decode to exactly 16 bytes.")};return bytes.map{String(format:"%02x",$0)}.joined()}
    static func clearKeys(_ raw:String)throws->[String:String]{
        var text=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("data:"),let comma=text.firstIndex(of:","){
            let prefix=String(text[..<comma]),body=String(text[text.index(after:comma)...]);if prefix.hasSuffix(";base64"){guard let data=Data(base64Encoded:body),let value=String(data:data,encoding:.utf8)else{throw TVFailure.invalidData};text=value}else{text=body.removingPercentEncoding ?? body}
        }
        if text.lowercased().hasPrefix("%7b"){text=text.removingPercentEncoding ?? text}
        var values:[String:String]=[:]
        if let data=text.data(using:.utf8),let root=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{
            if let keys=root["keys"] as? [[String:Any]]{for key in keys{guard jsonString(key["kty"])=="oct" else{throw TVFailure.invalidData};values[try hex(jsonString(key["kid"]))]=try hex(jsonString(key["k"]))}}
            else{for(id,key)in root{values[try hex(id)]=try hex(jsonString(key))}}
        }else{let pair=text.split(separator:":",maxSplits:1).map(String.init);guard pair.count==2 else{throw TVFailure.invalidData};values[try hex(pair[0])]=try hex(pair[1])}
        guard !values.isEmpty,values.count<=64 else{throw TVFailure.invalidData};return values
    }
    func keyID(_ proposed:String)throws->String{
        if !proposed.isEmpty{let id=try Self.hex(proposed);guard keys[id] != nil else{throw TVFailure.unsupported("The HLS key ID is not present in the configured ClearKey response.")};return id}
        guard keys.count==1,let key=keys.keys.first else{throw TVFailure.unsupported("This HLS playlist needs an explicit KEYID to select among multiple ClearKeys.")};return key
    }
    func localKey(for id:String)throws->Data{guard let value=keys[id],let data=Self.bytes(value)else{throw TVFailure.invalidData};return data}
    func resolvingKeys(manifest:String)async throws->Self{
        guard scheme=="clearkey",!licenseURL.isEmpty,manifest.contains("#EXT-X-KEY:") else{return self}
        var kids=Set<String>()
        for line in manifest.components(separatedBy:.newlines) where line.hasPrefix("#EXT-X-KEY:"){
            let attrs=PlaylistParser.attributes(line.replacingOccurrences(of:",",with:" "));if let id=attrs["keyid"]{kids.insert(try Self.hex(id))}
        }
        if !kids.isEmpty && kids.allSatisfy({keys[$0] != nil}){return self}
        guard let url=webURL(licenseURL)else{throw TVFailure.invalidURL}
        let body=try JSONSerialization.data(withJSONObject:["kids":try kids.sorted().map{try localBase64ID($0)},"type":"temporary"])
        var headers=self.headers;headers["Content-Type"]="application/json"
        let payload=try await HTTP.request(url,headers:headers,method:"POST",body:body,limit:128*1024)
        guard let text=String(data:payload.data,encoding:.utf8)else{throw TVFailure.invalidData}
        var copy=self;copy.keys.merge(try Self.clearKeys(text)){_,new in new};return copy
    }
    private func localBase64ID(_ value:String)throws->String{guard let data=Self.bytes(value)else{throw TVFailure.invalidData};return data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
    static func declaration(_ properties:[String:String],attributes:[String:String])->Self?{
        let type=(properties["inputstream.adaptive.license_type"] ?? "").lowercased()
        guard !type.isEmpty || properties["inputstream.adaptive.license_key"] != nil else{return nil}
        let scheme:[String:String]=["com.widevine.alpha":"widevine","widevine":"widevine","edef8ba9-79d6-4ace-a3c8-27dcd51d21ed":"widevine","clearkey":"clearkey","org.w3.clearkey":"clearkey","e2719d58-a985-b3c9-781a-b030af78d30e":"clearkey","fairplay":"fairplay","com.apple.fps":"fairplay","com.apple.fps.1_0":"fairplay"]
        var config=Self(scheme:scheme[type] ?? type)
        if config.scheme=="widevine"{config.failure="Widevine is not supported on tvOS. This source needs a provider-supplied compatible stream.";return config}
        guard config.supported else{config.failure="This playlist declares an unsupported DRM system.";return config}
        let parts=(properties["inputstream.adaptive.license_key"] ?? "").split(separator:"|",omittingEmptySubsequences:false).map(String.init)
        if parts.count>2 && parts.dropFirst(2).contains(where:{!$0.isEmpty}){config.failure="Custom licence body/response templates are unsupported.";return config}
        if parts.count>1{for item in parts[1].split(separator:"&"){let pair=item.split(separator:"=",maxSplits:1).map(String.init);if pair.count==2{config.headers[pair[0].removingPercentEncoding ?? pair[0]]=pair[1].removingPercentEncoding ?? pair[1]}}}
        let value=parts.first ?? ""
        if webURL(value) != nil{config.licenseURL=value}
        else if config.scheme=="clearkey"{do{config.keys=try clearKeys(value)}catch{config.failure="Invalid ClearKey licence data. Each key and ID must decode to 16 bytes."}}
        else if !value.isEmpty{config.failure="FairPlay requires an HTTP(S) licence URL."}
        config.certificateURL=attributes["contenttv-fps-certificate"] ?? "";config.contentID=attributes["contenttv-fps-content-id"] ?? ""
        config.requestFormat=attributes["contenttv-fps-request"] ?? "raw";config.responseFormat=attributes["contenttv-fps-response"] ?? "raw"
        return config
    }
}

// Client-side FPS only. Certificates and licence responses come from the provider.
final class FairPlaySession:NSObject,AVContentKeySessionDelegate,@unchecked Sendable {
    private let config:DRMConfig
    private let session=AVContentKeySession(keySystem:.fairPlayStreaming)
    private let queue=DispatchQueue(label:"tv.content.fairplay")
    private let lock=NSLock();private var tasks:[UUID:Task<Void,Never>]=[:]
    var failure:((String)->Void)?
    init(config:DRMConfig,asset:AVURLAsset){self.config=config;super.init();session.setDelegate(self,queue:queue);session.addContentKeyRecipient(asset)}
    func contentKeySession(_ session:AVContentKeySession,didProvide keyRequest:AVContentKeyRequest){process(keyRequest)}
    func contentKeySession(_ session:AVContentKeySession,didProvideRenewingContentKeyRequest keyRequest:AVContentKeyRequest){process(keyRequest)}
    private func process(_ request:AVContentKeyRequest){
        let id=UUID();let task=Task{[weak self]in guard let self=self else{return};defer{self.remove(id)}
            do{
                guard let certificateURL=webURL(config.certificateURL),let licenseURL=webURL(config.licenseURL)else{throw TVFailure.unsupported("FairPlay requires the provider's certificate and licence URLs. Configure them in this source’s settings.")}
                let certificate=try await HTTP.request(certificateURL,headers:config.headers,limit:1024*1024).data
                let identifier=config.contentID.isEmpty ? (request.identifier as? String ?? (request.identifier as? URL)?.absoluteString ?? ""):config.contentID
                guard !identifier.isEmpty else{throw TVFailure.unsupported("The FairPlay content identifier is missing.")}
                let contentID=Data(identifier.replacingOccurrences(of:"skd://",with:"").utf8)
                let spc:Data=try await withCheckedThrowingContinuation{continuation in request.makeStreamingContentKeyRequestData(forApp:certificate,contentIdentifier:contentID,options:nil){data,error in if let data=data{continuation.resume(returning:data)}else{continuation.resume(throwing:TVFailure.unsupported("FairPlay could not generate the licence request for this stream."))}}}
                var headers=config.headers;let body:Data
                if config.requestFormat=="form"{var parts=URLComponents();parts.queryItems=[URLQueryItem(name:"spc",value:spc.base64EncodedString()),URLQueryItem(name:"assetId",value:identifier)];body=Data((parts.percentEncodedQuery ?? "").replacingOccurrences(of:"+",with:"%2B").utf8);headers["Content-Type"]="application/x-www-form-urlencoded"}
                else{body=spc;headers["Content-Type"]="application/octet-stream"}
                let payload=try await HTTP.request(licenseURL,headers:headers,method:"POST",body:body,limit:1024*1024)
                let ckc:Data
                if config.responseFormat=="base64"{let text=(String(data:payload.data,encoding:.utf8) ?? "").replacingOccurrences(of:"<ckc>",with:"").replacingOccurrences(of:"</ckc>",with:"").trimmingCharacters(in:.whitespacesAndNewlines);guard let data=Data(base64Encoded:text,options:.ignoreUnknownCharacters),!data.isEmpty else{throw TVFailure.invalidData};ckc=data}else{ckc=payload.data}
                try Task.checkCancellation();request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData:ckc))
            }catch{request.processContentKeyResponseError(TVFailure.unsupported("FairPlay licence acquisition failed. Check provider authorisation, certificate and licence settings."));if !Task.isCancelled{failure?(error is TVFailure ? error.localizedDescription:"FairPlay licence acquisition failed.")}}
        };lock.lock();tasks[id]=task;lock.unlock()
    }
    private func remove(_ id:UUID){lock.lock();tasks[id]=nil;lock.unlock()}
    func stop(){lock.lock();let current=tasks.values;tasks=[:];lock.unlock();for task in current{task.cancel()};session.expire()}
}
