import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../platform/window.dart';
import '../theme.dart';
import 'search_box.dart';
import 'window_controls.dart';

/// Where the window can go.
enum AppTab { home, library, settings }

/// The chrome that stays, and the only bar the window has: the runner hides
/// the desktop's title bar, so the window buttons and the drag areas live
/// here.
///
/// No edge or fill of its own: over artwork it is nothing, and once the page
/// scrolls under it the ground arrives as a wash that fades downwards.
///
/// Three zones held apart by a [Stack], not a [Row], so no zone moves when
/// another changes width: the middle is centred on the window and the ends
/// are pinned to its edges.
class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.scrolled,
    required this.api,
    required this.tab,
    required this.onTab,
    required this.searchController,
    required this.downloads,
    required this.onSearch,
    required this.onOpenItem,
  });

  final ValueListenable<bool> scrolled;
  final LumeoApi api;

  /// Which tab is lit: the part of the app the window is in, not how deep it
  /// has gone. A title or a search opened from Home is still Home.
  final AppTab tab;
  final void Function(AppTab) onTab;

  /// Held by the shell, which handles Ctrl+F.
  final SearchController searchController;

  /// The downloads indicator, built by the shell that owns what its rows
  /// open.
  final Widget downloads;
  final void Function(String) onSearch;
  final void Function(MediaItem) onOpenItem;

  static const height = 68.0;

  /// What the middle is worth, which is also the width of the search panel:
  /// a title and its year at reading size, never reaching the wordmark or the
  /// window buttons.
  static double centreWidth(double window) =>
      min(560, max(300, window - 2 * 240));

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: scrolled,
      builder: (context, scrolled, controls) => AnimatedContainer(
        duration: Motion.wash,
        height: height,
        decoration: BoxDecoration(
          // Opaque where the type sits, gone by the bottom edge; the wash gives way
          // only below the tabs and window buttons.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: scrolled
                ? [
                    Palette.ground(0.95),
                    Palette.ground(0.90),
                    Palette.ground(0),
                  ]
                : [Palette.ground(0), Palette.ground(0), Palette.ground(0)],
            stops: const [0, 0.72, 1],
          ),
        ),
        child: controls,
      ),
      child: Stack(
        children: [
          // Everything in the bar that is not a control is title bar: drag moves the
          // window, double click maximises. It is the bottom of the stack, so only the
          // gaps between controls drag.
          const Positioned.fill(child: WindowDragArea()),
          // Tighter on the right than on the left: the window buttons belong to
          // the window's edge, the wordmark to the page's margin.
          Positioned(
            left: 48,
            top: 0,
            bottom: 0,
            child: Center(child: _Wordmark(onTap: () => onTab(AppTab.home))),
          ),
          Positioned.fill(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) => SizedBox(
                  width: centreWidth(constraints.maxWidth),
                  // The panel opens out of this box rather than out of the bar:
                  // see [SearchNav.fieldHeight].
                  height: SearchNav.fieldHeight,
                  child: SearchNav(
                    api: api,
                    controller: searchController,
                    width: centreWidth(constraints.maxWidth),
                    onSubmit: onSearch,
                    onOpen: onOpenItem,
                    // Centred inside the anchor, which is as wide as the panel and so much
                    // wider than the tabs.
                    child: Center(
                      child: _Tabs(
                        tab: tab,
                        onTab: onTab,
                        onSearch: searchController.openView,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 14,
            top: 0,
            bottom: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  downloads,
                  // No window buttons in fullscreen: nothing to minimise or maximise.
                  ListenableBuilder(
                    listenable: AppWindow.instance,
                    builder: (context, _) => AppWindow.instance.fullscreen
                        ? const SizedBox(width: 20)
                        : const Padding(
                            padding: EdgeInsets.only(left: 10),
                            child: WindowControls(),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The middle of the bar at rest: the way to search, and the places to be.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.tab, required this.onTab, required this.onSearch});

  final AppTab tab;
  final void Function(AppTab) onTab;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onSearch,
          // Icons.search, not a shape variant: the rounded and outlined sets are not
          // in the icon font Flutter ships.
          icon: const Icon(Icons.search, size: 19),
          tooltip: context.l10n.searchShortcutTooltip,
          color: Palette.dim,
          hoverColor: Palette.hover,
          style: IconButton.styleFrom(
            fixedSize: const Size.square(34),
            padding: EdgeInsets.zero,
            shape: const StadiumBorder(),
            // Without it the button keeps Material's 48 point touch target, taller than
            // the 42 point field.
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 6),
        PillTab(
          label: context.l10n.homeTitle,
          selected: tab == AppTab.home,
          onTap: () => onTab(AppTab.home),
        ),
        PillTab(
          label: context.l10n.libraryTitle,
          selected: tab == AppTab.library,
          onTap: () => onTab(AppTab.library),
        ),
        PillTab(
          label: context.l10n.settingsTitle,
          selected: tab == AppTab.settings,
          onTap: () => onTab(AppTab.settings),
        ),
      ],
    );
  }
}

/// A place, not an action: lit when the window is there. The bar's tabs,
/// and places within a page (My list and History in the library). A
/// [TextButton] for the pointer, states, focus ring, keys and tab order.
class PillTab extends StatelessWidget {
  const PillTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: selected ? Palette.text : Palette.dim,
        // A tint rather than a surface: a solid pill on a dark frame is a hole.
        backgroundColor: selected ? Palette.tint : Colors.transparent,
        // The hover, the press and the focus ring are one property on a
        // TextButton, and it is the tint the pill already uses.
        overlayColor: Palette.hover,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: Typo.cardTitle.copyWith(letterSpacing: 0.1),
      ),
      child: Text(label, style: const TextStyle(shadows: _overArt)),
    );
  }
}

/// Type over a frame we do not control keeps a shadow under it, or the bar
/// disappears into a bright banner.
const _overArt = [Shadow(color: Color(0xCC000000), blurRadius: 16)];

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: const Text(
          'LUMEO',
          style: TextStyle(
            fontFamily: Typo.wordmark,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 4,
            color: Palette.text,
            shadows: _overArt,
          ),
        ),
      ),
    );
  }
}
