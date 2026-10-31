import SwiftUI
import AVFoundation
import UIKit

struct Quality:Identifiable,Equatable {
    var bitrate:Double;var width:Double;var height:Double
    var id:String{String(bitrate)+"|"+String(height)}
    var label:String{height>0 ? "Up to \(Int(height))p" : "Up to \(Int(bitrate/1000)) kbps"}
    static func parse(_ text:String)->[Quality]{
        var values:[Quality]=[]
        for line in text.components(separatedBy:.newlines) where line.hasPrefix("#EXT-X-STREAM-INF:"){
            let a=PlaylistParser.attributes(line.replacingOccurrences(of:",",with:" "))
            guard let bitrate=Double(a["bandwidth"] ?? ""),bitrate>0 else{continue}
            let resolution=(a["resolution"] ?? "").split(separator:"x").compactMap{Double($0)}
            let value=Quality(bitrate:bitrate,width:resolution.count==2 ? resolution[0]:0,height:resolution.count==2 ? resolution[1]:0)
            if !values.contains(value){values.append(value)}
        };return values.sorted{$0.bitrate<$1.bitrate}
    }
}

@MainActor final class PlayerSession:ObservableObject,Identifiable {
    let id=UUID();let player=AVPlayer();let channels:[TVChannel]
    @Published var channel:TVChannel
    @Published var controls=false
    @Published var browser=false
    @Published var groups=false
    @Published var menu=""
    @Published var group="All groups"
    @Published var preview:TVChannel
    @Published var status="Connecting…"
    @Published var failed=false
    @Published var playing=true
    @Published var position:Double=0
    @Published var duration:Double=0
    @Published var audio:[AVMediaSelectionOption]=[]
    @Published var subtitles:[AVMediaSelectionOption]=[]
    @Published var qualities:[Quality]=[]
    @Published var selectedQuality:String="Auto"
    @Published var selectedAudio=""
    @Published var selectedSubtitle="Off"
    private var audible:AVMediaSelectionGroup?
    private var legible:AVMediaSelectionGroup?
    private var statusObservation:NSKeyValueObservation?
    private var playbackObservation:NSKeyValueObservation?
    private var timeObserver:Any?
    private var endObserver:NSObjectProtocol?
    private var loadTask:Task<Void,Never>?
    private weak var model:AppModel?
    private var resume:Double
    private var shouldResume=false
    private var stopped=false
    init(channel:TVChannel,channels:[TVChannel],resume:Double,model:AppModel){
        self.channel=channel;self.preview=channel;self.channels=channels;self.resume=resume;self.model=model
        timeObserver=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:1,preferredTimescale:1),queue:.main){[weak self] time in
            Task{@MainActor [weak self] in guard let self=self else{return};self.position=time.seconds.isFinite ? time.seconds:0;let value=self.player.currentItem?.duration.seconds ?? 0;self.duration=value.isFinite ? value:0}
        }
        playbackObservation=player.observe(\.timeControlStatus,options:[.new]){[weak self] player,_ in
            Task{@MainActor [weak self] in guard let self=self else{return};self.playing=player.timeControlStatus != .paused;if player.timeControlStatus == .waitingToPlayAtSpecifiedRate{self.status="Buffering…"}else if player.timeControlStatus == .playing{self.status=""}}
        };tune(channel)
    }
    var browserChannels:[TVChannel]{channels.filter{group=="All groups" || $0.group==group}}
    var availableGroups:[String]{["All groups"]+Set(channels.map(\.group)).sorted()}
    var alternateStreams:[TVChannel]{guard !channel.guideID.isEmpty else{return []};return channels.filter{$0.id != channel.id && $0.sourceID==channel.sourceID && $0.guideID==channel.guideID}}
    func tune(_ next:TVChannel){
        guard !stopped else{return}
        save();loadTask?.cancel();statusObservation=nil
        if let observer=endObserver{NotificationCenter.default.removeObserver(observer);endObserver=nil}
        channel=next;preview=next;failed=false;status="Connecting…";audio=[];subtitles=[];qualities=[];audible=nil;legible=nil;selectedQuality="Auto";selectedAudio="";selectedSubtitle="Off";duration=0;position=0
        if !next.restriction.isEmpty || !next.headers.isEmpty{failed=true;status=next.restriction.isEmpty ? "Custom HTTP headers are unsupported in this release.":next.restriction;player.replaceCurrentItem(with:nil);return}
        guard let url=webURL(next.url) else{failed=true;status=TVFailure.invalidURL.localizedDescription;return}
        let asset=AVURLAsset(url:url);let item=AVPlayerItem(asset:asset);player.replaceCurrentItem(with:item)
        statusObservation=item.observe(\.status,options:[.initial,.new]){[weak self] item,_ in
            Task{@MainActor [weak self] in guard let self=self,self.player.currentItem===item else{return}
                if item.status == .failed{self.failed=true;self.status="Playback failed. The format, connection or source may be incompatible with Apple TV.";self.controls=true}
                if item.status == .readyToPlay{self.status="";if self.resume>0,self.channel.kind != "live"{let target=self.resume;self.resume=0;if !item.duration.seconds.isFinite || target<item.duration.seconds-15{self.player.seek(to:CMTime(seconds:target,preferredTimescale:600))}}}
            }
        }
        endObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main){[weak self] _ in Task{@MainActor [weak self] in self?.controls=true;self?.playing=false;self?.save()}}
        player.play()
        loadTask=Task{[weak self] in
            guard let self=self else{return}
            let a=try? await asset.loadMediaSelectionGroup(for:.audible)
            let s=try? await asset.loadMediaSelectionGroup(for:.legible)
            guard !Task.isCancelled,self.player.currentItem===item else{return}
            self.audible=a;self.audio=a?.options ?? [];self.legible=s;self.subtitles=s?.options ?? []
            if let group=a{
                let preferred=UserDefaults.standard.string(forKey:"audioLanguage") ?? ""
                if !preferred.isEmpty,let choice=group.options.first(where:{$0.extendedLanguageTag==preferred || $0.locale?.identifier==preferred}){item.select(choice,in:group)}
                self.selectedAudio=item.currentMediaSelection.selectedMediaOption(in:group)?.displayName ?? "Default"
            }
            if url.pathExtension.lowercased()=="m3u8",let data=try? await HTTP.data(url.absoluteString,limit:1024*1024),let text=String(data:data,encoding:.utf8),!Task.isCancelled,self.player.currentItem===item{self.qualities=Quality.parse(text)}
        }
    }
    func step(_ delta:Int){guard channel.kind=="live",let next=steppedChannel(channels,current:channel,step:delta) else{return};resume=0;tune(next)}
    func toggle(){if player.rate==0{player.play()}else{player.pause()}}
    func seek(_ delta:Double){guard channel.kind != "live",duration>0 else{return};player.seek(to:CMTime(seconds:min(max(position+delta,0),duration),preferredTimescale:600))}
    func chooseAudio(_ option:AVMediaSelectionOption){guard let group=audible else{return};player.currentItem?.select(option,in:group);selectedAudio=option.displayName;UserDefaults.standard.set(option.extendedLanguageTag ?? option.locale?.identifier ?? "",forKey:"audioLanguage");menu=""}
    func chooseSubtitle(_ option:AVMediaSelectionOption?){guard let group=legible else{return};player.currentItem?.select(option,in:group);selectedSubtitle=option?.displayName ?? "Off";menu=""}
    func quality(_ value:Quality?){player.currentItem?.preferredPeakBitRate=value?.bitrate ?? 0;player.currentItem?.preferredMaximumResolution=CGSize(width:value?.width ?? 0,height:value?.height ?? 0);selectedQuality=value?.label ?? "Auto";menu=""}
    func background(){shouldResume=player.rate>0;player.pause();save()}
    func foreground(){if shouldResume{player.play()};shouldResume=false}
    func save(){guard player.currentItem != nil else{return};model?.record(channel,position:position,duration:duration)}
    func back(){if !menu.isEmpty{menu=""}else if groups{groups=false}else if browser{browser=false}else if controls{controls=false}else{close()}}
    func close(){stop();model?.player=nil}
    func stop(){guard !stopped else{return};stopped=true;save();player.pause();loadTask?.cancel();statusObservation=nil;playbackObservation=nil;if let token=timeObserver{player.removeTimeObserver(token);timeObserver=nil};if let observer=endObserver{NotificationCenter.default.removeObserver(observer);endObserver=nil};player.replaceCurrentItem(with:nil)}
}

struct VideoSurface:UIViewRepresentable {
    let player:AVPlayer
    final class Surface:UIView {override class var layerClass:AnyClass{AVPlayerLayer.self}}
    func makeUIView(context:Context)->Surface{let view=Surface();(view.layer as? AVPlayerLayer)?.videoGravity = .resizeAspect;return view}
    func updateUIView(_ view:Surface,context:Context){(view.layer as? AVPlayerLayer)?.player=player}
    static func dismantleUIView(_ view:Surface,coordinator:()){(view.layer as? AVPlayerLayer)?.player=nil}
}

struct PlayerScreen:View {
    @ObservedObject var session:PlayerSession
    @EnvironmentObject var model:AppModel
    @Environment(\.scenePhase) private var phase
    @FocusState private var focusedChannel:String?
    var body:some View{
        GeometryReader{geometry in
            ZStack(alignment:.bottom){
                Color.black;VideoSurface(player:session.player)
                if !session.controls && !session.browser && session.menu.isEmpty{
                    Button{session.controls=true}{Color.clear.contentShape(Rectangle())}.buttonStyle(.plain).focusEffectDisabled()
                        .onMoveCommand{direction in switch direction{case .up:session.step(1);case .down:session.step(-1);case .right:session.preview=session.channel;session.browser=true;focusedChannel=session.channel.id;default:break}}
                }
                if !session.status.isEmpty{VStack{Text(session.status).font(.headline).padding().background(.black.opacity(0.8));Spacer()}.padding(50).allowsHitTesting(false)}
                if session.controls && !session.browser && session.menu.isEmpty{controls}
                if session.browser{browser(width:geometry.size.width/2,height:geometry.size.height).frame(maxWidth:.infinity,alignment:.trailing)}
                if !session.menu.isEmpty{menu.frame(width:700).padding(50).background(Color(white:0.07)).cornerRadius(20).frame(maxHeight:.infinity)}
            }
        }.ignoresSafeArea().onExitCommand{session.back()}.onPlayPauseCommand{session.toggle()}
        .onChange(of:phase){_,value in if value == .active{session.foreground()}else{session.background()}}
        .onDisappear{session.stop()}
    }
    private var controls:some View{
        VStack(alignment:.leading,spacing:20){
            Spacer()
            Text(session.channel.name).font(.title).bold()
            if let now=model.now(session.channel){Text(now.title).font(.headline);Text(now.start.formatted(date:.omitted,time:.shortened)+" – "+now.end.formatted(date:.omitted,time:.shortened)).foregroundStyle(.secondary)}
            if session.duration>0 && session.channel.kind != "live"{ProgressView(value:min(session.position,session.duration),total:session.duration);Text(clock(session.position)+" / "+clock(session.duration)).font(.caption)}
            HStack(spacing:16){
                Button(session.playing ? "Pause":"Play"){session.toggle()}
                if session.channel.kind=="live"{Button("Previous"){session.step(-1)};Button("Next"){session.step(1)};Button("Channels / EPG"){session.browser=true;session.preview=session.channel;focusedChannel=session.channel.id}}
                else{Button("−30 sec"){session.seek(-30)};Button("+30 sec"){session.seek(30)}}
                Button("Options"){session.menu="Options"};Button("Hide"){session.controls=false};Button("Close"){session.close()}
            }.font(.callout)
        }.padding(60).background(LinearGradient(colors:[.clear,.black.opacity(0.95)],startPoint:.top,endPoint:.bottom))
    }
    private func browser(width:Double,height:Double)->some View{
        HStack(alignment:.top,spacing:0){
            VStack(alignment:.leading){
                Text(session.groups ? "Groups":"Channels").font(.title3).bold().padding(.bottom,10)
                if session.groups{
                    ScrollView{LazyVStack(alignment:.leading,spacing:12){ForEach(session.availableGroups,id:\.self){group in Button(group){session.group=group;session.groups=false;session.preview=session.browserChannels.first ?? session.channel;focusedChannel=session.preview.id}.frame(maxWidth:.infinity,alignment:.leading)}}}
                }else{
                    Text("← Groups").font(.caption).foregroundStyle(.secondary)
                    ScrollViewReader{proxy in ScrollView{LazyVStack(alignment:.leading,spacing:16){ForEach(session.browserChannels){channel in
                        Button{session.tune(channel);session.browser=false;session.controls=false}{VStack(alignment:.leading,spacing:5){Text(channel.name).lineLimit(2);Text(model.now(channel)?.title ?? "No guide available").font(.caption).foregroundStyle(.secondary).lineLimit(1)}.frame(maxWidth:.infinity,alignment:.leading)}
                            .focused($focusedChannel,equals:channel.id).id(channel.id)
                    }}.onAppear{proxy.scrollTo(session.channel.id,anchor:.center)}}
                    .onMoveCommand{if $0 == .left{session.groups=true}}
                    .onChange(of:focusedChannel){_,id in if let row=session.channels.first(where:{$0.id==id}){session.preview=row}}
                }
            }.padding(28).frame(width:width/2)
            Divider()
            ScrollView{VStack(alignment:.leading,spacing:20){
                Text(session.preview.name).font(.title3).bold()
                let rows=model.schedule(session.preview).filter{$0.end>Date()}
                if rows.isEmpty{Text("No programme data matched. Choose Guide mapping in Options to match a feed manually.").foregroundStyle(.secondary)}
                ForEach(Array(rows.prefix(12))){show in VStack(alignment:.leading,spacing:8){Text(show.start.formatted(date:.omitted,time:.shortened)+" – "+show.end.formatted(date:.omitted,time:.shortened)).font(.caption).foregroundStyle(.cyan);Text(show.title).bold();Text(show.detail).font(.caption).foregroundStyle(.secondary).lineLimit(7)};Divider()}
            }.padding(24)}.frame(width:width/2)
        }.frame(width:width,height:height).background(Color(white:0.06).opacity(0.98))
    }
    private var menu:some View{
        ScrollView{VStack(alignment:.leading,spacing:22){
            Text(session.menu).font(.title2).bold()
            switch session.menu{
            case "Audio":
                if session.audio.isEmpty{Text("No selectable audio tracks exposed by this stream.")}
                ForEach(Array(session.audio.enumerated()),id:\.offset){_,option in Button(option.displayName+(session.selectedAudio==option.displayName ? " ✓":"")){session.chooseAudio(option)}}
            case "Subtitles":
                Button("Off"){session.chooseSubtitle(nil)}
                ForEach(Array(session.subtitles.enumerated()),id:\.offset){_,option in Button(option.displayName){session.chooseSubtitle(option)}}
            case "Quality":
                Text("These settings cap the adaptive stream; actual resolution may be lower.").font(.caption)
                Button("Auto"){session.quality(nil)}
                ForEach(session.qualities){quality in Button(quality.label){session.quality(quality)}}
                if session.qualities.isEmpty{Text("This source does not expose an HLS master with selectable quality limits.")}
            case "Streams":
                if session.alternateStreams.isEmpty{Text("No alternative stream with the same guide ID exists in this source.")}
                ForEach(session.alternateStreams){channel in Button(channel.name){session.tune(channel);session.menu=""}}
            case "Guide mapping":
                Button("Automatic"){model.overrides[session.channel.id]=nil;session.menu=""}
                let guide=model.guides[session.channel.sourceID] ?? TVGuide()
                ForEach(guide.schedules.keys.sorted(),id:\.self){id in Button(guide.names[id]?.first ?? id){model.overrides[session.channel.id]=id;session.menu=""}}
            default:
                Button("Audio · "+session.selectedAudio){session.menu="Audio"}
                Button("Subtitles · "+session.selectedSubtitle){session.menu="Subtitles"}
                Button("Quality · "+session.selectedQuality){session.menu="Quality"}
                if session.channel.kind=="live"{Button("Alternative streams"){session.menu="Streams"};Button("Guide mapping"){session.menu="Guide mapping"};Button(model.favouriteIDs.contains(session.channel.id) ? "Remove favourite":"Add favourite"){model.toggleFavourite(session.channel)}}
                Button("Retry playback"){session.tune(session.channel);session.menu=""}
            }
            Button("Back"){session.menu=session.menu=="Options" ? "":"Options"}
        }.frame(maxWidth:.infinity,alignment:.leading).padding(20)}.frame(maxHeight:650)
    }
    private func clock(_ value:Double)->String{let seconds=Int(max(value,0));return String(format:"%d:%02d",seconds/60,seconds%60)}
}
