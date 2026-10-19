import 'dart:convert';
import 'dart:io';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/network_cache_service.dart';
import 'package:flick/services/sources/addon_models.dart';
import 'package:flick/services/sources/addon_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _root = 'https://addon.test';

Map<String, dynamic> _manifestJson({
  String id = 'demo',
  String name = 'Demo Addon',
  String? version = '1.2.0',
  List<String> resources = const ['search', 'stream'],
  List<Map<String, dynamic>> settings = const [],
  Object? allowDownloads,
}) => {
  'id': id,
  'name': name,
  'version': ?version,
  'resources': resources,
  if (settings.isNotEmpty) 'settings': settings,
  'allowDownloads': ?allowDownloads,
};

NetworkServerEntity _server({
  int id = 7,
  String root = _root,
  String? token,
  String protocol = 'addon',
}) => NetworkServerEntity()
  ..id = id
  ..label = 'Demo'
  ..protocol = protocol
  ..baseUrl = root
  ..username = null
  ..token = token;

/// Routes requests by path; anything unrouted fails loudly so a test cannot
/// silently pass on a request it did not expect.
MockClient _client(
  Future<http.Response> Function(http.Request request) handler,
) => MockClient((request) async => handler(request));

http.Response _json(Object? body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

String _storedBlob(String root, Map<String, dynamic> manifest) =>
    AddonService.encodeStored(root, AddonManifest.tryParse(manifest)!);

void main() {
  group('normalizeRoot', () {
    test('adds a scheme and strips trailing slashes', () {
      expect(AddonService.normalizeRoot('addon.test'), 'https://addon.test');
      expect(
        AddonService.normalizeRoot('  addon.test/  '),
        'https://addon.test',
      );
      expect(
        AddonService.normalizeRoot('https://addon.test///'),
        'https://addon.test',
      );
    });

    test('strips a terminal /manifest.json', () {
      expect(
        AddonService.normalizeRoot('https://addon.test/manifest.json'),
        'https://addon.test',
      );
      expect(
        AddonService.normalizeRoot('https://addon.test/api/manifest.json'),
        'https://addon.test/api',
      );
    });

    test('keeps a subpath and a port, drops query and fragment', () {
      expect(
        AddonService.normalizeRoot('https://addon.test:8443/api/?x=1#frag'),
        'https://addon.test:8443/api',
      );
    });

    test('keeps http and rejects everything else', () {
      expect(
        AddonService.normalizeRoot('http://127.0.0.1:8080'),
        'http://127.0.0.1:8080',
      );
      expect(AddonService.normalizeRoot('ftp://addon.test'), isNull);
      expect(AddonService.normalizeRoot(''), isNull);
      expect(AddonService.normalizeRoot('   '), isNull);
    });
  });

  group('manifest parsing', () {
    test('requires a non-empty id', () {
      expect(AddonManifest.tryParse({'name': 'x'}), isNull);
      expect(AddonManifest.tryParse({'id': ''}), isNull);
      expect(AddonManifest.tryParse('nope'), isNull);
      expect(AddonManifest.tryParse({'id': 'a'})!.name, 'a');
    });

    test('reads resources and the streaming capability', () {
      final manifest = AddonManifest.tryParse(
        _manifestJson(resources: ['search']),
      )!;
      expect(manifest.supportsSearch, isTrue);
      expect(manifest.supportsStream, isFalse);
      expect(manifest.displayName, 'Demo Addon 1.2.0');
    });

    test(
      'allowDownloads accepts 0/1, bools and strings, defaulting to true',
      () {
        bool flag(Object? v) => AddonManifest.tryParse(
          _manifestJson(allowDownloads: v),
        )!.allowDownloads;
        expect(flag(null), isTrue);
        expect(flag(0), isFalse);
        expect(flag(1), isTrue);
        expect(flag(false), isFalse);
        expect(flag('0'), isFalse);
        expect(flag('true'), isTrue);
        expect(flag('nonsense'), isTrue);
      },
    );

    test('keeps settings defaults and options', () {
      final manifest = AddonManifest.tryParse(
        _manifestJson(
          settings: [
            {
              'key': 'provider',
              'type': 'select',
              'default': 'qobuz',
              'options': [
                {'label': 'Qobuz', 'value': 'qobuz'},
              ],
            },
          ],
        ),
      )!;
      expect(manifest.settings.single.key, 'provider');
      expect(manifest.settings.single.defaultValue, 'qobuz');
      expect(manifest.settings.single.options.single.value, 'qobuz');
    });

    test('stored blob round-trips', () {
      final manifest = AddonManifest.tryParse(_manifestJson())!;
      final blob = AddonService.encodeStored(_root, manifest);
      final parsed = AddonService.parseStored(blob)!;
      expect(parsed.root, _root);
      expect(parsed.manifest.id, 'demo');
      expect(parsed.manifest.version, '1.2.0');
      expect(AddonService.parseStored('not json'), isNull);
      expect(AddonService.parseStored(null), isNull);
    });
  });

  group('ping', () {
    test('true for a valid manifest with search', () async {
      final service = AddonService.create(
        client: _client((_) async => _json(_manifestJson())),
      );
      expect(await service.ping(_server()), isTrue);
      expect(service.lastPingError, isNull);
    });

    test('false with a specific message for non-manifest JSON', () async {
      final service = AddonService.create(
        client: _client((_) async => _json({'hello': 'world'})),
      );
      expect(await service.ping(_server()), isFalse);
      expect(service.lastPingError, contains('not with an addon manifest'));
    });

    test('false for an HTML body', () async {
      final service = AddonService.create(
        client: _client((_) async => http.Response('<html></html>', 200)),
      );
      expect(await service.ping(_server()), isFalse);
      expect(service.lastPingError, isNotNull);
    });

    test('false for a 404', () async {
      final service = AddonService.create(
        client: _client((_) async => http.Response('missing', 404)),
      );
      expect(await service.ping(_server()), isFalse);
    });

    test('false when the manifest declares no search resource', () async {
      final service = AddonService.create(
        client: _client(
          (_) async => _json(_manifestJson(resources: ['stream'])),
        ),
      );
      expect(await service.ping(_server()), isFalse);
      expect(service.lastPingError, contains('"search"'));
    });
  });

  group('resolveToken', () {
    test('returns the manifest blob', () async {
      final service = AddonService.create(
        client: _client((_) async => _json(_manifestJson())),
      );
      final token = await service.resolveToken(_server(), '');
      expect(token, isNotNull);
      final parsed = AddonService.parseStored(token)!;
      expect(parsed.root, _root);
      expect(parsed.manifest.name, 'Demo Addon');
    });

    test('reuses a stored blob for the same root when offline', () async {
      final blob = _storedBlob(_root, _manifestJson());
      final service = AddonService.create(
        client: _client((_) async => throw const SocketException('offline')),
      );
      final token = await service.resolveToken(_server(token: blob), '');
      expect(token, blob);
    });

    test('rethrows when there is no matching stored blob', () async {
      final service = AddonService.create(
        client: _client((_) async => throw const SocketException('offline')),
      );
      await expectLater(
        service.resolveToken(_server(), ''),
        throwsA(isA<AddonException>()),
      );
    });

    test('rejects a URL that is not http(s)', () async {
      final service = AddonService.create(
        client: _client((_) async => _json(_manifestJson())),
      );
      await expectLater(
        service.resolveToken(_server(root: 'ftp://addon.test'), ''),
        throwsA(isA<AddonException>()),
      );
    });
  });

  group('search', () {
    test('sends q, manifest defaults, then quality=LOSSLESS', () async {
      late Uri seen;
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(
              _manifestJson(
                settings: [
                  {'key': 'provider', 'default': 'qobuz'},
                  {'key': 'quality', 'default': 'HIGH'},
                  {'key': 'unused'},
                ],
              ),
            );
          }
          seen = request.url;
          return _json({
            'tracks': [
              {'id': 't1', 'title': 'One'},
            ],
          });
        }),
      );

      final tracks = await service.search(_server(), 'daft punk');
      expect(tracks.single.id, 't1');

      expect(seen.path, '/search');
      // `Uri.queryParameters` loses order; assert the encoded query instead.
      final query = seen.query;
      expect(query, contains('q=daft+punk'));
      expect(query, contains('provider=qobuz'));
      expect(query, contains('quality=LOSSLESS'));
      expect(query, isNot(contains('unused')));
      // A manifest default never overrides the requested quality.
      expect('quality=HIGH', isNot(query));
    });

    test('encodes special characters in the query', () async {
      late Uri seen;
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          seen = request.url;
          return _json({'tracks': []});
        }),
      );

      await service.search(_server(), 'AC/DC & friends?');
      expect(seen.queryParameters['q'], 'AC/DC & friends?');
    });

    test('drops malformed rows, keeps addon order', () async {
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          return _json({
            'tracks': [
              {'id': 'a', 'title': 'A'},
              {'id': '', 'title': 'no id'},
              {'id': 'b'},
              {'id': 'c', 'title': 'C'},
            ],
          });
        }),
      );

      final tracks = await service.search(_server(), 'x');
      expect(tracks.map((t) => t.id), ['a', 'c']);
    });

    test('parses artwork fallback, fractional duration and audio modes', () {
      final tracks = AddonService.parseTracks({
        'tracks': [
          {
            'id': 'a',
            'title': 'A',
            'albumArtworkURL': 'https://cdn.test/cover.jpg',
            'duration': 12.25,
            'audioModes': ['atmos'],
          },
          {'id': 'b', 'title': 'B', 'artworkURL': 'relative/cover.jpg'},
        ],
      });
      expect(tracks, hasLength(2));
      expect(tracks[0].artworkURL, 'https://cdn.test/cover.jpg');
      expect(tracks[0].duration, const Duration(milliseconds: 12250));
      expect(tracks[0].audioMode, 'atmos');
      // A relative artwork path is unusable and must be dropped, not stored.
      expect(tracks[1].artworkURL, isNull);
    });

    test('caps a pathological response', () {
      final rows = [
        for (var i = 0; i < AddonService.maxSearchRows + 25; i++)
          {'id': '$i', 'title': 'T$i'},
      ];
      final tracks = AddonService.parseTracks({'tracks': rows});
      expect(tracks, hasLength(AddonService.maxSearchRows));
    });

    test('caches a search for its TTL', () async {
      var calls = 0;
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          calls++;
          return _json({
            'tracks': [
              {'id': 'a', 'title': 'A'},
            ],
          });
        }),
      );

      await service.search(_server(), 'x');
      await service.search(_server(), 'x');
      await service.search(_server(), 'X');
      expect(calls, 1);

      await service.search(_server(), 'x', forceRefresh: true);
      expect(calls, 2);
    });

    test('429 sets a throttle window that blocks the next search', () async {
      var calls = 0;
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          calls++;
          return http.Response(
            'slow down',
            429,
            headers: {'retry-after': '120'},
          );
        }),
      );

      await expectLater(
        service.search(_server(), 'x'),
        throwsA(
          isA<AddonException>().having(
            (e) => e.code,
            'code',
            AddonErrorCode.rateLimited,
          ),
        ),
      );
      await expectLater(
        service.search(_server(), 'y'),
        throwsA(
          isA<AddonException>().having(
            (e) => e.code,
            'code',
            AddonErrorCode.rateLimited,
          ),
        ),
      );
      // The second call never hit the network.
      expect(calls, 1);
    });

    test('a manifest without search throws rather than calling out', () async {
      var searched = false;
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson(resources: ['stream']));
          }
          searched = true;
          return _json({'tracks': []});
        }),
      );

      await expectLater(
        service.search(_server(), 'x'),
        throwsA(
          isA<AddonException>().having(
            (e) => e.code,
            'code',
            AddonErrorCode.noSearchResource,
          ),
        ),
      );
      expect(searched, isFalse);
    });
  });

  group('searchAll', () {
    test('merges addons and isolates a failing one', () async {
      final service = AddonService.create(
        client: _client((request) async {
          final host = request.url.host;
          if (request.url.path.endsWith('manifest.json')) {
            if (host == 'broken.test') {
              return http.Response('nope', 500);
            }
            return _json(_manifestJson(name: host));
          }
          return _json({
            'tracks': [
              {'id': '$host-1', 'title': 'T'},
            ],
          });
        }),
      );

      final results = await service.searchAll(
        'q',
        servers: [
          _server(id: 1, root: 'https://good.test'),
          _server(id: 2, root: 'https://broken.test'),
        ],
      );

      expect(results.hits, hasLength(1));
      expect(results.hits.single.track.id, 'good.test-1');
      expect(results.hits.single.manifest.name, 'good.test');
      expect(results.errors, hasLength(1));
      expect(results.errors.single.serverLabel, 'Demo');
    });

    test('an empty server list short-circuits', () async {
      var called = false;
      final service = AddonService.create(
        client: _client((_) async {
          called = true;
          return _json(_manifestJson());
        }),
      );
      final results = await service.searchAll('q', servers: const []);
      expect(results.isEmpty, isTrue);
      expect(results.errors, isEmpty);
      expect(called, isFalse);
    });
  });

  group('stream resolution', () {
    AddonService serviceWithStream(Object? Function() streamBody) =>
        AddonService.create(
          client: _client((request) async {
            if (request.url.path.endsWith('manifest.json')) {
              return _json(_manifestJson());
            }
            return _json(streamBody());
          }),
        );

    test('accepts a direct rendition', () async {
      final service = serviceWithStream(
        () => {
          'url': 'https://cdn.test/song.flac',
          'codec': 'flac',
          'manifest': 'none',
        },
      );
      final descriptor = await service.preflight(_server(), 't1');
      expect(descriptor.url, 'https://cdn.test/song.flac');
      expect(descriptor.headers, isEmpty);
    });

    test('a missing manifest field means direct audio', () async {
      final service = serviceWithStream(
        () => {'url': 'https://cdn.test/song.flac'},
      );
      expect(
        (await service.preflight(_server(), 't1')).url,
        'https://cdn.test/song.flac',
      );
    });

    test('rejects HLS and DASH with the kind attached', () async {
      for (final kind in ['hls', 'dash']) {
        final service = serviceWithStream(
          () => {'url': 'https://cdn.test/song.m3u8', 'manifest': kind},
        );
        await expectLater(
          service.preflight(_server(), 't1'),
          throwsA(
            isA<AddonException>()
                .having((e) => e.code, 'code', AddonErrorCode.unsupportedStream)
                .having((e) => e.kind, 'kind', kind),
          ),
        );
      }
    });

    test('rejects encrypted renditions', () async {
      final service = serviceWithStream(
        () => {'url': 'https://cdn.test/song.flac', 'encrypted': true},
      );
      await expectLater(
        service.preflight(_server(), 't1'),
        throwsA(
          isA<AddonException>().having(
            (e) => e.code,
            'code',
            AddonErrorCode.encrypted,
          ),
        ),
      );
    });

    test('rejects a relative url', () async {
      final service = serviceWithStream(() => {'url': '/song.flac'});
      await expectLater(
        service.preflight(_server(), 't1'),
        throwsA(
          isA<AddonException>().having(
            (e) => e.code,
            'code',
            AddonErrorCode.addonError,
          ),
        ),
      );
    });

    test('surfaces an error field that carries no url', () async {
      final service = serviceWithStream(() => {'error': 'region blocked'});
      await expectLater(
        service.preflight(_server(), 't1'),
        throwsA(
          isA<AddonException>().having(
            (e) => e.code,
            'code',
            AddonErrorCode.addonError,
          ),
        ),
      );
    });

    test('404 falls back to the streamURL remembered from search', () async {
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          if (request.url.path == '/search') {
            return _json({
              'tracks': [
                {
                  'id': 't1',
                  'title': 'T',
                  'streamURL': 'https://cdn.test/direct.flac',
                },
              ],
            });
          }
          return http.Response('gone', 404);
        }),
      );

      await service.search(_server(), 'x');
      final descriptor = await service.preflight(_server(), 't1');
      expect(descriptor.url, 'https://cdn.test/direct.flac');
    });

    test('404 without a fallback reports trackUnavailable', () async {
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          return http.Response('gone', 404);
        }),
      );

      await expectLater(
        service.preflight(_server(), 't1'),
        throwsA(
          isA<AddonException>().having(
            (e) => e.code,
            'code',
            AddonErrorCode.trackUnavailable,
          ),
        ),
      );
    });

    test(
      'no stream resource and no direct url reports notStreamable',
      () async {
        final service = AddonService.create(
          client: _client(
            (_) async => _json(_manifestJson(resources: ['search'])),
          ),
        );
        await expectLater(
          service.preflight(_server(), 't1'),
          throwsA(
            isA<AddonException>().having(
              (e) => e.code,
              'code',
              AddonErrorCode.notStreamable,
            ),
          ),
        );
      },
    );

    test('caches a descriptor for its TTL', () async {
      var streams = 0;
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          streams++;
          return _json({'url': 'https://cdn.test/song.flac'});
        }),
      );

      await service.preflight(_server(), 't1');
      await service.preflight(_server(), 't1');
      expect(streams, 1);
    });

    test('de-duplicates concurrent resolves', () async {
      var streams = 0;
      final service = AddonService.create(
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          streams++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _json({'url': 'https://cdn.test/song.flac'});
        }),
      );

      await Future.wait([
        service.preflight(_server(), 't1'),
        service.preflight(_server(), 't1'),
      ]);
      expect(streams, 1);
    });

    test('descriptor expiry re-resolves', () async {
      var now = DateTime(2026, 1, 1);
      var streams = 0;
      final service = AddonService.create(
        now: () => now,
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          streams++;
          return _json({'url': 'https://cdn.test/song.flac'});
        }),
      );

      await service.preflight(_server(), 't1');
      now = now.add(AddonService.descriptorTtl - const Duration(seconds: 1));
      await service.preflight(_server(), 't1');
      expect(streams, 1);

      now = now.add(const Duration(seconds: 2));
      await service.preflight(_server(), 't1');
      expect(streams, 2);
    });
  });

  group('stream()', () {
    test('refuses when the addon sets allowDownloads: 0', () async {
      final service = AddonService.create(
        client: _client((_) async => _json(_manifestJson(allowDownloads: 0))),
      );
      await expectLater(
        service.stream(_server(), 't1'),
        throwsA(
          isA<AddonException>().having(
            (e) => e.code,
            'code',
            AddonErrorCode.downloadsDisabled,
          ),
        ),
      );
    });

    test('downloads and stashes the bytes with progress', () async {
      final dir = Directory.systemTemp.createTempSync('addon_cache_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final service = AddonService.create(
        networkCache: NetworkCacheService(rootDirectory: dir),
        client: _client((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return _json(_manifestJson());
          }
          if (request.url.path.startsWith('/stream/')) {
            return _json({'url': 'https://cdn.test/song.flac'});
          }
          return http.Response.bytes(
            [1, 2, 3, 4],
            200,
            headers: {'content-length': '4'},
          );
        }),
      );

      final progress = <double>[];
      final path = await service.stream(
        _server(),
        't1',
        extension: 'flac',
        onProgress: progress.add,
      );

      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), [1, 2, 3, 4]);
      expect(progress.last, 1.0);

      // A cache hit never re-downloads.
      final again = await service.stream(_server(), 't1', extension: 'flac');
      expect(again, path);
    });
  });

  group('songForHit', () {
    test('builds an ephemeral addon song', () {
      final manifest = AddonManifest.tryParse(_manifestJson())!;
      final track = AddonTrack.tryParse({
        'id': 'track/with?chars',
        'title': 'Title',
        'artist': 'Artist',
        'album': 'Album',
        'duration': 61.5,
        'format': 'flac',
        'audioQuality': 'LOSSLESS',
        'artworkURL': 'https://cdn.test/art.jpg',
      })!;
      final song = AddonService.songForHit(
        AddonSearchHit(
          track: track,
          server: _server(id: 7),
          manifest: manifest,
        ),
      );

      expect(song.id, 'addon:7:track/with?chars');
      expect(int.tryParse(song.id), isNull);
      expect(song.filePath, startsWith('addon://7/'));
      expect(Uri.parse(song.filePath!).pathSegments.single, 'track/with?chars');
      expect(song.sourceType, 'addon');
      expect(song.remoteId, 'track/with?chars');
      expect(song.remoteServerId, 7);
      expect(song.albumArt, 'https://cdn.test/art.jpg');
      expect(song.duration, const Duration(milliseconds: 61500));
      expect(song.fileType, 'FLAC');
      expect(song.resolution, 'LOSSLESS');
      expect(song.isNetworkSource, isTrue);
    });

    test('falls back when the addon omits format and duration', () {
      final manifest = AddonManifest.tryParse(_manifestJson())!;
      final track = AddonTrack.tryParse({'id': 'a', 'title': 'A'})!;
      final song = AddonService.songForHit(
        AddonSearchHit(track: track, server: _server(), manifest: manifest),
      );
      expect(song.fileType, 'UNKNOWN');
      expect(song.duration, Duration.zero);
      expect(song.albumArt, isNull);
      expect(song.artist, '');
    });
  });

  group('syncLibrary', () {
    test('yields exactly one completed progress and writes nothing', () async {
      final service = AddonService.create(
        client: _client((_) async => _json(_manifestJson())),
      );
      final events = await service.syncLibrary(_server()).toList();
      expect(events, hasLength(1));
      expect(events.single.isComplete, isTrue);
      expect(events.single.songsFound, 0);
      expect(events.single.totalFiles, 0);
      expect(events.single.filesProcessed, 0);
    });
  });
}
