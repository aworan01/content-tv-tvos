# Content TV for Apple TV

Native SwiftUI/AVPlayer tvOS app, version 0.2.0. This first feature version follows the Watchly navigation and dark presentation. It is a new native implementation, not an Android APK converter or a copy of the MediaTV interface. The original installation pilot remains separate.

## Included

- Home, Search, Library, Live TV, Game Day and Settings.
- Movie/series/genre discovery from public Cinemeta catalogues, anime from Kitsu, and optional regional provider shelves. Providers are **off by default**. Over 30 provider options are offered; catalogue availability varies by country. No TMDB API key is needed.
- HTTP/HTTPS M3U imports and Xtream username/password imports. Live channels tune directly; source movies, series and episodes can be browsed under Live TV. A catalogue title can be matched by name to your Xtream movies or series. Source matching is approximate and you choose the result.
- Channel groups, source filters, A–Z/Z–A/source sorting, list/grid display, favourites, saved discovery titles and recent playback. On-demand history resumes when the item has not reached its end.
- XMLTV and gzip XMLTV. Automatic playlist-declared feeds, optional source/shared feeds, manual channel mapping and per-source time shifts. Country presets: UK, Finland, Iceland, Sweden, Latvia, Netherlands and USA. No guide feeds are enabled automatically.
- Game Day lists today's sports programmes from matched EPG data. It does not supply an independent sports stream service. Programme categories/titles determine whether an event appears.
- Live player with channel stepping, half-screen channel/EPG browser, group selection, favourite control, retry, audio/subtitle choices when exposed by the stream, HLS adaptive quality limits when advertised, and alternate entries sharing a guide ID within the same source.

## Siri Remote

With playback controls hidden:

- **OK:** show controls.
- **Up / Down:** next / previous live channel, wrapping in the list you started from.
- **Right:** open a browser on the right half of the screen. Its left half lists channels; its right half shows the focused channel's programmes and descriptions.
- **Left inside the channel column:** show groups; choose a group, then choose a channel. Focusing a channel previews its guide; OK tunes it immediately.
- **Play/Pause:** toggle playback.
- **Back:** close the active options/group/browser/controls layer, then exit playback.

Audio preferences are remembered by language when the next stream offers it. Quality options cap adaptive playback rather than guaranteeing a fixed resolution. The player uses the same controls for live and on-demand media, with live-specific channel/EPG actions and on-demand seek/resume actions.

## Install from Windows

1. Download the **unsigned device IPA** from this repository's Releases page.
2. Use [atvloadly](https://github.com/bitxeno/atvloadly) on Windows, following its Apple TV pairing instructions. Use the same local signing/pairing method that worked for the installation pilot.
3. Select the IPA and sign/install with your own free Apple account locally. Keep your password and two-factor codes in the installer, never in GitHub or a chat.
4. Launch **Content TV**. Add your source under Settings. Enable guide countries/URLs if required, then apply guide settings. Provider rows can be enabled separately.

The bundle ID is `tv.content.tvos.aworan01`, distinct from the pilot's bundle ID. A free account's installation generally needs re-signing after seven days. This is not an App Store or TestFlight package and contains no Apple signing identity, profile or entitlements. No paid developer account is used by the build.

## Limits and data handling

- Playback requires a stream supported by Apple's AVPlayer and access provided by your source. Metadata/provider listings do not provide subscription access. Not every stream playable on Android is supported on tvOS.
- Stalker portals, DaddyLive, torrents, DRM and custom HTTP playback headers are outside this release. Header/DRM playlist declarations are detected and reported rather than silently discarded. Timst is not included.
- M3U imports currently use URLs; there is no local file import UI. Large guide files are capped at 32 MB compressed / 256 MB expanded, with at most 100,000 retained programmes. The retained guide window is the previous day through the next two days.
- Sources and watch history are kept in the app's Keychain storage. Favourites and display/provider preferences are local settings. Downloaded playlist/API/guide/catalogue responses and logos may be cached in the local app sandbox and can contain source URLs; caches are not encrypted by this app and tvOS may evict them. No user data is included in this repository or build artifacts. Removing a source removes its configuration; tvOS manages cached response files separately.
- Network requests go to your configured sources, selected guide feeds, and public catalogue/image services. Plain HTTP is allowed for compatibility; prefer HTTPS for credentials. The app has no telemetry service.
- Public catalogues/guide services are external dependencies with no uptime guarantee. Cached responses are used after network failures where available and may be stale. Refresh forces a network attempt.
- Guide matching prioritizes a manual mapping, then an exact XMLTV ID, then a unique normalized display name. Ambiguous names are left unmatched. Dates are interpreted using the XMLTV timezone, or UTC when none is supplied; time shifts are applied once when displayed.

## Build and validation

The manual GitHub Actions workflow uses a standard **public** macOS runner with Xcode and XcodeGen. It refuses to run if the repository is private. There are no Apple credentials, paid services, artifact uploads or cache actions. It runs parser/selection unit tests on a tvOS simulator, captures the clean initial screen, builds the physical arm64 AppleTVOS app unsigned and validates the IPA's bundle/platform/Mach-O contents before publishing a prerelease.

Run locally on a Mac with Xcode and XcodeGen:

```sh
python3 -m unittest discover -s scripts -p 'test_*.py' -v
bash scripts/build-pilot.sh
```

`scripts/build-pilot.sh` retains its original filename from the proven pilot pipeline but now builds ContentTV. Python tests cover IPA validation; Swift tests cover playlist/guide parsing, matching/offsets, sorting/zapping, Xtream URLs, catalogue metadata and advertised HLS quality parsing. Network catalogue responses were checked during preparation; that is not a guarantee of future service availability.

Compilation and unit tests do not establish physical remote focus behavior, signing success or compatibility with your individual media sources. These need device checks. After installation, test source entry, direct tune, Up/Down, the right-side browser, group selection, audio/subtitle menus, guide matching, source movies/episodes, pause/resume and reopening the app. The pilot's successful device playback does not validate these new features.
