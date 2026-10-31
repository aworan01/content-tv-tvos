import Foundation
import SwiftUI

struct TorrentFile:Decodable,Identifiable,Hashable {
    var index:Int;var name:String;var size:Int64;var id:Int{index}
    var video:Bool{["mp4","m4v","mov","ts","mkv","avi","webm","m2ts"].contains((name as NSString).pathExtension.lowercased())}
    var compatible:Bool{["mp4","m4v","mov","ts"].contains((name as NSString).pathExtension.lowercased())}
}
struct TorrentStatus:Decodable {var metadata:Bool;var files:[TorrentFile];var failed:Bool?;var rate:Int?;var peers:Int?;var progress:Double?}
actor TorrentManager {
    static let shared=TorrentManager()
    private var engine:UnsafeMutableRawPointer?
    private var root:URL?
    private var input=""
    private var generation=UUID()
    private var server:LocalHTTPServer?
    private var selected:TorrentFile?
    func open(_ value:String)async throws{
        if value==input,engine != nil{return}
        stop();let generation=UUID();self.generation=generation;input=value
        let directory=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ContentTorrents",isDirectory:true).appendingPathComponent(generation.uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        guard let handle=ctv_torrent_create(directory.path,1)else{throw TVFailure.unsupported("The native torrent engine could not start.")};engine=handle;root=directory
        do{
            let result:Int32
            if value.lowercased().hasPrefix("magnet:?"){result=ctv_torrent_magnet(handle,value)}
            else{guard let url=webURL(value)else{throw TVFailure.invalidURL};let payload=try await HTTP.request(url,limit:8*1024*1024);guard self.generation==generation,engine==handle else{throw CancellationError()};result=payload.data.withUnsafeBytes{ctv_torrent_metadata(handle,$0.bindMemory(to:UInt8.self).baseAddress,payload.data.count)}}
            guard result==0 else{throw TVFailure.unsupported("Invalid magnet link or .torrent metadata.")}
        }catch{if self.generation==generation{stop()};throw error}
    }
    func status()throws->TorrentStatus{
        guard let engine=engine,let text=ctv_torrent_status(engine)else{throw TVFailure.unsupported("No torrent is open.")};defer{ctv_torrent_free(text)}
        let data=Data(String(cString:text).utf8);let status=try JSONDecoder().decode(TorrentStatus.self,from:data)
        if status.failed==true{throw TVFailure.unsupported("Torrent transfer failed. Check available storage and tracker/peer connectivity.")}
        guard status.files.count<=10000 else{throw TVFailure.tooLarge};return status
    }
    func prepare(_ value:String,index:Int,limit:Int64)async throws->URL{
        try await open(value);let generation=self.generation;let deadline=Date().addingTimeInterval(120)
        var current=try status()
        while !current.metadata{try Task.checkCancellation();guard Date()<deadline,self.generation==generation else{throw TVFailure.unsupported("Torrent metadata timed out. The magnet may have no reachable peers.")};try await Task.sleep(for:.milliseconds(250));current=try status()}
        guard let file=current.files.first(where:{$0.index==index}),file.compatible,let engine=engine else{throw TVFailure.unsupported("Select an MP4, M4V, MOV or TS file. Other containers are not supported by this player.")}
        let result=ctv_torrent_select(engine,Int32(index),limit)
        guard result==0 else{throw TVFailure.unsupported(result == -2 ? "The selected file exceeds the configured torrent cache limit. Increase it in Settings or choose a smaller file.":"The torrent contains an invalid or unsupported file path.")}
        selected=file;server?.stop();let server=LocalHTTPServer();self.server=server;let route="/"+UUID().uuidString+"/video."+(file.name as NSString).pathExtension.lowercased()
        server.handler={[weak self] request in guard let self=self else{throw TVFailure.network};guard request.path==route else{return LocalReply(status:404)};return try await self.response(request,file:file,generation:generation)}
        let base=try await server.start();return URL(string:route,relativeTo:base)!.absoluteURL
    }
    private func response(_ request:LocalRequest,file:TorrentFile,generation:UUID)throws->LocalReply{
        guard self.generation==generation else{throw CancellationError()}
        let range:ByteRange
        do{range=try ByteRange.parse(request.headers["range"],size:file.size)}catch{return LocalReply(status:416,headers:["Content-Range":"bytes */\(file.size)"])}
        var headers=["Accept-Ranges":"bytes"];if request.headers["range"] != nil{headers["Content-Range"]="bytes \(range.start)-\(range.end)/\(file.size)"}
        return LocalReply(status:request.headers["range"]==nil ? 200:206,type:(file.name as NSString).pathExtension.lowercased()=="ts" ? "video/mp2t":"video/mp4",headers:headers,length:range.length,reader:{[weak self] offset,count in guard let self=self else{throw TVFailure.network};return try await self.read(offset:offset,count:count,generation:generation)},start:range.start)
    }
    private func read(offset:Int64,count:Int,generation:UUID)async throws->Data{
        let deadline=Date().addingTimeInterval(90)
        while Date()<deadline{
            try Task.checkCancellation();guard self.generation==generation,let engine=engine else{throw CancellationError()}
            var bytes=Data(count:count);let result=bytes.withUnsafeMutableBytes{ctv_torrent_read(engine,offset,$0.bindMemory(to:UInt8.self).baseAddress,Int32(count))}
            if result>0{return bytes.prefix(Int(result))};if result == -1{throw TVFailure.invalidData}
            try await Task.sleep(for:.milliseconds(150))
        };throw TVFailure.unsupported("Torrent buffering timed out. More reachable peers may be needed.")
    }
    func stop(){
        generation=UUID();server?.stop();server=nil;selected=nil;input=""
        if let engine=engine{ctv_torrent_destroy(engine);self.engine=nil}
        if let root=root{let parent=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ContentTorrents",isDirectory:true).standardizedFileURL;if root.standardizedFileURL.deletingLastPathComponent()==parent{try? FileManager.default.removeItem(at:root)}};root=nil
    }
    func clearCache()throws{
        stop();let parent=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ContentTorrents",isDirectory:true)
        if FileManager.default.fileExists(atPath:parent.path){try FileManager.default.removeItem(at:parent)}
    }
}

struct TorrentScreen:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input=""
    @State private var files:[TorrentFile]=[]
    @State private var status="Paste a magnet link or an HTTP(S) .torrent URL."
    @State private var loading=false
    @State private var handedOff=false
    @State private var task:Task<Void,Never>?
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:25){
        Text("Torrents").font(.largeTitle).bold()
        TextField("Magnet link or .torrent URL",text:$input).autocorrectionDisabled()
        HStack{Button("Load files"){load()}.disabled(loading);Button("Close"){dismiss()}}
        Text(status).foregroundStyle(.secondary)
        if loading{ProgressView()}
        ForEach(files.filter(\.video)){file in Button{
            guard file.compatible else{status="This file’s container is unsupported. Choose MP4, M4V, MOV or TS.";return}
            let limit=Int64(UserDefaults.standard.integer(forKey:"torrentLimitGB")==0 ? 8:UserDefaults.standard.integer(forKey:"torrentLimitGB"))*1024*1024*1024
            guard file.size<=limit else{status="The file exceeds the torrent cache limit. Increase it in Settings.";return}
            handedOff=true;model.play(TVChannel(id:"torrent:"+stableID(input)+":\(file.index)",sourceID:"torrent",sourceName:"Torrent",name:(file.name as NSString).lastPathComponent,url:input,kind:"movie",transport:"torrent:\(file.index)"),within:[])
        }label:{HStack{Text(file.name).lineLimit(2);Spacer();Text(ByteCountFormatter.string(fromByteCount:file.size,countStyle:.file));if !file.compatible{Text("Unsupported container").font(.caption)}}}}
        Text("Transfers run while the app is active and stop when you close playback. Torrent caching is temporary; tvOS may reclaim it. Peer availability and the media’s codecs determine playback.").font(.caption).foregroundStyle(.secondary)
    }.padding(70)}.onChange(of:model.playbackRequest){_,_ in dismiss()}.onDisappear{task?.cancel();if !handedOff{Task{await TorrentManager.shared.stop()}}}}
    private func load(){
        task?.cancel();loading=true;files=[];let value=input.trimmingCharacters(in:.whitespacesAndNewlines);input=value;status="Getting torrent metadata…"
        task=Task{do{
            try await TorrentManager.shared.open(value);let deadline=Date().addingTimeInterval(120)
            while !Task.isCancelled{let current=try await TorrentManager.shared.status();if current.metadata{files=current.files;status=files.contains(where:\.video) ? "Choose a video file.":"No supported video entries found.";break};guard Date()<deadline else{throw TVFailure.unsupported("Metadata timed out. No reachable peers may be available.")};status="Getting metadata · \(current.peers ?? 0) peers";try await Task.sleep(for:.milliseconds(500))}
        }catch{if !Task.isCancelled{status=error.localizedDescription}};if !Task.isCancelled{loading=false}}
    }
}
