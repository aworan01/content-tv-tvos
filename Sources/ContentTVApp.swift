import SwiftUI

@main struct ContentTVApp:App {
    @StateObject private var model=AppModel()
    var body:some Scene{WindowGroup{RootScreen().environmentObject(model).preferredColorScheme(.dark)}}
}
enum Section:String,CaseIterable,Identifiable {
    case home="Home",search="Search",library="Library",live="Live TV",sports="Game Day",settings="Settings"
    var id:String{rawValue}
    var icon:String{switch self{case .home:return "house.fill";case .search:return "magnifyingglass";case .library:return "books.vertical.fill";case .live:return "tv.fill";case .sports:return "sportscourt.fill";case .settings:return "gearshape.fill"}}
}
struct RootScreen:View {
    @EnvironmentObject var model:AppModel
    @State private var section:Section = .home
    @Environment(\.scenePhase) private var phase
    var body:some View{
        HStack(alignment:.top,spacing:30){
            VStack(alignment:.leading,spacing:24){
                Text("CONTENT\nTV").font(.system(size:30,weight:.black)).foregroundStyle(.cyan).padding(.bottom,30)
                ForEach(Section.allCases){item in Button{section=item} label:{Label(item.rawValue,systemImage:item.icon).font(.system(size:20,weight:section==item ? .bold:.regular)).frame(width:180,alignment:.leading).padding(.vertical,8).foregroundStyle(section==item ? .cyan:.white)}.buttonStyle(.plain)}
                Spacer();Text("0.3.0 · tvOS").font(.caption2).foregroundStyle(.secondary)
            }.frame(width:200).padding(.vertical,30)
            Group{switch section{case .home:HomeScreen();case .search:SearchScreen();case .library:LibraryScreen();case .live:LiveScreen();case .sports:SportsScreen();case .settings:SettingsScreen()}}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }.padding(50).background(Color(red:0.025,green:0.035,blue:0.065)).task{await model.start()}
        .fullScreenCover(item:$model.player){session in PlayerScreen(session:session).environmentObject(model)}
        .alert("Content TV",isPresented:Binding(get:{model.message != nil},set:{if !$0{model.message=nil}})){Button("OK"){model.message=nil}}message:{Text(model.message ?? "")}
        .onChange(of:phase){_,value in if value == .active{Task{await model.refreshWhenNeeded()}}}
    }
}

struct Poster:View {
    var title:TVTitle
    var body:some View{VStack(alignment:.leading,spacing:10){
        AsyncImage(url:webURL(title.poster)){image in image.resizable().scaledToFill()}placeholder:{ZStack{Color(white:0.15);Image(systemName:"film").font(.largeTitle).foregroundStyle(.secondary)}}.frame(width:150,height:215).clipped().cornerRadius(10)
        Text(title.name).font(.system(size:17,weight:.semibold)).lineLimit(2).frame(width:150,height:45,alignment:.topLeading)
    }}
}
struct TitleRows:View {
    var titles:[TVTitle]
    @Binding var selected:TVTitle?
    var body:some View{ScrollView(.horizontal){LazyHStack(spacing:30){ForEach(titles){title in Button{selected=title} label:{Poster(title:title)}.buttonStyle(.plain)}}.padding(20)}.padding(-20)}
}
struct HomeScreen:View {
    @EnvironmentObject var model:AppModel
    @State private var selected:TVTitle?
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:30){
        Text("Discover").font(.largeTitle).bold()
        Text("Movies, series and your live channels").foregroundStyle(.secondary)
        if model.catalogueBusy{ProgressView("Loading catalogues…")}
        if !model.channels.isEmpty{HStack{Button("Watch live TV"){if let channel=model.visible().first{model.play(channel)}};Text("\(model.channels.count) channels in your sources").font(.caption).foregroundStyle(.secondary)}}
        ForEach(model.shelves){shelf in VStack(alignment:.leading,spacing:15){Text(shelf.name).font(.title2).bold();if let rows=model.titles[shelf.id],!rows.isEmpty{TitleRows(titles:rows,selected:$selected)}else{Text(model.shelfErrors[shelf.id] ?? "No titles available for this catalogue or region.").foregroundStyle(.secondary).font(.callout)}}}
        Button("Refresh catalogues"){Task{await model.refreshCatalogues(force:true)}}.disabled(model.catalogueBusy)
        Text("Provider catalogues are optional in Settings. They show availability metadata, not subscription playback.").font(.caption).foregroundStyle(.secondary)
    }.padding(20)}.sheet(item:$selected){TitleScreen(original:$0)}}
}
struct SearchScreen:View {
    @EnvironmentObject var model:AppModel
    @State private var query=""
    @State private var results:[TVTitle]=[]
    @State private var selected:TVTitle?
    @State private var searching=false
    @State private var failure=""
    @State private var searchTask:Task<Void,Never>?
    var matches:[TVChannel]{guard !query.isEmpty else{return []};return Array(model.liveChannels.filter{$0.name.localizedCaseInsensitiveContains(query)}.prefix(60))}
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:25){
        Text("Search").font(.largeTitle).bold()
        TextField("Title or channel",text:$query).onSubmit{search()}
        Button("Search movies and series"){search()}.disabled(searching || query.trimmingCharacters(in:.whitespaces).isEmpty)
        if searching{ProgressView()};if !failure.isEmpty{Text(failure).foregroundStyle(.secondary)}
        if !matches.isEmpty{Text("Your channels").font(.title2);ForEach(matches){channel in ChannelButton(channel:channel,rows:matches)}}
        if !results.isEmpty{Text("Catalogue results").font(.title2);LazyVGrid(columns:[GridItem(.adaptive(minimum:170))],spacing:30){ForEach(results){title in Button{selected=title} label:{Poster(title:title)}.buttonStyle(.plain)}}}
    }.padding(20)}.sheet(item:$selected){TitleScreen(original:$0)}.onDisappear{searchTask?.cancel()}}
    private func search(){
        let term=query.trimmingCharacters(in:.whitespacesAndNewlines);guard !term.isEmpty else{return};searchTask?.cancel();searching=true;failure=""
        searchTask=Task{do{async let movies=Catalogues.search(term,kind:"movie");async let series=Catalogues.search(term,kind:"series");let rows=try await movies+series;guard !Task.isCancelled else{return};results=rows;if rows.isEmpty{failure="No catalogue results."}}catch{if !Task.isCancelled{failure=error.localizedDescription}};if !Task.isCancelled{searching=false}}
    }
}
struct LibraryScreen:View {
    @EnvironmentObject var model:AppModel
    @State private var selected:TVTitle?
    @State private var torrents=false
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:25){
        Text("Library").font(.largeTitle).bold()
        Button("Open magnet / .torrent URL"){torrents=true}
        Text("Saved titles").font(.title2)
        if model.saved.isEmpty{Text("Save movies and series from their detail pages.").foregroundStyle(.secondary)}else{TitleRows(titles:model.saved,selected:$selected)}
        Text("Favourite channels").font(.title2)
        let favourites=model.visible(favourites:true)
        if favourites.isEmpty{Text("Add favourites from the live player's Options menu.").foregroundStyle(.secondary)}
        ForEach(favourites){ChannelButton(channel:$0,rows:favourites)}
        Text("Recently watched").font(.title2)
        ForEach(model.history){entry in Button{model.play(entry.channel)} label:{HStack{Text(entry.channel.name);Spacer();Text(entry.channel.kind=="live" ? "Live":"Resume").foregroundStyle(.secondary)}}}
    }.padding(20)}.sheet(item:$selected){TitleScreen(original:$0)}.sheet(isPresented:$torrents){TorrentScreen()}}
}
struct ChannelButton:View {
    @EnvironmentObject var model:AppModel
    var channel:TVChannel
    var rows:[TVChannel]
    var body:some View{Button{model.play(channel,within:rows)} label:{HStack(spacing:18){
        AsyncImage(url:webURL(channel.logo)){image in image.resizable().scaledToFit()}placeholder:{Image(systemName:"tv")}.frame(width:55,height:45)
        VStack(alignment:.leading,spacing:5){Text(channel.name).font(.headline);Text(model.now(channel)?.title ?? channel.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)}
        Spacer();if model.favouriteIDs.contains(channel.id){Image(systemName:"star.fill").foregroundStyle(.yellow)}
    }.frame(maxWidth:.infinity,alignment:.leading)}}
}
struct LiveScreen:View {
    @EnvironmentObject var model:AppModel
    @State private var group="All groups"
    @State private var favourites=false
    @State private var kind="live"
    @State private var vod:[TVChannel]=[]
    @State private var loading=false
    @State private var selectedSeries:TVChannel?
    var rows:[TVChannel]{kind=="live" ? model.visible(group:group,favourites:favourites):sortedChannels(vod,order:model.order)}
    var body:some View{VStack(alignment:.leading,spacing:25){
        Text("Live TV").font(.largeTitle).bold()
        HStack{
            Menu("\(kind=="live" ? "Channels":kind=="movie" ? "Source movies":"Source series")"){ForEach(["live","movie","series"],id:\.self){value in Button(value=="live" ? "Channels":value=="movie" ? "Source movies":"Source series"){kind=value;load()}}}
            Menu(sourceName){Button("All sources"){model.sourceFilter="All sources";group="All groups";load()};ForEach(model.sources){source in Button(source.name){model.sourceFilter=source.id;group="All groups";load()}};if model.daddyEnabled{Button("DaddyLive"){model.sourceFilter="daddylive";group="All groups";kind="live"}}}
            if kind=="live"{Menu(group){ForEach(model.groups,id:\.self){value in Button(value){group=value}}}}
        }.font(.callout)
        HStack{
            Menu(model.order.rawValue){ForEach(ChannelOrder.allCases,id:\.self){value in Button(value.rawValue){model.order=value}}}
            Button(model.listMode ? "View: List":"View: Grid"){model.listMode.toggle()}
            if kind=="live"{Button(favourites ? "Favourites":"All channels"){favourites.toggle()}}
            Button("Refresh"){if kind=="live"{Task{await model.refreshSources(force:true)}}else{load(force:true)}}.disabled(model.busy || loading)
        }.font(.callout)
        if model.busy || loading{ProgressView("Loading sources…")}
        if model.daddyEnabled && !model.daddyError.isEmpty{Text(model.daddyError).font(.caption).foregroundStyle(.orange)}
        if rows.isEmpty{Text(model.sources.isEmpty ? "Add an M3U or Xtream source in Settings.":kind=="live" ? "No channels in this selection.":"Source movies and series require an Xtream source with that catalogue.").foregroundStyle(.secondary)}
        ScrollView{
            if model.listMode{LazyVStack(spacing:22){ForEach(rows){channel in row(channel)}}.padding(20)}
            else{LazyVGrid(columns:[GridItem(.adaptive(minimum:270))],spacing:30){ForEach(rows){channel in row(channel)}}.padding(20)}
        }
    }.padding(20).sheet(item:$selectedSeries){SeriesScreen(series:$0)}}
    private var sourceName:String{model.sourceFilter=="daddylive" ? "DaddyLive":model.sources.first{$0.id==model.sourceFilter}?.name ?? "All sources"}
    @ViewBuilder private func row(_ channel:TVChannel)->some View{if kind=="series"{Button(channel.name){selectedSeries=channel}}else{ChannelButton(channel:channel,rows:kind=="live" ? rows:[])}}
    private func load(force:Bool=false){guard kind != "live" else{return};let requested=kind;loading=true;Task{let items=await model.sourceTitles(kind:requested,force:force);if kind==requested{vod=items};loading=false}}
}
struct SeriesScreen:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var series:TVChannel
    @State private var episodes:[TVChannel]=[]
    @State private var message="Loading episodes…"
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:25){Text(series.name).font(.largeTitle);Button("Close"){dismiss()};if episodes.isEmpty{Text(message)};ForEach(episodes){episode in Button(episode.name){dismiss();Task{try? await Task.sleep(for:.milliseconds(350));model.play(episode,within:[])}}}}.padding(70)}.task{
        do{guard let source=model.sources.first(where:{$0.id==series.sourceID})else{throw TVFailure.invalidData};episodes=try await Xtream.episodes(source,series:series);message="No episodes returned."}catch{message=error.localizedDescription}
    }.onChange(of:model.playbackRequest){_,_ in dismiss()}}
}
struct TitleScreen:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var original:TVTitle
    @State private var detail:TVTitle?
    @State private var matches:[TVChannel]=[]
    @State private var searched=false
    @State private var loading=false
    @State private var series:TVChannel?
    var title:TVTitle{detail ?? original}
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:25){
        HStack(alignment:.top,spacing:45){Poster(title:title);VStack(alignment:.leading,spacing:20){Text(title.name).font(.largeTitle).bold();Text([title.year,title.rating.isEmpty ? "":"★ "+title.rating,title.genres.joined(separator:" · ")].filter{!$0.isEmpty}.joined(separator:"   ")).foregroundStyle(.secondary);Text(title.plot.isEmpty ? "No description available.":title.plot);Button(model.saved.contains(where:{$0.id==title.id}) ? "Remove saved title":"Save to Library"){model.bookmark(title)}}}
        HStack{Button("Find in my sources"){loading=true;Task{matches=await model.find(title);searched=true;loading=false}}.disabled(loading);Button("Close"){dismiss()}}
        Text("Catalogues show metadata. Playback comes from your configured Xtream movies and series.").font(.caption).foregroundStyle(.secondary)
        if loading{ProgressView()}
        if searched && matches.isEmpty{Text("No matching title found in your sources. Add an Xtream source with movies or series, or browse its catalogue in Live TV.")}
        ForEach(matches){channel in Button(channel.name+" · "+channel.sourceName){if channel.kind=="series"{series=channel}else{dismiss();Task{try? await Task.sleep(for:.milliseconds(350));model.play(channel,within:[])}}}}
    }.padding(70)}.task{detail=try? await Catalogues.detail(original)}.sheet(item:$series){SeriesScreen(series:$0)}.onChange(of:model.playbackRequest){_,_ in dismiss()}}
}
struct SportsScreen:View {
    @EnvironmentObject var model:AppModel
    @State private var limit=40
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:25){
        Text("Game Day").font(.largeTitle).bold()
        Text("Today’s sports from your matched programme guides").foregroundStyle(.secondary)
        Button("Refresh guides"){Task{await model.refreshGuides(force:true)}}.disabled(model.guideBusy)
        if model.guideBusy{ProgressView()}
        if model.daddyEnabled{
            Text("DaddyLive schedule").font(.title2)
            Button(model.daddyBusy ? "Loading…":"Refresh DaddyLive schedule"){Task{await model.refreshDaddy(force:true)}}.disabled(model.daddyBusy)
            if !model.daddyError.isEmpty{Text(model.daddyError).font(.caption).foregroundStyle(.orange)}
            Text(model.daddyEvents.first?.scheduleDate ?? "No provider schedule returned. Times are as supplied by the provider.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(model.daddyEvents.prefix(limit))){event in VStack(alignment:.leading,spacing:14){Text(event.time+" · "+event.name).font(.headline);Text(event.category).font(.caption).foregroundStyle(.cyan);ForEach(event.channels){channel in ChannelButton(channel:channel,rows:model.channels.filter{$0.sourceID=="daddylive"})}}}
            if model.daddyEvents.count>limit{Button("Show more events"){limit += 40}}
            Divider();Text("Your programme guides").font(.title2)
        }
        if model.events.isEmpty{Text("No sports events found. Add channels and enable matching XMLTV feeds in Settings. Events depend on the feed’s programme titles and categories.").foregroundStyle(.secondary)}
        ForEach(model.events){event in VStack(alignment:.leading,spacing:15){Text(event.programme.title).font(.title2);Text(event.programme.start.formatted(date:.abbreviated,time:.shortened)).foregroundStyle(.cyan);Text(event.programme.detail).font(.caption).lineLimit(3);ForEach(event.channels){channel in ChannelButton(channel:channel,rows:model.visible())}}.padding(.vertical,12)}
    }.padding(20)}}
}


