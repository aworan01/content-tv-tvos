# Content TV for Apple TV

Native SwiftUI/AVPlayer tvOS app, version 0.3.0. The interface follows Watchly's navigation and dark presentation. This is a native implementation, not an Android APK converter or a copy of the MediaTV interface. The original installation pilot remains separate. Version 0.2.0 was confirmed working on the user's Apple TV; the new features in 0.3.0 need their own device checks.

## New in 0.3.0

- Optional DaddyLive channel directory and Game Day schedule, enabled in Settings. Its public stream resolver, renewable playlist tokens and packaged-media transport feed the same native player. Failures are reported separately from personal sources. Schedule times/date labels are displayed as supplied by the provider, not presented as live scores or confirmed match status.
- A loopback-only HLS relay forwards source headers, rewrites nested playlists/audio/subtitle/key/map URLs, unwraps DaddyLive media and services byte ranges. It uses per-session unguessable routes, never accepts arbitrary destination URLs from clients, and stops with playback. Bounded responses are capped at 24 MB; this is intended for HLS segments, not large direct files requiring custom headers.
- Native libtorrent 2.0.11 for magnet links and HTTP(S) `.torrent` metadata URLs. Open from Library or Settings, load metadata, then choose a video. Selected pieces are prioritized around playback reads; byte ranges support seeking and MP4 tail metadata reads. One temporary selected-file transfer at a time, configurable 2/4/8/16/32 GB file limit, 8 GB default. Transfers stop and their cache is removed on playback exit/background; foreground resume may need to re-download data. Upload is capped at 256 KiB/s. The engine uses DHT/PEX and UDP/HTTP trackers; this build has no native HTTPS tracker transport. HTTPS `.torrent` metadata downloads use URLSession and are supported.
- Compatible HLS ClearKey handling: parse Kodi `license_type`/`license_key`, validate 16-byte IDs/keys from `kid:key`, JSON maps, JWK responses or data URIs, and supply configured keys to HLS `AES-128`/compatible `SAMPLE-AES` identity-key playback. Multiple keys require explicit matching HLS `KEYID` values. Remote W3C-style ClearKey licence endpoints receive a JSON POST with `kids`/`type`. This does not add MPEG-DASH/CENC playback.
- FairPlay client licence handling using AVContentKeySession, including renewals, separate licence headers, provider certificate/content-ID configuration, raw SPC/raw CKC or form SPC/base64 CKC. Configure provider settings when editing a source; compatible M3U declarations can also supply licence metadata. Provider-specific protocols outside these formats are unsupported. No certificate provisioning service or user credentials are built in.

Widevine is unsupported on tvOS ([Google's platform table](https://developers.google.com/widevine/drm/overview)). FairPlay requires a provider-supplied compatible stream, certificate and licence service ([Apple documentation](https://developer.apple.com/streaming/fps/)). FairPlay playback remains unverified without provider test configuration. HLS ClearKey support is not a promise of Android DRM parity. Stalker and Timst are absent.

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
- Torrent playback currently accepts MP4, M4V, MOV and TS containers that AVPlayer can decode. MKV, AVI and WebM files are listed but rejected with an explanation; no VLC/transcoding engine is bundled. Tracker/peer availability, codecs, network speed and free temporary storage determine playback. tvOS may evict cached media; permanent downloads/background seeding are not offered.
- Widevine, MPEG-DASH/CENC, custom licence templates and unsupported key configurations produce limitation messages. The app does not obtain provider access or convert a Widevine stream into FairPlay. Stalker and Timst are not included.
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

`scripts/build-pilot.sh` retains its original filename from the proven pilot pipeline but now builds ContentTV. It verifies/downloads a SHA-256-pinned native dependency archive built by this repository's public macOS workflow. Third-party licence notices are included in the app. To rebuild the native dependency from source instead, install CMake and Ninja and run `CTV_BUILD_NATIVE_SOURCE=1 bash scripts/build-pilot.sh`. The native build pins libtorrent's commit and the official Boost 1.85.0 archive checksum. No Java/Android binary is reused.

Python tests cover IPA validation. Swift tests cover playlist/guide parsing, matching/offsets, sorting/zapping, Xtream URLs, catalogues, HLS qualities, ClearKey validation, HLS rewriting, DaddyLive parsing/unwrapping, real loopback relay/key delivery, local torrent peer transfer and synthetic encrypted-HLS video decoding. The test fixture is original generated test-pattern video/audio with a fixed public test key, not provider content, and is excluded from the IPA. Network catalogue responses were checked during preparation; that is not a guarantee of future service availability.

Compilation and unit tests do not establish physical remote focus behavior, signing success or compatibility with your individual media sources. These need device checks. After installation, test source entry, direct tune, Up/Down, the right-side browser, group selection, audio/subtitle menus, guide matching, source movies/episodes, pause/resume and reopening the app. The pilot's successful device playback does not validate these new features.
