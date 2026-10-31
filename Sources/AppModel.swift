import Foundation
import SwiftUI

@MainActor final class AppModel:ObservableObject {
    @Published var sources:[TVSource]=[]
    @Published var channels:[TVChannel]=[]
    @Published var shelves:[Shelf]=Catalogues.standard
    @Published var titles:[String:[TVTitle]]=[:]
    @Published var shelfErrors:[String:String]=[:]
    @Published var saved:[TVTitle]=[]
    @Published var history:[HistoryEntry]=[]
    @Published var favouriteIDs:Set<String>=[]
    @Published var guides:[String:TVGuide]=[:]
    @Published var message:String?
    @Published var busy=false
    @Published var guideBusy=false
    @Published var catalogueBusy=false
    @Published var sourceFilter="All sources" {didSet{defaults.set(sourceFilter,forKey:"sourceFilter")}}
    @Published var order:ChannelOrder = .source {didSet{defaults.set(order.rawValue,forKey:"order")}}
    @Published var listMode=true {didSet{defaults.set(listMode,forKey:"listMode")}}
    @Published var countries:Set<String>=[] {didSet{defaults.set(Array(countries),forKey:"countries")}}
    @Published var sharedGuides="" {didSet{defaults.set(sharedGuides,forKey:"sharedGuides")}}
    @Published var region="US" {didSet{defaults.set(region,forKey:"region")}}
    @Published var providersEnabled=false {didSet{defaults.set(providersEnabled,forKey:"providersEnabled")}}
    @Published var providerIDs:Set<String>=["nfx","hbm","dnp"] {didSet{defaults.set(Array(providerIDs),forKey:"providerIDs")}}
    @Published var overrides:[String:String]=[:] {didSet{defaults.set(overrides,forKey:"guideOverrides");indexGuides()}}
    @Published var player:PlayerSession?
    @Published var playbackRequest=UUID()
    @Published var daddyEnabled=false {didSet{defaults.set(daddyEnabled,forKey:"daddyEnabled")}}
    @Published var daddyEvents:[DaddyEvent]=[]
    @Published var daddyError=""
    @Published var daddyBusy=false
    private let defaults=UserDefaults.standard
    private var privateReadable=true
    private var guideMatches:[String:String]=[:]
    private var vod:[String:[TVChannel]]=[:]
    private var loaded=false
    private var lastGuideRefresh=Date.distantPast

    init(){
        sourceFilter=defaults.string(forKey:"sourceFilter") ?? "All sources"
        order=ChannelOrder(rawValue:defaults.string(forKey:"order") ?? "") ?? .source
        if defaults.object(forKey:"listMode") != nil{listMode=defaults.bool(forKey:"listMode")}
        countries=Set(defaults.stringArray(forKey:"countries") ?? [])
        sharedGuides=defaults.string(forKey:"sharedGuides") ?? ""
        region=defaults.string(forKey:"region") ?? "US"
        providersEnabled=defaults.bool(forKey:"providersEnabled")
        daddyEnabled=defaults.bool(forKey:"daddyEnabled")
        providerIDs=Set(defaults.stringArray(forKey:"providerIDs") ?? ["nfx","hbm","dnp"])
        favouriteIDs=Set(defaults.stringArray(forKey:"favourites") ?? [])
        overrides=defaults.dictionary(forKey:"guideOverrides") as? [String:String] ?? [:]
        if let data=defaults.data(forKey:"saved"),let items=try? JSONDecoder().decode([TVTitle].self,from:data){saved=items}
        do{sources=try PrivateStore.read("sources",as:[TVSource].self) ?? [];history=try PrivateStore.read("history",as:[HistoryEntry].self) ?? []}
        catch{privateReadable=false;message=TVFailure.storage.localizedDescription}
    }
    func start()async{
        guard !loaded else{return};loaded=true
        async let catalogues:Void=refreshCatalogues()
        await refreshSources();await catalogues
    }
    var liveChannels:[TVChannel]{channels.filter{sourceFilter=="All sources" || $0.sourceID==sourceFilter}}
    func visible(group:String="All groups",favourites:Bool=false)->[TVChannel]{sortedChannels(liveChannels.filter{!favourites || favouriteIDs.contains($0.id)},order:order,group:group)}
    var groups:[String]{["All groups"]+Set(liveChannels.map(\.group)).sorted()}
    private var guideSources:[TVSource]{sources+(daddyEnabled ? [TVSource(id:"daddylive",name:"DaddyLive",address:DaddyLive.home)]:[])}
    func refreshSources(force:Bool=false)async{
        guard !busy else{return};busy=true;defer{busy=false}
        var result:[TVChannel]=[];var failed:[String]=[]
        for source in sources{
            do{result += try await load(source,force:force).channels}
            catch{result += channels.filter{$0.sourceID==source.id};failed.append(source.name+": "+error.localizedDescription)}
        }
        channels=result+(daddyEnabled ? channels.filter{$0.sourceID=="daddylive"}:[]);indexGuides();if !failed.isEmpty{message=failed.joined(separator:"\n")}
        await refreshGuides(force:force)
        if daddyEnabled{await refreshDaddy(force:force)}
    }
    private func load(_ source:TVSource,force:Bool=false)async throws->(channels:[TVChannel],guides:[String]){
        if source.kind == .xtream{return(try await Xtream.fetch(source,kind:"live",force:force),[])}
        let data=try await HTTP.cached(source.address,age:6*3600,force:force)
        return try await Task.detached{
            guard let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1) else{throw TVFailure.invalidData}
            let result=PlaylistParser.parse(text,source:source);guard !result.channels.isEmpty else{throw TVFailure.noChannels};return result
        }.value
    }
    func saveSource(_ input:TVSource)async throws{
        guard privateReadable else{throw TVFailure.storage}
        var source=input;source.address=source.address.trimmingCharacters(in:.whitespacesAndNewlines)
        guard webURL(source.address) != nil,!source.name.trimmingCharacters(in:.whitespaces).isEmpty else{throw TVFailure.invalidURL}
        if source.kind == .xtream,(source.username.isEmpty || source.password.isEmpty){throw TVFailure.unsupported("Enter the Xtream username and password.")}
        let result=try await load(source,force:true)
        source.guides=Array(Set(source.guides+result.guides)).filter{webURL($0) != nil}.sorted()
        var next=sources;next.removeAll{$0.id==source.id};next.append(source)
        try PrivateStore.write("sources",next);sources=next
        channels.removeAll{$0.sourceID==source.id};channels += result.channels;vod=[:];indexGuides()
        await refreshGuides()
    }
    func removeSource(_ source:TVSource){
        do{guard privateReadable else{throw TVFailure.storage};let next=sources.filter{$0.id != source.id};try PrivateStore.write("sources",next);sources=next;channels.removeAll{$0.sourceID==source.id};guides[source.id]=nil;vod=[:];if sourceFilter==source.id{sourceFilter="All sources"};indexGuides()}
        catch{message=error.localizedDescription}
    }
    func toggleFavourite(_ channel:TVChannel){if !favouriteIDs.insert(channel.id).inserted{favouriteIDs.remove(channel.id)};defaults.set(Array(favouriteIDs),forKey:"favourites")}
    func bookmark(_ title:TVTitle){if saved.contains(where:{$0.id==title.id}){saved.removeAll{$0.id==title.id}}else{saved.append(title)};defaults.set(try? JSONEncoder().encode(saved),forKey:"saved")}
    func record(_ channel:TVChannel,position:Double,duration:Double){
        guard privateReadable else{return}
        var next=history.filter{$0.id != channel.id};next.insert(HistoryEntry(channel:channel,position:position.isFinite ? max(position,0):0,duration:duration.isFinite ? max(duration,0):0,watched:Date()),at:0);next=Array(next.prefix(40))
        do{try PrivateStore.write("history",next);history=next}catch{message=TVFailure.storage.localizedDescription}
    }
    func clearHistory(){do{guard privateReadable else{throw TVFailure.storage};try PrivateStore.write("history",[HistoryEntry]());history=[]}catch{message=error.localizedDescription}}
    func refreshGuides(force:Bool=false)async{
        guard !guideBusy else{return};guideBusy=true;defer{guideBusy=false}
        let shared=guidePresets.filter{countries.contains($0.id)}.map(\.url)+sharedGuides.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespaces)}.filter{webURL($0) != nil}
        let urls=Set(shared+sources.flatMap(\.guides));var fetched:[String:TVGuide]=[:];var failed=0
        for url in urls{
            do{let data=try await HTTP.cached(url,age:6*3600,force:force);let guide=try await Task.detached{try XMLTVParser.parse(data)}.value;fetched[url]=guide}
            catch{failed += 1}
        }
        var next:[String:TVGuide]=[:]
        for source in guideSources{var merged=TVGuide();for url in Set(shared+source.guides){if let guide=fetched[url]{merged.merge(guide)}};if merged.count>0 || urls.isEmpty{next[source.id]=merged}else{next[source.id]=guides[source.id]}}
        guides=next;indexGuides();lastGuideRefresh=Date()
        if failed>0{message="\(failed) guide feed(s) could not be loaded. Cached data is used where available. You can change feeds in Settings."}
    }
    func refreshWhenNeeded()async{if Date().timeIntervalSince(lastGuideRefresh)>6*3600{await refreshGuides()}}
    private func indexGuides(){
        var matches:[String:String]=[:]
        for source in guideSources{
            guard let guide=guides[source.id] else{continue};var byName:[String:Set<String>]=[:]
            for(id,names)in guide.names where guide.schedules[id] != nil{for name in names{byName[normalized(name),default:[]].insert(id)}}
            for channel in channels where channel.sourceID==source.id{
                if let override=overrides[channel.id],!override.isEmpty{if guide.schedules[override] != nil{matches[channel.id]=override}}
                else if guide.schedules[channel.guideID] != nil{matches[channel.id]=channel.guideID}
                else if let ids=byName[normalized(channel.name)],ids.count==1{matches[channel.id]=ids.first}
            }
        };guideMatches=matches
    }
    func schedule(_ channel:TVChannel)->[TVProgramme]{guard let id=guideMatches[channel.id],let shows=guides[channel.sourceID]?.schedules[id] else{return []};let offset=sources.first{$0.id==channel.sourceID}?.offsetMinutes ?? 0;return shows.map{$0.shifted(offset)}}
    func now(_ channel:TVChannel)->TVProgramme?{let time=Date();return schedule(channel).first{$0.start<=time && $0.end>time}}
    var events:[SportsEvent]{
        var grouped:[String:SportsEvent]=[:];let now=Date(),end=Calendar.current.startOfDay(for:now).addingTimeInterval(86400)
        for channel in liveChannels{for show in schedule(channel) where show.end>now && show.start<end{
            let text=(show.categories.joined(separator:" ")+" "+show.title).lowercased()
            guard ["sport","football","soccer","basketball","cricket","tennis","rugby","formula 1","grand prix","hockey","baseball"," vs "," v "].contains(where:text.contains) else{continue}
            let id=normalized(show.title)+"|"+String(Int(show.start.timeIntervalSince1970)/300)
            if grouped[id] != nil{grouped[id]?.channels.append(channel)}else{grouped[id]=SportsEvent(id:id,programme:show,channels:[channel])}
        }};return grouped.values.sorted{$0.programme.start<$1.programme.start}
    }
    func refreshCatalogues(force:Bool=false)async{
        guard !catalogueBusy else{return};catalogueBusy=true;defer{catalogueBusy=false}
        let selected=Catalogues.providers.filter{providerIDs.contains($0.0)}
        shelves=Catalogues.standard+(providersEnabled ? selected.flatMap{provider in [Shelf(id:provider.0+"movie",name:provider.1+" · Movies",kind:"movie",provider:provider.0),Shelf(id:provider.0+"series",name:provider.1+" · Series",kind:"series",provider:provider.0)]}:[])
        for shelf in shelves{do{titles[shelf.id]=Array(try await Catalogues.fetch(shelf,region:region,force:force).prefix(35));shelfErrors[shelf.id]=nil}catch{shelfErrors[shelf.id]=error.localizedDescription}}
    }
    func sourceTitles(kind:String,force:Bool=false)async->[TVChannel]{
        var result:[TVChannel]=[]
        for source in sources where source.kind == .xtream && (sourceFilter=="All sources" || source.id==sourceFilter){
            let key=source.id+kind
            if !force,let items=vod[key]{result += items;continue}
            do{let items=try await Xtream.fetch(source,kind:kind,force:force);vod[key]=items;result += items}catch{message=source.name+": "+error.localizedDescription}
        };return result
    }
    func find(_ title:TVTitle)async->[TVChannel]{
        let items=await sourceTitles(kind:title.kind)
        let target=normalized(title.name)
        return items.filter{let name=normalized($0.name);return !target.isEmpty && (name==target || name.hasPrefix(target) || target.hasPrefix(name) && !name.isEmpty)}
    }
    func play(_ channel:TVChannel,within rows:[TVChannel]?=nil,resume:Bool=true){
        if !channel.restriction.isEmpty{message=channel.restriction;return}
        guard webURL(channel.url) != nil || channel.transport?.hasPrefix("torrent:")==true && channel.url.lowercased().hasPrefix("magnet:?") else{message=TVFailure.invalidURL.localizedDescription;return}
        let position=channel.kind=="live" || !resume ? 0 : history.first{$0.id==channel.id}?.position ?? 0
        let list=rows ?? visible();let request=UUID();playbackRequest=request
        Task{try? await Task.sleep(for:.milliseconds(650));guard playbackRequest==request else{return};player=PlayerSession(channel:channel,channels:list,resume:position,model:self)}
    }
    func refreshDaddy(force:Bool=false)async{
        guard !daddyBusy else{return}
        guard daddyEnabled else{channels.removeAll{$0.sourceID=="daddylive"};daddyEvents=[];daddyError="";if sourceFilter=="daddylive"{sourceFilter="All sources"};return}
        daddyBusy=true;defer{daddyBusy=false};daddyError=""
        do{let rows=try await DaddyLive.loadChannels(force:force);if daddyEnabled{channels.removeAll{$0.sourceID=="daddylive"};channels += rows;indexGuides()}}catch{daddyError="Channels: "+error.localizedDescription}
        do{let events=try await DaddyLive.loadEvents(force:force);if daddyEnabled{daddyEvents=events}}catch{daddyError += (daddyError.isEmpty ? "":"\n")+"Schedule: "+error.localizedDescription}
    }
    func sample(){play(TVChannel(id:"apple-sample",sourceID:"sample",sourceName:"Apple sample",name:"Playback test",url:"https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8",kind:"movie"),within:[])}
}
