import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'core_client.dart';
import 'core_token.dart';
import 'models.dart';

/// The only way the client talks to the core. Local mode and server mode are
/// the same code with a different address and token, which is why those are
/// the things that are configurable here.
class LumeoApi {
  /// [token] defaults to the one the core on this machine wrote, but only for
  /// the default address, and only on loopback: a core named by hand, or
  /// built in as somewhere else, is a different core, and the local one's
  /// secret is not sent to it.
  LumeoApi({String? baseUrl, http.Client? client, CoreToken? token})
    : this._(
        Uri.parse(baseUrl ?? defaultBaseUrl),
        client ?? http.Client(),
        token,
        ownCore: baseUrl == null,
      );

  LumeoApi._(
    this.baseUri,
    http.Client client,
    CoreToken? token, {
    required bool ownCore,
  }) : token =
           token ??
           (ownCore && _loopback(baseUri)
               ? CoreToken.local()
               : CoreToken.none()) {
    _client = AuthorizedClient(
      CoreClient(client, patience: _timeout),
      this.token,
    );
  }

  static const defaultBaseUrl = String.fromEnvironment(
    'LUMEO_API',
    defaultValue: 'http://127.0.0.1:7666',
  );

  /// A core that has stopped answering should surface as an error, not as a
  /// spinner that never ends. It is also how long a core that is not
  /// listening yet is waited for.
  static const _timeout = Duration(seconds: 20);

  /// Where the core is; every request's address is resolved against it.
  final Uri baseUri;

  /// What proves to the core that this client may use it.
  final CoreToken token;

  late final http.Client _client;
  // Synchronous, so the list has a download by the time the call that
  // started it returns: the caller opens the player on it next.
  final _started = StreamController<Download>.broadcast(sync: true);

  /// Every download this client starts or opens, as the core answered it:
  /// the list of downloads shows one the moment it exists, not at its next
  /// poll.
  Stream<Download> get started => _started.stream;

  /// The address as the user would write it.
  String get baseUrl => baseUri.toString();

  /// Whether paths named by the core refer to this client's own machine.
  bool get isLocal => _loopback(baseUri);

  static bool _loopback(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  /// Whether the core is there at all, and what it has behind it. The one
  /// request that says something useful when nothing else works.
  Future<CoreHealth> health() async =>
      CoreHealth.fromJson(await _get('/healthz'));

  Future<Preferences> preferences() async =>
      Preferences.fromJson(await _get('/api/v1/preferences'));

  Future<Preferences> patchPreferences(Map<String, Object?> patch) async =>
      Preferences.fromJson(await _send('PATCH', '/api/v1/preferences', patch));

  /// Every preference back to its default; the core answers with the result.
  Future<Preferences> resetPreferences() async => Preferences.fromJson(
    _decode(await _request('DELETE', _uri('/api/v1/preferences')))
        as Map<String, dynamic>,
  );

  Future<List<Addon>> addons() async {
    final json = await _get('/api/v1/addons');
    return (json['addons'] as List<dynamic>? ?? [])
        .map((e) => Addon.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Installs the addon at a URL, or re-points the one already installed
  /// from it when the manifest there names the same addon. The core fetches
  /// the manifest first, so an address nothing answers at is refused here.
  Future<Addon> addAddon(String url) async => Addon.fromJson(
    await _send('POST', '/api/v1/addons', {'url': url}, expect: {200, 201}),
  );

  Future<Addon> patchAddon(String id, Map<String, Object?> patch) async =>
      Addon.fromJson(await _send('PATCH', '/api/v1/addons/${_seg(id)}', patch));

  Future<void> removeAddon(String id) => _delete('/api/v1/addons/${_seg(id)}');

  Future<List<NamedLanguage>> languages() async {
    final json = await _get('/api/v1/preferences/languages');
    return (json['languages'] as List<dynamic>? ?? [])
        .map((e) => NamedLanguage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<CoreAbout> about() async =>
      CoreAbout.fromJson(await _get('/api/v1/about'));

  Future<List<CatalogRow>> catalogs() async {
    final json = await _get('/api/v1/catalogs');
    return (json['catalogs'] as List<dynamic>? ?? [])
        .map((e) => CatalogRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<MediaItem>> catalog(
    CatalogRow row, {
    String genre = '',
    int skip = 0,
  }) async {
    final json = await _get('/api/v1/catalog', {
      'provider': row.providerId,
      'kind': row.kind,
      'id': row.id,
      if (genre.isNotEmpty) 'genre': genre,
      if (skip > 0) 'skip': '$skip',
    });
    return _items(json);
  }

  Future<void> stopDownload(String id, {bool discardData = true}) => _delete(
    '/api/v1/downloads/${_seg(id)}',
    query: discardData ? {'data': 'true'} : null,
  );

  Future<List<MediaItem>> search(String query, {String kind = 'movie'}) async {
    final json = await _get('/api/v1/search', {'q': query, 'kind': kind});
    return _items(json);
  }

  /// What was searched for, the latest first.
  Future<List<String>> recentSearches() async {
    final json = await _get('/api/v1/searches');
    return (json['searches'] as List<dynamic>? ?? const []).cast<String>();
  }

  /// Remembers a search somebody went through with.
  Future<void> rememberSearch(String query) => _request(
    'POST',
    _uri('/api/v1/searches'),
    body: {'query': query},
    expect: const {204},
  );

  /// Forgets one search, or every one when [query] is null.
  Future<void> forgetSearches({String? query}) =>
      _delete('/api/v1/searches', query: query == null ? null : {'q': query});

  Future<MediaItem> item(String id) async =>
      MediaItem.fromJson(await _get('/api/v1/items/${_seg(id)}'));

  /// Ranked ways to watch one thing, the providers that refused or did not
  /// answer, and how many were asked. The core does the ranking; the first is
  /// what Play uses.
  Future<
    ({List<MediaSource> sources, List<ProviderFailure> failed, int providers})
  >
  sources(String itemId, {int season = 0, int episode = 0}) async {
    final json = await _get('/api/v1/sources', {
      'item': itemId,
      if (season > 0) 'season': '$season',
      if (episode > 0) 'episode': '$episode',
    });
    return (
      sources: ((json['sources'] as List<dynamic>?) ?? [])
          .map((e) => MediaSource.fromJson(e as Map<String, dynamic>))
          .toList(),
      failed: [
        for (final f in (json['failed'] as List<dynamic>?) ?? [])
          ProviderFailure.fromJson(f as Map<String, dynamic>),
      ],
      providers: json['providers'] as int? ?? 0,
    );
  }

  /// Subtitle tracks for one file. The download is what makes the answer
  /// about the copy being watched rather than about the title: from it the
  /// core takes the hash a subtitle database matches an encode by.
  Future<List<Subtitle>> subtitles({
    required String itemId,
    String download = '',
    int season = 0,
    int episode = 0,
    List<String> languages = const [],
  }) async {
    final json = await _get('/api/v1/subtitles', {
      'item': itemId,
      if (download.isNotEmpty) 'download': download,
      if (season > 0) 'season': '$season',
      if (episode > 0) 'episode': '$episode',
      if (languages.isNotEmpty) 'lang': languages.join(','),
    });
    return ((json['subtitles'] as List<dynamic>?) ?? [])
        .map((e) => Subtitle.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Turns a path the core handed back into an address a player can open.
  String url(String path) => baseUri.resolve(path).toString();

  /// Where the player reads a download from, as it arrives.
  String streamUrl(String downloadId) =>
      url('/api/v1/downloads/${_seg(downloadId)}/stream');

  Future<Download> startDownload({
    required String itemId,
    required MediaSource source,
    int season = 0,
    int episode = 0,
    // A download nobody asked for yet; the core answers 507 when it does not
    // fit inside the disk limit.
    bool prefetch = false,
  }) async {
    return _announce(
      Download.fromJson(
        await _send(
          'POST',
          '/api/v1/downloads',
          {
            'itemId': itemId,
            'season': season,
            'episode': episode,
            'source': source.toJson(),
            if (prefetch) 'prefetch': true,
          },
          expect: const {201},
        ),
      ),
    );
  }

  /// Makes a file on this machine a download the player can open: "Open
  /// with Lumeo". The core names the title from the file name when it can.
  Future<Download> openLocal(String path) async => _announce(
    Download.fromJson(
      await _send('POST', '/api/v1/local', {'path': path}, expect: const {201}),
    ),
  );

  Download _announce(Download download) {
    if (!_started.isClosed) _started.add(download);
    return download;
  }

  Future<Download> download(String id) async =>
      Download.fromJson(await _get('/api/v1/downloads/${_seg(id)}'));

  Future<List<Download>> downloads() async {
    final json = await _get('/api/v1/downloads');
    return (json['downloads'] as List<dynamic>? ?? [])
        .map((e) => Download.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Stops fetching and keeps what arrived; the download stays listed as
  /// paused by the viewer.
  Future<Download> pauseDownload(String id) => _setPaused(id, true);

  /// Fetches again a paused download, or retries a failed one.
  Future<Download> resumeDownload(String id) => _setPaused(id, false);

  Future<Download> _setPaused(String id, bool paused) async =>
      Download.fromJson(
        await _send('PATCH', '/api/v1/downloads/${_seg(id)}', {
          'paused': paused,
        }),
      );

  Future<Storage> storage() async =>
      Storage.fromJson(await _get('/api/v1/storage'));

  /// Removes every download with its data, or only one title's when
  /// [itemId] is given.
  Future<void> clearStorage({String? itemId}) => _delete(
    '/api/v1/storage',
    query: itemId == null ? null : {'item': itemId},
  );

  Future<void> clearCache() => _delete('/api/v1/cache');

  Future<WatchProgress> progress(String itemId) async =>
      WatchProgress.fromJson(await _get('/api/v1/progress/${_seg(itemId)}'));

  Future<TitleChoice> choice(String itemId) async =>
      TitleChoice.fromJson(await _get('/api/v1/choices/${_seg(itemId)}'));

  /// Records a track picked by hand; a null one stays as it was.
  Future<void> rememberTracks(
    String itemId, {
    TrackChoice? audio,
    TrackChoice? subtitle,
  }) => _send('PATCH', '/api/v1/choices/${_seg(itemId)}', {
    if (audio != null) 'audio': audio.toJson(),
    if (subtitle != null) 'subtitle': subtitle.toJson(),
  });

  /// Reports where playback is. The core decides when that counts as
  /// watched; [watched] forces it either way, and false starts over.
  Future<WatchEntry> putProgress(
    String itemId, {
    int season = 0,
    int episode = 0,
    required Duration position,
    required Duration duration,
    bool? watched,
  }) async => WatchEntry.fromJson(
    await _send('PUT', '/api/v1/progress/${_seg(itemId)}', {
      'season': season,
      'episode': episode,
      'position': position.inMilliseconds / 1000,
      'duration': duration.inMilliseconds / 1000,
      'watched': ?watched,
    }),
  );

  /// The episode after the one named, or null when that was the last one out.
  ///
  /// Asked of the catalogue rather than read off [progress]: `next` there is
  /// "what Play should open", counted from the last position reported and from
  /// an episode that latches as watched at 90% — so the player, which is still
  /// reporting the episode it is playing, would be told about the one after
  /// the one it wants.
  Future<Episode?> episodeAfter(
    String itemId, {
    required int season,
    required int episode,
  }) async {
    final json = await _get('/api/v1/items/${_seg(itemId)}/after', {
      'season': '$season',
      'episode': '$episode',
    });
    final next = json['next'];
    return next == null ? null : Episode.fromJson(next as Map<String, dynamic>);
  }

  /// Forgets where a title was left: all of it, or one episode.
  Future<void> clearProgress(String itemId, {int? season, int? episode}) =>
      _delete(
        '/api/v1/progress/${_seg(itemId)}',
        query: season == null || episode == null
            ? null
            : {'season': '$season', 'episode': '$episode'},
      );

  /// What was watched, the latest first, a page at a time.
  Future<({List<Viewing> entries, bool more})> history({
    int limit = 50,
    int offset = 0,
  }) async {
    final json = await _get('/api/v1/history', {
      'limit': '$limit',
      if (offset > 0) 'offset': '$offset',
    });
    return (
      entries: [
        for (final e in json['entries'] as List<dynamic>? ?? const [])
          Viewing.fromJson(e as Map<String, dynamic>),
      ],
      more: json['more'] as bool? ?? false,
    );
  }

  /// My list, the latest added first.
  Future<List<ListedTitle>> myList() async {
    final json = await _get('/api/v1/list');
    return [
      for (final e in json['items'] as List<dynamic>? ?? const [])
        ListedTitle.fromJson(e as Map<String, dynamic>),
    ];
  }

  Future<ListState> listState(String itemId) async =>
      ListState.fromJson(await _get('/api/v1/list/${_seg(itemId)}'));

  Future<ListState> addToList(String itemId) async => ListState.fromJson(
    await _send('PUT', '/api/v1/list/${_seg(itemId)}', const {}),
  );

  Future<void> removeFromList(String itemId) =>
      _delete('/api/v1/list/${_seg(itemId)}');

  /// The series followed — on the list, or being watched — with episodes out
  /// in the last fortnight that nobody has watched.
  Future<List<NewEpisodes>> newEpisodes() async {
    final json = await _get('/api/v1/new-episodes');
    return [
      for (final e in json['items'] as List<dynamic>? ?? const [])
        NewEpisodes.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// Every score given to a title: its own and its episodes'.
  Future<List<Rating>> ratings(String itemId) async {
    final json = await _get('/api/v1/ratings/${_seg(itemId)}');
    return [
      for (final e in json['ratings'] as List<dynamic>? ?? const [])
        Rating.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// Scores a title, or one of its episodes, 1 to 10.
  Future<Rating> rate(
    String itemId,
    int score, {
    int season = 0,
    int episode = 0,
  }) async => Rating.fromJson(
    await _send('PUT', '/api/v1/ratings/${_seg(itemId)}', {
      'season': season,
      'episode': episode,
      'rating': score,
    }),
  );

  Future<void> unrate(String itemId, {int season = 0, int episode = 0}) =>
      _delete(
        '/api/v1/ratings/${_seg(itemId)}',
        query: {'season': '$season', 'episode': '$episode'},
      );

  Future<List<ContinueItem>> continueWatching({int limit = 30}) async {
    // The one list the core sends bare rather than under a key.
    final json = await _getJson('/api/v1/continue', {'limit': '$limit'});
    return (json as List<dynamic>)
        .map((e) => ContinueItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Releases the connections the client is holding. Called when the app
  /// shuts down; a desktop app that leaves sockets open on exit is a process
  /// that takes a while to die.
  void close() {
    unawaited(_started.close());
    _client.close();
  }

  List<MediaItem> _items(Map<String, dynamic> json) =>
      (json['items'] as List<dynamic>? ?? [])
          .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
          .toList();

  /// An id as one segment of a path, whatever it holds.
  static String _seg(String id) => Uri.encodeComponent(id);

  /// [path] resolved against the core's address, with [query] when it has
  /// any.
  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = baseUri.resolve(path);
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: query);
  }

  /// Sends one request and returns the response when its status is one of
  /// [expect]; anything else is a [LumeoApiException].
  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    Set<int> expect = const {200},
  }) async {
    final request = http.Request(method, uri);
    if (body != null) {
      request
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode(body);
    }
    final response = await _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(_timeout);
    if (!expect.contains(response.statusCode)) {
      throw LumeoApiException(
        uri,
        response.statusCode,
        response.body,
        method: method,
      );
    }
    return response;
  }

  static Object? _decode(http.Response response) =>
      jsonDecode(utf8.decode(response.bodyBytes));

  /// Sends a JSON document and decodes the JSON document that comes back.
  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, Object?> body, {
    Set<int> expect = const {200},
  }) async =>
      _decode(await _request(method, _uri(path), body: body, expect: expect))
          as Map<String, dynamic>;

  /// Deletes, treating "already gone" as done.
  Future<void> _delete(String path, {Map<String, String>? query}) =>
      _request('DELETE', _uri(path, query), expect: const {204, 404});

  Future<Object?> _getJson(String path, [Map<String, String>? query]) async =>
      _decode(await _request('GET', _uri(path, query)));

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
  ]) async => await _getJson(path, query) as Map<String, dynamic>;
}

class LumeoApiException implements Exception {
  LumeoApiException(this.uri, this.status, this.body, {this.method = 'GET'});

  final Uri uri;
  final int status;
  final String body;
  final String method;

  /// The core's explanation when it sent one, or its body unchanged otherwise.
  String get message {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic> && json['error'] is String) {
        return json['error'] as String;
      }
    } on FormatException {
      // A proxy or broken core may answer with plain text, which is already
      // the most useful explanation available.
    }
    return body;
  }

  @override
  String toString() => '$method $uri → $status';
}
