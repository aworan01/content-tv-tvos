import SwiftUI

struct SettingsScreen:View {
    @EnvironmentObject var model:AppModel
    @State private var editing:TVSource?
    @State private var remove:TVSource?
    @State private var showProviders=false
    @State private var showCountries=false
    @State private var guideText=""
    @State private var countryCode="US"
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:28){
        Text("Settings").font(.largeTitle).bold()
        Text("Sources").font(.title2).bold()
        Text("Add your HTTP/HTTPS M3U playlist or Xtream login. Source credentials are saved in this Apple TV’s Keychain.").font(.callout).foregroundStyle(.secondary)
        Button("Add source"){editing=TVSource()}
        ForEach(model.sources){source in HStack{Button(source.name+" · "+source.kind.rawValue){editing=source};Button("Remove"){remove=source}}}
        Button("Refresh all sources"){Task{await model.refreshSources(force:true)}}.disabled(model.busy)
        Divider();Text("Programme guides").font(.title2).bold()
        Button(showCountries ? "Hide countries":"Choose countries (\(model.countries.count))"){showCountries.toggle()}
        if showCountries{ForEach(guidePresets){preset in Button((model.countries.contains(preset.id) ? "✓ ":"")+preset.name){if !model.countries.insert(preset.id).inserted{model.countries.remove(preset.id)}}}}
        Text("UK, Finland, Iceland, Sweden, Latvia, Netherlands and USA. Feeds are third-party services; matching depends on channel IDs or unique names.").font(.caption).foregroundStyle(.secondary)
        TextField("Additional XMLTV URL",text:$guideText)
        Button("Add shared guide URL"){
            let value=guideText.trimmingCharacters(in:.whitespacesAndNewlines)
            guard webURL(value) != nil else{model.message=TVFailure.invalidURL.localizedDescription;return}
            let urls=model.sharedGuides.components(separatedBy:.newlines).filter{!$0.isEmpty}
            model.sharedGuides=Array(Set(urls+[value])).sorted().joined(separator:"\n");guideText=""
        }
        ForEach(model.sharedGuides.components(separatedBy:.newlines).filter{!$0.isEmpty},id:\.self){url in
            Button("Remove guide · "+(webURL(url)?.host ?? "Custom feed")){model.sharedGuides=model.sharedGuides.components(separatedBy:.newlines).filter{$0 != url}.joined(separator:"\n")}
        }
        Button(model.guideBusy ? "Refreshing guides…":"Apply guide settings / Refresh"){Task{await model.refreshGuides(force:true)}}.disabled(model.guideBusy)
        Divider();Text("Optional provider catalogues").font(.title2).bold()
        Toggle("Show provider shelves on Home",isOn:$model.providersEnabled)
        TextField("Two-letter catalogue country (e.g. US, GB, SE)",text:$countryCode)
        Button(showProviders ? "Hide providers":"Choose providers (\(model.providerIDs.count))"){showProviders.toggle()}
        if showProviders{LazyVGrid(columns:[GridItem(.adaptive(minimum:250))],spacing:24){ForEach(Catalogues.providers,id:\.0){id,name in Button((model.providerIDs.contains(id) ? "✓ ":"")+name){if !model.providerIDs.insert(id).inserted{model.providerIDs.remove(id)}}}}}
        Button("Apply provider settings"){
            let code=countryCode.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
            guard code.range(of:"^[A-Z]{2}$",options:.regularExpression) != nil else{model.message="Use a two-letter country code such as US, GB or SE.";return}
            model.region=code;Task{await model.refreshCatalogues(force:true)}
        }.disabled(model.catalogueBusy)
        Text("No API key required. Public catalogues can be unavailable or incomplete. A provider selection does not sign into that provider or grant access to its streams.").font(.caption).foregroundStyle(.secondary)
        Divider();Text("Playback and storage").font(.title2).bold()
        Button("Play Apple HLS test video"){model.sample()}
        Button("Clear watch history"){model.clearHistory()}
        Text("Remote: OK opens playback controls. With controls hidden, Up selects the next channel, Down the previous channel, and Right opens channels and EPG. Left inside the channel column opens groups. Back closes the top layer, then the player.").font(.callout).foregroundStyle(.secondary)
        Text("This version supports unprotected formats that Apple’s AVPlayer can decode. Custom playback headers, Stalker portals, DaddyLive, torrents and DRM are not included. Lists, logos, guide feeds and catalogue responses may be cached locally by tvOS and can be evicted to reclaim space.").font(.caption).foregroundStyle(.secondary)
    }.padding(20)}.onAppear{countryCode=model.region}
        .sheet(item:$editing){SourceForm(source:$0)}
        .confirmationDialog("Remove this source?",isPresented:Binding(get:{remove != nil},set:{if !$0{remove=nil}}),titleVisibility:.visible){Button("Remove source",role:.destructive){if let source=remove{model.removeSource(source)};remove=nil};Button("Cancel",role:.cancel){remove=nil}}
    }
}

struct SourceForm:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State var source:TVSource
    @State private var guideURL=""
    @State private var saving=false
    @State private var failure=""
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:26){
        Text(source.name.isEmpty ? "Add source":"Edit source").font(.largeTitle).bold()
        TextField("Source name",text:$source.name)
        Picker("Source type",selection:$source.kind){ForEach(SourceKind.allCases,id:\.self){kind in Text(kind.rawValue).tag(kind)}}
        TextField(source.kind == .m3u ? "Playlist URL":"Xtream server URL",text:$source.address).textContentType(.URL).autocorrectionDisabled()
        if source.kind == .xtream{
            TextField("Username",text:$source.username).textContentType(.username).autocorrectionDisabled()
            SecureField("Password",text:$source.password).textContentType(.password)
        }
        TextField("Optional source XMLTV URL",text:$guideURL).textContentType(.URL).autocorrectionDisabled()
        ForEach(source.guides,id:\.self){url in Button("Remove guide · "+(webURL(url)?.host ?? "Custom feed")){source.guides.removeAll{$0==url}}}
        HStack{Text("Guide time shift: \(source.offsetMinutes) min");Button("−30 min"){source.offsetMinutes=max(source.offsetMinutes-30,-1440)};Button("+30 min"){source.offsetMinutes=min(source.offsetMinutes+30,1440)};Button("Reset"){source.offsetMinutes=0}}
        Text("M3U-declared XMLTV feeds are discovered automatically. Positive time shifts move programmes later. HTTP credentials travel without transport encryption; use HTTPS when your provider supports it.").font(.caption).foregroundStyle(.secondary)
        if !failure.isEmpty{Text(failure).foregroundStyle(.orange)}
        if saving{ProgressView("Checking source and loading guides…")}
        HStack{Button("Validate and save"){
            saving=true;failure=""
            Task{do{
                var updated=source;let value=guideURL.trimmingCharacters(in:.whitespacesAndNewlines)
                if !value.isEmpty{guard webURL(value) != nil else{throw TVFailure.invalidURL};updated.guides.append(value)}
                try await model.saveSource(updated);dismiss()
            }catch{failure=error.localizedDescription};saving=false}
        }.disabled(saving);Button("Cancel"){dismiss()}.disabled(saving)}
    }.padding(70)}}
}
