import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Read shortcuts from mpv so the page follows its active bindings.
class MpvBinding {
  const MpvBinding({
    required this.key,
    required this.cmd,
    this.comment = '',
    this.section = '',
  });

  final String key;
  final String cmd;
  final String comment;

  final String section;

  /// An unparseable list leaves the shortcut page empty.
  static List<MpvBinding> parse(String json) {
    if (json.trim().isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is Map && entry['key'] is String && entry['cmd'] is String)
          MpvBinding(
            key: entry['key'] as String,
            cmd: entry['cmd'] as String,
            comment: entry['comment'] is String
                ? entry['comment'] as String
                : '',
            section: entry['section'] is String
                ? entry['section'] as String
                : '',
          ),
    ];
  }
}

class Shortcut {
  const Shortcut({required this.keys, required this.what});

  final List<String> keys;
  final String what;
}

const ownSection = 'lumeo';

/// Our input section. The arrows' step is the `seekStep` preference, bound
/// here so mpv does the seek; Shift+arrow and up/down stay mpv's own.
List<String> ownBindings({int seekStep = 5}) => [
  'MBTN_LEFT cycle pause',
  'ESC script-message lumeo escape',
  'q script-message lumeo back',
  'c script-message lumeo tracks',
  'F11 cycle fullscreen',
  'LEFT seek -$seekStep',
  'RIGHT seek $seekStep',
];

/// [ownBindings] as mpv would list them, for a page with no mpv of its own
/// to ask: the key, then the command.
List<MpvBinding> ownBindingList({int seekStep = 5}) => [
  for (final line in ownBindings(seekStep: seekStep))
    MpvBinding(
      key: line.substring(0, line.indexOf(' ')),
      cmd: line.substring(line.indexOf(' ') + 1),
      section: ownSection,
    ),
];

const _ownLabels = {
  'script-message lumeo escape': 'Leave fullscreen, else back to the title',
  'script-message lumeo back': 'Back to the title',
  'script-message lumeo tracks': 'Audio & subtitles',
  'cycle fullscreen': 'Fullscreen',
};

String layoutKey(int usbHidUsage, bool shift, String char, Set<String> bound) {
  if (char.runes.every((c) => c < 0x80) || bound.contains(char)) {
    return char;
  }
  const plain = 'abcdefghijklmnopqrstuvwxyz1234567890-=[]\\;\'`,./';
  const shifted = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#\$%^&*()_+{}|:"~<>?';
  final index = switch (usbHidUsage) {
    >= 0x70004 && <= 0x7001d => usbHidUsage - 0x70004,
    >= 0x7001e && <= 0x70027 => usbHidUsage - 0x7001e + 26,
    >= 0x7002d && <= 0x70031 => usbHidUsage - 0x7002d + 36,
    >= 0x70033 && <= 0x70038 => usbHidUsage - 0x70033 + 41,
    _ => -1,
  };
  return index < 0 ? char : (shift ? shifted : plain)[index];
}

/// Exclude inactive, irrelevant, script, and self-explanatory media keys.
/// Our bindings override defaults; group keys that run the same command.
///
/// With [only], the lines for what those keys (mpv's names) do, in that
/// order, each with every key that does the same.
List<Shortcut> shortcuts(List<MpvBinding> bindings, {List<String>? only}) {
  final byKey = <String, MpvBinding>{};
  for (final b in bindings) {
    if (b.section != 'default' && b.section != ownSection) continue;
    final held = byKey[b.key];
    if (held == null || held.section != ownSection) byKey[b.key] = b;
  }
  String normal(String cmd) => cmd.replaceAll(RegExp(r'\s+'), ' ');
  final wanted = only == null
      ? null
      : [
          for (final key in only)
            if (byKey[key] case final b?) normal(b.cmd),
        ];
  // Our bindings have no labels; reuse mpv's label for the command.
  final keys = <String, List<String>>{};
  final comments = <String, String>{};
  for (final b in byKey.values) {
    if (!_actsHere(b.cmd)) continue;
    final label = keyLabel(b.key);
    if (label == null) continue;
    final cmd = normal(b.cmd);
    if (wanted != null && !wanted.contains(cmd)) continue;
    final line = keys.putIfAbsent(cmd, () => []);
    if (!line.contains(label)) line.add(label);
    if (b.comment.isNotEmpty) comments.putIfAbsent(cmd, () => b.comment);
  }
  final order = wanted == null
      ? keys.keys.toList()
      : <String>{
          for (final cmd in wanted)
            if (keys.containsKey(cmd)) cmd,
        }.toList();
  return [
    for (final cmd in order)
      Shortcut(
        keys: keys[cmd]!,
        what:
            _ownLabels[cmd] ??
            switch (comments[cmd]) {
              final comment? => _sentence(comment),
              null => _plain(cmd),
            },
      ),
  ];
}

bool _actsHere(String cmd) {
  const dead = [
    'ignore',
    'quit',
    'playlist-',
    'set fullscreen',
    'cycle ontop',
    'set current-window-scale',
    'script-binding osc/',
    'script-binding console/',
  ];
  return !dead.any(cmd.startsWith);
}

String _sentence(String comment) =>
    comment[0].toUpperCase() + comment.substring(1);

String _plain(String cmd) {
  // Our own arrows, which carry no comment: said the way mpv says its own.
  final seek = RegExp(r'^seek (-?)(\d+)$').firstMatch(cmd);
  if (seek != null) {
    final seconds = int.parse(seek[2]!);
    final span = seconds % 60 == 0
        ? '${seconds ~/ 60} minute${seconds == 60 ? '' : 's'}'
        : '$seconds second${seconds == 1 ? '' : 's'}';
    return 'Seek $span ${seek[1]!.isEmpty ? 'forward' : 'backward'}';
  }
  final add = RegExp(r'^add ([a-z][a-z-]*) ([+-]?\d+(?:\.\d+)?)$')
      .firstMatch(cmd);
  if (add == null) return cmd;
  final step = add[2]!;
  return '${_sentence(add[1]!.replaceAll('-', ' '))} '
      '${step.startsWith('-') ? '−${step.substring(1)}' : '+${step.replaceFirst('+', '')}'}';
}

/// Return null for media and power keys, whose purpose is on the keycap.
String? keyLabel(String key) {
  final parts = <String>[];
  var rest = key;
  // Split on hyphens so `Ctrl++` keeps its plus key.
  var stripped = true;
  while (stripped) {
    stripped = false;
    for (final modifier in const ['Shift', 'Ctrl', 'Alt', 'Meta']) {
      if (rest.startsWith('$modifier+') && rest.length > modifier.length + 1) {
        parts.add(modifier);
        rest = rest.substring(modifier.length + 1);
        stripped = true;
      }
    }
  }
  if (rest.length == 1) {
    final c = rest;
    if (c.toLowerCase() != c.toUpperCase() && c == c.toUpperCase()) {
      parts.add('Shift');
    }
    parts.add(c.toUpperCase());
    return parts.join('+');
  }
  final named = _keyNames[rest];
  if (named == null) return null;
  return [...parts, named].join('+');
}

final _keyNames = {
  'SPACE': 'Space',
  'ENTER': 'Enter',
  'TAB': 'Tab',
  'BS': 'Backspace',
  'DEL': 'Delete',
  'INS': 'Insert',
  'HOME': 'Home',
  'END': 'End',
  'PGUP': 'PgUp',
  'PGDWN': 'PgDn',
  'ESC': 'Esc',
  'LEFT': '←',
  'RIGHT': '→',
  'UP': '↑',
  'DOWN': '↓',
  'SHARP': '#',
  'KP_DEC': 'Numpad .',
  'KP_ENTER': 'Numpad Enter',
  'MBTN_LEFT': 'Click',
  'MBTN_LEFT_DBL': 'Double click',
  'MBTN_RIGHT': 'Right click',
  'MBTN_MID': 'Middle click',
  'MBTN_BACK': 'Back button',
  'MBTN_FORWARD': 'Forward button',
  'WHEEL_UP': 'Wheel up',
  'WHEEL_DOWN': 'Wheel down',
  'WHEEL_LEFT': 'Wheel left',
  'WHEEL_RIGHT': 'Wheel right',
  for (var i = 1; i <= 12; i++) 'F$i': 'F$i',
  for (var i = 0; i <= 9; i++) 'KP$i': 'Numpad $i',
};

/// mpv's names for the mouse buttons it binds.
const mpvMouseButtons = <int, String>{
  kPrimaryMouseButton: 'MBTN_LEFT',
  kSecondaryMouseButton: 'MBTN_RIGHT',
  kMiddleMouseButton: 'MBTN_MID',
  kBackMouseButton: 'MBTN_BACK',
  kForwardMouseButton: 'MBTN_FORWARD',
};

final _namedKeys = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.space: 'SPACE',
  LogicalKeyboardKey.enter: 'ENTER',
  LogicalKeyboardKey.tab: 'TAB',
  LogicalKeyboardKey.escape: 'ESC',
  LogicalKeyboardKey.backspace: 'BS',
  LogicalKeyboardKey.delete: 'DEL',
  LogicalKeyboardKey.insert: 'INS',
  LogicalKeyboardKey.home: 'HOME',
  LogicalKeyboardKey.end: 'END',
  LogicalKeyboardKey.pageUp: 'PGUP',
  LogicalKeyboardKey.pageDown: 'PGDWN',
  LogicalKeyboardKey.arrowLeft: 'LEFT',
  LogicalKeyboardKey.arrowRight: 'RIGHT',
  LogicalKeyboardKey.arrowUp: 'UP',
  LogicalKeyboardKey.arrowDown: 'DOWN',
  LogicalKeyboardKey.f1: 'F1',
  LogicalKeyboardKey.f2: 'F2',
  LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4',
  LogicalKeyboardKey.f5: 'F5',
  LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7',
  LogicalKeyboardKey.f8: 'F8',
  LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10',
  LogicalKeyboardKey.f11: 'F11',
  LogicalKeyboardKey.f12: 'F12',
  LogicalKeyboardKey.numpad0: 'KP0',
  LogicalKeyboardKey.numpad1: 'KP1',
  LogicalKeyboardKey.numpad2: 'KP2',
  LogicalKeyboardKey.numpad3: 'KP3',
  LogicalKeyboardKey.numpad4: 'KP4',
  LogicalKeyboardKey.numpad5: 'KP5',
  LogicalKeyboardKey.numpad6: 'KP6',
  LogicalKeyboardKey.numpad7: 'KP7',
  LogicalKeyboardKey.numpad8: 'KP8',
  LogicalKeyboardKey.numpad9: 'KP9',
  LogicalKeyboardKey.numpadDecimal: 'KP_DEC',
  LogicalKeyboardKey.numpadEnter: 'KP_ENTER',
  LogicalKeyboardKey.mediaPlay: 'PLAY',
  LogicalKeyboardKey.mediaPause: 'PAUSE',
  LogicalKeyboardKey.mediaPlayPause: 'PLAYPAUSE',
  LogicalKeyboardKey.mediaStop: 'STOP',
  LogicalKeyboardKey.mediaTrackNext: 'NEXT',
  LogicalKeyboardKey.mediaTrackPrevious: 'PREV',
  LogicalKeyboardKey.mediaFastForward: 'FORWARD',
  LogicalKeyboardKey.mediaRewind: 'REWIND',
  LogicalKeyboardKey.audioVolumeUp: 'VOLUME_UP',
  LogicalKeyboardKey.audioVolumeDown: 'VOLUME_DOWN',
  LogicalKeyboardKey.audioVolumeMute: 'MUTE',
};

/// mpv's name for a key press, modifiers included, or null for a key mpv
/// has no name for. Releases have no character, so the caller keeps the name
/// recorded at press time for the matching keyup.
String? mpvKeyName(KeyDownEvent event, Set<String> bound) {
  final modifiers = HardwareKeyboard.instance;
  final prefix = StringBuffer();
  if (modifiers.isControlPressed) prefix.write('Ctrl+');
  if (modifiers.isAltPressed) prefix.write('Alt+');
  if (modifiers.isMetaPressed) prefix.write('Meta+');
  final special = _namedKeys[event.logicalKey];
  if (special != null) {
    if (modifiers.isShiftPressed) prefix.write('Shift+');
    return '$prefix$special';
  }
  var char = event.character;
  if (char == null || char.isEmpty || char.codeUnitAt(0) < 0x20) {
    return null;
  }
  char = layoutKey(
    event.physicalKey.usbHidUsage,
    modifiers.isShiftPressed,
    char,
    bound,
  );
  if (char == '#') char = 'SHARP';
  return '$prefix$char';
}
