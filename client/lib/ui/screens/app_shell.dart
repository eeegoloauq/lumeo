import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../../api/preferences_store.dart';
import '../../l10n/l10n.dart';
import '../../platform/folders.dart';
import '../../platform/local_file.dart';
import '../../platform/local_settings.dart';
import '../../platform/release_notes.dart';
import '../../platform/window.dart';
import '../player/episode_frames.dart';
import '../player/player_screen.dart';
import '../widgets/downloads_indicator.dart';
import '../widgets/top_bar.dart';
import '../widgets/release_notes_card.dart';
import 'home_screen.dart';
import 'item_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'settings/settings_screen.dart';

/// What the shell shows for a film. Widget tests put a stand-in here: the real
/// screen needs libmpv and a GPU texture, which only the UI suite on Weston has.
@visibleForTesting
Widget Function(PlayerScreen screen) playerLayer = (screen) => screen;

/// Everything the window holds: one bar that stays, and a page under it.
///
/// Navigation is a stack of our own rather than a Navigator with routes: the
/// bar floats over every page, and a route pushed over it would cover it or
/// make every screen draw its own copy.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.api,
    required this.downloads,
    required this.frames,
    required this.settings,
    required this.preferences,
    this.open,
  });

  final LumeoApi api;
  final DownloadsStore downloads;
  final EpisodeFrames frames;
  final LocalSettings settings;
  final PreferencesStore preferences;

  /// A local file to play at once.
  final String? open;

  @override
  State<AppShell> createState() => _AppShellState();
}

/// How long closing a newer release's notice keeps the next ones away.
const updateQuiet = Duration(days: 7);

class _AppShellState extends State<AppShell> {
  final _scroll = ScrollController();

  /// Ctrl+F lands here. Owned by the shell, not the bar: the bar is rebuilt as
  /// pages come and go, and search opens as a panel the key has to open.
  final _search = SearchController();

  /// Where the keyboard lives when nothing else has asked for it: the bottom
  /// of the climb key events make, so the shell's shortcuts are reachable.
  final _shellFocus = FocusNode(debugLabel: 'shell');

  /// Stops "Open with Lumeo" from a later launch reaching this shell.
  late final void Function() _stopOpening;

  final _history = <_Page>[const _Page.home()];
  // A notifier rather than state: crossing the threshold changes only the
  // bar's ground, and a setState would rebuild the whole page under it.
  final _scrolled = ValueNotifier(false);
  _Playing? _playing;
  // This release's notes, and what the viewer has not been told since the
  // version they last saw: every release they skipped.
  List<String> _notes = const [];
  List<String> _news = const [];
  // The betas before this release told the viewer its news already.
  bool _newsTold = false;
  String? _notesLanguage;
  // A newer release, and its notes since this one in the interface language.
  CoreUpdate? _update;
  List<String> _updateNotes = const [];

  _Page get _page => _history.last;

  @override
  void initState() {
    super.initState();
    // A first run has nothing to compare with: its notes are not news.
    widget.settings.lastSeenVersion ??= appVersion;
    // Whenever the keyboard ends up on the floor, the shell picks it up.
    // autofocus below fires once; later the focus can empty when the desktop
    // focuses the window a beat after it opens, or the focused widget is
    // unmounted by the navigation it caused, and then no shortcut answers.
    FocusManager.instance.addListener(_keyboardOnTheFloor);
    widget.settings.addListener(_configureBackground);
    if (widget.open case final path?) unawaited(_openFile(path));
    unawaited(_checkForUpdate());
    _stopOpening = onFileOpened((path) => unawaited(_openFile(path)));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configureBackground();
    final language = Localizations.localeOf(context).languageCode;
    if (_notesLanguage == language) return;
    _notesLanguage = language;
    if (_update case final update?) _updateNotes = _notesOf(update);
    final seen = widget.settings.lastSeenVersion ?? appVersion;
    ReleaseNotes.bundled().then((source) {
      if (!mounted) return;
      setState(() {
        _notes = ReleaseNotes.parse(source, appVersion, language);
        _news = seen == appVersion
            ? const []
            : ReleaseNotes.between(source, seen, appVersion, language);
        _newsTold = ReleaseNotes.toldInBetas(seen, appVersion);
      });
    });
  }

  /// A failed check is no news: the core logs why.
  Future<void> _checkForUpdate() async {
    try {
      final update = await widget.api.update();
      if (!mounted || update == null) return;
      final settings = widget.settings;
      if (update.version == settings.dismissedUpdate) return;
      // A closed notice keeps the next ones quiet for a while: releases can
      // come several a day, and one reminder a week is enough.
      if (settings.updateDismissedAt case final at?
          when DateTime.now().difference(at) < updateQuiet) {
        return;
      }
      setState(() {
        _update = update;
        _updateNotes = _notesOf(update);
      });
    } on Object catch (_) {}
  }

  List<String> _notesOf(CoreUpdate update) => ReleaseNotes.between(
    update.notes,
    appVersion,
    update.version,
    _notesLanguage ?? 'en',
  );

  /// A newer release comes before the notes of this one: it is the news
  /// that asks for something, and it covers the update the viewer is on.
  Widget? _releaseCard() {
    final l10n = context.l10n;
    void seen() {
      widget.settings.lastSeenVersion = appVersion;
      _news = const [];
    }

    if (_update case final update?) {
      void dismiss() => setState(() {
        widget.settings
          ..dismissedUpdate = update.version
          ..updateDismissedAt = DateTime.now();
        _update = null;
        seen();
      });
      return ReleaseNotesCard(
        title: l10n.releaseAvailable(update.version),
        items: _updateNotes,
        action: l10n.releaseDownload,
        onAction: () {
          unawaited(openUrl(update.url));
          dismiss();
        },
        onClose: dismiss,
      );
    }
    if (_news.isNotEmpty) {
      return ReleaseNotesCard(
        title: l10n.releaseUpdatedTo(appVersion),
        items: _news,
        // Offered before it was installed, or told beta by beta: the list
        // was read then.
        collapsed: _newsTold || widget.settings.dismissedUpdate == appVersion,
        action: l10n.releaseGotIt,
        onAction: () => setState(seen),
        onClose: () => setState(seen),
      );
    }
    return null;
  }

  /// "Open with Lumeo": the core makes the file a download, and from there it
  /// plays like any other, under the title the core named it as, if any.
  Future<void> _openFile(String path) async {
    final name = Uri.file(path).pathSegments.last;
    try {
      final download = await widget.api.openLocal(path);
      var title = name;
      if (download.itemId.isNotEmpty) {
        try {
          final item = await widget.api.item(download.itemId);
          title = item.title;
        } on Object catch (_) {
          // Not a catalogue title: the file plays under its own name.
        }
      }
      if (mounted) _play(download.id, title);
    } on Object catch (error) {
      if (!mounted) return;
      final reason = error is LumeoApiException ? error.message : '$error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.commonCouldNotOpen(name, reason))),
      );
    }
  }

  void _keyboardOnTheFloor() {
    // Not while a film is up: the player is not built inside this Focus, and
    // it owns the keyboard for as long as it is on screen.
    if (!mounted || _playing != null) return;
    // Nor while a dialog or drawer is over the page: its own scope holding the
    // focus is where the keyboard belongs, and Escape there closes it.
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final focus = FocusManager.instance.primaryFocus;
    // A scope rather than a node means the focus is nowhere in particular:
    // the root scope is where it lands when whatever held it went away.
    if (focus == null || focus is FocusScopeNode) _shellFocus.requestFocus();
  }

  (bool, bool, String)? _backgroundSent;

  /// The runner keeps the settings and the words for the tray and the
  /// notification; sent again only when one of them changed, since the
  /// settings notify on every volume step.
  void _configureBackground() {
    final settings = widget.settings;
    final l10n = context.l10n;
    final sent = (settings.background, settings.autostart, l10n.localeName);
    if (sent == _backgroundSent) return;
    _backgroundSent = sent;
    unawaited(
      AppWindow.instance.configureBackground(
        enabled: settings.background,
        autostart: settings.autostart,
        open: l10n.backgroundOpen,
        quit: l10n.backgroundQuit,
        running: l10n.backgroundRunning,
        runningBody: l10n.backgroundRunningBody,
      ),
    );
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_keyboardOnTheFloor);
    widget.settings.removeListener(_configureBackground);
    _stopOpening();
    _scroll.dispose();
    _search.dispose();
    _shellFocus.dispose();
    _scrolled.dispose();
    super.dispose();
  }

  /// Whether the page has moved under the bar, which gives the bar its
  /// ground. Read from the scroll itself: our controller refuses its offset
  /// while two pages are attached during a page change. A shelf dragged
  /// sideways is not the page scrolling.
  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    _scrolled.value = notification.metrics.pixels > 12;
    return false;
  }

  /// After the tree has been rebuilt, not during: the widget that had the
  /// focus is still there while this frame is being built.
  void _takeKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _shellFocus.requestFocus();
    });
  }

  void _go(_Page page) {
    setState(() {
      _history.add(page);
      _scrolled.value = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _takeKeyboard();
  }

  /// The wordmark: Home is the whole stack, not the bottom of it.
  void _home() {
    if (_history.length == 1) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      return;
    }
    setState(() {
      _history
        ..clear()
        ..add(const _Page.home());
      _scrolled.value = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _takeKeyboard();
  }

  /// Home clears the stack the way the wordmark does; Library and Settings
  /// are pushed so back returns to whatever was being looked at. A tab already
  /// in the stack is gone back to rather than pushed again.
  void _tab(AppTab tab) {
    switch (tab) {
      case AppTab.home:
        _home();
      case AppTab.library:
        _place(_PageKind.library, const _Page.library());
      case AppTab.settings:
        _place(_PageKind.settings, const _Page.settings());
    }
  }

  /// Bumped to scroll a settings page that is already open to a section.
  int _settingsRequest = 0;

  /// Settings, scrolled to [section]; a Settings already in the history is
  /// gone back to rather than opened twice.
  void openSettings({SettingsSection? section}) {
    final at = _history.lastIndexWhere((p) => p.kind == _PageKind.settings);
    if (at < 0) {
      _go(_Page.settings(section));
      return;
    }
    setState(() {
      _history
        ..removeRange(at, _history.length)
        ..add(_Page.settings(section));
      _settingsRequest++;
      _scrolled.value = false;
    });
    _takeKeyboard();
  }

  void _place(_PageKind kind, _Page page) {
    final at = _history.lastIndexWhere((p) => p.kind == kind);
    if (at == _history.length - 1) return;
    if (at < 0) {
      _go(page);
      return;
    }
    setState(() {
      _history.removeRange(at + 1, _history.length);
      _scrolled.value = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _takeKeyboard();
  }

  /// Which tab is lit: the place the pages on top were opened from. A title
  /// opened from the library is still the library, and one opened from a
  /// search on the home screen is still home.
  AppTab get _lit {
    for (final page in _history.reversed) {
      switch (page.kind) {
        case _PageKind.home:
          return AppTab.home;
        case _PageKind.library:
          return AppTab.library;
        case _PageKind.settings:
          return AppTab.settings;
        case _PageKind.item || _PageKind.search:
          continue;
      }
    }
    return AppTab.home;
  }

  /// Back lands at the top of the page it returns to: the pages share one
  /// ScrollController, so the one coming back is built from scratch.
  void _back() {
    if (_history.length < 2) return;
    setState(() {
      _history.removeLast();
      _scrolled.value = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _takeKeyboard();
  }

  void _play(String downloadId, String title) {
    setState(() {
      // Play from the banner is a one-off, or coming back out of the film would
      // start it again.
      if (_page.kind == _PageKind.item && _page.autoplay) {
        _history[_history.length - 1] = _Page.item(
          _page.value,
          episode: _page.episode,
        );
      }
      _playing = _Playing(
        downloadId,
        title,
        wasFullscreen: AppWindow.instance.fullscreen,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // The player is a layer over the whole window, not a page: it has no bar,
    // no scroll and nothing else on screen with it.
    if (_playing != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: playerLayer(
          PlayerScreen(
            key: ValueKey('player:${_playing!.downloadId}'),
            api: widget.api,
            downloads: widget.downloads,
            frames: widget.frames,
            download: _playing!.downloadId,
            title: _playing!.title,
            settings: widget.settings,
            preferences: widget.preferences,
            continuing: _playing!.continuing,
            onClose: () {
              final playing = _playing!;
              setState(() => _playing = null);
              // The window goes back the way the film found it. Held here, not in the
              // screen, which is rebuilt for every episode.
              AppWindow.instance.setFullscreen(playing.wasFullscreen);
              _takeKeyboard();
            },
            // Runs after onClose, which the player calls first.
            onStorage: () => openSettings(section: SettingsSection.downloads),
            // The next episode is a screen of its own, keyed to its own download:
            // media_kit's open() resets the player anyway, and the old screen's state
            // (down to the position it was about to report) belongs to the old file.
            onNext: (downloadId, title) {
              // The film may already have been left while the next episode was found.
              final playing = _playing;
              if (playing == null) return;
              setState(() => _playing = playing.then(downloadId, title));
            },
          ),
        ),
      );
    }
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.f11): _ToggleFullscreenIntent(),
        // Escape means back, and only back: fullscreen has F11. Not bare
        // Backspace: a binding here is closer to the focus than MaterialApp's
        // DefaultTextEditingShortcuts, so the search field would stop deleting.
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FocusSearchIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _BackIntent(),
        // Quit, which closing is not while the app runs in the background.
        SingleActivator(LogicalKeyboardKey.keyQ, control: true): _QuitIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _BackIntent(),
        SingleActivator(LogicalKeyboardKey.browserBack): _BackIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ToggleFullscreenIntent: CallbackAction<_ToggleFullscreenIntent>(
            onInvoke: (_) => AppWindow.instance.toggleFullscreen(),
          ),
          _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
            onInvoke: (_) {
              if (!_search.isOpen) _search.openView();
              return null;
            },
          ),
          _QuitIntent: CallbackAction<_QuitIntent>(
            onInvoke: (_) => AppWindow.instance.quit(),
          ),
          _BackIntent: CallbackAction<_BackIntent>(
            onInvoke: (_) {
              _back();
              return null;
            },
          ),
        },
        // Something inside has to hold the focus or the shortcuts above never see a
        // key; there is no Navigator to seed it. Not a tab stop of its own.
        child: Focus(
          focusNode: _shellFocus,
          autofocus: true,
          skipTraversal: true,
          child: Listener(
            // The mouse's back button.
            onPointerDown: (event) {
              if (event.buttons & kBackMouseButton != 0) _back();
            },
            child: Scaffold(
              body: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: PrimaryScrollController(
                        controller: _scroll,
                        // Every platform: a vertical ScrollView adopts the primary controller by
                        // itself only on phones.
                        automaticallyInheritForPlatforms: TargetPlatform.values
                            .toSet(),
                        child: switch (_page.kind) {
                          _PageKind.home => HomeScreen(
                            key: const ValueKey('home'),
                            api: widget.api,
                            downloads: widget.downloads,
                            onOpen: (item) => _go(_Page.item(item.id)),
                            onPlay: (item) =>
                                _go(_Page.item(item.id, autoplay: true)),
                          ),
                          _PageKind.item => ItemScreen(
                            key: ValueKey(
                              'item:${_page.value}:${_page.episode}',
                            ),
                            itemId: _page.value,
                            api: widget.api,
                            downloads: widget.downloads,
                            frames: widget.frames,
                            preferences: widget.preferences,
                            autoplay: _page.autoplay,
                            episode: _page.episode,
                            onPlay: _play,
                            onAddSource: () =>
                                openSettings(section: SettingsSection.sources),
                          ),
                          _PageKind.search => SearchScreen(
                            key: ValueKey('search:${_page.value}'),
                            query: _page.value,
                            api: widget.api,
                            downloads: widget.downloads,
                            onOpen: (item) => _go(_Page.item(item.id)),
                          ),
                          _PageKind.library => LibraryScreen(
                            key: const ValueKey('library'),
                            api: widget.api,
                            downloads: widget.downloads,
                            preferences: widget.preferences,
                            frames: widget.frames,
                            settings: widget.settings,
                            onOpen: (item, {season, episode}) => _go(
                              _Page.item(
                                item.id,
                                episode: season == null || episode == null
                                    ? null
                                    : (season: season, episode: episode),
                              ),
                            ),
                          ),
                          _PageKind.settings => SettingsScreen(
                            key: const ValueKey('settings'),
                            section: _page.section,
                            request: _settingsRequest,
                            api: widget.api,
                            downloads: widget.downloads,
                            preferences: widget.preferences,
                            settings: widget.settings,
                            notes: _notes,
                          ),
                        },
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: TopBar(
                        api: widget.api,
                        searchController: _search,
                        tab: _lit,
                        onTab: _tab,
                        // Every page starts under artwork or its own top margin, so the bar is
                        // transparent at the top of all of them.
                        scrolled: _scrolled,
                        downloads: DownloadsIndicator(
                          api: widget.api,
                          store: widget.downloads,
                          settings: widget.settings,
                          preferences: widget.preferences,
                          onStop: _stop,
                          onOpen: (d) {
                            if (d.itemId.isNotEmpty) _go(_Page.item(d.itemId));
                          },
                          onPlay: _playDownload,
                          onStorage: () =>
                              openSettings(section: SettingsSection.downloads),
                        ),
                        onSearch: (q) {
                          if (q.trim().isEmpty) return;
                          _go(_Page.search(q.trim()));
                        },
                        onOpenItem: (item) => _go(_Page.item(item.id)),
                      ),
                    ),
                    // Spans the height so a long card is held to the window
                    // and scrolls, rather than running off its top.
                    if (_releaseCard() case final card?)
                      Positioned(
                        top: 24,
                        right: 24,
                        bottom: 24,
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: card,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A row of the downloads panel, played under the name its title page
  /// would have given it.
  void _playDownload(Download d) {
    final item = widget.downloads.itemOf(d);
    var title = item?.title ?? d.name;
    if (d.episode > 0) {
      final s = NumberFormat('00', context.l10n.localeName).format(d.season);
      final e = NumberFormat('00', context.l10n.localeName).format(d.episode);
      title = context.l10n.itemPlaybackTitle(title, s, e);
    }
    _play(d.id, title);
  }

  Future<void> _stop(Download download) async {
    // Gone from the list before the request is sent, so the click visibly
    // lands.
    widget.downloads.forget(download.id);
    try {
      await widget.api.stopDownload(download.id);
    } on Object catch (_) {
      // The next poll shows whether it actually went.
    }
  }
}

class _ToggleFullscreenIntent extends Intent {
  const _ToggleFullscreenIntent();
}

class _QuitIntent extends Intent {
  const _QuitIntent();
}

class _BackIntent extends Intent {
  const _BackIntent();
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

/// One sitting in front of one title: the episode on screen now, and the two
/// things that outlive it.
class _Playing {
  const _Playing(
    this.downloadId,
    this.title, {
    required this.wasFullscreen,
    this.continuing = false,
  });

  final String downloadId;
  final String title;

  /// How the window stood when the sitting began, to be put back when it
  /// ends. It belongs to the sitting rather than to any one episode's screen.
  final bool wasFullscreen;

  /// Whether the episode on screen followed another one. The window is the
  /// film's already by then, so it is not taken a second time.
  final bool continuing;

  _Playing then(String downloadId, String title) => _Playing(
    downloadId,
    title,
    wasFullscreen: wasFullscreen,
    continuing: true,
  );
}

enum _PageKind { home, item, search, library, settings }

class _Page {
  const _Page.home()
    : kind = _PageKind.home,
      value = '',
      autoplay = false,
      episode = null,
      section = null;
  const _Page.item(this.value, {this.autoplay = false, this.episode})
    : kind = _PageKind.item,
      section = null;
  const _Page.search(this.value)
    : kind = _PageKind.search,
      autoplay = false,
      episode = null,
      section = null;
  const _Page.library()
    : kind = _PageKind.library,
      value = '',
      autoplay = false,
      episode = null,
      section = null;
  const _Page.settings([this.section])
    : kind = _PageKind.settings,
      value = '',
      autoplay = false,
      episode = null;

  final _PageKind kind;
  final String value;

  /// Where a settings page opens; its top when null.
  final SettingsSection? section;

  /// Set when the page was opened by Play rather than by a poster.
  final bool autoplay;

  /// The episode a title page opens on, when it was opened for one.
  final ({int season, int episode})? episode;
}
