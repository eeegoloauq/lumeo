import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumeo/api/client.dart';

/// A core that answers instantly, with mutable state kept in memory.
///
/// The UI tests are about the interface, not about the network: a screen that
/// looks right only when Cinemeta is fast is a screen nobody can test. Every
/// endpoint the client knows is answered here, from fixtures, so a run needs
/// neither a binary nor a connection — and a failure is always the client's.
LumeoApi fakeCore({
  List<Map<String, dynamic>> downloads = const [],
  bool catalogFails = false,

  /// Which kind of search fails: 'movie', 'series', or 'all'. A provider that
  /// is down for one kind and not the other is the case that used to empty the
  /// whole panel.
  String searchFails = '',
  List<String>? started,

  /// Answers a prefetch with the core's 507, as when it is over the limit.
  bool prefetchRefused = false,
  List<String>? stopped,

  /// Every pause and resume, as "id body".
  List<String>? downloadPatches,
  Map<String, dynamic>? preferences,
  List<String>? patched,
  bool preferencesFail = false,

  /// How many reads of the preferences fail before one succeeds, as when
  /// the client starts before the core is up.
  int preferencesUnreachable = 0,
  Map<String, List<Map<String, dynamic>>> progress = const {},
  bool progressFails = false,

  /// Every body the player patched the title's track choice with.
  List<String>? choicePatches,
  String aboutDir = '/nowhere/downloads',

  /// Every request about the addon list, as "METHOD path body", so a test
  /// about a switch can prove the core was told.
  List<String>? addonCalls,
  List<Map<String, dynamic>> addons = fakeAddons,
  String baseUrl = 'http://core.invalid',

  /// Artwork for every title served, when a test has somewhere real to serve
  /// it from. The fixtures otherwise point their pictures at a port nothing
  /// listens on, so that no test depends on a network.
  String background = '',

  /// Where the episode stills are served from, for the same reason; the
  /// fixtures' own URLs are kept when this is empty.
  String stills = '',

  /// Every path "Open with Lumeo" handed the core.
  List<String>? opened,

  /// The core refuses the file, as it does one that is not a video.
  bool openFails = false,

  /// How long the source list takes, as a provider does on a real network.
  Duration sourcesDelay = Duration.zero,

  /// The copies /api/v1/sources answers with, when a test needs its own.
  List<Map<String, dynamic>> sources = _sources,

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
  const preferenceDefaults = <String, dynamic>{
    'subtitleLanguages': ['en'],
    'subtitleBackground': 'none',
    'episodeArtwork': 'show',
    'accent': 'white',
    'keep': 'forever',
    'diskLimit': 0,
    'prefetch': true,
    'subtitleMode': 'always',
    'audioLanguages': <String>[],
    'subtitleScale': 1.0,
    'subtitlePosition': 100,
    'nextCountdown': 5,
    'subtitleColor': 'white',
    'subtitleKeepStyling': true,
    'nextNotice': 30,
    'seekStep': 5,
    'keepDays': 30,
    'downloadDir': '',
    'seed': true,
    'uploadLimit': 0,
    'downloadLimit': 0,
  };
  final preferenceState = Map<String, dynamic>.of(
    preferences ?? preferenceDefaults,
  );
  final addonState = [
    for (final addon in addons) Map<String, dynamic>.of(addon),
  ];
  var artworkCache = 212 * 1024 * 1024;
  // The core's search history: once per word whatever its case, the latest
  // first, ten at most.
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
  final progressState = <String, List<Map<String, dynamic>>>{
    for (final item in progress.entries)
      item.key: [for (final entry in item.value) Map.of(entry)],
  };

  final choiceState = <String, Map<String, dynamic>>{};
  final listState = Map<String, String>.of(list);
  final ratingState = <String, List<Map<String, dynamic>>>{
    for (final item in ratings.entries)
      item.key: [for (final r in item.value) Map.of(r)],
  };

  int scoreOf(String id, int season, int episode) {
    for (final r in ratingState[id] ?? const <Map<String, dynamic>>[]) {
      if (r['season'] == season && r['episode'] == episode) {
        return r['rating'] as int;
      }
    }
    return 0;
  }

  Map<String, dynamic>? itemFor(String id) {
    for (final item in [..._itemsFor('movie'), ..._itemsFor('series')]) {
      if (item['id'] == id) return item;
    }
    return null;
  }

  DateTime updated(Map<String, dynamic> entry) =>
      DateTime.tryParse(entry['updatedAt'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  Map<String, dynamic>? nextFor(String id) {
    final entries = progressState[id] ?? const [];
    if (entries.isEmpty) return null;
    final latest = entries.reduce(
      (a, b) => updated(b).isAfter(updated(a)) ? b : a,
    );
    if (latest['watched'] != true || (latest['position'] as num) > 0) {
      return Map.of(latest);
    }
    final item = itemFor(id);
    if (item == null || item['kind'] != 'series') return null;
    final episodes =
        [
          for (final episode in item['episodes'] as List<dynamic>)
            Map<String, dynamic>.of(episode as Map<String, dynamic>),
        ]..sort((a, b) {
          final season = (a['season'] as int).compareTo(b['season'] as int);
          return season != 0
              ? season
              : (a['number'] as int).compareTo(b['number'] as int);
        });
    final index = episodes.indexWhere(
      (episode) =>
          episode['season'] == latest['season'] &&
          episode['number'] == latest['episode'],
    );
    if (index < 0 || index + 1 >= episodes.length) return null;
    final following = episodes[index + 1];
    for (final entry in entries) {
      if (entry['season'] == following['season'] &&
          entry['episode'] == following['number']) {
        return Map.of(entry);
      }
    }
    return {
      'season': following['season'],
      'episode': following['number'],
      'position': 0,
      'duration': 0,
      'watched': false,
      'updatedAt': latest['updatedAt'],
    };
  }

  return LumeoApi(
    // Only mpv ever dials this for real — every call the client makes is
    // answered here without a socket — so a test that needs the player to meet
    // a slow server points it at one.
    baseUrl: baseUrl,
    client: MockClient((request) async {
      final path = request.url.path;
      final query = request.url.queryParameters;
      // What Play does, recorded rather than performed: a test about a button
      // starting something should not need a swarm to prove it.
      if (request.method == 'POST' && path == '/api/v1/downloads') {
        started?.add(request.body);
        if (prefetchRefused && request.body.contains('"prefetch":true')) {
          return _json({'error': 'no room'}, status: 507);
        }
        // The download the core makes is for the episode that was asked for.
        // A test that hands in one download per episode gets that one back,
        // with the id the player then plays; everything else is a film, where
        // there is one download and no numbers on it.
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        // A film's download carries no season, and the body says 0.
        bool same(Map<String, dynamic> d) =>
            (d['season'] ?? 0) == body['season'] &&
            (d['episode'] ?? 0) == body['episode'];
        final made = downloads.firstWhere(
          (d) => same(d) && d['name'] == (body['source'] as Map)['rawName'],
          orElse: () => downloads.firstWhere(same, orElse: fakeDownload),
        );
        // 201, because that is what the core answers and what the client
        // insists on: anything else and Play looks like it did nothing.
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
        final paused = (jsonDecode(request.body) as Map)['paused'] as bool;
        // What the core does: a paused download keeps its bytes, stops
        // fetching and says who paused it; resumed, it is active again.
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
        final items = <Map<String, dynamic>>[];
        for (final id in progressState.keys) {
          final next = nextFor(id);
          final item = itemFor(id);
          if (next == null || item == null) continue;
          final entries = progressState[id]!;
          final latest = entries
              .map(updated)
              .reduce((a, b) => b.isAfter(a) ? b : a);
          items.add({
            'item': Map<String, dynamic>.of(item)..remove('episodes'),
            'next': next,
            'updatedAt': latest.toUtc().toIso8601String(),
          });
        }
        items.sort(
          (a, b) =>
              DateTime.parse(b['updatedAt'] as String)
                  .compareTo(DateTime.parse(a['updatedAt'] as String)),
        );
        final limit = int.tryParse(query['limit'] ?? '') ?? 30;
        return _json(items.take(limit).toList());
      }
      if (path.startsWith('/api/v1/progress/')) {
        final id = path.split('/').last;
        if (request.method == 'GET') {
          return _json({
            'entries': progressState[id] ?? const [],
            'next': nextFor(id),
          });
        }
        if (request.method == 'DELETE') {
          final hasSeason = query.containsKey('season');
          final hasEpisode = query.containsKey('episode');
          if (hasSeason != hasEpisode) {
            return _json({
              'error': 'season and episode must be provided together',
            }, status: 400);
          }
          final season = int.tryParse(query['season'] ?? '');
          final episode = int.tryParse(query['episode'] ?? '');
          if (!hasSeason) {
            progressState.remove(id);
          } else if (season == null ||
              episode == null ||
              season < 0 ||
              episode < 0) {
            return _json({
              'error': 'season and episode must be non-negative integers',
            }, status: 400);
          } else {
            progressState[id]?.removeWhere(
              (entry) =>
                  entry['season'] == season && entry['episode'] == episode,
            );
          }
          return http.Response('', 204);
        }
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final season = body['season'] as int? ?? 0;
          final episode = body['episode'] as int? ?? 0;
          var position = (body['position'] as num? ?? 0).toDouble();
          final duration = (body['duration'] as num? ?? 0).toDouble();
          final forced = body['watched'] as bool?;

          final entries = progressState.putIfAbsent(id, () => []);
          final index = entries.indexWhere(
            (entry) => entry['season'] == season && entry['episode'] == episode,
          );
          final latched = index >= 0 && entries[index]['watched'] == true;
          final finished =
              forced ?? (duration > 0 && position / duration >= 0.9);
          if (finished || forced != null) position = 0;
          final entry = <String, dynamic>{
            'season': season,
            'episode': episode,
            'position': position,
            'duration': duration,
            'watched': forced ?? (latched || finished),
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          };
          if (index < 0) {
            entries.add(entry);
          } else {
            entries[index] = entry;
          }
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
                  if (scoreOf(id, 0, 0) > 0) 'rating': scoreOf(id, 0, 0),
                  'seen': {
                    'watched': (progressState[id] ?? const [])
                        .where((e) => e['watched'] == true)
                        .length,
                    'released': item['kind'] == 'series'
                        ? (item['episodes'] as List).length
                        : 1,
                  },
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
        final viewed = <Map<String, dynamic>>[];
        for (final id in progressState.keys) {
          final item = itemFor(id);
          if (item == null) continue;
          for (final entry in progressState[id]!) {
            if (entry['watched'] != true && (entry['position'] as num) <= 0) {
              continue;
            }
            final season = entry['season'] as int;
            final number = entry['episode'] as int;
            Map<String, dynamic>? episode;
            for (final e in (item['episodes'] as List<dynamic>?) ?? const []) {
              final map = e as Map<String, dynamic>;
              if (map['season'] == season && map['number'] == number) {
                episode = map;
              }
            }
            final score = scoreOf(id, season, number);
            viewed.add({
              'item': Map<String, dynamic>.of(item)..remove('episodes'),
              'entry': entry,
              'episode': ?episode,
              if (score > 0) 'rating': score,
            });
          }
        }
        viewed.sort((a, b) {
          final at = updated(a['entry'] as Map<String, dynamic>);
          return updated(b['entry'] as Map<String, dynamic>).compareTo(at);
        });
        final limit = int.tryParse(query['limit'] ?? '') ?? 50;
        final offset = int.tryParse(query['offset'] ?? '') ?? 0;
        return _json({
          'entries': viewed.skip(offset).take(limit).toList(),
          'more': viewed.length > offset + limit,
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
          return _json({
            'languages': const [
              {
                'code': 'en',
                'name': 'English',
                'aliases': ['eng'],
              },
              {
                'code': 'ru',
                'name': 'Russian',
                'aliases': ['rus'],
              },
              {
                'code': 'de',
                'name': 'German',
                'aliases': ['deu', 'ger'],
              },
              {
                'code': 'fr',
                'name': 'French',
                'aliases': ['fra', 'fre'],
              },
            ],
          });
        case '/api/v1/about':
          return _json({
            'version': 'dev',
            'dataDir': '/nowhere/data',
            'downloadDir':
                preferenceState['downloadDir'] is String &&
                    (preferenceState['downloadDir'] as String).isNotEmpty
                ? preferenceState['downloadDir']
                : aboutDir,
            'addr': '127.0.0.1:7666',
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
            'sources': sources,
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
        // What the player asks between two episodes. The rules it stands for
        // — the order, the season boundary, the air date — are the core's and
        // are tested there; what is answered here is the fixture's own list,
        // so that a player moving on has something real to move on to.
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
          'background': background,
          if (episodes.isNotEmpty) 'episodes': episodes,
        });
      }
      if (path == '/api/v1/searches') {
        switch (request.method) {
          case 'GET':
            return _json({'searches': searches});
          case 'POST':
            final query = ((jsonDecode(request.body) as Map)['query'] as String)
                .split(RegExp(r'\s+'))
                .where((word) => word.isNotEmpty)
                .join(' ');
            searches
              ..removeWhere((q) => q.toLowerCase() == query.toLowerCase())
              ..insert(0, query);
            if (searches.length > 10) searches.removeLast();
            return http.Response('', 204);
          case 'DELETE':
            final one = query['q']?.toLowerCase();
            searches.removeWhere((q) => one == null || q.toLowerCase() == one);
            return http.Response('', 204);
        }
      }
      if (path.startsWith('/api/v1/downloads/')) {
        // By id, so that a second episode is a second file rather than the
        // first one again. Whatever is there answers for an id nobody put in
        // the list, which is what every test with one download relies on.
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

/// The three addons a fresh core starts with, as its list reports them —
/// one of each kind, so the words a settings page uses for them are all on
/// screen at once.
const fakeAddons = <Map<String, dynamic>>[
  {
    'id': 'cinemeta',
    'name': 'Cinemeta',
    'url': 'https://v3-cinemeta.strem.io',
    'enabled': true,
    'resources': ['catalog', 'meta'],
    'description': 'The official addon for movie and series catalogs',
    'version': '3.0.14',
  },
  {
    'id': 'torrentio',
    'name': 'Torrentio',
    'url': 'https://torrentio.strem.fun/sort=qualitysize',
    'enabled': true,
    'resources': ['stream'],
    'description': 'Streams from public trackers.',
    'version': '0.0.14',
  },
  {
    'id': 'opensubtitles',
    'name': 'OpenSubtitles v3',
    'url': 'https://opensubtitles-v3.strem.io',
    'enabled': true,
    'resources': ['subtitles'],
    'version': '1.0.0',
  },
];

const fakeStorageTitles = <Map<String, dynamic>>[
  {
    'itemId': 'tt3230854',
    'title': 'The Expanse',
    'poster': '',
    'kind': 'series',
    'onDisk': 4509715661,
    'downloads': [
      {
        'id': 'storage-series-1',
        'season': 1,
        'episode': 1,
        'name': 'Dulcinea',
        'state': 'done',
        'onDisk': 2254857830,
      },
      {
        'id': 'storage-series-2',
        'season': 1,
        'episode': 2,
        'name': 'The Big Empty',
        'state': 'active',
        'onDisk': 2254857831,
      },
    ],
  },
  {
    'itemId': 'tt2543164',
    'title': 'Arrival',
    'poster': '',
    'kind': 'movie',
    'onDisk': 1932735283,
    'downloads': [
      {
        'id': 'storage-film',
        'season': 0,
        'episode': 0,
        'name': 'Arrival',
        'state': 'done',
        'onDisk': 1932735283,
      },
    ],
  },
];

/// One download, active and half arrived, for the tests about the indicator.
Map<String, dynamic> fakeDownload({
  String id = 'd1',
  String itemId = 'tt0063350',
  String state = 'active',
  String name = 'Night of the Living Dead 1968 1080p BluRay x264 AC3',
  // Whether the core has anything to serve yet. False is a magnet that knows
  // the name of the file and has not been given a byte of it.
  bool ready = true,
  // Whether the core knows which file it is. False is a magnet still asking
  // its peers for the metadata.
  bool resolved = true,
  // Which episode this is, for the tests that are about a series. Left out
  // entirely for a film, which is what the core does and what keeps every
  // other fixture here exactly as it was.
  int season = 0,
  int episode = 0,
  DateTime? updatedAt,
  // Set while an active download receives nothing, as the core does.
  DateTime? waitingSince,
  bool pausedByUser = false,
  String error = '',
  // Seconds left; the fixture's rate and size make it about eleven minutes.
  int? eta = 683,
}) => {
  'id': id,
  'itemId': itemId,
  'name': name,
  'state': state,
  'ready': ready,
  'resolved': resolved,
  if (season > 0 || episode > 0) ...{'season': season, 'episode': episode},
  if (updatedAt != null) 'updatedAt': updatedAt.toUtc().toIso8601String(),
  if (waitingSince != null)
    'waitingSince': waitingSince.toUtc().toIso8601String(),
  if (pausedByUser) 'pausedByUser': true,
  if (error.isNotEmpty) 'error': error,
  'progress': {
    'completed': 2 * 1024 * 1024 * 1024,
    'total': 4 * 1024 * 1024 * 1024,
    // Bytes flow only while it is active and not waiting.
    if (state == 'active' && waitingSince == null) ...{
      'rate': 3 * 1024 * 1024,
      'eta': ?eta,
    },
    'peers': waitingSince == null ? 12 : 0,
    'seeders': waitingSince == null ? 7 : 0,
  },
};

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const _catalogs = [
  {
    'providerId': 'cinemeta',
    'id': 'top',
    'kind': 'movie',
    'name': 'Popular',
    'searchable': true,
    'genres': ['Comedy', 'Drama'],
  },
  {
    'providerId': 'cinemeta',
    'id': 'top',
    'kind': 'series',
    'name': 'Popular',
    'searchable': true,
    'genres': ['Comedy'],
  },
];

/// Two films and one series, with the fields the interface actually reads. No
/// artwork URLs: a test must not depend on a picture arriving, and the tile
/// without one is a case worth having under test anyway.
List<Map<String, dynamic>> _itemsFor(String kind) => kind == 'series'
    ? const [
        {
          'id': 'tt0903747',
          'kind': 'series',
          'title': 'Breaking Bad',
          'year': 2008,
          'yearEnd': 2013,
          'imdbRating': 9.5,
          'overview': 'A chemistry teacher turns to manufacturing.',
          'runtime': '49 min',
          'genres': ['Crime', 'Drama'],
          'episodes': [
            {
              'season': 1,
              'number': 1,
              'title': 'Pilot',
              'overview': 'It begins.',
              'released': '2008-01-20',
              'thumbnail': 'http://127.0.0.1:1/breaking-bad-1.jpg',
            },
            {
              'season': 1,
              'number': 2,
              'title': "Cat's in the Bag...",
              'overview': 'It continues.',
              'released': '2008-01-27',
              'thumbnail': 'http://127.0.0.1:1/breaking-bad-2.jpg',
            },
            {
              'season': 1,
              'number': 3,
              'title': 'And the Bag is in the River',
              'overview': 'The story continues.',
              'released': '2008-02-10',
            },
            {
              'season': 1,
              'number': 4,
              'title': 'Cancer Man',
              'overview': 'The story continues.',
              'released': '2008-02-17',
            },
            {
              'season': 1,
              'number': 5,
              'title': 'Gray Matter',
              'overview': 'The story continues.',
              'released': '2008-02-24',
            },
            {
              'season': 1,
              'number': 6,
              'title': 'Crazy Handful of Nothin',
              'released': '2008-03-02',
            },
            {
              'season': 2,
              'number': 1,
              'title': 'Seven Thirty-Seven',
              'released': '2009-03-08',
            },
          ],
        },
      ]
    : const [
        {
          'id': 'tt0063350',
          'kind': 'movie',
          'title': 'Night of the Living Dead',
          'year': 1968,
          'imdbRating': 7.8,
          'overview': 'Seven people take refuge in a farmhouse.',
          'runtime': '96 min',
          'genres': ['Horror'],
        },
        {
          'id': 'tt0110912',
          'kind': 'movie',
          'title': 'Pulp Fiction',
          'year': 1994,
          'imdbRating': 8.9,
          'overview': 'Lives of two mob hitmen intertwine.',
          'runtime': '154 min',
          'genres': ['Crime'],
        },
      ];

/// Two copies, ranked the way the core ranks them: the sharper one first.
///
/// The field names are the core's own — a fixture that invents its own spelling
/// tests nothing, and this one used to say "kind" and "codec" where the API
/// says "source" and "videoCodec", so every row in every test had an empty
/// KIND column and no codec in it at all.
const _sources = [
  {
    'providerId': 'torrentio',
    'rawName': 'Night of the Living Dead 1968 2160p BluRay x265 DTS-HD',
    'release': {
      'title': 'Night of the Living Dead',
      'year': 1968,
      'resolution': '2160p',
      'source': 'BluRay',
      'videoCodec': 'HEVC',
      'audioCodec': 'DTS-HD',
      'group': 'GROUP',
    },
    'locator': {'scheme': 'torrent', 'infoHash': 'def', 'fileIndex': 0},
    'size': 18 * 1024 * 1024 * 1024,
    'seeders': 61,
    'tracker': 'test',
    'languages': ['en'],
  },
  {
    'providerId': 'torrentio',
    'rawName': 'Night of the Living Dead 1968 1080p BluRay x264 AC3',
    'release': {
      'title': 'Night of the Living Dead',
      'year': 1968,
      'resolution': '1080p',
      'source': 'BluRay',
      'videoCodec': 'AVC',
      'audioCodec': 'AC3',
      'group': 'GROUP',
    },
    'locator': {'scheme': 'torrent', 'infoHash': 'abc', 'fileIndex': 0},
    'size': 4 * 1024 * 1024 * 1024,
    'seeders': 42,
    'tracker': 'test',
    'languages': ['en'],
  },
];
