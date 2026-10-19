import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';

import 'package:flick/data/database.dart';
import 'package:flick/providers/connectivity_provider.dart';
import 'package:flick/services/sources/addon_models.dart';
import 'package:flick/services/sources/addon_service.dart';
import 'package:flick/services/sources/network_source_service.dart';

/// Fan-out search over every configured addon.
///
/// Deliberately separate from [globalSearchResultsProvider]: local results are
/// an instant Isar read, while addons are network calls. Keeping them apart
/// lets the local sections render immediately while the addon section fills in.
///
/// The provider reads the server table directly instead of watching
/// `networkServersProvider` so an addon added moments ago participates in the
/// very next search without a provider refresh.
final addonSearchProvider =
    FutureProvider.autoDispose.family<AddonSearchResults, String>((ref, raw) async {
  final query = raw.trim();
  if (query.length < 2) return AddonSearchResults.empty;

  // An offline device turns every addon into an 8 s timeout; skip the fan-out
  // and let the local results stand alone.
  if (ref.watch(connectivityProvider) == ConnectivityStatus.offline) {
    return AddonSearchResults.empty;
  }

  final servers = await Database.networkServers.where().findAll();
  final addons = servers
      .where((s) => s.protocol == NetworkProtocol.addon)
      .toList(growable: false);
  if (addons.isEmpty) return AddonSearchResults.empty;

  return AddonService.instance.searchAll(query, servers: addons);
});
