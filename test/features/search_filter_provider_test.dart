import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/features/search/providers/search_filter_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The addon category shipped after filters were already persisted. An old
/// stored list must gain it exactly once -- otherwise a user who later turns
/// addons off would find them back on at every launch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storedKey = 'search_enabled_categories';
  const migrationKey = 'search_categories_addon_migrated';
  const all = SearchCategory.values;

  /// The notifier hydrates in a microtask; poll long enough for the async
  /// `SharedPreferences` read to land.
  Future<Set<SearchCategory>> hydrate() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // The default state is "everything enabled"; any test whose expectation
      // differs from that needs the real stored value, so poll until the
      // provider has stopped looking like the default.
      final state = container.read(searchFilterProvider);
      final stillDefault = state.length == all.length &&
          state.containsAll(all);
      if (!stillDefault) return state;
    }
    return container.read(searchFilterProvider);
  }

  test('adds addon to a pre-existing stored filter once', () async {
    SharedPreferences.setMockInitialValues({
      storedKey: ['songs', 'albums'],
    });

    final state = await hydrate();
    expect(state, contains(SearchCategory.addon));
    expect(state, containsAll([SearchCategory.songs, SearchCategory.albums]));
    expect(state, hasLength(3));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(migrationKey), isTrue);
    expect(prefs.getStringList(storedKey), contains('addon'));
  });

  test('does not re-enable addon after the user turns it off', () async {
    SharedPreferences.setMockInitialValues({
      storedKey: ['songs', 'artists', 'albums', 'albumArtists', 'folders',
        'year', 'playlists'],
      migrationKey: true,
    });

    final state = await hydrate();
    expect(state, isNot(contains(SearchCategory.addon)));
    expect(state, hasLength(all.length - 1));
  });

  test('respects an empty stored list', () async {
    SharedPreferences.setMockInitialValues({
      storedKey: <String>[],
      migrationKey: true,
    });
    final state = await hydrate();
    expect(state, isEmpty);
  });
}
