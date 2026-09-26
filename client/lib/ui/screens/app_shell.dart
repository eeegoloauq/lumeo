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
import '../../platform/local_file.dart';
import '../../platform/local_settings.dart';
import '../../platform/window.dart';
import '../player/episode_frames.dart';
import '../player/player_screen.dart';
import '../widgets/downloads_indicator.dart';
import '../widgets/top_bar.dart';
import 'home_screen.dart';
import 'item_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'settings/settings_screen.dart';

/// Everything the window holds: one bar that stays, and a page under it.
///
/// Navigation is a stack of our own rather than a Navigator with routes,
/// because the bar is not part of any page — it floats over the artwork, and
/// pushing a route over it would either cover it or make every screen redraw
/// its own copy. A stack of our own still has to be a stack: it was one page
/// replacing another for a while, which meant a search was gone the moment you
/// opened anything in it, and the only way out of a title was the wordmark —
/// which goes home, not back.
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

class _AppShellState extends State<AppShell> {
  final _scroll = ScrollController();

  /// Ctrl+F lands here. Owned by the shell rather than by the bar, because the
  /// key is pressed while a page has the keyboard, and the bar is rebuilt
  /// under it as pages come and go. It is a controller rather than a focus
  /// node now that the field is not always there to be focused: search opens
  /// as a panel over the tabs, and opening it is what the key has to do.
  final _search = SearchController();

  /// Where the keyboard lives when nothing else has asked for it.
  ///
  /// Keys are delivered by climbing from whatever holds the focus, and this
  /// node is the bottom of that climb — the reason the shell's own shortcuts
  /// are reachable at all. Its `autofocus` fires once, and after that the
  /// focus goes wherever the page sends it: into the search field, into a
  /// player, into a widget that is then unmounted by the very navigation it
  /// caused. When that happens the focus lands nowhere, and back, fullscreen
  /// and search all stop answering with nothing on screen to say why. So the
  /// shell takes the keyboard back whenever the page changes under it.
  final _shellFocus = FocusNode(debugLabel: 'shell');

  /// Stops "Open with Lumeo" from a later launch reaching this shell.
  late final void Function() _stopOpening;

  final _history = <_Page>[const _Page.home()];
  bool _scrolled = false;
  _Playing? _playing;

  _Page get _page => _history.last;

  @override
  void initState() {
    super.initState();
    // Whenever the keyboard ends up on the floor, the shell picks it up.
    //
    // autofocus below fires exactly once, and only if nothing holds the focus
    // in that frame. Everything else that empties it happens later: a desktop
    // that focuses the window a beat after it opens (Flutter drops the focus
    // when the view is not focused and does not put it back), a widget
    // unmounted by the navigation it caused, a menu that closed. With nothing
    // focused there is nothing for a key to climb from, so every shortcut in
    // this file goes quiet with nothing on screen to say why — which is how
    // Ctrl+F came to work only after the first click somewhere in the page.
    FocusManager.instance.addListener(_keyboardOnTheFloor);
    if (widget.open case final path?) unawaited(_openFile(path));
    _stopOpening = onFileOpened((path) => unawaited(_openFile(path)));
  }

  /// "Open with Lumeo": the core makes the file a download, and from there it
  /// plays like any other, under the title the core named it as, if any.
  Future<void> _openFile(String path) async {
    final name = Uri.file(path).pathSegments.last;
    try {
      final download = await widget.api.openLocal(path);
      var title = name, background = '';
      if (download.itemId.isNotEmpty) {
        try {
          final item = await widget.api.item(download.itemId);
          title = item.title;
          background = item.background;
        } on Object catch (_) {
          // Not a catalogue title: the file plays under its own name.
        }
      }
      if (mounted) _play(download.id, title, background);
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

  @override
  void dispose() {
    FocusManager.instance.removeListener(_keyboardOnTheFloor);
    _stopOpening();
    _scroll.dispose();
    _search.dispose();
    _shellFocus.dispose();
    super.dispose();
  }

  /// Whether the page has moved under the bar, which is what gives the bar its
  /// ground. Read from the scroll itself rather than from our controller: a
  /// controller with two positions attached — which is every frame where one
  /// page replaces another — refuses to say what its offset is, and this only
  /// ever needs to know that the page is not at the top.
  ///
  /// The horizontal rows send these too, and a shelf being dragged sideways is
  /// not the page scrolling.
  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final scrolled = notification.metrics.pixels > 12;
    if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
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
      _scrolled = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _takeKeyboard();
  }

  /// The wordmark. Home is not the bottom of the stack, it is the whole stack:
  /// clicking it means "start again", and leaving five titles behind it to walk
  /// back through would be the opposite of what it says.
  void _home() {
    if (_history.length == 1) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      return;
    }
    setState(() {
      _history
        ..clear()
        ..add(const _Page.home());
      _scrolled = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _takeKeyboard();
  }

  /// A tab is a place, and there is one of each: Home clears the stack the way
  /// the wordmark does, and Library and Settings are pushed onto it so that
  /// Escape and the mouse's back button return to whatever was being looked
  /// at. A tab already in the stack is gone back to rather than pushed again:
  /// Library pressed on a title opened from the library is the library that
  /// title came from, not a second one to walk back through.
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

  /// Settings, scrolled to [section] — from the downloads panel's Storage
  /// link, say. Like the tab, a Settings already in the history is gone back
  /// to rather than opened twice.
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
      _scrolled = false;
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
      _scrolled = false;
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

  /// Back lands at the top of the page it returns to, not where that page was
  /// left. Remembering the offset would be pointless while every page is built
  /// from scratch on the way back — they share one ScrollController, so only
  /// one of them can be mounted at a time, and the one coming back has no
  /// content yet to scroll through. Keeping them mounted is a controller each,
  /// which is a change to this whole file rather than a line here.
  void _back() {
    if (_history.length < 2) return;
    setState(() {
      _history.removeLast();
      _scrolled = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _takeKeyboard();
  }

  void _play(String downloadId, String title, String background) {
    setState(() {
      // Play from the banner is a one-off. Left set on the page it opened,
      // coming back out of the film landed on a page that started it again —
      // a loop you had to outrun with the Escape key.
      if (_page.kind == _PageKind.item && _page.autoplay) {
        _history[_history.length - 1] = _Page.item(
          _page.value,
          episode: _page.episode,
        );
      }
      _playing = _Playing(
        downloadId,
        title,
        background,
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
        body: PlayerScreen(
          key: ValueKey('player:${_playing!.downloadId}'),
          api: widget.api,
          downloads: widget.downloads,
          frames: widget.frames,
          download: _playing!.downloadId,
          title: _playing!.title,
          background: _playing!.background,
          settings: widget.settings,
          preferences: widget.preferences,
          continuing: _playing!.continuing,
          onClose: () {
            final playing = _playing!;
            setState(() => _playing = null);
            // The window goes back the way the film found it. Held here and
            // not in the screen: the screen is torn down and built again for
            // every episode, and one that handed the window back on its way
            // out dropped somebody out of fullscreen between two episodes.
            AppWindow.instance.setFullscreen(playing.wasFullscreen);
            _takeKeyboard();
          },
          // Runs after onClose, which the player calls first.
          onStorage: () => openSettings(section: SettingsSection.downloads),
          // The next episode is another film in the same sitting: a screen of
          // its own, keyed to its own download, over the same window. The
          // player cannot keep the one it has — media_kit's open() stops and
          // resets the player underneath anyway, and everything the old
          // screen had learned about the old file, down to the position it
          // was about to report, would be applied to the new one.
          onNext: (downloadId, title) {
            // The film may already have been left: Escape while the next
            // episode was being found, and the core's answer lands in the
            // frame between the sitting ending and the screen going. There
            // is nothing to carry it into then.
            final playing = _playing;
            if (playing == null) return;
            setState(() => _playing = playing.then(downloadId, title));
          },
        ),
      );
    }
    // F11 is the shortcut every desktop application has for this, and the one
    // the player already answers to under another name. Escape gives the
    // window back rather than doing nothing, which is what somebody who is
    // stuck in fullscreen will press first.
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.f11): _ToggleFullscreenIntent(),
        // Escape means back, and only back. It used to give the window back
        // from fullscreen first and go back a page on the second press, which
        // made it depend on a piece of state it could not see: the moment that
        // state was stale, Escape did nothing visible at all. Fullscreen has
        // F11, which is a key nobody presses by accident.
        // Not bare Backspace, however much of a browser habit it is:
        // DefaultTextEditingShortcuts is installed by MaterialApp, which is
        // above this, so a binding here is *closer* to the focus and wins —
        // and the search field silently stops deleting characters. Measured,
        // not guessed.
        // Ctrl+F is what every desktop application means by "find", and what
        // this window has to find with is search. The pointer was the only way
        // to the field, and the field slides along the bar as the downloads
        // indicator beside it grows and goes.
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FocusSearchIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _BackIntent(),
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
          _BackIntent: CallbackAction<_BackIntent>(
            onInvoke: (_) {
              _back();
              return null;
            },
          ),
        },
        // Something inside has to hold the focus or the shortcuts above never
        // see a key: Flutter walks key events up from whatever is focused, and
        // this application has no Navigator to seed that. Nothing had it until
        // the first click, so F11 did nothing on a window nobody had touched
        // yet. Never a tab stop of its own — it exists to be the bottom of
        // that walk, not somewhere to arrive.
        child: Focus(
          focusNode: _shellFocus,
          autofocus: true,
          skipTraversal: true,
          child: Listener(
            // The side button on a mouse. It means back everywhere else on the
            // desktop, and a media library is exactly the kind of page somebody
            // walks back out of with their thumb.
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
                        // Every platform, not the default. A vertical ScrollView
                        // adopts the primary controller by itself on phones only, so
                        // on this desktop the pages scrolled a controller of their
                        // own: ours had no positions attached at all, and the two
                        // things it exists for — the wordmark returning a scrolled
                        // page to the top, and the bar knowing it is no longer over
                        // artwork — silently did nothing.
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
                        // Every page starts under artwork or under its own top
                        // margin, so the bar is transparent at the top of all of
                        // them. It used to take its ground the moment a title page
                        // opened, which put a panel with a line under it across the
                        // top of a full-bleed banner.
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
    _play(d.id, title, item?.background ?? '');
  }

  Future<void> _stop(Download download) async {
    // Gone from the list before the request is even sent: waiting for the next
    // poll to notice made a discarded download look like a click that missed.
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
    this.title,
    this.background, {
    required this.wasFullscreen,
    this.continuing = false,
  });

  final String downloadId;
  final String title;
  final String background;

  /// How the window stood when the sitting began, to be put back when it
  /// ends. It belongs to the sitting rather than to any one episode's screen.
  final bool wasFullscreen;

  /// Whether the episode on screen followed another one. The window is the
  /// film's already by then, so it is not taken a second time.
  final bool continuing;

  _Playing then(String downloadId, String title) => _Playing(
    downloadId,
    title,
    background,
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
