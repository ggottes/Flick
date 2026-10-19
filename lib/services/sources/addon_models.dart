import 'package:flutter/foundation.dart';

import '../../data/entities/network_server_entity.dart';

/// Wire-format model of an addon's `/manifest.json`.
///
/// An addon is a remote HTTP service, not in-app code: Flick only reads JSON
/// from it. [id] is required and namespaces the addon's tracks; [resources]
/// says which routes it serves (`search`, optionally `stream`); [settings]
/// declares query parameters the addon understands, with the default Flick
/// sends when the user has not chosen one.
@immutable
class AddonManifest {
  const AddonManifest({
    required this.id,
    required this.name,
    this.version,
    this.resources = const <String>[],
    this.settings = const <AddonSetting>[],
    this.allowDownloads = true,
    this.checkValidLossless = false,
  });

  final String id;
  final String name;
  final String? version;
  final List<String> resources;
  final List<AddonSetting> settings;

  /// When false the app must stream only, never cache whole files.
  final bool allowDownloads;

  /// Addon-side lossless validation flag. Accepted and stored, but not acted
  /// on: it is an Android-only check in the addon's own reference client and
  /// Flick verifies bit depth itself on the native path.
  final bool checkValidLossless;

  bool get supportsSearch => resources.contains('search');
  bool get supportsStream => resources.contains('stream');

  /// Display label: "Name 1.2.0" when a version is declared.
  String get displayName =>
      version == null || version!.isEmpty ? name : '$name $version';

  /// Parse a raw manifest object. Returns null when the payload is not a
  /// manifest at all (missing/empty `id`), so callers can distinguish "this
  /// URL is not an addon" from "the addon failed".
  static AddonManifest? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _string(raw['id']);
    if (id == null || id.isEmpty) return null;
    final name = _string(raw['name']);
    return AddonManifest(
      id: id,
      name: (name == null || name.isEmpty) ? id : name,
      version: _string(raw['version']),
      resources: _stringList(raw['resources']),
      settings: _parseSettings(raw['settings']),
      allowDownloads: _flag(raw['allowDownloads'], fallback: true),
      checkValidLossless: _flag(raw['checkValidLossless'], fallback: false),
    );
  }

  /// Shape persisted in [NetworkServerEntity.token] alongside the root URL.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (version != null) 'version': version,
        'resources': resources,
        if (settings.isNotEmpty)
          'settings': [for (final s in settings) s.toJson()],
        'allowDownloads': allowDownloads,
        'checkValidLossless': checkValidLossless,
      };

  /// Rehydrate a manifest from a stored blob. Tolerant: a blob written by an
  /// older build (or hand-edited) simply yields a best-effort manifest.
  static AddonManifest? fromJson(Object? raw) => tryParse(raw);

  static List<AddonSetting> _parseSettings(Object? raw) {
    if (raw is! List) return const <AddonSetting>[];
    final out = <AddonSetting>[];
    for (final entry in raw) {
      final setting = AddonSetting.tryParse(entry);
      if (setting != null) out.add(setting);
    }
    return out;
  }

  static String? _string(Object? v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return null;
  }

  static List<String> _stringList(Object? v) {
    if (v is! List) return const <String>[];
    return [
      for (final e in v)
        if (_string(e) != null) _string(e)!,
    ];
  }

  /// The contract allows `1`/`0`, real bools and their string forms.
  static bool _flag(Object? v, {required bool fallback}) {
    if (v == null) return fallback;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().trim().toLowerCase();
    if (s == '1' || s == 'true' || s == 'yes') return true;
    if (s == '0' || s == 'false' || s == 'no') return false;
    return fallback;
  }

  @override
  String toString() => 'AddonManifest($id, $name, $version)';
}

/// One declared addon setting: a query parameter with a default.
@immutable
class AddonSetting {
  const AddonSetting({
    required this.key,
    this.type,
    this.defaultValue,
    this.label,
    this.options = const <AddonSettingOption>[],
  });

  /// Query-parameter name.
  final String key;

  /// Declared type (`select`, `text`, `number`, `toggle`, …). Free text on
  /// purpose: Flick only forwards defaults, it does not render a form.
  final String? type;

  /// Value Flick sends when the user has not picked one.
  final String? defaultValue;

  final String? label;
  final List<AddonSettingOption> options;

  static AddonSetting? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final key = AddonManifest._string(raw['key']);
    if (key == null || key.isEmpty) return null;
    final options = <AddonSettingOption>[];
    final rawOptions = raw['options'];
    if (rawOptions is List) {
      for (final o in rawOptions) {
        if (o is! Map) continue;
        final value = AddonManifest._string(o['value']);
        if (value == null) continue;
        options.add(AddonSettingOption(
          value: value,
          label: AddonManifest._string(o['label']),
        ));
      }
    }
    return AddonSetting(
      key: key,
      type: AddonManifest._string(raw['type']),
      defaultValue: AddonManifest._string(raw['default']),
      label: AddonManifest._string(raw['label']),
      options: options,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        if (type != null) 'type': type,
        if (defaultValue != null) 'default': defaultValue,
        if (label != null) 'label': label,
        if (options.isNotEmpty) 'options': [for (final o in options) o.toJson()],
      };
}

@immutable
class AddonSettingOption {
  const AddonSettingOption({required this.value, this.label});

  final String value;
  final String? label;

  Map<String, dynamic> toJson() => {
        'value': value,
        if (label != null) 'label': label,
      };
}

/// One row from `/search`.
@immutable
class AddonTrack {
  const AddonTrack({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.duration,
    this.artworkURL,
    this.format,
    this.audioQuality,
    this.audioMode,
    this.streamURL,
  });

  /// Opaque, addon-scoped track id. Safe to put in a stream path.
  final String id;
  final String title;
  final String? artist;
  final String? album;

  /// Fractional seconds are allowed by the contract.
  final Duration? duration;

  /// Absolute http(s) artwork URL, when the addon supplies one.
  final String? artworkURL;

  /// Format hint (e.g. `flac`). Advisory: the stream response carries the
  /// authoritative `codec`.
  final String? format;

  /// Free-text quality label, e.g. `LOSSLESS`.
  final String? audioQuality;

  /// Dolby audio mode (`atmos`, …), when the row is a spatial variant.
  final String? audioMode;

  /// Direct media URL. Used only as a fallback when `/stream/{id}` has no
  /// rendition for this track.
  final String? streamURL;

  static AddonTrack? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = AddonManifest._string(raw['id'])?.trim();
    final title = AddonManifest._string(raw['title'])?.trim();
    if (id == null || id.isEmpty) return null;
    if (title == null || title.isEmpty) return null;

    final art = AddonManifest._string(raw['artworkURL']) ??
        AddonManifest._string(raw['albumArtworkURL']);

    return AddonTrack(
      id: id,
      title: title,
      artist: _trimmed(raw['artist']),
      album: _trimmed(raw['album']),
      duration: _duration(raw['duration']),
      artworkURL: _absoluteHttp(art),
      format: _trimmed(raw['format']),
      audioQuality: _trimmed(raw['audioQuality']),
      audioMode: _trimmed(raw['audioMode']) ?? _firstString(raw['audioModes']),
      streamURL: _absoluteHttp(AddonManifest._string(raw['streamURL'])),
    );
  }

  static String? _trimmed(Object? v) {
    final s = AddonManifest._string(v)?.trim();
    return s == null || s.isEmpty ? null : s;
  }

  static String? _firstString(Object? v) {
    if (v is! List) return null;
    for (final e in v) {
      final s = _trimmed(e);
      if (s != null) return s;
    }
    return null;
  }

  static Duration? _duration(Object? v) {
    if (v is! num) return null;
    if (v <= 0) return null;
    return Duration(milliseconds: (v * 1000).round());
  }

  static String? _absoluteHttp(String? value) {
    final uri = value == null ? null : Uri.tryParse(value.trim());
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.toString();
  }
}

/// A search row together with the addon and server it came from. Carries
/// everything needed to build an ephemeral `Song` without another round-trip.
@immutable
class AddonSearchHit {
  const AddonSearchHit({
    required this.track,
    required this.server,
    required this.manifest,
  });

  final AddonTrack track;
  final NetworkServerEntity server;
  final AddonManifest manifest;
}

/// One addon that failed during a fan-out search. Surfaced as a quiet line so
/// a single broken addon never hides the others' results.
@immutable
class AddonSearchFailure {
  const AddonSearchFailure({required this.serverLabel, required this.message});

  final String serverLabel;
  final String message;

  @override
  String toString() => '$serverLabel: $message';
}

@immutable
class AddonSearchResults {
  const AddonSearchResults({this.hits = const [], this.errors = const []});

  static const empty = AddonSearchResults();

  final List<AddonSearchHit> hits;
  final List<AddonSearchFailure> errors;

  bool get isEmpty => hits.isEmpty;
  bool get isNotEmpty => hits.isNotEmpty;
}

/// Failure reasons the UI maps to localized messages. Kept as an enum (not a
/// message string) so presentation stays in the widget layer.
enum AddonErrorCode {
  /// Could not reach the addon, or it answered with a non-JSON / non-2xx body.
  unreachable,

  /// The addon URL did not serve a valid manifest.
  notAnAddon,

  /// The addon's manifest does not declare the `search` resource.
  noSearchResource,

  /// The addon has no `/stream` resource and the track carries no stream URL.
  notStreamable,

  /// The addon returned an HLS or DASH rendition. Flick's native engine has no
  /// HLS/DASH demuxer, so these are refused rather than faked.
  unsupportedStream,

  /// The rendition is DRM-encrypted.
  encrypted,

  /// `/stream/{id}` returned 404 (or no usable url) for this track.
  trackUnavailable,

  /// The addon answered 200 with an `error` field instead of a rendition.
  addonError,

  /// The addon sets `allowDownloads: 0`, so whole-file caching is forbidden.
  downloadsDisabled,

  /// The addon throttled us (HTTP 429).
  rateLimited,
}

class AddonException implements Exception {
  AddonException(this.code, this.message, {this.kind});

  final AddonErrorCode code;
  final String message;

  /// For [AddonErrorCode.unsupportedStream]: the received manifest kind
  /// (`hls` / `dash`), so the UI can name it.
  final String? kind;

  @override
  String toString() => 'Addon error (${code.name}): $message';
}
