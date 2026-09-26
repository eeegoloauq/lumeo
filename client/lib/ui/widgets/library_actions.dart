import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';
import 'buttons.dart';
import 'rating_button.dart';

/// What the viewer keeps and thinks of a title, on its page: My list and
/// their score of it.
///
/// Round buttons beside the source rather than words beside Play: Play is
/// the one thing this page is for, and every streaming app that puts "+" by
/// the title does it as a quiet mark next to the main action, not as a
/// second one. Neither is in the accent, which marks what will play.
///
/// Both change at once and are sent behind the change: a button that waited
/// on the core would read as a click that missed, and one that fails is put
/// back with a line saying so.
class LibraryActions extends StatefulWidget {
  const LibraryActions({super.key, required this.api, required this.itemId});

  final LumeoApi api;
  final String itemId;

  @override
  State<LibraryActions> createState() => _LibraryActionsState();
}

class _LibraryActionsState extends State<LibraryActions> {
  /// Null until the core has said.
  bool? _inList;

  /// What the core last said about My list, which [_inList] runs ahead of.
  bool? _saved;
  bool _sending = false;
  int _score = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final state = widget.api.listState(widget.itemId);
      final ratings = widget.api.ratings(widget.itemId);
      final inList = (await state).inList;
      final score =
          (await ratings)
              .where((r) => r.season == 0 && r.episode == 0)
              .firstOrNull
              ?.score ??
          0;
      if (mounted) {
        setState(() {
          _inList = inList;
          _saved = inList;
          _score = score;
        });
      }
    } on Object catch (_) {
      // The buttons stay off: a core that cannot say whether the title is on
      // the list cannot be told to change it either.
    }
  }

  /// Clicks flip the button at once and are sent one at a time, each after
  /// the core answered the last: two in flight could land in either order and
  /// leave the core on the opposite of what the button shows.
  Future<void> _toggleList() async {
    final shown = _inList;
    if (shown == null) return;
    setState(() => _inList = !shown);
    if (_sending) return;
    _sending = true;
    var want = !shown;
    try {
      while (want != _saved) {
        if (want) {
          await widget.api.addToList(widget.itemId);
        } else {
          await widget.api.removeFromList(widget.itemId);
        }
        _saved = want;
        want = _inList!;
      }
    } on Object catch (_) {
      if (!mounted) return;
      setState(() => _inList = _saved);
      _say(
        want
            ? context.l10n.libraryCouldNotAdd
            : context.l10n.libraryCouldNotRemove,
      );
    } finally {
      _sending = false;
    }
  }

  Future<void> _rate(int score) async {
    final was = _score;
    setState(() => _score = score);
    try {
      await widget.api.rate(widget.itemId, score);
    } on Object catch (_) {
      if (!mounted) return;
      setState(() => _score = was);
      _say(context.l10n.libraryRatingNotSaved);
    }
  }

  Future<void> _clear() async {
    final was = _score;
    setState(() => _score = 0);
    try {
      await widget.api.unrate(widget.itemId);
    } on Object catch (_) {
      if (!mounted) return;
      setState(() => _score = was);
      _say(context.l10n.libraryRatingNotRemoved);
    }
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final known = _inList != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListButton(
          inList: _inList ?? false,
          onPressed: known ? _toggleList : null,
        ),
        const SizedBox(width: 8),
        if (known)
          RatingButton(score: _score, onRate: _rate, onClear: _clear)
        else
          // The same footprint, so nothing moves when the core answers.
          const SizedBox.square(dimension: RatingButton.size),
      ],
    );
  }
}

/// On My list or not: a plus that turns into a check.
class ListButton extends StatelessWidget {
  const ListButton({super.key, required this.inList, required this.onPressed});

  final bool inList;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('list-button'),
      tooltip: inList
          ? context.l10n.libraryRemoveFromList
          : context.l10n.libraryAddToList,
      onPressed: onPressed,
      isSelected: inList,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(DownloadButton.size),
        minimumSize: const Size.square(DownloadButton.size),
        padding: EdgeInsets.zero,
        backgroundColor: Palette.tint,
        disabledBackgroundColor: Palette.tint,
        foregroundColor: Palette.text,
        disabledForegroundColor: Palette.muted,
      ),
      icon: const Icon(Icons.add, size: 20),
      selectedIcon: const Icon(Icons.check, size: 20),
    );
  }
}
