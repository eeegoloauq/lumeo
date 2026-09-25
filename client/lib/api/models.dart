/// The shapes the core sends. Names match the JSON so the mapping stays
/// obvious; anything the client computes is a getter, never a stored field.
library;

/// Choices shared by every client that talks to one core.
class Preferences {
  const Preferences({
    required this.subtitleLanguages,
    this.audioLanguages = const [],
    this.subtitleMode = 'always',
    this.subtitleScale = 1,
    this.subtitlePosition = 100,
    this.subtitleBackground = 'none',
    this.episodeArtwork = 'show',
    this.accent = 'white',
    this.keep = 'forever',
    this.diskLimit = 0,
    this.prefetch = true,
    this.nextCountdown = 5,
    this.subtitleColor = 'white',
    this.subtitleKeepStyling = true,
    this.nextNotice = 30,
    this.seekStep = 5,
    this.keepDays = 30,
    this.downloadDir = '',
    this.seed = true,
    this.uploadLimit = 0,
    this.downloadLimit = 0,
  });

  /// Best first, as ISO 639-1 with an optional region. The audio list empty
  /// means the file's own default soundtrack.
  final List<String> subtitleLanguages;
  final List<String> audioLanguages;

  /// When subtitles come on by themselves: `always` for the first preferred
  /// language on offer, `foreign` only when the soundtrack is not in one of
  /// the subtitle languages, `manual` for never until picked.
  final String subtitleMode;

  /// mpv's sub-scale and sub-pos: 1 is the size mpv draws by default; 100
  /// sits the line on the bottom edge and lower numbers lift it.
  final double subtitleScale;
  final int subtitlePosition;

  /// What sits behind subtitle text: `none`, `shadow` or `box`.
  final String subtitleBackground;

  /// What an episode still does on the item page: `show`, `blur` (until the
  /// episode is watched) or `hide`.
  final String episodeArtwork;

  /// A key of `Palette.accents`.
  final String accent;

  /// How long a download stays once watched: `watched`, `days` (for
  /// [keepDays] after) or `forever`. Unwatched downloads are never freed by
  /// it.
  final String keep;
  final int keepDays;

  /// The ceiling in bytes on what downloads take, 0 for none. Over it the
  /// core frees watched downloads, the longest watched first.
  final int diskLimit;

  /// Whether the player starts the next episode once the one playing is on
  /// disk. The core starts it only inside the disk limit and the free disk.
  final bool prefetch;

  /// Seconds the last frame of an episode counts down before the next one
  /// starts by itself; 0 waits for a press. Credits marked as a chapter are
  /// the countdown themselves.
  final int nextCountdown;

  bool get autoplayNext => nextCountdown > 0;

  /// A key of `subtitleColours`: what mpv draws plain subtitle text in.
  final String subtitleColor;

  /// Whether a styled (ASS) track keeps its own look. Off, our size, colour
  /// and background win over it: mpv's `sub-ass-override=force`.
  final bool subtitleKeepStyling;

  /// Seconds before the end at which the next-episode card is offered, when
  /// the file marks no credits.
  final int nextNotice;

  /// Seconds the arrow keys seek. Shift+arrow stays one second.
  final int seekStep;

  /// Where new downloads go on the core's machine; empty for its default.
  final String downloadDir;

  /// Whether finished and running torrents upload. Applied by the core.
  final bool seed;

  /// Bytes per second, 0 for none.
  final int uploadLimit;
  final int downloadLimit;

  factory Preferences.fromJson(Map<String, dynamic> json) {
    // A core from before `keepDays` stored thirty days as a keep of its own.
    final keep = json['keep'] as String? ?? 'forever';
    final legacyDays = keep == '30days';
    return Preferences(
      subtitleLanguages: (json['subtitleLanguages'] as List<dynamic>? ?? [])
          .cast<String>(),
      audioLanguages: (json['audioLanguages'] as List<dynamic>? ?? [])
          .cast<String>(),
      subtitleMode: json['subtitleMode'] as String? ?? 'always',
      subtitleScale: (json['subtitleScale'] as num?)?.toDouble() ?? 1,
      subtitlePosition: (json['subtitlePosition'] as num?)?.toInt() ?? 100,
      subtitleBackground: json['subtitleBackground'] as String? ?? 'none',
      episodeArtwork: json['episodeArtwork'] as String? ?? 'show',
      accent: json['accent'] as String? ?? 'white',
      keep: legacyDays ? 'days' : keep,
      diskLimit: (json['diskLimit'] as num?)?.toInt() ?? 0,
      prefetch: json['prefetch'] as bool? ?? true,
      nextCountdown: (json['nextCountdown'] as num?)?.toInt() ?? 5,
      subtitleColor: json['subtitleColor'] as String? ?? 'white',
      subtitleKeepStyling: json['subtitleKeepStyling'] as bool? ?? true,
      nextNotice: (json['nextNotice'] as num?)?.toInt() ?? 30,
      seekStep: (json['seekStep'] as num?)?.toInt() ?? 5,
      keepDays: legacyDays ? 30 : (json['keepDays'] as num?)?.toInt() ?? 30,
      downloadDir: json['downloadDir'] as String? ?? '',
      seed: json['seed'] as bool? ?? true,
      uploadLimit: (json['uploadLimit'] as num?)?.toInt() ?? 0,
      downloadLimit: (json['downloadLimit'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A language the core accepts in language preferences, with its display
/// name and the other codes it arrives under — see [Languages].
class NamedLanguage {
  const NamedLanguage({
    required this.code,
    required this.name,
    this.aliases = const [],
  });

  final String code;
  final String name;

  /// ISO 639-2, in both of its spellings where they differ: what a container
  /// writes on its tracks and a subtitle database sends back.
  final List<String> aliases;

  factory NamedLanguage.fromJson(Map<String, dynamic> json) => NamedLanguage(
    code: json['code'] as String? ?? '',
    name: json['name'] as String? ?? '',
    aliases: (json['aliases'] as List<dynamic>? ?? []).cast<String>(),
  );
}

/// Paths that describe the machine on which the core is running.
class CoreAbout {
  const CoreAbout({
    required this.version,
    required this.dataDir,
    required this.downloadDir,
    this.addr = '',
    this.logPath = '',
  });

  /// Empty from a core older than 0.1.42, which did not say.
  final String version;
  final String dataDir;

  /// The effective one: the viewer's choice, or the core's default.
  final String downloadDir;

  /// The address it listens on; empty from a core that does not say.
  final String addr;

  /// The core's own log file, when it writes one rather than logging to the
  /// journal or stderr.
  final String logPath;

  factory CoreAbout.fromJson(Map<String, dynamic> json) => CoreAbout(
    version: json['version'] as String? ?? '',
    dataDir: json['dataDir'] as String? ?? '',
    downloadDir: json['downloadDir'] as String? ?? '',
    addr: json['addr'] as String? ?? '',
    logPath: json['logPath'] as String? ?? '',
  );
}

/// One installed addon: a URL the core reads catalogs, streams or subtitles
/// from, and what its manifest says it serves.
class Addon {
  const Addon({
    required this.id,
    required this.name,
    required this.url,
    required this.enabled,
    required this.resources,
    this.description = '',
    this.version = '',
    this.error = '',
  });

  final String id;
  final String name;
  final String url;
  final bool enabled;

  /// What the manifest lists — "catalog", "meta", "stream", "subtitles" —
  /// and empty while the addon has never answered.
  final List<String> resources;
  final String description;
  final String version;

  /// Why the manifest is missing, when it is.
  final String error;

  factory Addon.fromJson(Map<String, dynamic> json) => Addon(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? false,
    resources: (json['resources'] as List<dynamic>? ?? []).cast<String>(),
    description: json['description'] as String? ?? '',
    version: json['version'] as String? ?? '',
    error: json['error'] as String? ?? '',
  );

  /// The resources in the words a settings page uses, in the order a reader
  /// meets them: what fills the home screen before what plays on it.
  List<String> get provides => [
    if (resources.contains('catalog')) 'Catalog',
    if (resources.contains('meta')) 'Titles',
    if (resources.contains('stream')) 'Streams',
    if (resources.contains('subtitles')) 'Subtitles',
  ];
}

/// The core's answer to "are you there". Deliberately thin: everything else
/// about a core is a question with its own endpoint.
class CoreHealth {
  const CoreHealth({required this.status, required this.providers});

  final String status;

  /// How many source providers it was started with. Zero is a core that can
  /// browse and play nothing, which is worth seeing on a settings page.
  final int providers;

  factory CoreHealth.fromJson(Map<String, dynamic> json) => CoreHealth(
    status: json['status'] as String? ?? '',
    providers: json['providers'] as int? ?? 0,
  );
}

class CatalogRow {
  const CatalogRow({
    required this.providerId,
    required this.id,
    required this.kind,
    required this.name,
    required this.searchable,
    this.genres = const [],
  });

  final String providerId;
  final String id;
  final String kind;
  final String name;
  final bool searchable;

  /// The genre values this catalogue accepts as a filter. They are what the
  /// home screen's depth is built from, so they come from the provider rather
  /// than from a list of ours that would go stale.
  final List<String> genres;

  factory CatalogRow.fromJson(Map<String, dynamic> json) => CatalogRow(
    providerId: json['providerId'] as String? ?? '',
    id: json['id'] as String? ?? '',
    kind: json['kind'] as String? ?? 'movie',
    name: json['name'] as String? ?? '',
    searchable: json['searchable'] as bool? ?? false,
    genres: (json['genres'] as List<dynamic>? ?? []).cast<String>(),
  );
}

class MediaItem {
  const MediaItem({
    required this.id,
    required this.kind,
    required this.title,
    this.year = 0,
    this.yearEnd = 0,
    this.overview = '',
    this.poster = '',
    this.background = '',
    this.logo = '',
    this.genres = const [],
    this.cast = const [],
    this.directors = const [],
    this.runtime = '',
    this.imdbRating = 0,
    this.episodes = const [],
  });

  final String id;
  final String kind;
  final String title;
  final int year;
  final int yearEnd;
  final String overview;
  final String poster;
  final String background;
  final String logo;
  final List<String> genres;
  final List<String> cast;
  final List<String> directors;
  final String runtime;
  final double imdbRating;
  final List<Episode> episodes;

  bool get isSeries => kind == 'series';

  /// "2022", or "2015–2019" for a series that has ended.
  ///
  /// An en dash and no spaces around it, because this is a range rather than
  /// an aside: "2015 — 2019" is the punctuation of a parenthesis, and set in a
  /// caption under a poster it reads as two separate years. A series still
  /// running ends on the dash, which is what the dash already means.
  String get years {
    if (year == 0) return '';
    if (!isSeries) return '$year';
    return yearEnd == 0 ? '$year–' : '$year–$yearEnd';
  }

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
    id: json['id'] as String? ?? '',
    kind: json['kind'] as String? ?? 'movie',
    title: json['title'] as String? ?? '',
    year: json['year'] as int? ?? 0,
    yearEnd: json['yearEnd'] as int? ?? 0,
    overview: json['overview'] as String? ?? '',
    poster: json['poster'] as String? ?? '',
    background: json['background'] as String? ?? '',
    logo: json['logo'] as String? ?? '',
    genres: (json['genres'] as List<dynamic>? ?? []).cast<String>(),
    cast: (json['cast'] as List<dynamic>? ?? []).cast<String>(),
    directors: (json['directors'] as List<dynamic>? ?? []).cast<String>(),
    runtime: json['runtime'] as String? ?? '',
    imdbRating: (json['imdbRating'] as num?)?.toDouble() ?? 0,
    episodes: (json['episodes'] as List<dynamic>? ?? [])
        .map((e) => Episode.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

class Episode {
  const Episode({
    required this.season,
    required this.number,
    this.title = '',
    this.overview = '',
    this.thumbnail = '',
    this.released,
    this.rating = 0,
  });

  final int season;
  final int number;
  final String title;
  final String overview;
  final String thumbnail;
  final DateTime? released;

  /// Per-episode rating. Some titles have one for every episode and some for
  /// none, so zero means "not stated" and the row simply omits it.
  final double rating;

  /// Not out yet. Providers list a whole season as soon as the dates are
  /// known, so half a season page can be episodes nobody can watch — and
  /// offering to play them would be a lie.
  bool get isUpcoming =>
      released != null && released!.isAfter(DateTime.now().toUtc());

  /// "18 · Title" in a list of one season, "Episode 18 · Title" alone.
  String get label => _named.isEmpty ? 'Episode $number' : '$number · $_named';
  String get fullLabel => episodeName(number, title);
  String get _named => realTitle(number, title);

  /// Out in the last couple of weeks. An air date is worth the space when it
  /// says "this one is new" or "this one is not out yet"; on an episode from
  /// 2008 it is trivia in the place where something useful could be.
  bool get isRecent {
    if (released == null || isUpcoming) return false;
    return DateTime.now().toUtc().difference(released!).inDays <= 14;
  }

  factory Episode.fromJson(Map<String, dynamic> json) => Episode(
    season: json['season'] as int? ?? 0,
    number: json['number'] as int? ?? 0,
    title: json['title'] as String? ?? '',
    overview: json['overview'] as String? ?? '',
    thumbnail: json['thumbnail'] as String? ?? '',
    released: DateTime.tryParse(json['released'] as String? ?? ''),
    rating: (json['rating'] as num?)?.toDouble() ?? 0,
  );
}

/// One subtitle track on offer for the file being played.
class Subtitle {
  const Subtitle({
    required this.id,
    required this.language,
    required this.url,
    this.providerId = '',
    this.languageName = '',
    this.name = '',
    this.hashMatch = false,
    this.fps = 0,
  });

  final String id;
  final String providerId;

  /// ISO 639-1 where the core recognised the provider's code.
  final String language;
  final String languageName;

  /// The release this file was timed for, as the provider names it.
  final String name;

  /// Where to fetch it — a path on the core, never the provider's own
  /// address: the core is what turns the file into UTF-8 on the way through.
  final String url;

  /// The provider found this by the hash of the video, not by its title: it
  /// is in sync with this exact encode rather than with some other one.
  final bool hashMatch;

  /// Frames per second it was timed at, when the provider knows. A track
  /// timed at 25 against a 23.976 encode drifts by minutes over a film.
  final double fps;

  String get label =>
      languageName.isNotEmpty ? languageName : language.toUpperCase();

  factory Subtitle.fromJson(Map<String, dynamic> json) => Subtitle(
    id: json['id'] as String? ?? '',
    providerId: json['providerId'] as String? ?? '',
    language: json['language'] as String? ?? '',
    languageName: json['languageName'] as String? ?? '',
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    hashMatch: json['hashMatch'] as bool? ?? false,
    fps: (json['fps'] as num?)?.toDouble() ?? 0,
  );
}

class Download {
  const Download({
    required this.id,
    required this.itemId,
    required this.name,
    required this.state,
    required this.progress,
    this.season = 0,
    this.episode = 0,
    this.ready = false,
    this.resolved = false,
    this.updatedAt,
    this.waitingSince,
    this.pausedByUser = false,
    this.error = '',
    this.release = const Release(),
  });

  final String id;
  final String itemId;
  final String name;
  final String state;

  /// The copy, read from its name by the core the way the source list is.
  final Release release;

  /// When the state last changed; for a finished download, when it finished.
  final DateTime? updatedAt;
  final Progress progress;
  final int season;
  final int episode;

  /// The backend knows which file this is, so there is something to open. A
  /// size arrives with the source, long before that.
  final bool ready;

  /// The backend knows which file of the source this is: for a magnet link,
  /// its metadata has arrived. Until then its size and rate say nothing.
  final bool resolved;

  /// Since when an active download has been receiving nothing: resolving,
  /// no peers, or peers that send nothing. Null while bytes flow.
  final DateTime? waitingSince;

  /// Paused because somebody pressed Pause, rather than because the core
  /// stopped. Only this kind is the viewer's to resume.
  final bool pausedByUser;

  /// Why a failed download failed, in the core's words.
  final String error;

  bool get isDone => state == 'done';
  bool get isActive => state == 'active';
  bool get isPaused => state == 'paused';
  bool get isFailed => state == 'failed';

  /// What an active download is doing: waiting for anybody at all, asking
  /// the peers it found what the torrent holds, or taking the file.
  DownloadStage get stage => progress.peers == 0
      ? DownloadStage.findingPeers
      : resolved
      ? DownloadStage.arriving
      : DownloadStage.fetchingMetadata;

  factory Download.fromJson(Map<String, dynamic> json) => Download(
    id: json['id'] as String? ?? '',
    itemId: json['itemId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    state: json['state'] as String? ?? '',
    season: json['season'] as int? ?? 0,
    episode: json['episode'] as int? ?? 0,
    ready: json['ready'] as bool? ?? false,
    resolved: json['resolved'] as bool? ?? false,
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    waitingSince: DateTime.tryParse(json['waitingSince'] as String? ?? ''),
    pausedByUser: json['pausedByUser'] as bool? ?? false,
    error: json['error'] as String? ?? '',
    release: Release.fromJson(json['release'] as Map<String, dynamic>? ?? {}),
    progress: Progress.fromJson(
      json['progress'] as Map<String, dynamic>? ?? {},
    ),
  );
}

enum DownloadStage {
  findingPeers('Finding peers'),
  fetchingMetadata('Fetching metadata'),
  arriving('Downloading');

  const DownloadStage(this.label);

  final String label;
}

class Progress {
  const Progress({
    this.completed = 0,
    this.total = 0,
    this.peers = 0,
    this.seeders = 0,
    this.rate = 0,
    this.eta,
  });

  final int completed;
  final int total;
  final int peers;
  final int seeders;
  final int rate;

  /// Seconds to completion at the core's smoothed rate; null unless bytes are
  /// arriving.
  final int? eta;

  /// 0 while the size is still unknown, so a fresh download shows an empty
  /// bar rather than a full one.
  double get fraction => total <= 0 ? 0 : (completed / total).clamp(0, 1);

  factory Progress.fromJson(Map<String, dynamic> json) => Progress(
    completed: json['completed'] as int? ?? 0,
    total: json['total'] as int? ?? 0,
    peers: json['peers'] as int? ?? 0,
    seeders: json['seeders'] as int? ?? 0,
    rate: json['rate'] as int? ?? 0,
    eta: json['eta'] as int?,
  );
}

/// A source provider that refused or did not answer when asked for copies.
class ProviderFailure {
  const ProviderFailure({
    required this.provider,
    this.reason = '',
    this.status = 0,
  });

  final String provider;

  /// The status line it answered with, "403 Forbidden", or "no answer".
  final String reason;

  /// The HTTP status, 0 when there was no answer.
  final int status;

  /// Said as what it means for the viewer: a 403 is a block, not an empty
  /// list, and a 503 is an outage that goes away on its own. A block is
  /// usually of the network (Cloudflare in front of the addon), so it is not
  /// said to be of Lumeo.
  String get phrase => switch (status) {
    0 => '$provider did not answer',
    401 || 403 => '$provider is blocking requests from here ($status)',
    429 => '$provider is limiting requests (429)',
    >= 500 => '$provider is down ($status)',
    _ => '$provider: $reason',
  };

  factory ProviderFailure.fromJson(Map<String, dynamic> json) =>
      ProviderFailure(
        provider: json['provider'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
        status: json['status'] as int? ?? 0,
      );
}

/// One way to watch a title, as the core ranked it. Everything structured here
/// was parsed out of a free-text release name by the core — the client never
/// parses, it only shows.
class MediaSource {
  const MediaSource({
    required this.providerId,
    required this.rawName,
    required this.release,
    required this.locator,
    this.size = 0,
    this.seeders = 0,
    this.filename = '',
    this.tracker = '',
    this.languages = const [],
    this.bingeGroup = '',
    this.local = '',
    this.lastUsed = false,
  });

  final String providerId;
  final String rawName;
  final Release release;
  final Map<String, dynamic> locator;
  final int size;
  final int seeders;
  final String filename;

  /// Where the provider found this copy, and which languages it says it
  /// carries, audio and subtitles alike. Both come from the provider rather than from the release name,
  /// which is why they are on the source and not on the parsed release.
  final String tracker;
  final List<String> languages;

  /// The provider's hint that this copy is the same one that holds the next
  /// episode — a season pack, in practice. Remembering it is what stops the
  /// second episode of an evening downloading a second copy of the season.
  final String bingeGroup;

  /// What this library knows of the copy: 'done' on disk, 'partial' started,
  /// and whether its pack is the one used last time. Read only: the core sets
  /// them on the list, and a download does not carry them.
  final String local;
  final bool lastUsed;

  factory MediaSource.fromJson(Map<String, dynamic> json) => MediaSource(
    providerId: json['providerId'] as String? ?? '',
    rawName: json['rawName'] as String? ?? '',
    release: Release.fromJson(json['release'] as Map<String, dynamic>? ?? {}),
    locator: json['locator'] as Map<String, dynamic>? ?? const {},
    size: json['size'] as int? ?? 0,
    seeders: json['seeders'] as int? ?? 0,
    filename: json['filename'] as String? ?? '',
    tracker: json['tracker'] as String? ?? '',
    languages: (json['languages'] as List<dynamic>? ?? []).cast<String>(),
    bingeGroup: json['bingeGroup'] as String? ?? '',
    local: json['local'] as String? ?? '',
    lastUsed: json['lastUsed'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'providerId': providerId,
    'rawName': rawName,
    'release': release.toJson(),
    'locator': locator,
    'size': size,
    'seeders': seeders,
    'filename': filename,
    if (tracker.isNotEmpty) 'tracker': tracker,
    if (languages.isNotEmpty) 'languages': languages,
    if (bingeGroup.isNotEmpty) 'bingeGroup': bingeGroup,
  };
}

class Release {
  const Release({
    this.season = 0,
    this.episode = 0,
    this.resolution = '',
    this.source = '',
    this.videoCodec = '',
    this.audioCodec = '',
    this.channels = '',
    this.group = '',
    this.hdr = const [],
    this.languages = const [],
    this.bitDepth = 0,
    this.atmos = false,
    this.remux = false,
  });

  final int season;
  final int episode;
  final String resolution;
  final String source;
  final String videoCodec;
  final String audioCodec;
  final String channels;
  final String group;
  final List<String> hdr;
  final List<String> languages;
  final int bitDepth;
  final bool atmos;
  final bool remux;

  /// The one line that says what this copy is. Ordered the way someone scans
  /// it: how it looks, where it came from, how it sounds.
  /// A copy that names a season and no episode is the whole season. Nearly
  /// every source for a series is one, and knowing it is the difference
  /// between downloading a season once and downloading it per episode.
  bool get isSeasonPack => season > 0 && episode == 0;

  /// What the copy is, without the resolution: that has a column of its own,
  /// and saying it twice is what made the old row unreadable.
  String get kind => [
    if (isSeasonPack) 'S${season.toString().padLeft(2, '0')}',
    if (remux) 'Remux' else if (source.isNotEmpty) source,
    if (hdr.isNotEmpty) hdr.first,
  ].join(' · ');

  /// The rest, shown only when a row is the one in question.
  String get detail => [
    if (videoCodec.isNotEmpty) videoCodec,
    if (bitDepth > 0) '${bitDepth}bit',
    if (audioCodec.isNotEmpty)
      [
        audioCodec,
        if (channels.isNotEmpty) channels,
        if (atmos) 'Atmos',
      ].join(' '),
    if (group.isNotEmpty) group,
  ].join(' · ');

  factory Release.fromJson(Map<String, dynamic> json) => Release(
    season: json['season'] as int? ?? 0,
    episode: json['episode'] as int? ?? 0,
    resolution: json['resolution'] as String? ?? '',
    source: json['source'] as String? ?? '',
    videoCodec: json['videoCodec'] as String? ?? '',
    audioCodec: json['audioCodec'] as String? ?? '',
    channels: json['channels'] as String? ?? '',
    group: json['group'] as String? ?? '',
    hdr: (json['hdr'] as List<dynamic>? ?? []).cast<String>(),
    languages: (json['languages'] as List<dynamic>? ?? []).cast<String>(),
    bitDepth: json['bitDepth'] as int? ?? 0,
    atmos: json['atmos'] as bool? ?? false,
    remux: json['remux'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    if (season > 0) 'season': season,
    if (episode > 0) 'episode': episode,
    if (resolution.isNotEmpty) 'resolution': resolution,
    if (source.isNotEmpty) 'source': source,
    if (videoCodec.isNotEmpty) 'videoCodec': videoCodec,
    if (audioCodec.isNotEmpty) 'audioCodec': audioCodec,
    if (channels.isNotEmpty) 'channels': channels,
    if (group.isNotEmpty) 'group': group,
    if (hdr.isNotEmpty) 'hdr': hdr,
    if (languages.isNotEmpty) 'languages': languages,
    if (bitDepth > 0) 'bitDepth': bitDepth,
    if (atmos) 'atmos': atmos,
    if (remux) 'remux': remux,
  };
}

/// What the core holds on disk, grouped by title, and the disk it sits on.
class Storage {
  const Storage({
    required this.dir,
    required this.used,
    required this.titles,
    this.diskTotal = 0,
    this.diskFree = 0,
    this.cache = 0,
  });

  final String dir;

  /// Bytes every known download occupies together: what "free all" frees.
  final int used;

  /// The filesystem holding [dir]; zero when the core could not read it.
  final int diskTotal;
  final int diskFree;
  final List<StorageTitle> titles;

  /// Bytes of artwork the core keeps; it downloads again when needed.
  final int cache;

  factory Storage.fromJson(Map<String, dynamic> json) {
    final disk = json['disk'] as Map<String, dynamic>? ?? {};
    return Storage(
      dir: json['dir'] as String? ?? '',
      used: (json['used'] as num?)?.toInt() ?? 0,
      diskTotal: (disk['total'] as num?)?.toInt() ?? 0,
      diskFree: (disk['free'] as num?)?.toInt() ?? 0,
      cache: (json['cache'] as num?)?.toInt() ?? 0,
      titles: (json['titles'] as List<dynamic>? ?? [])
          .map((e) => StorageTitle.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// One title's downloads on disk. [itemId] is empty for a download the core
/// could not tie to a catalog item; [title] is then the download's own name.
class StorageTitle {
  const StorageTitle({
    required this.itemId,
    required this.title,
    required this.poster,
    required this.kind,
    required this.onDisk,
    required this.downloads,
  });

  final String itemId;
  final String title;
  final String poster;
  final String kind;
  final int onDisk;
  final List<StorageDownload> downloads;

  factory StorageTitle.fromJson(Map<String, dynamic> json) => StorageTitle(
    itemId: json['itemId'] as String? ?? '',
    title: json['title'] as String? ?? '',
    poster: json['poster'] as String? ?? '',
    kind: json['kind'] as String? ?? '',
    onDisk: (json['onDisk'] as num?)?.toInt() ?? 0,
    downloads: (json['downloads'] as List<dynamic>? ?? [])
        .map((e) => StorageDownload.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

class StorageDownload {
  const StorageDownload({
    required this.id,
    required this.name,
    required this.state,
    required this.onDisk,
    this.season = 0,
    this.episode = 0,
  });

  final String id;
  final String name;
  final String state;
  final int onDisk;
  final int season;
  final int episode;

  factory StorageDownload.fromJson(Map<String, dynamic> json) =>
      StorageDownload(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        state: json['state'] as String? ?? '',
        onDisk: (json['onDisk'] as num?)?.toInt() ?? 0,
        season: json['season'] as int? ?? 0,
        episode: json['episode'] as int? ?? 0,
      );
}

/// How far one film or episode has been watched. Season and episode are zero
/// for a film.
class WatchEntry {
  const WatchEntry({
    required this.season,
    required this.episode,
    required this.position,
    required this.duration,
    required this.watched,
    required this.updatedAt,
  });

  final int season;
  final int episode;
  final Duration position;
  final Duration duration;

  /// Latched by the core once ~90% has been seen. Finishing leaves no
  /// position, so a position on a watched entry is a rewatch under way.
  final bool watched;
  final DateTime updatedAt;

  /// The share seen, for a bar on a card. Zero until the duration is known.
  double get fraction => duration <= Duration.zero
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);

  /// The bar on a card: a rewatch shows how far it got, a finished one full.
  double get bar => position > Duration.zero ? fraction : (watched ? 1 : 0);

  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    season: json['season'] as int? ?? 0,
    episode: json['episode'] as int? ?? 0,
    position: _seconds(json['position']),
    duration: _seconds(json['duration']),
    watched: json['watched'] as bool? ?? false,
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  static Duration _seconds(Object? value) =>
      Duration(milliseconds: (((value as num?) ?? 0) * 1000).round());
}

/// Everything the core knows about one item's watching, and what it thinks
/// the Play button should open: [next] is null when there is nothing left.
class WatchProgress {
  const WatchProgress({required this.entries, this.next});

  final List<WatchEntry> entries;
  final WatchEntry? next;

  WatchEntry? entry(int season, int episode) {
    for (final e in entries) {
      if (e.season == season && e.episode == episode) return e;
    }
    return null;
  }

  factory WatchProgress.fromJson(Map<String, dynamic> json) => WatchProgress(
    entries: (json['entries'] as List<dynamic>? ?? [])
        .map((e) => WatchEntry.fromJson(e as Map<String, dynamic>))
        .toList(),
    next: json['next'] is Map<String, dynamic>
        ? WatchEntry.fromJson(json['next'] as Map<String, dynamic>)
        : null,
  );
}

/// The tracks picked by hand for a title, kept by the core for the whole
/// series: a pick the next episode forgot would be asked for again every
/// evening.
class TitleChoice {
  const TitleChoice({this.audio, this.subtitle});

  static const none = TitleChoice();

  final TrackChoice? audio;
  final TrackChoice? subtitle;

  factory TitleChoice.fromJson(Map<String, dynamic> json) => TitleChoice(
    audio: json['audio'] is Map<String, dynamic>
        ? TrackChoice.fromJson(json['audio'] as Map<String, dynamic>)
        : null,
    subtitle: json['subtitle'] is Map<String, dynamic>
        ? TrackChoice.fromJson(json['subtitle'] as Map<String, dynamic>)
        : null,
  );
}

/// A track the way it carries over from one file to the next. mpv's ids are
/// per file; a release keeps its languages and titles, and the title is what
/// tells apart the tracks that share a language — "English Full", "English
/// Honorifics", "Signs & Songs".
class TrackChoice {
  const TrackChoice({this.language = '', this.title = '', this.off = false});

  final String language;
  final String title;

  /// A subtitle turned off by hand.
  final bool off;

  factory TrackChoice.fromJson(Map<String, dynamic> json) => TrackChoice(
    language: json['language'] as String? ?? '',
    title: json['title'] as String? ?? '',
    off: json['off'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() =>
      off ? {'off': true} : {'language': language, 'title': title};
}

/// A title someone is part-way through, for the shelf on the home screen.
class ContinueItem {
  const ContinueItem({
    required this.item,
    required this.next,
    required this.updatedAt,
  });

  final MediaItem item;
  final WatchEntry next;
  final DateTime updatedAt;

  factory ContinueItem.fromJson(Map<String, dynamic> json) => ContinueItem(
    item: MediaItem.fromJson(json['item'] as Map<String, dynamic>? ?? {}),
    next: WatchEntry.fromJson(json['next'] as Map<String, dynamic>? ?? {}),
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// Cinemeta names an episode it has no title for "Episode N", which is no
/// title: printed after the number it read "18 · Episode 18".
String realTitle(int number, String title) =>
    title == 'Episode $number' ? '' : title;

String episodeName(int number, String title) => [
  'Episode $number',
  realTitle(number, title),
].where((part) => part.isNotEmpty).join(' · ');

/// Whether a title is on My list, and since when.
class ListState {
  const ListState({required this.inList, this.addedAt});

  final bool inList;
  final DateTime? addedAt;

  factory ListState.fromJson(Map<String, dynamic> json) => ListState(
    inList: json['inList'] as bool? ?? false,
    addedAt: DateTime.tryParse(json['addedAt'] as String? ?? ''),
  );
}

/// One title on My list, with what its tile says about it.
class ListedTitle {
  const ListedTitle({
    required this.item,
    required this.addedAt,
    this.rating = 0,
    this.watched = 0,
    this.released = 0,
  });

  /// Without its episodes: the counts below are what a tile needs of them.
  final MediaItem item;
  final DateTime addedAt;

  /// The viewer's own score of the title, 1 to 10; 0 when there is none.
  final int rating;

  /// Of the episodes out, how many are watched. A film is one episode; a
  /// series whose episodes the core never fetched says 0 of 0.
  final int watched;
  final int released;

  factory ListedTitle.fromJson(Map<String, dynamic> json) {
    final seen = json['seen'] as Map<String, dynamic>? ?? const {};
    return ListedTitle(
      item: MediaItem.fromJson(json['item'] as Map<String, dynamic>? ?? {}),
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      rating: json['rating'] as int? ?? 0,
      watched: seen['watched'] as int? ?? 0,
      released: seen['released'] as int? ?? 0,
    );
  }
}

/// A followed series with episodes out in the last fortnight that nobody
/// has watched.
class NewEpisodes {
  const NewEpisodes({
    required this.item,
    required this.episode,
    required this.count,
  });

  final MediaItem item;

  /// The latest of them.
  final Episode episode;

  /// How many there are, [episode] included.
  final int count;

  factory NewEpisodes.fromJson(Map<String, dynamic> json) => NewEpisodes(
    item: MediaItem.fromJson(json['item'] as Map<String, dynamic>? ?? {}),
    episode: Episode.fromJson(json['episode'] as Map<String, dynamic>? ?? {}),
    count: json['count'] as int? ?? 1,
  );
}

/// The viewer's score of a title (season and episode 0) or of one episode.
class Rating {
  const Rating({
    required this.season,
    required this.episode,
    required this.score,
  });

  final int season;
  final int episode;
  final int score;

  factory Rating.fromJson(Map<String, dynamic> json) => Rating(
    season: json['season'] as int? ?? 0,
    episode: json['episode'] as int? ?? 0,
    score: json['rating'] as int? ?? 0,
  );
}

/// One line of the history: what was watched, of which title, and the score
/// given to it.
class Viewing {
  const Viewing({
    required this.item,
    required this.entry,
    this.episode,
    this.rating = 0,
  });

  final MediaItem item;
  final WatchEntry entry;

  /// The episode as the catalogue has it; null for a film.
  final Episode? episode;
  final int rating;

  /// The same line with another score; 0 takes it off.
  Viewing rated(int score) =>
      Viewing(item: item, entry: entry, episode: episode, rating: score);

  factory Viewing.fromJson(Map<String, dynamic> json) => Viewing(
    item: MediaItem.fromJson(json['item'] as Map<String, dynamic>? ?? {}),
    entry: WatchEntry.fromJson(json['entry'] as Map<String, dynamic>? ?? {}),
    episode: json['episode'] is Map<String, dynamic>
        ? Episode.fromJson(json['episode'] as Map<String, dynamic>)
        : null,
    rating: json['rating'] as int? ?? 0,
  );
}
