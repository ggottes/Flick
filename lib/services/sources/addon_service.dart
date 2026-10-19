import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/utils/app_log.dart';
import '../../data/database.dart';
import '../../models/song.dart';
import '../library_scanner_service.dart' show ScanProgress;
import '../network_cache_service.dart';
import 'addon_models.dart';
import 'network_source_service.dart';

/// Adapter for generic third-party **addons**.
///
/// An addon is a remote HTTP service with three `GET` JSON routes:
///
///   * `GET <root>/manifest.json`   → id/name/resources/settings
///   * `GET <root>/search?q=…`      → `{"tracks": […]}` (plus setting defaults)
///   * `GET <root>/stream/{id}`     → one playable rendition
///
/// Flick never executes addon code. It reads JSON, then hands the returned
/// absolute media URL to the existing native engine, so bit-perfect PCM, DSP,
/// gapless and DSD all keep working unchanged.
///
/// Only direct (`manifest: "none"`) renditions are accepted. HLS/DASH are
/// refused with a typed [AddonException] because the Rust engine has no
/// HLS/DASH demuxer; faking playback through a second player would break the
/// one-playback-path invariant.
///
/// Songs returned by [songForHit] are **ephemeral**: they are never written to
/// Isar, so an addon can never pollute the local library. Their ids are
/// deliberately non-numeric, which makes every row-based subsystem (recently
/// played, waveform cache, metadata editor, delete) no-op instead of corrupt.
class AddonService implements NetworkSourceService {
  AddonService._({
    http.Client? client,
    NetworkCacheService? networkCache,
    DateTime Function()? now,
  })  : _client = client ?? http.Client(),
        _networkCache = networkCache,
        _now = now ?? DateTime.now;

  /// Singleton used by the app.
  static AddonService instance = AddonService._();

  /// Test seam: build an isolated instance with mocked dependencies.
  @visibleForTesting
  static AddonService create({
    http.Client? client,
    NetworkCacheService? networkCache,
    DateTime Function()? now,
  }) {
    return AddonService._(
      client: client,
      networkCache: networkCache,
      now: now,
    );
  }

  /// Quality Flick always requests. Lossless-only is a product decision: the
  /// engine's job is bit-exact output, and every addon in scope can serve it.
  static const String requestedQuality = 'LOSSLESS';

  /// The contract specifies addon caches of 10 minutes for manifest/search.
  static const Duration manifestTtl = Duration(minutes: 10);
  static const Duration searchTtl = Duration(minutes: 10);

  /// Stream URLs stay valid for at least 5 minutes; re-resolve before that.
  static const Duration descriptorTtl = Duration(minutes: 5);

  /// Search is a fan-out on the typing path, so it must fail fast.
  static const Duration requestTimeout = Duration(seconds: 8);

  /// A malicious or broken addon must not be able to dump 100k rows into the
  /// search list.
  static const int maxSearchRows = 500;

  static const String coverMarkerScheme = 'addon-cover://';

  final http.Client _client;

  NetworkCacheService? _networkCache;

  NetworkCacheService get _cache => _networkCache ??= NetworkCacheService();

  final DateTime Function() _now;

  String? _lastPingError;

  // --- Caches --------------------------------------------------------------

  final Map<int, _CachedManifest> _manifests = {};
  final Map<String, _CachedSearch> _searches = {};
  final Map<String, _CachedDescriptor> _descriptors = {};
  final Map<String, Future<({String url, Map<String, String> headers})>>
      _inflightDescriptors = {};

  /// 429 throttle windows keyed by addon root.
  final Map<int, DateTime> _throttledUntil = {};

  @override
  String get protocol => NetworkProtocol.addon;

  @override
  String get coverScheme => coverMarkerScheme;

  @override
  String? get lastPingError => _lastPingError;

  // --- Root / manifest -----------------------------------------------------

  /// Normalize a user-typed addon URL into a usable root.
  ///
  /// Accepts a bare host, a trailing slash, the manifest URL itself, and
  /// ignores query/fragment noise. Returns null when the result could not be
  /// an http(s) origin + path.
  static String? normalizeRoot(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';

    var uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (path.endsWith('/manifest.json')) {
      path = path.substring(0, path.length - '/manifest.json'.length);
      path = path.replaceAll(RegExp(r'/+$'), '');
    }

    final root = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
    return root.toString().replaceAll(RegExp(r'/+$'), '');
  }

  Uri _rootUri(NetworkServerEntity server) {
    final normalized = normalizeRoot(server.baseUrl);
    if (normalized == null) {
      throw AddonException(
        AddonErrorCode.notAnAddon,
        'Invalid addon URL "${server.baseUrl}"',
      );
    }
    return Uri.parse(normalized);
  }

  /// Well-known manifest URL for [server] (used by tests and ping).
  Uri manifestUri(NetworkServerEntity server) =>
      _rootUri(server).replace(path: '${_rootUri(server).path}/manifest.json');

  Uri _searchUri(NetworkServerEntity server) =>
      _rootUri(server).replace(path: '${_rootUri(server).path}/search');

  Uri _streamUri(NetworkServerEntity server, String trackId) {
    final root = _rootUri(server);
    final encoded = Uri.encodeComponent(trackId);
    return root.replace(path: '${root.path}/stream/$encoded');
  }

  /// Manifest for [server], from cache when fresh, else fetched. Falls back to
  /// the blob stored in [NetworkServerEntity.token] so an edit screen can show
  /// the name/version while offline.
  Future<AddonManifest> manifestFor(
    NetworkServerEntity server, {
    bool forceRefresh = false,
  }) async {
    final cached = _manifests[server.id];
    if (!forceRefresh && cached != null && _now().isBefore(cached.expiresAt)) {
      return cached.manifest;
    }

    final stored = parseStored(server.token)?.manifest;
    if (cached == null && stored != null && !forceRefresh) {
      // Seed from disk so the first frame after a cold start has a name.
      _manifests[server.id] = _CachedManifest(
        stored,
        _now().add(manifestTtl),
      );
      unawaited(_refreshManifestQuietly(server));
      return stored;
    }

    return _fetchManifest(server);
  }

  Future<void> _refreshManifestQuietly(NetworkServerEntity server) async {
    try {
      await _fetchManifest(server);
    } catch (e) {
      AppLog.instance.add('Addon manifest refresh failed for ${server.label}: $e');
    }
  }

  Future<AddonManifest> _fetchManifest(NetworkServerEntity server) async {
    final raw = await _getJson(
      server,
      manifestUri(server),
      timeout: requestTimeout,
    );
    final manifest = AddonManifest.tryParse(raw);
    if (manifest == null) {
      throw AddonException(
        AddonErrorCode.notAnAddon,
        'That URL answered, but not with an addon manifest.',
      );
    }
    _manifests[server.id] = _CachedManifest(
      manifest,
      _now().add(manifestTtl),
    );
    return manifest;
  }

  /// The persisted blob shape: `{"root": …, "manifest": {…}}`.
  static ({String root, AddonManifest manifest})? parseStored(String? token) {
    if (token == null || token.isEmpty) return null;
    try {
      final decoded = jsonDecode(token);
      if (decoded is! Map) return null;
      final manifest = AddonManifest.fromJson(decoded['manifest']);
      if (manifest == null) return null;
      final root = decoded['root'];
      return (root: root is String ? root : '', manifest: manifest);
    } catch (_) {
      return null;
    }
  }

  /// Serialize a manifest + root into the token blob.
  static String encodeStored(String root, AddonManifest manifest) =>
      jsonEncode({'root': root, 'manifest': manifest.toJson()});

  // --- NetworkSourceService ------------------------------------------------

  /// Fetch the manifest and persist it in the token blob. On a transport
  /// failure, reuse the blob when it describes the same root (so re-saving an
  /// unchanged addon offline keeps working); otherwise rethrow for the edit
  /// screen's failure banner.
  @override
  Future<String?> resolveToken(
    NetworkServerEntity server,
    String password,
  ) async {
    final root = normalizeRoot(server.baseUrl);
    if (root == null) {
      throw AddonException(
        AddonErrorCode.notAnAddon,
        'Invalid addon URL "${server.baseUrl}"',
      );
    }
    final probe = NetworkServerEntity()
      ..id = server.id
      ..label = server.label
      ..protocol = server.protocol
      ..baseUrl = root;
    try {
      final manifest = await _fetchManifest(probe);
      return encodeStored(root, manifest);
    } catch (e) {
      final stored = parseStored(server.token);
      if (stored != null && stored.root == root) return server.token;
      rethrow;
    }
  }

  @override
  Future<bool> ping(NetworkServerEntity server) async {
    _lastPingError = null;
    try {
      final manifest = await _fetchManifest(server);
      if (!manifest.supportsSearch) {
        _lastPingError =
            'This addon is reachable but does not declare the "search" '
            'resource, so Flick cannot use it.';
        return false;
      }
      return true;
    } on AddonException catch (e) {
      _lastPingError = e.message;
      AppLog.instance.add('Addon ping failed for ${server.label}: $e');
      return false;
    } catch (e) {
      _lastPingError = 'Could not reach ${server.label}: $e';
      AppLog.instance.add('Addon ping failed for ${server.label}: $e');
      return false;
    }
  }

  /// Fetch artwork bytes for [marker], which is an absolute URL for addons.
  @override
  Future<List<int>> getCoverArt(
    NetworkServerEntity server,
    String marker,
  ) async {
    final uri = Uri.tryParse(marker);
    if (uri == null) {
      throw AddonException(AddonErrorCode.unreachable, 'Invalid artwork URL');
    }
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw AddonException(
        AddonErrorCode.unreachable,
        'Artwork HTTP ${response.statusCode}',
      );
    }
    return response.bodyBytes;
  }

  @override
  Future<({String url, Map<String, String> headers})?> streamDescriptor(
    NetworkServerEntity server,
    String remoteId, {
    String? extension,
  }) =>
      preflight(server, remoteId);

  /// Resolve (and validate) the playable rendition for [remoteId].
  ///
  /// Public so the search screen can call it *before* starting playback: the
  /// player's own resolve path swallows errors, so an HLS/encrypted addon would
  /// otherwise only surface in the log after a spinner had already started.
  /// Results are cached, so the play-time resolve is free.
  Future<({String url, Map<String, String> headers})> preflight(
    NetworkServerEntity server,
    String remoteId,
  ) async {
    final key = '${server.id}:$remoteId';
    final cached = _descriptors[key];
    if (cached != null && _now().isBefore(cached.expiresAt)) {
      return cached.descriptor;
    }
    final inflight = _inflightDescriptors[key];
    if (inflight != null) return inflight;

    final future = _resolveDescriptor(server, remoteId);
    _inflightDescriptors[key] = future;
    try {
      final descriptor = await future;
      _descriptors[key] = _CachedDescriptor(
        descriptor,
        _now().add(descriptorTtl),
      );
      return descriptor;
    } finally {
      _inflightDescriptors.remove(key);
    }
  }

  Future<({String url, Map<String, String> headers})> _resolveDescriptor(
    NetworkServerEntity server,
    String remoteId,
  ) async {
    final manifest = await manifestFor(server);
    final root = normalizeRoot(server.baseUrl) ?? server.baseUrl;

    if (!manifest.supportsStream) {
      final fallback = _streamUrlFallback(root, remoteId);
      if (fallback != null) return fallback;
      throw AddonException(
        AddonErrorCode.notStreamable,
        'Addon "${manifest.name}" declares no stream resource and this track '
        'has no direct URL.',
      );
    }

    final uri = _streamUri(server, remoteId).replace(
      queryParameters: {'quality': requestedQuality, 'atmos': 'auto'},
    );

    final http.Response response;
    try {
      response = await _client.get(uri).timeout(requestTimeout);
    } catch (e) {
      throw AddonException(
        AddonErrorCode.unreachable,
        'Could not reach the addon: $e',
      );
    }

    if (response.statusCode == 429) {
      _throttledUntil[server.id] =
          _now().add(_retryAfter(response.headers['retry-after']));
      throw AddonException(
        AddonErrorCode.rateLimited,
        'Addon "${manifest.name}" is rate limiting requests.',
      );
    }

    if (response.statusCode == 404) {
      final fallback = _streamUrlFallback(root, remoteId);
      if (fallback != null) return fallback;
      throw AddonException(
        AddonErrorCode.trackUnavailable,
        'The addon no longer has this track.',
      );
    }

    if (response.statusCode != 200) {
      throw AddonException(
        AddonErrorCode.unreachable,
        'Addon stream HTTP ${response.statusCode}',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw AddonException(
        AddonErrorCode.addonError,
        'The addon returned a non-JSON stream response.',
      );
    }
    return _descriptorFromPayload(decoded, manifest);
  }

  /// Validate a `/stream/{id}` payload against the playback contract.
  ({String url, Map<String, String> headers}) _descriptorFromPayload(
    Object? raw,
    AddonManifest manifest,
  ) {
    final map = raw is Map ? raw : const <String, dynamic>{};

    final error = map['error'];
    final whileUrl = map['url'];
    if (error is String && error.trim().isNotEmpty &&
        (whileUrl is! String || whileUrl.trim().isEmpty)) {
      throw AddonException(
        AddonErrorCode.addonError,
        'Addon "${manifest.name}": ${error.trim()}',
      );
    }

    final encrypted = map['encrypted'];
    if (encrypted == true || encrypted?.toString() == 'true') {
      throw AddonException(
        AddonErrorCode.encrypted,
        'This rendition is DRM-encrypted.',
      );
    }

    final container = map['manifest']?.toString().trim().toLowerCase();
    if (container == 'hls' || container == 'dash') {
      throw AddonException(
        AddonErrorCode.unsupportedStream,
        'This track is only offered as $container.',
        kind: container,
      );
    }

    final url = map['url'];
    final uri = url is String ? Uri.tryParse(url.trim()) : null;
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw AddonException(
        AddonErrorCode.addonError,
        'The addon returned no absolute stream URL.',
      );
    }

    return (url: uri.toString(), headers: const <String, String>{});
  }

  /// The track's own direct URL, when a previous search stored one.
  ({String url, Map<String, String> headers})? _streamUrlFallback(
    String root,
    String remoteId,
  ) {
    final direct = _directFor(root, remoteId);
    if (direct == null) return null;
    final uri = Uri.tryParse(direct);
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return (url: uri.toString(), headers: const <String, String>{});
  }

  /// Direct stream URLs remembered from the last search, keyed
  /// `root\u0000trackId`. Bounded by the search TTL; never persisted.
  final Map<String, _CachedDirect> _directUrls = {};

  String? _directFor(String root, String trackId) {
    final key = '$root\u0000$trackId';
    final entry = _directUrls[key];
    if (entry == null) return null;
    if (_now().isAfter(entry.expiresAt)) {
      _directUrls.remove(key);
      return null;
    }
    return entry.url;
  }

  void _rememberDirect(String root, AddonTrack track) {
    final url = track.streamURL;
    if (url == null) return;
    _directUrls['$root\u0000${track.id}'] = _CachedDirect(
      url,
      _now().add(searchTtl),
    );
  }

  @override
  Future<String> stream(
    NetworkServerEntity server,
    String remoteId, {
    String? extension,
    void Function(double progress)? onProgress,
  }) async {
    final manifest = await manifestFor(server);
    if (!manifest.allowDownloads) {
      throw AddonException(
        AddonErrorCode.downloadsDisabled,
        'Addon "${manifest.name}" does not allow downloads.',
      );
    }

    final cached = await _cache.getPath(server.id, remoteId,
        extension: extension);
    if (cached != null) return cached;

    final descriptor = await preflight(server, remoteId);
    final request = http.Request('GET', Uri.parse(descriptor.url));
    request.headers.addAll(descriptor.headers);
    final response =
        await _client.send(request).timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) {
      throw AddonException(
        AddonErrorCode.unreachable,
        'Download HTTP ${response.statusCode}',
      );
    }
    final total = response.contentLength;
    final builder = BytesBuilder();
    var received = 0;
    await for (final chunk in response.stream) {
      builder.add(chunk);
      received += chunk.length;
      if (onProgress != null && total != null && total > 0) {
        onProgress(received / total);
      }
    }
    return _cache.stash(
      server.id,
      remoteId,
      builder.takeBytes(),
      extension: extension,
    );
  }

  /// Addons have no catalogue endpoint: search is the only way in. Yield one
  /// completed progress so the settings screen's generic sync loop settles
  /// without touching the library.
  @override
  Stream<ScanProgress> syncLibrary(NetworkServerEntity server) async* {
    yield ScanProgress(
      songsFound: 0,
      totalFiles: 0,
      filesProcessed: 0,
      isComplete: true,
    );
  }

  // --- Search --------------------------------------------------------------

  /// Search a single addon. Throws [AddonException] on failure.
  Future<List<AddonTrack>> search(
    NetworkServerEntity server,
    String query, {
    bool forceRefresh = false,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const <AddonTrack>[];

    final manifest = await manifestFor(server);
    if (!manifest.supportsSearch) {
      throw AddonException(
        AddonErrorCode.noSearchResource,
        'Addon "${manifest.name}" does not declare the search resource.',
      );
    }

    final root = normalizeRoot(server.baseUrl) ?? server.baseUrl;
    final cacheKey = '${server.id}\u0000${q.toLowerCase()}';
    final cached = _searches[cacheKey];
    if (!forceRefresh && cached != null && _now().isBefore(cached.expiresAt)) {
      return cached.tracks;
    }

    final throttled = _throttledUntil[server.id];
    if (throttled != null && _now().isBefore(throttled)) {
      throw AddonException(
        AddonErrorCode.rateLimited,
        'Addon "${manifest.name}" is rate limiting requests.',
      );
    }

    // `q`, then the manifest's declared defaults, then the requested quality
    // (which wins over a default of the same name).
    final params = <String, String>{'q': q};
    for (final setting in manifest.settings) {
      final value = setting.defaultValue;
      if (value == null) continue;
      params[setting.key] = value;
    }
    params['quality'] = requestedQuality;

    final uri = _searchUri(server).replace(queryParameters: params);

    final http.Response response;
    try {
      response = await _client.get(uri).timeout(requestTimeout);
    } catch (e) {
      throw AddonException(
        AddonErrorCode.unreachable,
        'Could not reach the addon: $e',
      );
    }

    if (response.statusCode == 429) {
      _throttledUntil[server.id] =
          _now().add(_retryAfter(response.headers['retry-after']));
      throw AddonException(
        AddonErrorCode.rateLimited,
        'Addon "${manifest.name}" is rate limiting requests.',
      );
    }
    if (response.statusCode != 200) {
      throw AddonException(
        AddonErrorCode.unreachable,
        'Addon search HTTP ${response.statusCode}',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw AddonException(
        AddonErrorCode.unreachable,
        'The addon returned a non-JSON search response.',
      );
    }

    final tracks = parseTracks(decoded);
    for (final track in tracks) {
      _rememberDirect(root, track);
    }
    _searches[cacheKey] = _CachedSearch(
      tracks,
      _now().add(searchTtl),
    );
    return tracks;
  }

  /// Parse a `{"tracks": [...]}` payload, dropping malformed rows and capping
  /// the count. Addon order is preserved (it is the addon's relevance order).
  @visibleForTesting
  static List<AddonTrack> parseTracks(Object? decoded) {
    if (decoded is! Map) return const <AddonTrack>[];
    final raw = decoded['tracks'];
    if (raw is! List) return const <AddonTrack>[];
    final out = <AddonTrack>[];
    for (final entry in raw) {
      final track = AddonTrack.tryParse(entry);
      if (track == null) continue;
      out.add(track);
      if (out.length >= maxSearchRows) break;
    }
    return out;
  }

  /// Fan out across [servers]. One failing addon never blanks the section: its
  /// error is recorded and the rest still return.
  Future<AddonSearchResults> searchAll(
    String query, {
    required List<NetworkServerEntity> servers,
  }) async {
    if (servers.isEmpty) return AddonSearchResults.empty;
    final hits = <AddonSearchHit>[];
    final errors = <AddonSearchFailure>[];

    final results = await Future.wait(
      servers.map((server) async {
        try {
          final manifest = await manifestFor(server);
          final tracks = await search(server, query);
          return (
            server: server,
            manifest: manifest,
            tracks: tracks,
            error: null,
          );
        } on AddonException catch (e) {
          return (
            server: server,
            manifest: null,
            tracks: const <AddonTrack>[],
            error: e.message,
          );
        } catch (e) {
          return (
            server: server,
            manifest: null,
            tracks: const <AddonTrack>[],
            error: e.toString(),
          );
        }
      }),
    );

    for (final result in results) {
      final manifest = result.manifest;
      if (manifest == null || result.error != null) {
        errors.add(AddonSearchFailure(
          serverLabel: result.server.label,
          message: result.error ?? 'Unknown addon error',
        ));
        continue;
      }
      for (final track in result.tracks) {
        hits.add(AddonSearchHit(
          track: track,
          server: result.server,
          manifest: manifest,
        ));
      }
    }

    return AddonSearchResults(hits: hits, errors: errors);
  }

  // --- Ephemeral songs -----------------------------------------------------

  /// Build a [Song] for a search hit. Pure mapping; nothing is persisted.
  ///
  /// The synthetic id is non-numeric on purpose: every Isar-backed subsystem
  /// parses song ids with `int.tryParse` and therefore no-ops for addon
  /// tracks instead of writing or deleting rows.
  static Song songForHit(AddonSearchHit hit) {
    final track = hit.track;
    final serverId = hit.server.id;
    final filePath = Uri(
      scheme: NetworkProtocol.addon,
      host: '$serverId',
      pathSegments: [track.id],
    ).toString();

    return Song(
      id: '${NetworkProtocol.addon}:$serverId:${track.id}',
      title: track.title,
      artist: track.artist ?? '',
      album: track.album,
      albumArt: track.artworkURL,
      duration: track.duration ?? Duration.zero,
      fileType: (track.format ?? 'unknown').toUpperCase(),
      resolution: track.audioQuality,
      filePath: filePath,
      sourceType: NetworkProtocol.addon,
      remoteId: track.id,
      remoteServerId: serverId,
    );
  }

  // --- Helpers -------------------------------------------------------------

  Future<Object?> _getJson(
    NetworkServerEntity server,
    Uri uri, {
    required Duration timeout,
  }) async {
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } catch (e) {
      throw AddonException(
        AddonErrorCode.unreachable,
        'Could not reach the addon: $e',
      );
    }
    if (response.statusCode != 200) {
      throw AddonException(
        AddonErrorCode.unreachable,
        'Addon HTTP ${response.statusCode}',
      );
    }
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw AddonException(
        AddonErrorCode.notAnAddon,
        'That URL answered, but not with an addon manifest.',
      );
    }
  }

  static Duration _retryAfter(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    if (seconds == null || seconds <= 0) return const Duration(seconds: 30);
    return Duration(seconds: seconds.clamp(1, 3600));
  }
}

class _CachedManifest {
  _CachedManifest(this.manifest, this.expiresAt);
  final AddonManifest manifest;
  final DateTime expiresAt;
}

class _CachedSearch {
  _CachedSearch(this.tracks, this.expiresAt);
  final List<AddonTrack> tracks;
  final DateTime expiresAt;
}

class _CachedDescriptor {
  _CachedDescriptor(this.descriptor, this.expiresAt);
  final ({String url, Map<String, String> headers}) descriptor;
  final DateTime expiresAt;
}

class _CachedDirect {
  _CachedDirect(this.url, this.expiresAt);
  final String url;
  final DateTime expiresAt;
}
