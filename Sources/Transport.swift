import Foundation
import Network

struct HTTPPayload {var data:Data;var response:HTTPURLResponse}
extension HTTP {
    static func request(_ url:URL,headers:[String:String]=[:],method:String="GET",body:Data?=nil,limit:Int=24*1024*1024)async throws->HTTPPayload{
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=body;request.timeoutInterval=35
        request.setValue("Mozilla/5.0 ContentTV/0.3",forHTTPHeaderField:"User-Agent")
        for(key,value)in headers where key.range(of:"^[A-Za-z0-9-]+$",options:.regularExpression) != nil && !value.contains("\r") && !value.contains("\n") && !["host","content-length","connection"].contains(key.lowercased()){request.setValue(value,forHTTPHeaderField:key)}
        do{
            let(bytes,response)=try await URLSession.shared.bytes(for:request)
            guard let response=response as? HTTPURLResponse else{throw TVFailure.network}
            guard (200..<300).contains(response.statusCode)else{throw TVFailure.http(response.statusCode)}
            guard method=="HEAD" || response.expectedContentLength<=limit else{throw TVFailure.tooLarge}
            var data=Data();for try await byte in bytes{try Task.checkCancellation();if data.count>=limit{throw TVFailure.tooLarge};data.append(byte)}
            return HTTPPayload(data:data,response:response)
        }catch is CancellationError{throw CancellationError()}catch let failure as TVFailure{throw failure}catch{throw TVFailure.network}
    }
}
struct LocalRequest {var method:String;var path:String;var headers:[String:String]}
struct LocalReply {
    var status=200;var type="application/octet-stream";var headers:[String:String]=[:];var data=Data()
    var length:Int64?;var reader:((Int64,Int)async throws->Data)?;var start:Int64=0
}
struct ByteRange:Equatable {
    var start:Int64;var end:Int64
    var length:Int64{end-start+1}
    static func parse(_ value:String?,size:Int64)throws->ByteRange{
        guard size>0 else{throw TVFailure.invalidData}
        guard let value=value else{return ByteRange(start:0,end:size-1)}
        guard value.hasPrefix("bytes="),!value.contains(",")else{throw TVFailure.invalidData}
        let pair=value.dropFirst(6).split(separator:"-",maxSplits:1,omittingEmptySubsequences:false)
        guard pair.count==2 else{throw TVFailure.invalidData}
        if pair[0].isEmpty{guard let suffix=Int64(pair[1]),suffix>0 else{throw TVFailure.invalidData};return ByteRange(start:max(size-suffix,0),end:size-1)}
        guard let start=Int64(pair[0]),start>=0,start<size else{throw TVFailure.invalidData}
        let end:Int64;if pair[1].isEmpty{end=size-1}else{guard let parsed=Int64(pair[1]),parsed>=start else{throw TVFailure.invalidData};end=min(parsed,size-1)}
        return ByteRange(start:start,end:end)
    }
}

// Bound to loopback, with per-session unguessable routes. Never a network-facing proxy.
final class LocalHTTPServer:@unchecked Sendable {
    private let queue=DispatchQueue(label:"tv.content.loopback")
    private var listener:NWListener?
    private var clients:[UUID:NWConnection]=[:]
    private var tasks:[UUID:Task<Void,Never>]=[:]
    var handler:((LocalRequest)async throws->LocalReply)?
    func start()async throws->URL{
        try await withCheckedThrowingContinuation{continuation in queue.async{
            do{
                let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
                let listener=try NWListener(using:parameters);self.listener=listener;var resumed=false
                listener.stateUpdateHandler={state in
                    switch state{
                    case .ready:if !resumed,let port=listener.port{resumed=true;continuation.resume(returning:URL(string:"http://127.0.0.1:\(port.rawValue)")!)}
                    case .failed:if !resumed{resumed=true;continuation.resume(throwing:TVFailure.network)}
                    default:break
                    }
                }
                listener.newConnectionHandler={[weak self] connection in self?.accept(connection)};listener.start(queue:self.queue)
            }catch{continuation.resume(throwing:TVFailure.network)}
        }}
    }
    private func accept(_ connection:NWConnection){
        guard clients.count<16 else{connection.cancel();return};let id=UUID();clients[id]=connection
        connection.stateUpdateHandler={[weak self] state in if case .cancelled=state{self?.tasks[id]?.cancel();self?.tasks[id]=nil;self?.clients[id]=nil};if case .failed=state{connection.cancel()}}
        connection.start(queue:queue);receive(connection,id:id,previous:Data())
    }
    private func receive(_ connection:NWConnection,id:UUID,previous:Data){
        connection.receive(minimumIncompleteLength:1,maximumLength:16*1024){[weak self] data,_,complete,error in
            guard let self=self else{connection.cancel();return};var buffer=previous;buffer.append(data ?? Data())
            guard buffer.count<=16*1024,error==nil else{connection.cancel();return}
            guard buffer.range(of:Data("\r\n\r\n".utf8)) != nil else{if complete{connection.cancel()}else{self.receive(connection,id:id,previous:buffer)};return}
            guard let text=String(data:buffer,encoding:.utf8)else{connection.cancel();return}
            let lines=text.components(separatedBy:"\r\n"),first=lines[0].split(separator:" ")
            guard first.count==3,["GET","HEAD"].contains(String(first[0]))else{connection.cancel();return}
            var headers:[String:String]=[:];for line in lines.dropFirst(){let p=line.split(separator:":",maxSplits:1).map(String.init);if p.count==2{headers[p[0].lowercased()]=p[1].trimmingCharacters(in:.whitespaces)}}
            let request=LocalRequest(method:String(first[0]),path:String(first[1]),headers:headers)
            self.tasks[id]=Task{[weak self] in
                do{guard let handler=self?.handler else{throw TVFailure.invalidData};let reply=try await handler(request);do{try await Self.send(reply,to:connection,head:request.method=="HEAD")}catch{ /* Close a partial response; do not append a second HTTP header. */ }}
                catch{try? await Self.send(LocalReply(status:502,type:"text/plain",data:Data("Source request failed".utf8)),to:connection,head:false)}
                connection.cancel()
            }
        }
    }
    private static func write(_ data:Data,to connection:NWConnection)async throws{
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>)in connection.send(content:data,completion:.contentProcessed{error in if error != nil{continuation.resume(throwing:TVFailure.network)}else{continuation.resume()}})}
    }
    private static func send(_ reply:LocalReply,to connection:NWConnection,head:Bool)async throws{
        let length=reply.length ?? Int64(reply.data.count)
        var text="HTTP/1.1 \(reply.status) Response\r\nContent-Type: \(reply.type)\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for(key,value)in reply.headers where !value.contains("\r") && !value.contains("\n"){text += key+": "+value+"\r\n"};text += "\r\n"
        try await write(Data(text.utf8),to:connection);if head{return}
        if let reader=reply.reader{var offset:Int64=0;while offset<length{try Task.checkCancellation();let data=try await reader(reply.start+offset,Int(min(256*1024,length-offset)));guard !data.isEmpty else{throw TVFailure.invalidData};try await write(data,to:connection);offset += Int64(data.count)}}else{try await write(reply.data,to:connection)}
    }
    func stop(){queue.async{self.listener?.cancel();self.listener=nil;for task in self.tasks.values{task.cancel()};self.tasks=[:];for connection in self.clients.values{connection.cancel()};self.clients=[:]}}
    deinit{listener?.cancel();for connection in clients.values{connection.cancel()}}
}

actor MediaRelay {
    private let server=LocalHTTPServer();private let nonce=UUID().uuidString
    private var base:URL?;private var resources:[String:(URL,Date)]=[:]
    private var headers:[String:String];private let daddy:DaddySession?;private var drm:DRMConfig?
    init(headers:[String:String],daddy:DaddySession?=nil,drm:DRMConfig?=nil){self.headers=headers;self.daddy=daddy;self.drm=drm}
    func start(_ url:URL)async throws->URL{
        server.handler={[weak self] request in guard let self=self else{throw TVFailure.network};return try await self.respond(request)}
        base=try await server.start();return local(url)
    }
    func stop(){server.stop();resources=[:]}
    private func local(_ url:URL)->URL{
        let id=stableID(url.absoluteString);resources[id]=(url,Date())
        if resources.count>4000{let cutoff=Date().addingTimeInterval(-180);resources=resources.filter{$0.value.1>cutoff}}
        return base!.appendingPathComponent(nonce).appendingPathComponent(id).appendingPathExtension(url.pathExtension.isEmpty ? "bin":url.pathExtension)
    }
    private func respond(_ request:LocalRequest)async throws->LocalReply{
        let parts=request.path.split(separator:"/");guard parts.count==2,String(parts[0])==nonce else{return LocalReply(status:404)}
        let id=(String(parts[1]) as NSString).deletingPathExtension
        guard let(url,_)=resources[id]else{return LocalReply(status:404)}
        if url.scheme=="ctvkey",let data=try drm?.localKey(for:url.host ?? ""){return LocalReply(data:data)}
        let target=try await daddy?.authorized(url) ?? url
        var h=headers;if daddy==nil,let range=request.headers["range"]{h["Range"]=range}
        let payload:HTTPPayload
        do{payload=try await HTTP.request(target,headers:h)}catch let error as TVFailure{
            if case .http(let status)=error,[401,403].contains(status),let daddy=daddy{await daddy.invalidate();payload=try await HTTP.request(daddy.authorized(url),headers:h)}else{throw error}
        }
        var bytes=payload.data;if daddy != nil{bytes=try DaddyTransport.unwrap(bytes)}
        if let text=String(data:bytes,encoding:.utf8),text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("#EXTM3U"){
            let parent=payload.response.url ?? url
            if let configured=drm{drm=try await configured.resolvingKeys(manifest:text)}
            let rewritten=try HLSRewrite.rewrite(text,base:parent,drm:drm){self.local($0).absoluteString}
            return LocalReply(type:"application/vnd.apple.mpegurl",data:Data(rewritten.utf8))
        }
        if daddy != nil,let requested=request.headers["range"]{
            guard let range=try? ByteRange.parse(requested,size:Int64(bytes.count))else{return LocalReply(status:416,headers:["Content-Range":"bytes */\(bytes.count)"])}
            return LocalReply(status:206,type:"video/mp2t",headers:["Accept-Ranges":"bytes","Content-Range":"bytes \(range.start)-\(range.end)/\(bytes.count)"],data:bytes.subdata(in:Int(range.start)..<Int(range.end+1)))
        }
        var output:[String:String]=[:];for key in ["Content-Range","Accept-Ranges"]{if let value=payload.response.value(forHTTPHeaderField:key){output[key]=value}}
        return LocalReply(status:payload.response.statusCode,type:daddy == nil ? (payload.response.mimeType ?? "application/octet-stream"):"video/mp2t",headers:output,data:bytes)
    }
}
enum HLSRewrite {
    static func rewrite(_ text:String,base:URL,drm:DRMConfig?=nil,map:(URL)->String)throws->String{
        let uri=try NSRegularExpression(pattern:#"URI="([^"]+)""#)
        return try text.components(separatedBy:.newlines).map{raw in
            let line=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if line.isEmpty{return raw}
            if !line.hasPrefix("#"){guard let url=URL(string:line,relativeTo:base)?.absoluteURL,webURL(url.absoluteString) != nil else{throw TVFailure.invalidURL};return map(url)}
            var result=line
            if line.hasPrefix("#EXT-X-KEY:"),let drm=drm,drm.scheme=="clearkey",!drm.keys.isEmpty{
                let attributes=PlaylistParser.attributes(line.replacingOccurrences(of:",",with:" "))
                if attributes["method"]=="AES-128" || attributes["method"]=="SAMPLE-AES"{
                    let kid=try drm.keyID(attributes["keyid"] ?? "")
                    result=result.replacingOccurrences(of:#",?KEYFORMAT(?:VERSIONS)?="[^"]*""#,with:"",options:.regularExpression)
                    result=result.replacingOccurrences(of:#"URI="[^"]+""#,with:"URI=\"ctvkey://\(kid)\"",options:.regularExpression)
                }
            }
            for match in uri.matches(in:result,range:NSRange(result.startIndex...,in:result)).reversed(){guard let range=Range(match.range(at:1),in:result),let url=URL(string:String(result[range]),relativeTo:base)?.absoluteURL else{continue};if url.scheme=="http" || url.scheme=="https" || url.scheme=="ctvkey"{result.replaceSubrange(range,with:map(url))}}
            return result
        }.joined(separator:"\n")
    }
}
