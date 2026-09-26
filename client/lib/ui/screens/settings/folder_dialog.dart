import 'dart:io';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme.dart';

/// Picks a folder on this machine, by walking it or by typing its path.
///
/// Drawn by us rather than asked of the desktop: the runners have no file
/// chooser, and a native one on each platform is two pieces of code that
/// nothing here can build or run. The question is small — one folder — and
/// the listing is the filesystem's own.
Future<String?> chooseFolder(
  BuildContext context, {
  required String title,
  required String start,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _FolderDialog(title: title, start: start),
  );
}

class _FolderDialog extends StatefulWidget {
  const _FolderDialog({required this.title, required this.start});

  final String title;
  final String start;

  @override
  State<_FolderDialog> createState() => _FolderDialogState();
}

class _FolderDialogState extends State<_FolderDialog> {
  late final _path = TextEditingController();
  List<String> _children = const [];
  String _at = '';
  String? _problem;

  @override
  void initState() {
    super.initState();
    _open(_nearestExisting(widget.start));
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  /// The folder asked for, or the closest one above it that exists — a
  /// download folder that was never created yet still opens somewhere near.
  static String _nearestExisting(String path) {
    var dir = Directory(path.isEmpty ? _home() : path).absolute;
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    return dir.path;
  }

  static String _home() =>
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '/';

  Future<void> _open(String path) async {
    final dir = Directory(path);
    try {
      final children = <String>[];
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        // Dot-folders are configuration, not somewhere to keep films.
        if (!name.startsWith('.')) children.add(name);
      }
      children.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _at = dir.path;
        _children = children;
        _problem = null;
        _path.text = dir.path;
      });
    } on FileSystemException catch (error) {
      if (!mounted) return;
      setState(() => _problem = error.osError?.message ?? error.message);
    }
  }

  String _join(String name) {
    final separator = Platform.pathSeparator;
    return _at.endsWith(separator) ? '$_at$name' : '$_at$separator$name';
  }

  void _typed(String typed) {
    final path = typed.trim();
    if (path.isEmpty) return;
    if (Directory(path).existsSync()) {
      _open(path);
    } else {
      setState(() => _problem = context.l10n.settingsFolderMissing);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = Directory(_at).parent.path;
    return AlertDialog(
      title: Text(widget.title, style: Typo.shelfLabel),
      content: SizedBox(
        width: 520,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: context.l10n.settingsFolderUp,
                  onPressed: _at.isEmpty || parent == _at
                      ? null
                      : () => _open(parent),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _path,
                    style: Typo.code.copyWith(
                      fontSize: 13,
                      color: Palette.text,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      errorText: _problem,
                    ),
                    onSubmitted: _typed,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _children.isEmpty
                  ? Center(
                      child: Text(
                        context.l10n.settingsFolderEmpty,
                        style: Typo.data,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final name in _children)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.folder_outlined,
                              size: 18,
                              color: Palette.muted,
                            ),
                            title: Text(name, style: Typo.dataStrong),
                            onTap: () => _open(_join(name)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.commonCancel),
        ),
        TextButton(
          onPressed: _at.isEmpty ? null : () => Navigator.pop(context, _at),
          child: Text(context.l10n.settingsFolderUse),
        ),
      ],
    );
  }
}
