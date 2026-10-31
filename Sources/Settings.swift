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
        Divider();Text("DaddyLive").font(.title2).bold()
        Toggle("Enable DaddyLive channels and Game Day",isOn:$model.daddyEnabled).onChange(of:model.daddyEnabled){_,_ in Task{await model.refreshDaddy();await model.refreshGuides()}}
        if model.daddyEnabled{Button(model.daddyBusy ? "Loading DaddyLive…":"Refresh DaddyLive"){Task{await model.refreshDaddy(force:true)}}.disabled(model.daddyBusy);if !model.daddyError.isEmpty{Text(model.daddyError).font(.caption).foregroundStyle(.orange)}}
        Divider();Text("Torrents").font(.title2).bold()
        TorrentSettings()
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
        Text("Playback depends on Apple TV’s supported containers and codecs. HLS headers, DaddyLive transport and temporary torrent playback are included. DRM support covers compatible HLS ClearKey and configurable FairPlay client requests. Widevine and DASH/CENC are unsupported. Stalker and Timst are absent. Cached media and guide data may be evicted by tvOS.").font(.caption).foregroundStyle(.secondary)
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
    @State private var licenseHeaders=""
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
        Toggle("Configure provider FairPlay",isOn:Binding(get:{source.fairPlay != nil},set:{source.fairPlay=$0 ? DRMConfig(scheme:"fairplay"):nil}))
        if source.fairPlay != nil{
            TextField("Provider certificate URL",text:Binding(get:{source.fairPlay?.certificateURL ?? ""},set:{source.fairPlay?.certificateURL=$0}))
            TextField("Provider licence URL",text:Binding(get:{source.fairPlay?.licenseURL ?? ""},set:{source.fairPlay?.licenseURL=$0}))
            TextField("Optional provider content ID",text:Binding(get:{source.fairPlay?.contentID ?? ""},set:{source.fairPlay?.contentID=$0}))
            SecureField("Optional licence headers JSON",text:$licenseHeaders)
            Menu("SPC request: "+(source.fairPlay?.requestFormat ?? "raw")){Button("Raw SPC"){source.fairPlay?.requestFormat="raw"};Button("Form: spc + assetId"){source.fairPlay?.requestFormat="form"}}
            Menu("CKC response: "+(source.fairPlay?.responseFormat ?? "raw")){Button("Raw CKC"){source.fairPlay?.responseFormat="raw"};Button("Base64 / <ckc>"){source.fairPlay?.responseFormat="base64"}}
            Text("Use settings supplied by your provider. These client settings do not create a DRM licence or convert Widevine/DASH streams to FairPlay.").font(.caption).foregroundStyle(.secondary)
        }
        Text("M3U-declared XMLTV feeds are discovered automatically. Positive time shifts move programmes later. HTTP credentials travel without transport encryption; use HTTPS when your provider supports it.").font(.caption).foregroundStyle(.secondary)
        if !failure.isEmpty{Text(failure).foregroundStyle(.orange)}
        if saving{ProgressView("Checking source and loading guides…")}
        HStack{Button("Validate and save"){
            saving=true;failure=""
            Task{do{
                var updated=source;let value=guideURL.trimmingCharacters(in:.whitespacesAndNewlines)
                if updated.fairPlay != nil{
                    guard webURL(updated.fairPlay!.certificateURL) != nil,webURL(updated.fairPlay!.licenseURL) != nil else{throw TVFailure.unsupported("Enter the provider’s valid FairPlay certificate and licence URLs.")}
                    if !licenseHeaders.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{guard let data=licenseHeaders.data(using:.utf8),let headers=try? JSONDecoder().decode([String:String].self,from:data)else{throw TVFailure.unsupported("Licence headers must be a JSON object of text names and values.")};updated.fairPlay?.headers=headers}else{updated.fairPlay?.headers=[:]}
                }
                if !value.isEmpty{guard webURL(value) != nil else{throw TVFailure.invalidURL};updated.guides.append(value)}
                try await model.saveSource(updated);dismiss()
            }catch{failure=error.localizedDescription};saving=false}
        }.disabled(saving);Button("Cancel"){dismiss()}.disabled(saving)}
    }.padding(70)}.onAppear{if let headers=source.fairPlay?.headers,!headers.isEmpty,let data=try? JSONEncoder().encode(headers){licenseHeaders=String(data:data,encoding:.utf8) ?? ""}}}
}

struct TorrentSettings:View {
    @AppStorage("torrentLimitGB") private var limit=8
    @State private var show=false
    @State private var message=""
    var body:some View{VStack(alignment:.leading,spacing:22){Button("Open magnet / .torrent URL"){show=true};Menu("Cache limit: \(limit) GB"){ForEach([2,4,8,16,32],id:\.self){value in Button("\(value) GB"){limit=value}}};Button("Clear torrent cache"){Task{do{try await TorrentManager.shared.clearCache();message="Torrent cache cleared."}catch{message="Could not clear the torrent cache."}}};if !message.isEmpty{Text(message).font(.caption)};Text("One temporary transfer at a time. MP4/M4V/MOV/TS containers use native playback; codec compatibility still applies.").font(.caption).foregroundStyle(.secondary)}.sheet(isPresented:$show){TorrentScreen()}}
}
