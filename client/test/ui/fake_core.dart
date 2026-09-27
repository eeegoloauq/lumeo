import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumeo/api/client.dart';

/// Answers client endpoints from mutable fixtures without a core process or
/// network.
LumeoApi fakeCore({
  List<Map<String, dynamic>> downloads = const [],
  bool catalogFails = false,

  /// Search kind to fail: movie, series or all; one kind can fail
  /// independently.
  String searchFails = '',
  List<String>? started,

  /// Answers a prefetch with the core's 507, as when it is over the limit.
  bool prefetchRefused = false,
  List<String>? stopped,

  /// Every download patch, as "id body".
  List<String>? downloadPatches,
  Map<String, dynamic>? preferences,
  List<String>? patched,
  bool preferencesFail = false,

  /// How many reads of the preferences fail before one succeeds, as when
  /// the client starts before the core is up.
  int preferencesUnreachable = 0,
  Map<String, Map<String, dynamic>> progress = const {},
  List<Map<String, dynamic>> continueWatching = const [],
  List<Map<String, dynamic>> history = const [],
  List<String>? progressCalls,
  bool progressFails = false,

  /// Every body the player patched the title's track choice with.
  List<String>? choicePatches,
  String aboutDir = '/nowhere/downloads',

  /// Records addon requests as "METHOD path body".
  List<String>? addonCalls,
  List<Map<String, dynamic>>? addons,
  String baseUrl = 'http://core.invalid',

  /// Overrides fixture artwork URLs with a real serving address.
  String background = '',

  /// Overrides fixture still URLs with a real serving address when set.
  String stills = '',

  /// Every path "Open with Lumeo" handed the core.
  List<String>? opened,

  /// The core refuses the file, as it does one that is not a video.
  bool openFails = false,

  /// How long the source list takes, as a provider does on a real network.
  Duration sourcesDelay = Duration.zero,

  /// The copies /api/v1/sources answers with, when a test needs its own.
  List<Map<String, dynamic>>? sources,

  /// The providers /api/v1/sources says refused, as the core reports them.
  List<Map<String, dynamic>> failed = const [],

  /// Every query /api/v1/sources was asked, so a test can prove a retry.
  List<String>? sourceCalls,

  /// My list at the start, as title id to the time it was added.
  Map<String, String> list = const {},

  /// Scores at the start, by title, as the core lists them.
  Map<String, List<Map<String, dynamic>>> ratings = const {},

  /// What /api/v1/new-episodes answers. Which episodes are new is the core's
  /// rule and is tested there; a test here needs a shelf to look at.
  List<Map<String, dynamic>> newEpisodes = const [],

  /// Every change to the list or to a score, as "METHOD path body".
  List<String>? libraryCalls,
}) {
  final preferenceState = Map<String, dynamic>.of(
    preferences ?? preferenceDefaults,
  );
  final addonState = [
    for (final addon in addons ?? fakeAddons) Map<String, dynamic>.of(addon),
  ];
  var artworkCache = 212 * 1024 * 1024;
  final searches = <String>[];
  final storageTitles = [
    for (final title in fakeStorageTitles)
      <String, dynamic>{
        ...title,
        'downloads': [
          for (final download in title['downloads'] as List)
            Map<String, dynamic>.of(download as Map<String, dynamic>),
        ],
      },
  ];
  final historyState = [
    for (final item in history) Map<String, dynamic>.of(item),
  ];
  final progressState = <String, Map<String, dynamic>>{
    for (final item in progress.entries)
      item.key: {
        'entries': [
          for (final entry in item.value['entries'] as List)
            Map<String, dynamic>.of((entry as Map).cast<String, dynamic>()),
        ],
        'next': item.value['next'],
      },
  };

  final choiceState = <String, Map<String, dynamic>>{};
  final listState = Map<String, String>.of(list);
  final ratingState = <String, List<Map<String, dynamic>>>{
    for (final item in ratings.entries)
      item.key: [for (final r in item.value) Map.of(r)],
  };

  Map<String, dynamic>? itemFor(String id) {
    for (final item in [..._itemsFor('movie'), ..._itemsFor('series')]) {
      if (item['id'] == id) return item;
    }
    return null;
  }

  return LumeoApi(
    // Only mpv dials this for real, so a test that needs the player to meet a
    // slow server points it at one.
    baseUrl: baseUrl,
    client: MockClient((request) async {
      final path = request.url.path;
      final query = request.url.queryParameters;
      // Record Play without starting a swarm; UI tests only need the request.
      if (request.method == 'POST' && path == '/api/v1/downloads') {
        started?.add(request.body);
        if (prefetchRefused && request.body.contains('"prefetch":true')) {
          return _json({'error': 'no room'}, status: 507);
        }
        // Return the requested episode's download so the player gets its
        // matching id.
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        // A film's download carries no season, and the body says 0.
        bool same(Map<String, dynamic> d) =>
            (d['season'] ?? 0) == body['season'] &&
            (d['episode'] ?? 0) == body['episode'];
        final made = downloads.firstWhere(
          (d) => same(d) && d['name'] == (body['source'] as Map)['rawName'],
          orElse: () => downloads.firstWhere(same, orElse: fakeDownload),
        );
        // Play requires the core's 201 response to proceed.
        return _json(made, status: 201);
      }
      if (request.method == 'POST' && path == '/api/v1/local') {
        opened?.add((jsonDecode(request.body) as Map)['path'] as String);
        if (openFails) return _json({'error': 'not a video file'}, status: 400);
        return _json(
          downloads.isEmpty ? fakeDownload() : downloads.first,
          status: 201,
        );
      }
      if (request.method == 'DELETE' && path.startsWith('/api/v1/downloads/')) {
        final id = path.split('/').last;
        stopped?.add(id);
        for (final title in storageTitles) {
          (title['downloads'] as List<Map<String, dynamic>>).removeWhere(
            (download) => download['id'] == id,
          );
        }
        storageTitles.removeWhere(
          (title) => (title['downloads'] as List).isEmpty,
        );
        return http.Response('', 204);
      }
      if (request.method == 'PATCH' && path.startsWith('/api/v1/downloads/')) {
        final id = path.split('/').last;
        downloadPatches?.add('$id ${request.body}');
        final download = downloads.where((d) => d['id'] == id).firstOrNull;
        if (download == null) {
          return _json({'error': 'no such download'}, status: 404);
        }
        final body = jsonDecode(request.body) as Map;
        if (body['seeding'] == false) {
          download['seeding'] = false;
          return _json(download);
        }
        final paused = body['paused'] as bool;
        download['state'] = paused ? 'paused' : 'active';
        if (paused) {
          download['pausedByUser'] = true;
          download.remove('waitingSince');
          (download['progress'] as Map<String, dynamic>)
            ..remove('rate')
            ..remove('eta');
        } else {
          download.remove('pausedByUser');
          download.remove('error');
        }
        return _json(download);
      }
      if (request.method == 'DELETE' && path == '/api/v1/cache') {
        artworkCache = 0;
        return http.Response('', 204);
      }
      if (request.method == 'DELETE' && path == '/api/v1/storage') {
        final itemId = query['item'];
        storageTitles.removeWhere(
          (title) => itemId == null || title['itemId'] == itemId,
        );
        return http.Response('', 204);
      }
      if (path == '/api/v1/preferences' && request.method == 'DELETE') {
        patched?.add('DELETE');
        preferenceState
          ..clear()
          ..addAll(preferenceDefaults);
        return _json(preferenceState);
      }
      if (path == '/api/v1/preferences' && request.method == 'PATCH') {
        patched?.add(request.body);
        if (preferencesFail) {
          return _json({'error': 'preferences refused'}, status: 400);
        }
        final patch = jsonDecode(request.body) as Map<String, dynamic>;
        for (final key in patch.keys) {
          if (!preferenceDefaults.containsKey(key)) {
            return _json({'error': 'unknown preference "$key"'}, status: 400);
          }
        }
        for (final entry in patch.entries) {
          preferenceState[entry.key] =
              entry.value ?? preferenceDefaults[entry.key];
        }
        return _json(preferenceState);
      }
      if (path.startsWith('/api/v1/addons')) {
        addonCalls?.add('${request.method} $path ${request.body}'.trim());
        final id = path.split('/').last;
        switch (request.method) {
          case 'POST':
            final url = (jsonDecode(request.body) as Map)['url'] as String;
            // The core fetches the manifest before storing anything; here
            // the address says whether one is there.
            if (url.contains('dead')) {
              return _json({
                'error': 'no addon answered there: 404 Not Found',
              }, status: 400);
            }
            for (final addon in addonState) {
              if (url.startsWith(addon['url'] as String)) {
                addon['url'] = url;
                return _json(addon);
              }
            }
            final added = <String, dynamic>{
              'id': 'public-domain',
              'name': 'Public Domain Movies',
              'url': url,
              'enabled': true,
              'resources': ['catalog', 'meta', 'stream'],
              'description': 'Films whose copyright has run out.',
              'version': '1.2.0',
            };
            addonState.add(added);
            return _json(added, status: 201);
          case 'PATCH':
            final patch = jsonDecode(request.body) as Map<String, dynamic>;
            final addon = addonState.firstWhere((a) => a['id'] == id);
            if (patch['enabled'] is bool) addon['enabled'] = patch['enabled'];
            if (patch['position'] is int) {
              addonState.remove(addon);
              addonState.insert(patch['position'] as int, addon);
            }
            return _json(addon);
          case 'DELETE':
            addonState.removeWhere((a) => a['id'] == id);
            return http.Response('', 204);
        }
        return _json({'addons': addonState});
      }
      if (progressFails &&
          (path == '/api/v1/continue' ||
              path.startsWith('/api/v1/progress/'))) {
        return _json({'error': 'progress unavailable'}, status: 500);
      }
      if (path == '/api/v1/continue' && request.method == 'GET') {
        final limit = int.tryParse(query['limit'] ?? '') ?? 30;
        return _json(continueWatching.take(limit).toList());
      }
      if (path.startsWith('/api/v1/progress/')) {
        final id = path.split('/').last;
        if (request.method == 'GET') {
          return _json(progressState[id] ?? {'entries': [], 'next': null});
        }
        if (request.method == 'DELETE') {
          final entries =
              (progressState[id]?['entries'] as List<Map<String, dynamic>>?);
          if (query.containsKey('season') && query.containsKey('episode')) {
            final season = int.tryParse(query['season'] ?? '');
            final episode = int.tryParse(query['episode'] ?? '');
            entries?.removeWhere(
              (entry) =>
                  entry['season'] == season && entry['episode'] == episode,
            );
          } else {
            progressState.remove(id);
          }
          historyState.removeWhere(
            (viewing) =>
                viewing['item']['id'] == id &&
                (!query.containsKey('season') ||
                    (viewing['entry']['season'].toString() == query['season'] &&
                        viewing['entry']['episode'].toString() ==
                            query['episode'])),
          );
          return http.Response('', 204);
        }
        if (request.method == 'PUT') {
          progressCalls?.add(request.body);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final season = body['season'] as int? ?? 0;
          final episode = body['episode'] as int? ?? 0;
          final state = progressState.putIfAbsent(
            id,
            () => {'entries': <Map<String, dynamic>>[], 'next': null},
          );
          final entries = state['entries'] as List<Map<String, dynamic>>;
          final entry = <String, dynamic>{
            'season': season,
            'episode': episode,
            'position': body['position'] ?? 0,
            'duration': body['duration'] ?? 0,
            'watched': body['watched'] ?? false,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          };
          entries.removeWhere(
            (old) => old['season'] == season && old['episode'] == episode,
          );
          entries.add(entry);
          return _json(entry);
        }
      }
      if (path == '/api/v1/list' && request.method == 'GET') {
        final ids = listState.keys.toList()
          ..sort((a, b) => listState[b]!.compareTo(listState[a]!));
        return _json({
          'items': [
            for (final id in ids)
              if (itemFor(id) case final item?)
                {
                  'item': Map<String, dynamic>.of(item)..remove('episodes'),
                  'addedAt': listState[id],
                  'seen': {'watched': 0, 'released': 0},
                },
          ],
        });
      }
      if (path.startsWith('/api/v1/list/')) {
        final id = path.split('/').last;
        if (request.method != 'GET') {
          libraryCalls?.add('${request.method} $path');
        }
        switch (request.method) {
          case 'PUT':
            if (itemFor(id) == null) {
              return _json({'error': 'unknown item'}, status: 404);
            }
            listState.putIfAbsent(
              id,
              () => DateTime.now().toUtc().toIso8601String(),
            );
          case 'DELETE':
            listState.remove(id);
            return http.Response('', 204);
        }
        return _json({
          'inList': listState.containsKey(id),
          'addedAt': ?listState[id],
        });
      }
      if (path == '/api/v1/new-episodes') {
        return _json({'items': newEpisodes});
      }
      if (path.startsWith('/api/v1/ratings/')) {
        final id = path.split('/').last;
        final list = ratingState.putIfAbsent(id, () => []);
        switch (request.method) {
          case 'PUT':
            libraryCalls?.add('PUT $path ${request.body}');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final rating = <String, dynamic>{
              'season': body['season'] ?? 0,
              'episode': body['episode'] ?? 0,
              'rating': body['rating'],
              'ratedAt': DateTime.now().toUtc().toIso8601String(),
            };
            list.removeWhere(
              (r) =>
                  r['season'] == rating['season'] &&
                  r['episode'] == rating['episode'],
            );
            list.add(rating);
            return _json(rating);
          case 'DELETE':
            libraryCalls?.add('DELETE $path ${request.url.query}'.trim());
            final season = int.tryParse(query['season'] ?? '0') ?? 0;
            final episode = int.tryParse(query['episode'] ?? '0') ?? 0;
            list.removeWhere(
              (r) => r['season'] == season && r['episode'] == episode,
            );
            return http.Response('', 204);
        }
        return _json({'ratings': list});
      }
      if (path == '/api/v1/history') {
        final limit = int.tryParse(query['limit'] ?? '') ?? 50;
        final offset = int.tryParse(query['offset'] ?? '') ?? 0;
        return _json({
          'entries': historyState.skip(offset).take(limit).toList(),
          'more': false,
        });
      }
      if (path.startsWith('/api/v1/choices/')) {
        final choice = choiceState.putIfAbsent(path.split('/').last, () => {});
        if (request.method == 'PATCH') {
          choicePatches?.add(request.body);
          choice.addAll(jsonDecode(request.body) as Map<String, dynamic>);
        }
        return _json(choice);
      }
      if (catalogFails) {
        return _json({'error': 'nope'}, status: 500);
      }
      switch (path) {
        case '/healthz':
          return _json({'status': 'ok', 'providers': 1});
        case '/api/v1/preferences':
          if (preferencesUnreachable > 0) {
            preferencesUnreachable--;
            return _json({'error': 'starting'}, status: 503);
          }
          return _json(preferenceState);
        case '/api/v1/preferences/languages':
          return _json({'languages': _languages});
        case '/api/v1/about':
          return _json({
            ..._about,
            'downloadDir':
                preferenceState['downloadDir'] is String &&
                    (preferenceState['downloadDir'] as String).isNotEmpty
                ? preferenceState['downloadDir']
                : aboutDir,
          });
        case '/api/v1/storage':
          final used = storageTitles.fold<int>(
            0,
            (sum, title) => sum + (title['onDisk'] as int),
          );
          final initialUsed = fakeStorageTitles.fold<int>(
            0,
            (sum, title) => sum + (title['onDisk'] as int),
          );
          return _json({
            'dir': aboutDir,
            'disk': {
              'total': 300 * 1024 * 1024 * 1024,
              'free': 90 * 1024 * 1024 * 1024 + initialUsed - used,
            },
            'used': used,
            'cache': artworkCache,
            'titles': storageTitles,
          });
        case '/api/v1/catalogs':
          return _json({'catalogs': _catalogs});
        case '/api/v1/catalog':
          // Past the first page every shelf runs out, or a test would page for
          // as long as it was scrolled.
          final skip = int.tryParse(query['skip'] ?? '0') ?? 0;
          return _json({
            'items': skip > 0 ? const [] : _itemsFor(query['kind'] ?? 'movie'),
          });
        case '/api/v1/search':
          final kind = query['kind'] ?? 'movie';
          if (searchFails == 'all' || searchFails == kind) {
            return _json({'error': 'nope'}, status: 500);
          }
          return _json({'items': _itemsFor(kind)});
        case '/api/v1/sources':
          sourceCalls?.add(request.url.query);
          await Future<void>.delayed(sourcesDelay);
          return _json({
            'sources': sources ?? _sources,
            'failed': failed,
            'providers': addonState
                .where(
                  (a) =>
                      a['enabled'] == true &&
                      (a['resources'] as List).contains('stream'),
                )
                .length,
          });
        case '/api/v1/subtitles':
          return _json({'subtitles': const []});
        case '/api/v1/downloads':
          return _json({'downloads': downloads});
      }
      if (path.startsWith('/api/v1/items/') && path.endsWith('/after')) {
        // Return the fixture's next episode; ordering and air-date rules belong
        // to the core tests.
        final season = int.tryParse(query['season'] ?? '');
        final episode = int.tryParse(query['episode'] ?? '');
        if (season == null || episode == null || season < 0 || episode < 0) {
          return _json({
            'error': 'season and episode must be non-negative integers',
          }, status: 400);
        }
        final item = itemFor(path.split('/')[4]);
        final episodes = [
          for (final e in (item?['episodes'] as List<dynamic>?) ?? const [])
            Map<String, dynamic>.of(e as Map<String, dynamic>),
        ];
        final index = episodes.indexWhere(
          (e) => e['season'] == season && e['number'] == episode,
        );
        final following = index < 0 || index + 1 >= episodes.length
            ? null
            : episodes[index + 1];
        return _json({'next': following});
      }
      if (path.startsWith('/api/v1/items/')) {
        final id = path.split('/').last;
        final all = [..._itemsFor('movie'), ..._itemsFor('series')];
        final item = all.firstWhere(
          (e) => e['id'] == id,
          orElse: () => all.first,
        );
        final episodes = [
          for (final episode in (item['episodes'] as List?) ?? const [])
            {
              ...episode as Map<String, dynamic>,
              if (stills.isNotEmpty && episode['thumbnail'] != null)
                'thumbnail':
                    '$stills/${(episode['thumbnail'] as String).split('/').last}',
            },
        ];
        return _json({
          ...item,
          if (background.isNotEmpty) 'background': background,
          if (episodes.isNotEmpty) 'episodes': episodes,
        });
      }
      if (path == '/api/v1/searches') {
        switch (request.method) {
          case 'GET':
            return _json({'searches': searches});
          case 'POST':
            final query = (jsonDecode(request.body) as Map)['query'] as String;
            searches.insert(0, query);
            return http.Response('', 204);
          case 'DELETE':
            final one = query['q']?.toLowerCase();
            searches.removeWhere((q) => one == null || q.toLowerCase() == one);
            return http.Response('', 204);
        }
      }
      if (path.startsWith('/api/v1/downloads/')) {
        // Separate ids must yield separate files; an unknown id falls back for
        // single-download tests.
        final id = path.split('/')[4];
        return _json(
          downloads.firstWhere(
            (download) => download['id'] == id,
            orElse: () => downloads.isEmpty ? const {} : downloads.first,
          ),
        );
      }
      return _json({'error': 'unknown path $path'}, status: 404);
    }),
  );
}

// Fixture JSON is checked against core handler types in
// core/internal/api/fixtures_test.go.
List<Map<String, dynamic>> _fixtureList(String name) =>
    (jsonDecode(File('test/fixtures/core/$name').readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();

Map<String, dynamic> _fixtureMap(String name) =>
    jsonDecode(File('test/fixtures/core/$name').readAsStringSync())
        as Map<String, dynamic>;

/// The two addons a fresh core starts with, and a stream addon the viewer
/// added, without which nothing has a copy to play.
final fakeAddons = _fixtureList('addons.json');
final fakeStorageTitles = _fixtureList('storage-titles.json');
final preferenceDefaults = _fixtureMap('preferences.json');
final _catalogs = _fixtureList('catalogs.json');
// Fixture artwork cannot arrive, so app tests do not depend on network images.
final _items = _fixtureList('items.json');
final _sources = _fixtureList('sources.json');
final _languages = _fixtureList('languages.json');
final _about = _fixtureMap('about.json');
final _download = _fixtureMap('download.json');

Map<String, dynamic> fakeItem(String id) =>
    _items.firstWhere((item) => item['id'] == id);

List<Map<String, dynamic>> _itemsFor(String kind) =>
    _items.where((item) => item['kind'] == kind).toList();

/// One download, active and half arrived, for the tests about the indicator.
Map<String, dynamic> fakeDownload({
  String id = 'd1',
  String itemId = 'tt0063350',
  String state = 'active',
  String name = 'Night of the Living Dead 1968 1080p BluRay x264 AC3',
  // False means the magnet has a name but no bytes yet.
  bool ready = true,
  // False means the magnet has not received metadata yet.
  bool resolved = true,
  // Left out entirely for a film, as the core does.
  int season = 0,
  int episode = 0,
  DateTime? updatedAt,
  // Set while an active download receives nothing, as the core does.
  DateTime? waitingSince,
  bool pausedByUser = false,
  String error = '',
  int? eta = 683,
  bool seeding = false,
  int upload = 0,
  int sent = 0,
}) => {
  ..._download,
  'id': id,
  'itemId': itemId,
  'name': name,
  'state': state,
  'ready': ready,
  'resolved': resolved,
  'seeding': seeding,
  if (season > 0 || episode > 0) ...{'season': season, 'episode': episode},
  if (updatedAt != null) 'updatedAt': updatedAt.toUtc().toIso8601String(),
  if (waitingSince != null)
    'waitingSince': waitingSince.toUtc().toIso8601String(),
  if (pausedByUser) 'pausedByUser': true,
  if (error.isNotEmpty) 'error': error,
  'progress': {
    'completed': (_download['progress'] as Map)['completed'],
    'total': (_download['progress'] as Map)['total'],
    if (state == 'active' && waitingSince == null) ...{
      'rate': (_download['progress'] as Map)['rate'],
      'eta': ?eta,
    },
    'peers': waitingSince == null ? 12 : 0,
    'seeders': waitingSince == null ? 7 : 0,
    'upload': upload,
    'sent': sent,
  },
};

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
