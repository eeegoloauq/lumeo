import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../../api/preferences_store.dart';
import '../../l10n/l10n.dart';
import '../../platform/decoders.dart';
import '../../platform/folders.dart';
import '../../platform/local_settings.dart';
import '../../platform/window.dart';
import '../widgets/loading.dart';
import '../widgets/play_block.dart';
import 'bindings.dart';
import 'chapters.dart';
import 'chrome.dart';
import 'episode_frames.dart';
import 'menus.dart';
import 'mpv_facts.dart';
import 'mpv_host.dart';
import 'panels.dart';
import 'screenshots.dart';
import 'skip.dart';
import 'subtitle_style.dart';
import 'thumbnails.dart';
import 'tracks.dart';
import 'waiting.dart';

// Torrent pieces may arrive after media_kit's default network timeout.
const playerProperties = <String, String>{
  'network-timeout': '60',
  'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=30',
  'cache-on-disk': 'no',
  'cache-pause-initial': 'yes',
  'volume-max': '${VolumeControl.max}',
  'hr-seek': 'yes',
  'input-default-bindings': 'yes',
  'osd-level': '1',
  'osd-font-size': '28',
  'osd-border-size': '1.5',
  'osd-margin-x': '32',
  'osd-margin-y': '28',
  'osd-duration': '1200',
};

/// The mpv properties behind a subtitle background: `none`, `shadow` or
/// `box`. mpv 0.38 gave the box its own `sub-border-style` and made
/// `sub-back-color` the shadow's colour; before it, `sub-back-color` alone drew
/// the box and the shadow had `sub-shadow-color`.
Map<String, String> subtitleBackgroundProperties(
  String background, {
  required bool borderStyle,
}) {
  const dark = '#C0000000';
  const clear = '#00000000';
  final offset = background == 'shadow' ? '3' : '0';
  if (borderStyle) {
    return {
      'sub-border-style': background == 'box'
          ? 'background-box'
          : 'outline-and-shadow',
      'sub-back-color': background == 'none' ? clear : dark,
      'sub-shadow-offset': offset,
    };
  }
  return {
    'sub-back-color': background == 'box' ? dark : clear,
    'sub-shadow-color': dark,
    'sub-shadow-offset': offset,
  };
}

/// Retry startup failures briefly; torrents can still be acquiring data.
/// Counted from the first failure, not the start of a slow open.
@visibleForTesting
Duration openPatience = const Duration(seconds: 30);

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.api,
    required this.downloads,
    required this.frames,
    required this.download,
    required this.title,
    required this.background,
    required this.settings,
    required this.preferences,
    required this.onClose,
    required this.onNext,
    required this.onStorage,
    this.continuing = false,
  });

  final LumeoApi api;

  /// Every download, for the next episode's row in the download panel.
  final DownloadsStore downloads;
  final EpisodeFrames frames;
  final String download;
  final String title;

  final String background;
  final LocalSettings settings;
  final PreferencesStore preferences;
  final VoidCallback onClose;

  final void Function(String downloadId, String title) onNext;

  /// Leaves the player for Settings › Storage.
  final VoidCallback onStorage;

  // Episode switches retain the window for the whole sitting.
  final bool continuing;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// libass preserves ASS positioning and styling in mpv's renderer.
  late final Player _player = Player(
    configuration: const PlayerConfiguration(libass: true, title: 'Lumeo'),
  );

  /// `auto-safe` is mpv's documented value for turning hardware decoding on:
  /// only the methods known to decode correctly. media_kit's default is `auto`.
  late final VideoController _video = VideoController(
    _player,
    configuration: const VideoControllerConfiguration(hwdec: 'auto-safe'),
  );
  late final Future<MpvHost?> _hostReady;
  MpvHost? _host;
  Thumbnails? _thumbnails;
  bool _coreDead = false;
  Set<String> _boundKeys = const {};
  final _focus = FocusNode();

  // Releases have no character; retain the press name for matching keyup.
  final _held = <PhysicalKeyboardKey, String>{};

  Timer? _poll;
  Timer? _idle;
  Timer? _progressTimer;
  final _subscriptions = <StreamSubscription<dynamic>>[];

  Download? _download;
  String _episodeTitle = '';
  MediaItem? _item;
  WatchProgress? _episodeProgress;
  bool _itemAsked = false;

  /// Whether the download came without a title: a file opened with the app
  /// plays at once and the core names it while it does, so the name the
  /// shell passed in is the file's until then.
  bool? _openedUnnamed;
  String? _namedTitle;
  String get _title => _namedTitle ?? widget.title;
  Duration _duration = Duration.zero;

  Duration _position = Duration.zero;
  bool _playing = false;
  bool _scrubWasPlaying = false;
  bool _progressInFlight = false;
  bool _progressPending = false;
  bool _resumeAsked = false;
  Duration _lastReported = Duration.zero;

  bool _buffering = false;
  bool _opened = false;
  bool _opening = false;

  TitleChoice? _choice;

  final _titlesMatched = <String>{};
  final _trackChanges = TrackChanges();

  final _unsaved = <String, String>{};

  // Track the subtitle we loaded so its later `sid` is recognized.
  String? _ownFound;

  // Core and mpv failures need different messages.
  Object? _playbackError;

  int _attempts = 0;
  DateTime? _firstFailure;
  DateTime? _reopenAt;
  bool _reopenPending = false;

  // Async opens can finish after another attempt has started.
  int _generation = 0;

  // Unknown decoder availability must not be reported as missing.
  bool _decoderAsked = false;
  bool? _decoderMissing;
  String? _decoderInstallHint;

  // Audio can fail before the first frame while video still plays.
  String? _silent;

  // A decoded picture distinguishes survivable audio failure from fatal playback.
  int? _pictureWidth;
  Timer? _noticeTimer;
  String? _notice;

  bool get _hasPicture => (_pictureWidth ?? 0) > 0;
  bool _chrome = true;
  bool _overBar = false;

  // Drag moves replace hovers, so a held button must keep chrome visible.
  bool _mouseDown = false;

  final _buttons = <int, int>{};
  Object? _error;

  late double _volume;
  bool _muted = false;

  double _audible = 100;
  double _rate = 1;
  int _fit = 0;
  List<MpvChapter> _chapters = const [];
  int? _chapter;
  String _hardware = 'auto-safe';
  String _decoding = 'Hardware';

  // Bindings stay fixed during a film; load them when the page first opens.
  List<Shortcut>? _shortcuts;

  List<MpvTrack> _tracks = const [];
  List<Subtitle> _found = const [];
  double _subtitleDelay = 0;
  bool _subtitlesShown = true;
  double _subtitleScale = 1;
  // In mpv, sub-pos 100 is the bottom edge; lower values lift subtitles.
  double _subtitlePosition = 100;
  String _subtitleBackground = 'none';

  /// Whether this mpv has `sub-border-style` (0.38 and later).
  bool _borderStyle = false;
  PlayerMenu _menu = PlayerMenu.none;

  /// The settings page the menu opens on: the download panel's source row
  /// goes straight to Source.
  String _settingsPage = '';

  SourceChoice? _sources;
  bool _looking = false;
  bool _lookedUp = false;
  Object? _lookupError;

  static const _fits = [BoxFit.contain, BoxFit.cover, BoxFit.fill];

  // Other controls can change the shared window's fullscreen state.
  bool get _fullscreen => AppWindow.instance.fullscreen;

  // The visible bar raises subtitles by its height in mpv's 720-unit scale.
  static const _subtitleMargin = 22;
  static const _subtitleMarginWithChrome = 100;

  @override
  void initState() {
    super.initState();
    widget.downloads.addListener(_onDownloads);
    widget.frames.addListener(_onFrames);
    widget.preferences.addListener(_onPreferences);
    _hostReady = _attachHost();
    _volume = widget.settings.volume;
    _player.setVolume(_volume);
    _subscriptions.addAll([
      _player.stream.position.listen((p) {
        if (!mounted) return;
        setState(() => _position = p);
        // Compare with the last frame: container duration can extend beyond it.
        if ((_fileEnded || _endedAt != null) &&
            p < _endedPosition - const Duration(seconds: 1)) {
          _fileEnded = false;
          _endedTimer?.cancel();
          _endedTimer = null;
          if (_endedAt != null) setState(() => _endedAt = null);
        }
      }),
      _player.stream.duration.listen((d) {
        if (mounted) {
          setState(() => _duration = d);
          unawaited(_resume());
        }
      }),
      _player.stream.playing.listen((p) {
        if (!mounted) return;
        final paused = _playing && !p;
        setState(() => _playing = p);
        if (p) {
          _progressTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
            if (_playing) unawaited(_reportProgress());
          });
        } else if (paused) {
          unawaited(_reportProgress(afterCurrent: true));
        }
      }),
      // mpv keys can change these values, so persist the observed result.
      _player.stream.volume.listen((v) {
        if (!mounted) return;
        setState(() => _volume = v);
        if (v > 0) _audible = v;
        widget.settings.volume = v;
      }),
      _player.stream.width.listen((w) {
        if (!mounted) return;
        final had = _hasPicture;
        setState(() => _pictureWidth = w);
        if (_hasPicture) {
          // Start the hide timer after the first picture appears.
          if (!had) {
            _restartIdle();
            unawaited(_subtitleFromDatabase());
          }
          // A later failure needs a fresh retry budget.
          _attempts = 0;
          _firstFailure = null;
          _reopenAt = null;
          _reopenPending = false;
          unawaited(_checkDecoder());
        }
      }),
      // media_kit does not otherwise surface an unplayable file here.
      _player.stream.error.listen((e) {
        if (!mounted) return;
        unawaited(_explain(e));
      }),
    ]);
    unawaited(_watchPlayer());
    // Preserve the original window state across episode screen replacements.
    if (!widget.continuing) AppWindow.instance.setFullscreen(true);
    AppWindow.instance.addListener(_onWindow);
    // Sync mpv fullscreen so its first `f` toggles in the right direction.
    _mpvFullscreen = AppWindow.instance.fullscreen;
    unawaited(_mpvSet('fullscreen', _mpvFullscreen ? 'yes' : 'no'));
    unawaited(_mpvSet('log-file', mpvLogFile()));
    _pollNow();
    unawaited(_applyScreenshotProperties());
    _restartIdle();
  }

  Future<MpvHost?> _attachHost() async {
    // Before the file, not with it: the bindings below are mpv defaults, and
    // media_kit starts mpv with them off, so until then keys (Esc too) did
    // nothing while the swarm was still being found.
    for (final property in playerProperties.entries) {
      await _mpvSet(property.key, property.value);
    }
    final MpvHost host;
    try {
      host = await MpvHost.attach(_player.platform as NativePlayer);
    } on Object catch (e) {
      debugPrint('mpv client: $e');
      if (mounted) _focus.requestFocus();
      return null;
    }
    if (!mounted) {
      host.dispose();
      return null;
    }
    _host = host;
    _hardware = await host.get('hwdec') ?? 'auto-safe';
    _borderStyle = await host.get('sub-border-style') != null;
    _subscriptions.add(
      host.messages.listen((args) {
        if (!mounted || args.length != 2 || args[0] != 'lumeo') return;
        // Esc undoes one thing at a time, as mpv and the browsers do, so a
        // stray press in fullscreen no longer ends the film; q always leaves.
        if (args[1] == 'escape') {
          if (_menu != PlayerMenu.none) {
            _closeMenu();
          } else if (_fullscreen) {
            unawaited(_mpvSet('fullscreen', 'no'));
          } else {
            _close();
          }
        } else if (args[1] == 'back') {
          _close();
        } else if (args[1] == 'tracks') {
          _openMenu(PlayerMenu.tracks);
        }
      }),
    );
    host.shutdown.then((_) {
      _coreDead = true;
      if (mounted) _close();
    });
    await _defineOwnBindings();
    await _command(['enable-section', ownSection]);
    final bindings = MpvBinding.parse(await host.get('input-bindings') ?? '');
    if (!mounted) return host;
    _boundKeys = {for (final binding in bindings) binding.key};
    // Before our bindings load, Esc changes mpv fullscreen itself.
    _focus.requestFocus();
    return host;
  }

  /// The step the arrows are bound to, once our section is defined.
  int? _seekStep;

  /// Our section, with the arrows at the stored step: mpv seeks, so the step
  /// is a binding and not a Dart seek. Defined again when the preference
  /// changes; a section of the same name replaces the old one.
  Future<void> _defineOwnBindings() async {
    final step = widget.preferences.current?.seekStep ?? 5;
    if (step == _seekStep) return;
    _seekStep = step;
    await _command([
      'define-section',
      ownSection,
      ownBindings(seekStep: step).join('\n'),
      'default',
    ]);
    _shortcuts = null;
  }

  void _onPreferences() {
    if (_seekStep != null && mounted) unawaited(_defineOwnBindings());
  }

  // Fullscreen can change elsewhere; sync both this screen and mpv.
  void _onWindow() {
    if (!mounted) return;
    setState(() {});
    final on = AppWindow.instance.fullscreen;
    if (on != _mpvFullscreen) {
      _mpvFullscreen = on;
      unawaited(_mpvSet('fullscreen', on ? 'yes' : 'no'));
    }
  }

  // mpv may auto-select a track without media_kit reporting it.
  void _onTracks(String json) {
    if (!mounted) return;
    setState(() {
      _tracks = MpvTrack.parse(json);
      // A new audio track may decode correctly after the previous one failed.
      final codec = _selectedAudio?.codec.toLowerCase();
      if (_silent != null &&
          codec != null &&
          codec.isNotEmpty &&
          codec != _silent) {
        _silent = null;
      }
    });
    _matchTitles();
    final loaded = _subtitleTracks
        .where((t) => t.external && t.externalFilename == _ownFound)
        .firstOrNull;
    if (loaded != null) {
      _ownFound = null;
      _selectOwn('sid', loaded.id);
    }
    _saveTracks();
  }

  void _selectOwn(String property, String id) {
    _trackChanges.own(property, id);
    unawaited(_mpvSet(property, id));
  }

  Future<TitleChoice> _loadChoice(String itemId) async {
    if (itemId.isEmpty) return TitleChoice.none;
    try {
      return await widget.api.choice(itemId);
    } on Object catch (e) {
      debugPrint('title choice: $e');
      return TitleChoice.none;
    }
  }

  // Apply a title pick once tracks are listed; otherwise use mpv language rules.
  void _matchTitles() {
    if (!_opened) return;
    for (final (property, type, picked) in [
      ('aid', 'audio', _choice?.audio),
      ('sid', 'sub', _choice?.subtitle),
    ]) {
      if (_titlesMatched.contains(type) ||
          !_tracks.any((t) => t.type == type)) {
        continue;
      }
      _titlesMatched.add(type);
      final track = trackToSelect(_tracks, type, picked);
      if (track != null) _selectOwn(property, track.id);
    }
  }

  void _onTrackChange(String property, String value) {
    if (!_trackChanges.byViewer(property, value)) return;
    _unsaved[property] = value;
    _saveTracks();
  }

  void _saveTracks() {
    final itemId = _download?.itemId ?? '';
    final aid = _unsaved['aid'], sid = _unsaved['sid'];
    final audio = aid == null ? null : trackToRemember(_tracks, 'audio', aid);
    final subtitle = sid == null ? null : trackToRemember(_tracks, 'sub', sid);
    if (audio != null) _unsaved.remove('aid');
    if (subtitle != null) _unsaved.remove('sid');
    if (itemId.isEmpty || (audio == null && subtitle == null)) return;
    widget.api
        .rememberTracks(itemId, audio: audio, subtitle: subtitle)
        .catchError((Object e) => debugPrint('remember tracks: $e'));
  }

  List<MpvTrack> get _audioTracks =>
      _tracks.where((t) => t.type == 'audio').toList(growable: false);
  List<MpvTrack> get _subtitleTracks =>
      _tracks.where((t) => t.type == 'sub').toList(growable: false);
  MpvTrack? get _selectedAudio =>
      _audioTracks.where((t) => t.selected).firstOrNull;
  MpvTrack? get _selectedSubtitle =>
      _subtitleTracks.where((t) => t.selected).firstOrNull;

  // Avoid echoing fullscreen changes between mpv and the window.
  bool _mpvFullscreen = false;

  // Before the open, mpv still holds its defaults, not the stored values.
  // After it, only the user changes these, from the menu or with mpv's keys.
  void _remember(String key, Object value) {
    if (!_opened) return;
    final stored = switch (key) {
      'subtitleScale' => widget.preferences.current?.subtitleScale,
      'subtitlePosition' => widget.preferences.current?.subtitlePosition,
      _ => null,
    };
    if (value != stored) widget.preferences.remember(key, value);
  }

  Future<void> _watchPlayer() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final watched = <String, void Function(String)>{
      'track-list': _onTracks,
      'aid': (value) => _onTrackChange('aid', value),
      'sid': (value) => _onTrackChange('sid', value),
      'chapter-list': (value) =>
          setState(() => _chapters = MpvChapter.parse(value)),
      'chapter': (value) {
        final i = int.tryParse(value);
        setState(() => _chapter = i == null || i < 0 ? null : i);
      },
      'hwdec-current': (value) {
        setState(() => _decoding = value == 'no' ? 'Software' : 'Hardware');
        // For Settings › About, which has no film to ask.
        if (value.isNotEmpty) MpvFacts.instance.hardware = value;
      },
      // media_kit buffering also marks pauses and seeks; cache buffering does not.
      'paused-for-cache': (value) =>
          setState(() => _buffering = value == 'yes'),
      'mute': (value) => setState(() => _muted = value == 'yes'),
      // `keep-open=yes` holds the last frame; this clears on seek. Not
      // media_kit's `completed`: it drops the event while its own play/pause
      // bookkeeping disagrees with mpv, which pauses through its keys.
      'eof-reached': (value) {
        if (value == 'yes') _onEndOfFile();
      },
      // media_kit omits speed changes made through mpv keys. Speed is for
      // this film only and is never stored.
      'speed': (value) {
        final rate = double.tryParse(value);
        if (rate != null) setState(() => _rate = rate);
      },
      'sub-delay': (value) =>
          setState(() => _subtitleDelay = double.tryParse(value) ?? 0),
      'sub-visibility': (value) =>
          setState(() => _subtitlesShown = value == 'yes'),
      // Persist size and height so the next film uses the same setting.
      'sub-scale': (value) {
        final scale = double.tryParse(value);
        if (scale == null) return;
        setState(() => _subtitleScale = scale);
        _remember('subtitleScale', scale);
      },
      // mpv prints this integer setting as a float since 0.36.
      'sub-pos': (value) {
        final position = double.tryParse(value)?.round();
        if (position == null) return;
        setState(() => _subtitlePosition = position.toDouble());
        _remember('subtitlePosition', position);
      },
      // mpv has no window here; GTK follows its fullscreen property.
      'fullscreen': (value) {
        final on = value == 'yes';
        if (on == _mpvFullscreen) return;
        _mpvFullscreen = on;
        unawaited(AppWindow.instance.setFullscreen(on));
      },
    };
    for (final entry in watched.entries) {
      try {
        await platform.observeProperty(entry.key, (value) async {
          if (mounted) entry.value(value);
        });
      } on Object catch (_) {
        // Older mpv builds may lack a property; playback can still open.
      }
    }
  }

  @override
  void dispose() {
    widget.downloads.removeListener(_onDownloads);
    widget.frames.removeListener(_onFrames);
    widget.preferences.removeListener(_onPreferences);
    unawaited(_reportProgress(afterCurrent: true));
    _poll?.cancel();
    _idle?.cancel();
    _progressTimer?.cancel();
    _noticeTimer?.cancel();
    _endedTimer?.cancel();
    for (final choice in {_switch, _sources}) {
      choice?.dispose();
    }
    for (final s in _subscriptions) {
      s.cancel();
    }
    AppWindow.instance.removeListener(_onWindow);
    _focus.dispose();
    _host?.dispose();
    _thumbnails?.dispose();
    unawaited(_hostReady.whenComplete(_player.dispose));
    super.dispose();
  }

  // Schedule after each response to avoid overlapping polls and stale progress.
  Future<void> _pollNow() async {
    await _refresh();
    if (!mounted) return;
    _poll = Timer(const Duration(seconds: 2), _pollNow);
  }

  // mpv cannot open the file until the core has its metadata.
  Future<void> _refresh() async {
    try {
      final fresh = await widget.api.download(widget.download);
      if (!mounted) return;
      setState(() {
        _download = fresh;
        _error = null;
      });
      _openedUnnamed ??= fresh.itemId.isEmpty;
      if (!_itemAsked &&
          fresh.itemId.isNotEmpty &&
          (fresh.episode > 0 || _openedUnnamed!)) {
        _itemAsked = true;
        unawaited(_loadItem(fresh));
      }
      unawaited(_resume());
      unawaited(_lookUpNext());
      unawaited(_prefetchNext());
      if (!_opened && !_opening && fresh.ready && _dueToOpen) {
        // Mark open only after mpv accepts the file, so failures remain visible.
        _opening = true;
        final attempt = ++_generation;
        _choice ??= await _loadChoice(fresh.itemId);
        final prefs = await _preferences();
        _subtitleScale = prefs.subtitleScale;
        _subtitlePosition = prefs.subtitlePosition.toDouble();
        _subtitleBackground = prefs.subtitleBackground;
        await _hostReady;
        for (final property in _trackProperties().entries) {
          if (property.key == 'sid') _trackChanges.own('sid', property.value);
          await _mpvSet(property.key, property.value);
        }
        final stream = widget.api.streamUrl(widget.download);
        final headers = await widget.api.token.headers();
        await _player.open(Media(stream, httpHeaders: headers));
        // A superseded async open must not hide the waiting overlay.
        if (!mounted || attempt != _generation) return;
        // A fresh one per open: a stream that failed failed for it too.
        _thumbnails?.dispose();
        // Off in Settings, the second mpv behind the frames never starts.
        _thumbnails = widget.settings.timelinePreviews
            ? Thumbnails(stream, headers: headers)
            : null;
        setState(() {
          _opened = true;
          _playbackError = null;
          _reopenPending = false;
        });
        _matchTitles();
        unawaited(_resume());
        await _applySubtitleMargin();
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      _opening = false;
    }
  }

  // Opening on defaults would show the wrong size and languages, and a value
  // read back later would be compared with nothing and stored.
  Future<Preferences> _preferences() async {
    final store = widget.preferences;
    if (store.current == null) await store.load();
    return store.current ?? (throw store.error ?? StateError('no preferences'));
  }

  Future<void> _loadItem(Download download) async {
    try {
      final item = await widget.api.item(download.itemId);
      final episode = item.episodes
          .where(
            (e) => e.season == download.season && e.number == download.episode,
          )
          .firstOrNull;
      if (mounted) {
        setState(() {
          if (download.episode > 0) {
            _item = item;
            _episodeTitle = episode?.title ?? '';
          }
          if (_openedUnnamed == true) _namedTitle = item.title;
        });
      }
      if (download.episode > 0) await _loadEpisodeProgress(download.itemId);
    } on Object catch (_) {}
  }

  Future<void> _loadEpisodeProgress(String itemId) async {
    try {
      final progress = await widget.api.progress(itemId);
      if (mounted) setState(() => _episodeProgress = progress);
    } on Object catch (_) {}
  }

  /// Resolve the screenshot directory only on demand; it may run a program.
  /// Failure affects screenshots, not playback.
  Future<void> _applyScreenshotProperties() async {
    try {
      final properties = screenshotProperties(
        title: _title,
        pictures: await picturesFolder(),
        chosen: widget.settings.screenshotsDir,
      );
      for (final property in properties.entries) {
        if (!mounted) return;
        await _mpvSet(property.key, property.value);
      }
    } on Object catch (error) {
      debugPrint('screenshot properties: $error');
    }
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  // Retry immediately instead of waiting for the next poll.
  void _retry() {
    setState(() {
      _error = null;
      _playbackError = null;
      _notice = null;
      _opened = false;
      _titlesMatched.clear();
      _attempts = 0;
      _forgetChapters();
    });
    _firstFailure = null;
    _reopenAt = null;
    _reopenPending = false;
    _generation++;
    _refresh();
  }

  bool get _dueToOpen {
    final at = _reopenAt;
    return at == null || !DateTime.now().isBefore(at);
  }

  bool get _worthAnotherAttempt {
    final since = _firstFailure;
    return since == null || DateTime.now().difference(since) < openPatience;
  }

  // Space retries because each attempt opens a new core reader.
  void _openAgainLater() {
    _attempts++;
    _generation++;
    _firstFailure ??= DateTime.now();
    _reopenPending = true;
    _reopenAt = DateTime.now().add(
      Duration(seconds: _attempts < 5 ? 2 * _attempts : 10),
    );
    unawaited(_player.stop());
    setState(() {
      _opened = false;
      _titlesMatched.clear();
      _playbackError = null;
      _forgetChapters();
    });
  }

  // mpv makes `chapter` unavailable between files; media_kit omits that event.
  void _forgetChapters() {
    _chapters = const [];
    _chapter = null;
  }

  /// Pointer activity controls chrome; menus and a pointer on the bar hold it.
  /// Pausing or seeking alone must not cover the picture.
  void _restartIdle() {
    _idle?.cancel();
    if (!_chrome) _showChrome(true);
    _idle = Timer(chromeHideDelay, () {
      if (mounted &&
          _hasPicture &&
          !_overBar &&
          !_mouseDown &&
          _menu == PlayerMenu.none) {
        _showChrome(false);
      }
    });
  }

  void _release() {
    _mouseDown = false;
    _restartIdle();
  }

  void _showChrome(bool show) {
    setState(() => _chrome = show);
    _applySubtitleMargin();
  }

  // mpv resets subtitle margin on each file open.
  Future<void> _applySubtitleMargin() => _mpvSet(
    'sub-margin-y',
    '${_chrome ? _subtitleMarginWithChrome : _subtitleMargin}',
  );

  Future<void> _command(List<String> args) async {
    if (_coreDead) return;
    final platform = _player.platform;
    if (platform is NativePlayer) await platform.command(args);
  }

  void _togglePlay() {
    if (!_hasPicture) return;
    unawaited(_command(['cycle', 'pause']));
  }

  // Flutter reports a second held button as a move; forward mask changes.
  // Ignore presses before a picture exists to avoid pausing unseen playback.
  void _onPictureButtons(PointerEvent event) {
    final was = _buttons[event.pointer] ?? 0;
    final now = event is PointerCancelEvent ? 0 : event.buttons;
    if (now == was) return;
    // A click that closes a menu is only that, not a pause.
    final accepts = _hasPicture && _menu == PlayerMenu.none;
    if (now & ~was != 0 && _menu != PlayerMenu.none) _closeMenu();
    for (final button in mpvMouseButtons.entries) {
      final pressed = now & button.key != 0;
      if (pressed == (was & button.key != 0)) continue;
      if (pressed && !accepts) continue;
      unawaited(_command([pressed ? 'keydown' : 'keyup', button.value]));
    }
    final held = accepts ? now : now & was;
    if (held == 0) {
      _buttons.remove(event.pointer);
    } else {
      _buttons[event.pointer] = held;
    }
  }

  void _pictureMotion(PointerEvent event, Size widgetSize) {
    if (!_hasPicture) return;
    final width = _player.state.width;
    final height = _player.state.height;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    final videoSize = Size(width.toDouble(), height.toDouble());
    final fitted = applyBoxFit(_fits[_fit], videoSize, widgetSize);
    final rect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & widgetSize,
    );
    if (!rect.contains(event.localPosition)) return;
    final x =
        (event.localPosition.dx - rect.left) *
            fitted.source.width /
            rect.width +
        (videoSize.width - fitted.source.width) / 2;
    final y =
        (event.localPosition.dy - rect.top) *
            fitted.source.height /
            rect.height +
        (videoSize.height - fitted.source.height) / 2;
    unawaited(_command(['mouse', '${x.round()}', '${y.round()}']));
  }

  Future<void> _resume() async {
    final download = _download;
    if (_resumeAsked ||
        !_opened ||
        _duration <= Duration.zero ||
        download == null ||
        download.itemId.isEmpty) {
      return;
    }
    _resumeAsked = true;
    try {
      final progress = await widget.api.progress(download.itemId);
      if (!mounted) return;
      final entry = progress.entry(download.season, download.episode);
      if (entry != null &&
          entry.position > const Duration(seconds: 10) &&
          entry.position < _duration * 0.95) {
        _seekTo(entry.position);
      }
    } on Object catch (error) {
      debugPrint('progress lookup failed: $error');
    }
  }

  /// Keep the active report future: replacing it with a completed future
  /// makes flush spin microtasks and starves its HTTP response.
  Future<void>? _reporting;

  Future<void> _reportProgress({bool afterCurrent = false, bool? watched}) {
    if (_progressInFlight) {
      if (afterCurrent) _progressPending = true;
      return _reporting ?? Future<void>.value();
    }
    return _reporting = _report(watched: watched);
  }

  Future<void> _report({bool? watched}) async {
    final download = _download;
    final position = _position;
    if (_duration <= Duration.zero ||
        download == null ||
        download.itemId.isEmpty) {
      return;
    }
    if (watched == null && position == _lastReported) return;
    _progressInFlight = true;
    _lastReported = position;
    try {
      await widget.api.putProgress(
        download.itemId,
        season: download.season,
        episode: download.episode,
        position: position,
        duration: _duration,
        watched: watched,
      );
    } on Object catch (error) {
      debugPrint('progress report failed: $error');
    } finally {
      _progressInFlight = false;
      if (_progressPending) {
        _progressPending = false;
        unawaited(_reportProgress());
      }
    }
  }

  void _close() {
    unawaited(_reportProgress(afterCurrent: true));
    widget.onClose();
  }

  Episode? _next;
  bool _nextAsked = false;

  Future<void> _lookUpNext() async {
    final download = _download;
    if (_nextAsked || download == null || download.itemId.isEmpty) return;
    if (download.season <= 0 && download.episode <= 0) return;
    _nextAsked = true;
    try {
      final found = await widget.api.episodeAfter(
        download.itemId,
        season: download.season,
        episode: download.episode,
      );
      if (!mounted) return;
      setState(() => _next = found);
      // Ignore a stale end event after seeking back into the file.
      if (_fileEnded && found != null) {
        _fileEnded = false;
        _onEndOfFile();
      }
    } on LumeoApiException catch (error) {
      // A catalogue miss is final for this episode; repeated polls add no value.
      debugPrint('next episode lookup refused: ${error.message}');
    } on Object catch (error) {
      // Retry transient core failures so the next button can still appear.
      _nextAsked = false;
      debugPrint('next episode lookup failed: $error');
    }
  }

  bool _prefetchAsked = false;
  NextFetch _nextFetch = NextFetch.waiting;

  /// The next episode's download, once there is one.
  Download? get _nextDownload {
    final download = _download, next = _next;
    if (download == null || next == null) return null;
    return widget.downloads.all
        .where(
          (d) =>
              d.itemId == download.itemId &&
              d.season == next.season &&
              d.episode == next.number,
        )
        .firstOrNull;
  }

  void _onDownloads() {
    if (mounted && _menu == PlayerMenu.download) setState(() {});
  }

  void _onFrames() {
    if (mounted) setState(() {});
  }

  /// Once this episode is on disk, the next one starts downloading: the copy
  /// Play would start for it. The core refuses one that does not fit inside
  /// the disk limit, and that refusal is the answer, not a failure.
  Future<void> _prefetchNext() async {
    final download = _download, next = _next;
    if (_prefetchAsked || download == null || !download.isDone) return;
    if (next == null || next.isUpcoming) return;
    _prefetchAsked = true;
    try {
      // The panel reads "off" from the preference itself.
      if (!(await _preferences()).prefetch) return;
    } on Object catch (error) {
      debugPrint('prefetch preference unavailable: $error');
      return;
    }
    // Asked before the provider: one already there needs no source list.
    await widget.downloads.refresh();
    if (_nextDownload case final d? when d.state != 'failed') return;
    await _downloadNext(prefetch: true);
  }

  /// The prefetch, or the panel's Download now and Download anyway, which are
  /// the same request without the disk-limit check.
  Future<void> _downloadNext({bool prefetch = false}) async {
    final download = _download, next = _next;
    if (download == null || next == null) return;
    NextFetch outcome = NextFetch.waiting;
    try {
      final started = await downloadPreferred(
        widget.api,
        download.itemId,
        season: next.season,
        episode: next.number,
        prefetch: prefetch,
      );
      if (started == null) outcome = NextFetch.noCopy;
    } on LumeoApiException catch (error) {
      outcome = error.status == 507 ? NextFetch.noRoom : NextFetch.failed;
      debugPrint('downloading the next episode did not start: $error');
    } on Object catch (error) {
      outcome = NextFetch.failed;
      debugPrint('downloading the next episode did not start: $error');
    }
    await widget.downloads.refresh();
    if (mounted) setState(() => _nextFetch = outcome);
  }

  // With no ending chapter, the last frame is held this long, counting down;
  // zero holds it until the card is pressed.
  Duration get _lastFrameGrace =>
      Duration(seconds: widget.preferences.current?.nextCountdown ?? 5);

  bool get _autoplayNext => _lastFrameGrace > Duration.zero;

  /// How long before an end the file does not mark the next episode is
  /// offered.
  Duration get _nextNotice =>
      Duration(seconds: widget.preferences.current?.nextNotice ?? 30);

  DateTime? _endedAt;
  Timer? _endedTimer;

  // Seek-back detection uses the last frame, not container duration.
  Duration _endedPosition = Duration.zero;
  Duration _endedOfferStart = Duration.zero;

  // The next-episode lookup may finish after the one-shot end event.
  bool _fileEnded = false;

  // A button press and end event must start only one next download.
  bool _advancing = false;

  SourceChoice? _switch;
  Episode? _switchingTo;

  double get _endedFill {
    final at = _endedAt;
    if (at == null || !_autoplayNext) return 0;
    final since = DateTime.now().difference(at).inMilliseconds;
    final played = (_endedPosition - _endedOfferStart).inMilliseconds;
    return ((played + since) / (played + _lastFrameGrace.inMilliseconds)).clamp(
      0.0,
      1.0,
    );
  }

  // Rounded progress can reach one before mpv signals end.
  void _onEndOfFile() {
    if (_advancing || _endedAt != null || !_opened) return;
    _endedPosition = _position;
    _fileEnded = true;
    if (_next == null) return;
    final showing = skipMoment(
      chapters: _chapters,
      position: _position,
      duration: _duration,
      hasNext: true,
      notice: _nextNotice,
    );
    _endedOfferStart = showing?.action == SkipAction.next
        ? showing!.start
        : _endedPosition;
    // Marked credits advance at EOF; an unmarked end holds its last frame.
    if (showing?.action == SkipAction.next &&
        showing!.credits &&
        _autoplayNext) {
      unawaited(_advance());
      return;
    }
    setState(() => _endedAt = DateTime.now());
    // The card stays over the held frame until it is pressed.
    if (!_autoplayNext) return;
    _endedTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;
      if (_endedFill >= 1) {
        timer.cancel();
        unawaited(_advance());
      } else {
        setState(() {});
      }
    });
  }

  // Credit skips count as watched even before the core's 90% threshold.
  Future<void> _flushProgress() async {
    _progressTimer?.cancel();
    _progressTimer = null;
    while (_progressInFlight) {
      await _reporting;
    }
    _progressPending = false;
    await _reportProgress(watched: true);
  }

  Future<void> _advance() async {
    final next = _next;
    if (_advancing || next == null) return;
    _endedTimer?.cancel();
    await _startEpisode(next, finished: true);
  }

  // Credit skips count as watched before the core's 90% threshold.
  Future<void> _startEpisode(Episode episode, {bool finished = false}) async {
    final download = _download;
    // One copy at a time: a second pick while one is starting would start
    // a second download.
    if (download == null || episode.isUpcoming || (_switch?.pending ?? false)) {
      return;
    }
    _closeMenu();
    setState(() {
      _advancing = true;
      _switchingTo = episode;
    });
    if (_playing) unawaited(_mpvSet('pause', 'yes'));
    if (finished) await _flushProgress();
    if (!mounted) return;
    _switchTo(
      SourceChoice(
        api: widget.api,
        itemId: download.itemId,
        season: episode.season,
        episode: episode.number,
        startWhenReady: true,
        onStarted: (started) => widget.onNext(
          started.id,
          nextEpisodeTitle(_title, episode.season, episode.number),
        ),
      ),
    );
  }

  void _switchTo(SourceChoice choice) {
    if (!identical(_switch, _sources)) _switch?.dispose();
    setState(() => _switch = choice);
    if (!identical(choice, _sources)) {
      choice.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  void _retrySwitch() {
    final choice = _switch;
    if (choice == null) return;
    if (choice.picked != null) {
      unawaited(choice.start());
    } else {
      choice.startWhenReady = true;
      unawaited(choice.load());
    }
  }

  String get _artwork => widget.preferences.current?.episodeArtwork ?? 'show';

  File? _frameOf(Episode e) =>
      widget.frames.of(_download?.itemId ?? '', e.season, e.number);

  void _pickSource(MediaSource source) {
    final choice = _sources!..pick(source);
    _closeMenu();
    setState(() {
      _advancing = true;
      _switchingTo = null;
    });
    if (_playing) unawaited(_mpvSet('pause', 'yes'));
    _switchTo(choice);
    unawaited(choice.start());
  }

  Widget? _skip() {
    // The episodes panel covers the corner the card would take.
    if (!_hasPicture || _menu == PlayerMenu.episodes) return null;
    final next = _next;
    if (_advancing) return null;
    if (_endedAt != null && next != null) {
      return NextEpisodeCard(
        artwork: _artwork,
        frame: _frameOf(next),
        episode: next,
        fill: _endedFill,
        secondsLeft: _autoplayNext
            ? ((_lastFrameGrace.inMilliseconds -
                          DateTime.now().difference(_endedAt!).inMilliseconds) /
                      1000)
                  .ceil()
                  .clamp(0, 999)
            : null,
        onPressed: () => unawaited(_advance()),
      );
    }
    final moment = skipMoment(
      chapters: _chapters,
      position: _position,
      duration: _duration,
      hasNext: next != null,
      notice: _nextNotice,
    );
    return switch (moment?.action) {
      null => null,
      SkipAction.intro => SkipPill(
        label: context.l10n.playerSkipOpening,
        fill: moment!.fill,
        onPressed: () => _seekTo(moment.target),
      ),
      SkipAction.next => NextEpisodeCard(
        artwork: _artwork,
        frame: _frameOf(next!),
        episode: next,
        fill: moment!.fillUntilAdvance(
          _position,
          moment.credits ? Duration.zero : _lastFrameGrace,
        ),
        // Only credits count down to the next episode; the notice before an
        // unmarked end offers it, and the held last frame counts.
        secondsLeft: _autoplayNext && moment.credits
            ? ((moment.end - _position).inSeconds).clamp(0, 999)
            : null,
        onPressed: () => unawaited(_advance()),
      ),
    };
  }

  // Exact seeking on release complements keyframe seeking during drag.
  void _seekTo(Duration target) {
    if (!_opened) return;
    var clamped = target < Duration.zero ? Duration.zero : target;
    if (_duration > Duration.zero && clamped > _duration) clamped = _duration;
    unawaited(
      _command([
        'seek',
        (clamped.inMilliseconds / 1000).toStringAsFixed(3),
        'absolute+exact',
      ]),
    );
  }

  // Keyframe seeks are cheap enough to follow each drag movement.
  void _scrubTo(double fraction) {
    if (!_opened) return;
    unawaited(
      _command([
        'seek',
        (fraction * 100).toStringAsFixed(3),
        'absolute-percent+keyframes',
      ]),
    );
  }

  void _startScrub() {
    _scrubWasPlaying = _playing;
    if (_scrubWasPlaying) unawaited(_mpvSet('pause', 'yes'));
  }

  void _endScrub() {
    if (_scrubWasPlaying) unawaited(_mpvSet('pause', 'no'));
    _scrubWasPlaying = false;
  }

  void _setVolume(double percent) {
    final v = percent.clamp(0.0, VolumeControl.max);
    unawaited(_mpvSet('volume', '$v'));
    if (_muted && v > 0) unawaited(_mpvSet('mute', 'no'));
  }

  // At zero volume, the button restores audible sound instead of muting.
  void _toggleMute() {
    if (_volume == 0) {
      unawaited(_mpvSet('volume', '$_audible'));
      if (_muted) unawaited(_mpvSet('mute', 'no'));
    } else {
      unawaited(_command(['cycle', 'mute']));
    }
  }

  void _setRate(double rate) => unawaited(_mpvSet('speed', '$rate'));

  // mpv's `f` and the button must toggle the same property.
  void _toggleFullscreen() => unawaited(_command(['cycle', 'fullscreen']));

  void _openMenu(PlayerMenu menu) {
    setState(() => _menu = _menu == menu ? PlayerMenu.none : menu);
    if (_menu == PlayerMenu.tracks && !_lookedUp) _lookUp();
    if (_menu == PlayerMenu.episodes && _download != null) {
      unawaited(_loadEpisodeProgress(_download!.itemId));
    }
    _settingsPage = '';
    final wantsSources =
        _menu == PlayerMenu.settings || _menu == PlayerMenu.download;
    if (wantsSources && _sources == null && (_download?.itemId ?? '') != '') {
      final download = _download!;
      _sources =
          SourceChoice(
            api: widget.api,
            itemId: download.itemId,
            season: download.season,
            episode: download.episode,
            onStarted: (started) => widget.onNext(started.id, _title),
          )..addListener(() {
            if (mounted) setState(() {});
          });
    }
    // Restart chrome timeout when a menu closes.
    if (_menu == PlayerMenu.none) _restartIdle();
  }

  void _closeMenu() {
    if (_menu != PlayerMenu.none) _openMenu(_menu);
  }

  /// Let mpv select tracks using language, default, and forced flags.
  /// Manual mode retains forced subs; a title-specific off choice overrides them.
  Map<String, String> _trackProperties() {
    final prefs = widget.preferences.current;
    if (prefs == null) return const {};
    final mode = prefs.subtitleMode;
    final audio = _choice?.audio;
    final subtitle = _choice?.subtitle;
    final pickedSubtitle =
        subtitle != null && !subtitle.off && subtitle.language.isNotEmpty;
    return {
      'alang': [
        if (audio != null && audio.language.isNotEmpty) audio.language,
        ...prefs.audioLanguages,
      ].join(','),
      'slang': [
        if (pickedSubtitle) subtitle.language,
        if (mode != 'manual') ...prefs.subtitleLanguages,
      ].join(','),
      'subs-with-matching-audio': mode == 'foreign' && !pickedSubtitle
          ? 'no'
          : 'yes',
      'subs-fallback': mode == 'manual' ? 'no' : 'default',
      if (subtitle?.off ?? false) 'sid': 'no',
      'sub-scale': '$_subtitleScale',
      'sub-pos': '${_subtitlePosition.round()}',
      ...subtitleBackgroundProperties(
        _subtitleBackground,
        borderStyle: _borderStyle,
      ),
      ...subtitleStyleProperties(
        colour: prefs.subtitleColor,
        keepStyling: prefs.subtitleKeepStyling,
      ),
    };
  }

  /// Lazy lookup avoids fetching the file's final 64 KiB for viewers without subs.
  /// Share an in-flight lookup with an early menu request.
  Future<void>? _lookup;

  Future<void> _lookUp() =>
      _lookup ??= _lookUpNow().whenComplete(() => _lookup = null);

  Future<void> _lookUpNow() async {
    final download = _download;
    if (download == null || download.itemId.isEmpty) return;
    setState(() {
      _looking = true;
      _lookupError = null;
    });
    try {
      final found = await widget.api.subtitles(
        itemId: download.itemId,
        download: download.id,
      );
      if (!mounted) return;
      setState(() {
        _found = found;
        _looking = false;
        _lookedUp = true;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _lookupError = e;
        _looking = false;
        _lookedUp = true;
      });
    }
  }

  /// Add a database subtitle only when mpv selected none and the mode wants one.
  /// Run once per film so a manual off choice sticks.
  bool _subtitleFromDatabaseAsked = false;

  Future<void> _subtitleFromDatabase() async {
    if (_subtitleFromDatabaseAsked) return;
    _subtitleFromDatabaseAsked = true;
    final prefs = widget.preferences.current;
    if (prefs == null || _selectedSubtitle != null) return;
    final languages = widget.preferences.languages;
    // A title-specific subtitle choice overrides the general mode.
    final picked = _choice?.subtitle;
    if (picked?.off ?? false) return;
    final wanted = [
      if (picked != null && picked.language.isNotEmpty)
        languages.canonical(picked.language),
      if (prefs.subtitleMode != 'manual') ...prefs.subtitleLanguages,
    ];
    if (wanted.isEmpty) return;
    final audio = _selectedAudio?.language ?? '';
    if (picked == null &&
        prefs.subtitleMode == 'foreign' &&
        languages.rank(audio, prefs.subtitleLanguages) >= 0) {
      return;
    }
    if (!_lookedUp) await _lookUp();
    if (!mounted || _selectedSubtitle != null) return;
    final best = _found
        .where((f) => languages.rank(f.language, wanted) >= 0)
        .firstOrNull;
    if (best == null) return;
    final url = widget.api.url(best.url);
    _ownFound = url;
    unawaited(
      _command([
        'sub-add',
        url,
        'auto',
        best.name.isEmpty ? best.label : best.name,
        best.language,
      ]),
    );
  }

  void _pickSubtitle(MpvTrack? track) {
    _closeMenu();
    _player.setSubtitleTrack(
      track == null
          ? SubtitleTrack.no()
          : SubtitleTrack(track.id, track.title, track.language),
    );
  }

  /// The core converts database subtitles to text; reuse loaded mpv tracks
  /// because mpv retains every external track added.
  void _pickFound(Subtitle found) {
    _closeMenu();
    final url = widget.api.url(found.url);
    final loaded = _subtitleTracks
        .where((t) => t.external && t.externalFilename == url)
        .firstOrNull;
    if (loaded != null) {
      _player.setSubtitleTrack(
        SubtitleTrack(loaded.id, loaded.title, loaded.language),
      );
    } else {
      _player.setSubtitleTrack(
        SubtitleTrack.uri(
          url,
          title: found.name.isEmpty ? found.label : found.name,
          language: found.language,
        ),
      );
    }
  }

  void _pickAudio(MpvTrack track) {
    _closeMenu();
    _player.setAudioTrack(AudioTrack(track.id, track.title, track.language));
  }

  /// Read back mpv properties so menu and keyboard changes persist equally.
  Future<void> _setSubtitleDelay(double seconds) =>
      _mpvSet('sub-delay', seconds.toStringAsFixed(1));

  Future<void> _setSubtitleScale(double scale) =>
      _mpvSet('sub-scale', scale.clamp(0.5, 2.0).toStringAsFixed(2));

  // mpv sub-pos above 100 pushes subtitles below the picture.
  Future<void> _setSubtitlePosition(double position) =>
      _mpvSet('sub-pos', '${position.clamp(70.0, 100.0).round()}');

  /// Stored on the pick itself: no mpv key changes it, so there is nothing
  /// to read back.
  Future<void> _setSubtitleBackground(String background) async {
    setState(() => _subtitleBackground = background);
    widget.preferences.remember('subtitleBackground', background);
    for (final property in subtitleBackgroundProperties(
      background,
      borderStyle: _borderStyle,
    ).entries) {
      await _mpvSet(property.key, property.value);
    }
  }

  Future<void> _mpvSet(String property, String value) async {
    if (_coreDead) return;
    final platform = _player.platform;
    if (platform is NativePlayer) await platform.setProperty(property, value);
  }

  /// Show fatal video failure over black; show audio failure over the picture.
  /// Decoder availability determines which recovery advice is accurate.
  Future<void> _explain(Object error) async {
    final codec = decoderErrorCodec(error);
    final sound = codec != null && await _isSoundTrack(codec);
    if (!mounted) return;
    // A network startup failure may be transient; no picture and no named
    // codec is insufficient evidence that the copy is broken.
    if (!sound && !_hasPicture && codec == null) {
      // mpv may report the same failure more than once per attempt.
      if (_reopenPending) return;
      if (_worthAnotherAttempt) {
        _openAgainLater();
        return;
      }
    }
    setState(() {
      if (sound) {
        _silent = codec;
      } else {
        _playbackError = error;
      }
    });
    if (sound || _hasPicture) _showNotice(_trouble(error, sound: sound));

    if (codec == null || _decoderAsked) return;
    _decoderAsked = true;
    await DeviceDecoders.instance.load();
    if (!mounted) return;
    final present = DeviceDecoders.instance.has(codec);
    // Unknown decoder availability must not turn advice into a claim.
    if (present == null) return;
    setState(() {
      _decoderMissing = !present;
      _decoderInstallHint = DeviceDecoders.instance.installHint(context.l10n);
    });
    if (!present && (sound || _hasPicture)) {
      _showNotice(_trouble(error, sound: sound));
    }
  }

  String _trouble(Object error, {required bool sound}) {
    final codec = decoderErrorCodec(error);
    if (codec == null) return playbackTrouble(error, context.l10n);
    final missing = _decoderMissing == true;
    return [
      missing
          ? (sound
                ? context.l10n.playerNoSoundDecoder(codec)
                : context.l10n.playerPictureDecoder(codec))
          : (sound
                ? context.l10n.playerNoSoundDecodeFailed(codec)
                : context.l10n.playerPictureDecodeFailed(codec)),
      if (missing) ?_decoderInstallHint,
    ].join(' ');
  }

  /// Wait for a picture before checking the selected decoder or warning.
  bool _decoderChecked = false;

  Future<void> _checkDecoder() async {
    if (_decoderChecked) return;
    _decoderChecked = true;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await DeviceDecoders.instance.load();
      final format = await (await _hostReady)?.get('video-format');
      if (format == null) return;
      final broken = DeviceDecoders.instance.unreliable(format);
      if (broken != null && mounted) _showNotice(broken.sentence(context.l10n));
    } on Object catch (_) {}
  }

  Future<void> _readShortcuts() async {
    if (_shortcuts != null) return;
    final read = MpvBinding.parse(
      await (await _hostReady)?.get('input-bindings') ?? '',
    );
    if (!mounted) return;
    setState(() => _shortcuts = shortcuts(read, context.l10n));
  }

  /// A failed audio decoder remains identifiable in mpv's track list;
  /// fall back to media_kit when mpv has no matching track.
  Future<bool> _isSoundTrack(String codec) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        final type = trackTypeFor(
          await (await _hostReady)?.get('track-list') ?? '',
          codec,
        );
        if (type != null) return type == 'audio';
      } on Object catch (_) {}
    }
    final wanted = codec.toLowerCase();
    final tracks = _player.state.tracks;
    if (tracks.video.any((t) => t.codec?.toLowerCase() == wanted)) return false;
    return tracks.audio.any((t) => t.codec?.toLowerCase() == wanted);
  }

  /// Forward keydown and keyup so mpv controls repeat behavior.
  /// Drop Flutter repeats to avoid repeating keys mpv would not.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      final name = _held.remove(event.physicalKey);
      if (name != null) unawaited(_command(['keyup', name]));
      return name == null ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final name = mpvKeyName(event, _boundKeys);
    if (name == null) return KeyEventResult.ignored;
    _held[event.physicalKey] = name;
    unawaited(_command(['keydown', name]));
    return KeyEventResult.handled;
  }

  /// Release all mpv keys when focus leaves to avoid stuck repeats.
  void _releaseKeys() {
    if (_held.isEmpty) return;
    _held.clear();
    // The empty name is "release all"; an omitted one reaches mpv 0.41's
    // cmd_key as NULL and crashes it (seen on Ctrl+V with the console open).
    unawaited(_command(['keyup', '']));
  }

  /// The wheel is mpv's over the picture only; over a panel or the bar it
  /// never reaches here, because the Stack hits only the topmost layer.
  void _onScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_hasPicture) return;
    final delta = event.scrollDelta;
    final String key;
    if (delta.dy.abs() >= delta.dx.abs()) {
      if (delta.dy == 0) return;
      key = delta.dy < 0 ? 'WHEEL_UP' : 'WHEEL_DOWN';
    } else {
      key = delta.dx < 0 ? 'WHEEL_LEFT' : 'WHEEL_RIGHT';
    }
    final modifiers = HardwareKeyboard.instance;
    final prefix = StringBuffer();
    if (modifiers.isControlPressed) prefix.write('Ctrl+');
    if (modifiers.isAltPressed) prefix.write('Alt+');
    if (modifiers.isShiftPressed) prefix.write('Shift+');
    unawaited(_command(['keypress', '$prefix$key']));
  }

  Widget? _menuWidget() {
    switch (_menu) {
      case PlayerMenu.none:
        return null;
      case PlayerMenu.episodes:
        return null;
      case PlayerMenu.download:
        final download = _download;
        if (download == null) return null;
        final next = _next;
        final playing = _sources?.sources
            ?.where(
              (s) => s.rawName == download.name || s.filename == download.name,
            )
            .firstOrNull;
        return DownloadPanel(
          download: download,
          source: playing == null
              ? ''
              : SettingsMenu.sourceLabel(playing, context.l10n),
          onSource: download.itemId.isEmpty
              ? null
              : () {
                  _openMenu(PlayerMenu.settings);
                  setState(() => _settingsPage = 'Source');
                },
          next: next == null || next.isUpcoming ? null : next,
          nextDownload: _nextDownload,
          nextFetch:
              _nextFetch == NextFetch.waiting &&
                  widget.preferences.current?.prefetch == false
              ? NextFetch.off
              : _nextFetch,
          onDownloadNext: () => unawaited(_downloadNext()),
          onStorage: () {
            _close();
            widget.onStorage();
          },
        );
      case PlayerMenu.tracks:
        return TracksMenu(
          audio: _audioTracks,
          subtitles: _subtitleTracks,
          found: _found,
          languages: widget.preferences.languages,
          preferredSubtitles:
              widget.preferences.current?.subtitleLanguages ?? const [],
          looking: _looking,
          error: _lookupError,
          delay: _subtitleDelay,
          scale: _subtitleScale,
          position: _subtitlePosition,
          url: widget.api.url,
          onAudio: _pickAudio,
          onSubtitle: _pickSubtitle,
          onFound: _pickFound,
          onRetry: _lookUp,
          onDelay: _setSubtitleDelay,
          onScale: _setSubtitleScale,
          onPosition: _setSubtitlePosition,
          background: _subtitleBackground,
          onBackground: _setSubtitleBackground,
        );
      case PlayerMenu.settings:
        return SettingsMenu(
          page: _settingsPage,
          sources: _sources,
          current: _download?.name ?? '',
          onSource: _pickSource,
          rate: _rate,
          fit: _fit,
          chapters: _chapters,
          chapter: _chapter,
          onRate: _setRate,
          onFit: (i) => setState(() => _fit = i),
          onChapter: (i) => unawaited(_mpvSet('chapter', '$i')),
          shortcuts: _shortcuts,
          hardware: _hardware,
          decoding: _decoding,
          onDecoding: (value) => unawaited(_mpvSet('hwdec', value)),
          onShortcuts: () => unawaited(_readShortcuts()),
          onStats: () {
            _closeMenu();
            unawaited(
              _command(['script-binding', 'stats/display-stats-toggle']),
            );
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = ChromeModel(
      title: _title.replaceFirst(RegExp(r' · S\d+E\d+$'), ''),
      episodeTitle: _download != null && _download!.episode > 0
          ? (_episodeTitle.isEmpty
                ? context.l10n.playerEpisodeId(
                    _download!.season,
                    _download!.episode,
                  )
                : context.l10n.playerEpisodeTitle(
                    _download!.season,
                    _download!.episode,
                    _episodeTitle,
                  ))
          : '',
      download: _download,
      position: _position,
      duration: _duration,
      chapters: _chapters,
      playing: _playing,
      volume: _volume,
      muted: _muted,
      fullscreen: _fullscreen,
      subtitlesOn: _subtitlesShown && _selectedSubtitle != null,
      menu: _menu,
      hasNext: _next != null,
    );
    final actions = ChromeActions(
      close: _close,
      togglePlay: _togglePlay,
      scrub: _scrubTo,
      seek: _seekTo,
      startScrub: _startScrub,
      endScrub: _endScrub,
      nextEpisode: _next == null ? null : () => unawaited(_advance()),
      episodes: _download != null && _download!.episode > 0
          ? () => _openMenu(PlayerMenu.episodes)
          : null,
      setVolume: _setVolume,
      toggleMute: _toggleMute,
      toggleFullscreen: _toggleFullscreen,
      openMenu: _openMenu,
      closeMenu: _closeMenu,
      hoverBar: (over) {
        _overBar = over;
        _restartIdle();
      },
    );

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      onFocusChange: (focused) {
        if (!focused) _releaseKeys();
      },
      child: Listener(
        onPointerDown: (_) => _mouseDown = true,
        onPointerUp: (_) => _release(),
        onPointerCancel: (_) => _release(),
        child: MouseRegion(
          onHover: (_) => _restartIdle(),
          cursor: _chrome ? SystemMouseCursors.basic : SystemMouseCursors.none,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // A listener forwards presses immediately; a gesture recognizer
                // delays them while resolving Flutter's gesture arena.
                LayoutBuilder(
                  builder: (context, constraints) => Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerSignal: _onScroll,
                    onPointerDown: _onPictureButtons,
                    onPointerMove: (event) {
                      _pictureMotion(event, constraints.biggest);
                      _onPictureButtons(event);
                    },
                    onPointerHover: (event) =>
                        _pictureMotion(event, constraints.biggest),
                    onPointerUp: _onPictureButtons,
                    onPointerCancel: _onPictureButtons,
                    child: Video(
                      controller: _video,
                      controls: NoVideoControls,
                      fit: _fits[_fit],
                      fill: Colors.black,
                      // mpv already renders subtitles; Flutter would draw them twice.
                      subtitleViewConfiguration:
                          const SubtitleViewConfiguration(visible: false),
                    ),
                  ),
                ),
                // mpv can report playing before any decodable frame arrives.
                // Dim artwork under the wait so it cannot look like a frozen frame.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _hasPicture || widget.background.isEmpty
                      ? const SizedBox.shrink()
                      : PlayerBackdrop(url: widget.background),
                ),
                if (!_hasPicture || _advancing)
                  PlayerWaiting(
                    title: switch ((_switchingTo, _download)) {
                      (final Episode e?, _) => e.fullLabel(context.l10n),
                      (_, final Download d?) when d.episode > 0 => episodeName(
                        d.episode,
                        _episodeTitle,
                        context.l10n,
                      ),
                      _ => _title,
                    },
                    percent:
                        _advancing ||
                            (_download?.isDone ?? false) ||
                            (_download?.progress.total ?? 0) <= 0
                        ? null
                        : _download!.progress.fraction,
                    error: _error,
                    choiceError: _advancing ? _switch?.error : null,
                    choiceEmpty:
                        _advancing && (_switch?.sources?.isEmpty ?? false),
                    overPicture: _advancing && _hasPicture,
                    playbackError: _playbackError,
                    decoderMissing: _decoderMissing,
                    decoderInstallHint: _decoderInstallHint,
                    onRetry: _advancing ? _retrySwitch : _retry,
                    onBack: _close,
                    showBack: !_chrome,
                  ),
                if (_buffering && _hasPicture && !_advancing)
                  const Center(child: Loading()),
                if (_notice != null)
                  Positioned(
                    top: 84,
                    left: 0,
                    right: 0,
                    child: Center(child: PlayerNotice(text: _notice!)),
                  ),
                AnimatedOpacity(
                  opacity: _chrome ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_chrome,
                    // Keep chrome up while the pointer is on the bar itself.
                    child: PlayerChrome(
                      model: model,
                      actions: actions,
                      menu: _menuWidget(),
                      thumbnails: _thumbnails,
                      episodesPanel: _item == null || _download == null
                          ? null
                          : EpisodesPanel(
                              artwork: _artwork,
                              frameOf: _frameOf,
                              episodes: _item!.episodes,
                              currentSeason: _download!.season,
                              currentEpisode: _download!.episode,
                              progress: _episodeProgress,
                              runtime: _item!.runtime,
                              onPlay: _startEpisode,
                            ),
                    ),
                  ),
                ),
                // Keep the skip button available after chrome fades.
                if (_skip() case final pill?)
                  Positioned(
                    right: pill is NextEpisodeCard ? 24 : chromeBandInset,
                    bottom: pill is NextEpisodeCard ? 96 : chromeBottomBand,
                    child: pill,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
