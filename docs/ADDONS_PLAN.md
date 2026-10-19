# Addons — Generic Search & Streaming Sources

Flick can search and play audio from **third-party addons**. An addon is not
in-app code: it is a remote HTTP service exposing three `GET` JSON routes. Flick
reads JSON, then hands the returned absolute media URL to the **existing Rust
audio engine**, so bit-perfect PCM, native DSD, the full DSP chain, gapless and
crossfade all keep working. One playback path — no plugin runtime, no second
player, no new dependencies.

An addon is treated as a `NetworkSourceService` (the same abstraction behind
Subsonic, Jellyfin, WebDAV, UPnP, SMB and Tidal) with one deliberate difference:
it has **no library**. There is no catalogue endpoint to sync, so addon tracks
are *ephemeral*: they exist only as `Song` objects handed to the player and are
never written to Isar.

## Wire contract

All routes are plain `GET`s. Responses are JSON; media bytes are fetched
separately from the URL the addon returns.

### `GET <root>/manifest.json`

```json
{
  "id": "my-addon",
  "name": "My Addon",
  "version": "1.2.0",
  "resources": ["search", "stream"],
  "settings": [
    {
      "key": "provider",
      "type": "select",
      "default": "lossless",
      "label": "Provider",
      "options": [{ "label": "Lossless", "value": "lossless" }]
    }
  ],
  "allowDownloads": 1,
  "checkValidLossless": 1
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Non-empty. Namespaces the addon's tracks. |
| `name` | no | Display name; falls back to `id`. |
| `version` | no | Shown beside the name in Settings. |
| `resources` | yes | Must contain `search`. `stream` is optional when rows carry `streamURL`. |
| `settings` | no | Query parameters the addon understands. Flick forwards each `default` on every search. |
| `allowDownloads` | no | `1`/`0`, `true`/`false`, or their string forms. Default `1`. `0` forbids whole-file caching. |
| `checkValidLossless` | no | Accepted and stored, then ignored: Flick verifies bit depth itself on the native path. |

A manifest without a non-empty `id` is rejected, and the URL is reported as
"answered, but not with an addon manifest".

The root URL is normalized on entry: a missing scheme becomes `https://`, a
trailing `/` and a terminal `/manifest.json` are stripped, and query/fragment
noise is dropped.

### `GET <root>/search?q=<query>`

Query parameters are, in order: `q`, every manifest `settings` default, then
`quality=LOSSLESS`. The requested quality always wins over a same-named default.

```json
{
  "tracks": [
    {
      "id": "track-1",
      "title": "Song",
      "artist": "Artist",
      "album": "Album",
      "duration": 245.3,
      "artworkURL": "https://cdn.example.com/cover.jpg",
      "format": "flac",
      "audioQuality": "LOSSLESS",
      "streamURL": "https://cdn.example.com/track-1.flac",
      "audioModes": ["atmos"]
    }
  ]
}
```

- `id` and `title` are required; rows missing either are dropped.
- `duration` is seconds and may be fractional.
- `artworkURL` wins over `albumArtworkURL`. Only absolute `http(s)` URLs are
  kept; anything else is ignored rather than shown broken.
- `streamURL` is a fallback used when `/stream/{id}` has no rendition.
- Addon order is preserved (it is the addon's relevance order). A response is
  capped at 500 rows.
- `quality=LOSSLESS` is not negotiable: the app's product invariant is
  bit-exact output, so a lossy-only rendition is not requested.

### `GET <root>/stream/<id>?quality=LOSSLESS&atmos=auto`

```json
{
  "url": "https://cdn.example.com/track-1.flac",
  "codec": "flac",
  "container": "flac",
  "manifest": "none",
  "encrypted": false,
  "sampleRate": 96000,
  "bitDepth": 24,
  "bitrate": 2300
}
```

| Field | Meaning |
| --- | --- |
| `url` | Required. Absolute `http(s)` URL of the audio bytes. |
| `codec` | Most reliable format hint (`flac`, `alac`, `mp3`, `aac`, `eac3-joc`). |
| `container` | Advisory only. |
| `manifest` | `none` (or absent) for direct audio. `hls`/`dash` are **refused**. |
| `encrypted` | Must not be `true`. Encrypted renditions are refused. |
| `sampleRate` | Hz. Values below 1000 are treated as kHz. |
| `bitDepth` | Bits. |
| `bitrate` | Display only. |
| `error` | A 200 with `error` and no `url` is surfaced as an addon error. |

`404` means the addon no longer has the track: Flick falls back to the
`streamURL` remembered from the last search, and otherwise reports the track as
unavailable.

### Caching and throttling

- Manifests: 10 minutes. Searches: 10 minutes, keyed by lowercased query.
- Stream descriptors: 5 minutes, in-flight requests de-duplicated. **Stream
  URLs are never persisted.**
- `429` must carry `Retry-After`: the addon is throttled for that window and no
  further requests are made until it expires.

## Behaviour in Flick

- **Search.** Addon hits appear as their own section at the bottom of the
  existing global search screen, with a chip count, and only when the Addons
  chip is enabled. Local results render immediately; the addon section fills in
  when the network answers. A failing addon becomes one quiet line and never
  blanks the others.
- **Playback.** The stream descriptor is resolved **before** playback starts, so
  an HLS/DASH/encrypted answer produces a specific message instead of a spinner
  that never resolves. Queue mode is honoured; "play from library" behaves like
  "play from results", because addon tracks are not in the library.
- **Settings.** Addons are added under Network Sources like any other server:
  paste the base URL, Test Connection, save. There is no username or password,
  and no sync button — only "Search and stream" or "Search only" from the
  manifest.
- **Removing an addon** leaves no library rows behind, because none were
  created.

## Ephemeral tracks: what does not work, by design

An addon track has a non-numeric id (`addon:<serverId>:<trackId>`), so every
Isar-backed subsystem no-ops instead of corrupting:

- No recently-played entry, no waveform peaks, no metadata editing, no delete.
- No favorites-screen entry (the favorite itself has no row to live on).
- No last-played resume: `_savePosition` skips non-numeric ids so an addon
  track can never clobber the local resume point.
- No notification/lock-screen/home-widget artwork: those decode a local file,
  and addon art is an absolute URL. In-app artwork works normally.

## Limits

- Only direct (`manifest: "none"`) audio is supported; HLS/DASH require a
  demuxer the native engine does not have, and shipping a second player would
  break the single-playback-path invariant.
- No cross-addon stream fallback: a track id is addon-scoped, so retrying it on
  another addon would risk id collisions and extra latency.
- `allowDownloads: 0` disables prefetch as well as explicit downloads.

## Where the code lives

| File | Role |
| --- | --- |
| `lib/services/sources/addon_models.dart` | Wire models, typed errors. |
| `lib/services/sources/addon_service.dart` | The `NetworkSourceService` adapter: manifest, search, stream, cache. |
| `lib/features/search/providers/addon_search_provider.dart` | Fan-out provider for the search screen. |
| `test/services/addon_service_test.dart` | Contract tests (no network, `MockClient`). |

The manifest blob is stored in `NetworkServerEntity.token` as
`{"root": …, "manifest": {…}}`, following the Jellyfin/Tidal precedent, so no
schema change was needed.
