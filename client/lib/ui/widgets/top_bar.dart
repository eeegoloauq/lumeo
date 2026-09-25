import 'dart:math';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../platform/window.dart';
import '../theme.dart';
import 'search_box.dart';
import 'window_controls.dart';

/// Where the window can go.
enum AppTab { home, library, settings }

/// The chrome that stays, and the only bar the window has.
///
/// It stays, because it is also the window's title bar — the runner hides the
/// desktop's, so the buttons at the right and the empty runs on either side of
/// the tabs, which drag the window, live here. A bar that scrolled away, or hid
/// itself on the way down, would take Close with it.
///
/// What it must not do is read as a separate slab bolted over the page. It has
/// no edge and no fill of its own: over artwork it is nothing at all, and once
/// the page scrolls under it the ground arrives as a wash that fades out
/// downwards. A flat panel with a hairline under it is the version this
/// replaces — the line is what the eye reads as "another thing", and a
/// full-bleed banner does not have a border across its top.
///
/// Three zones held apart by a [Stack], not a [Row], and that is the whole
/// layout. In a row every child is moved by its neighbours' width, which is
/// how the downloads indicator appearing used to shove the search field
/// sideways: a control sliding out from under a pointer already aimed at it.
/// Here the middle is centred on the window and the two ends are pinned to the
/// window's edges, so what any of them is worth in points is nobody else's
/// business.
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

  final bool scrolled;
  final LumeoApi api;

  /// Which tab is lit. A title or a search opened from Home is still Home:
  /// the tabs say which part of the application the window is in, not how many
  /// pages deep it has gone.
  final AppTab tab;
  final void Function(AppTab) onTab;

  /// Held by the shell, because Ctrl+F is pressed while a page has the
  /// keyboard: the bar is not what has it when somebody presses it.
  final SearchController searchController;

  /// The downloads indicator, built by the shell that owns what its rows
  /// open.
  final Widget downloads;
  final void Function(String) onSearch;
  final void Function(MediaItem) onOpenItem;

  static const height = 68.0;

  /// What the middle is worth, which is also the width of the search panel.
  /// Wide enough for a title and its year at reading size, and never so wide
  /// that it reaches the wordmark or the window buttons on a small window.
  static double centreWidth(double window) =>
      min(560, max(300, window - 2 * 240));

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Motion.wash,
      height: height,
      decoration: BoxDecoration(
        // Opaque where the type sits, gone by the bottom edge. The stops are
        // not symmetrical on purpose: the tabs and the window buttons need a
        // ground under them, so the wash only starts giving way below them.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: scrolled
              ? [Palette.ground(0.95), Palette.ground(0.90), Palette.ground(0)]
              : [Palette.ground(0), Palette.ground(0), Palette.ground(0)],
          stops: const [0, 0.72, 1],
        ),
      ),
      child: Stack(
        children: [
          // Everything in the bar that is not a control is title bar: press and
          // move here and the window moves, double click and it maximises. It
          // is the bottom of the stack, so the controls over it keep their
          // clicks and only the gaps between them drag.
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
                    // Centred inside the anchor rather than laid against its
                    // left edge: the anchor is as wide as the panel that opens
                    // out of it, which is much wider than the tabs, and a group
                    // pinned to that box's left is a group visibly off the
                    // middle of the window.
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
                  // Nothing to minimise to and nothing to maximise while the
                  // window is the screen, so in fullscreen the buttons go and
                  // the bar is only a bar again.
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
          // Icons.search, not one of the shape variants: the rounded and
          // outlined sets are not in the icon font Flutter ships, and a missing
          // glyph renders as a pair of empty boxes.
          icon: const Icon(Icons.search, size: 19),
          tooltip: 'Search  ·  Ctrl+F',
          color: Palette.dim,
          hoverColor: Palette.hover,
          style: IconButton.styleFrom(
            fixedSize: const Size.square(34),
            padding: EdgeInsets.zero,
            shape: const StadiumBorder(),
            // Without this the button keeps the 48 point touch target every
            // Material button has, and the group is taller than the field it
            // stands in — 48 points inside 42, which is an overflow stripe
            // across the middle of the bar.
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 6),
        PillTab(
          label: 'Home',
          selected: tab == AppTab.home,
          onTap: () => onTab(AppTab.home),
        ),
        PillTab(
          label: 'Library',
          selected: tab == AppTab.library,
          onTap: () => onTab(AppTab.library),
        ),
        PillTab(
          label: 'Settings',
          selected: tab == AppTab.settings,
          onTap: () => onTab(AppTab.settings),
        ),
      ],
    );
  }
}

/// A place, not a button that does something: lit when the window is there,
/// quiet when it is not. The bar's tabs, and the parts of a page that are
/// places of their own (My list and History in the library).
///
/// A [TextButton] rather than our own hover ground, which is what the rest of
/// this bar used to be built from. What comes with it: the pointer, the hover
/// and pressed states, a focus ring, Enter and Space, and a place in the tab
/// order — none of which a `MouseRegion` around a `Text` has ever had here.
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
        // White at low alpha rather than one of the surfaces: the bar is
        // transparent over artwork, and a solid dark pill on a dark frame is a
        // hole in the picture. This is a tint of whatever is behind it.
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
