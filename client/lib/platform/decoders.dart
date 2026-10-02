import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';

/// What this machine can actually play, asked of mpv's `decoder-list`
/// once, before anything is chosen: Fedora's ffmpeg lacks hevc and dts, and
/// a copy in them opens to a black screen or silence. The source table marks
/// its rows with the answer. Distributions appear only in the install hint.
class DeviceDecoders {
  DeviceDecoders({
    Future<String> Function()? ask,
    Future<String?> Function()? osRelease,
  }) : _ask = ask ?? _askMpv,
       _osRelease = osRelease ?? readOsRelease;

  /// The one every screen reads. Replaceable, so a test can say what the
  /// machine cannot play.
  static DeviceDecoders instance = DeviceDecoders();

  final Future<String> Function() _ask;
  final Future<String?> Function() _osRelease;

  /// mpv's codec names against the drivers offered for each, or null while
  /// nobody has answered. Null is not "none": a query that failed must never
  /// turn into "this machine decodes nothing".
  Map<String, Set<String>>? _drivers;
  String? _osReleaseContents;
  List<String> _installCommands = const [];
  Future<void>? _asking;

  bool get answered => _drivers != null;

  /// Asked once and remembered. Safe to call from anywhere, at any time.
  Future<void> load() => _asking ??= _load();

  Future<void> _load() async {
    try {
      final drivers = decoderDrivers(await _ask());
      if (drivers == null) return;
      _drivers = drivers;
      final os = await _osRelease();
      if (os == null) return;
      _osReleaseContents = os;
      _installCommands = codecInstallCommands(os);
    } on Object catch (_) {
      // Nothing is claimed when the question could not be put.
    }
  }

  /// Whether this machine has a decoder for one of mpv's codec names. Null
  /// while the list is unknown.
  bool? has(String codec) => _drivers?.containsKey(codec.toLowerCase());

  /// A codec this machine plays with a decoder that is known not to survive a
  /// seek, when there is one.
  ///
  /// Fedora's libavcodec-free has no h264 and Cisco's libopenh264 fills the
  /// hole: it plays, so [has] answers yes, but after a backward seek the sound
  /// lands seconds away from the picture, and the player must say why.
  ///
  /// The hardware wrappers (h264_qsv, h264_cuvid, ...) are listed everywhere
  /// and used only when named; what matters is whether the driver named after
  /// the codec is there.
  BrokenDecoder? unreliable(String codec) {
    final name = codec.toLowerCase();
    final drivers = _drivers?[name];
    if (drivers == null || drivers.contains(name)) return null;
    final substitute = _knownBroken[name];
    if (substitute == null || !drivers.contains(substitute)) return null;
    return BrokenDecoder(
      codec: name,
      driver: substitute,
      osReleaseContents: _osReleaseContents,
    );
  }

  /// Only decoders with evidence of breaking, not everything that could.
  static const _knownBroken = <String, String>{'h264': 'libopenh264'};

  /// How to install what is missing, on the distributions that ship their
  /// missing decoders separately.
  String? installHint(AppLocalizations l10n) => _osReleaseContents == null
      ? null
      : codecInstallHint(_osReleaseContents!, l10n);

  /// The same thing a shell can be given, where there is one worth printing.
  List<String> get installCommands => _installCommands;

  /// What this copy would lose here, going by the codecs its name states.
  /// Null when it plays, when the name says nothing, or when mpv never
  /// answered. The picture is reported before the sound.
  DecodeGap? gapIn(Release release) {
    final video = mpvVideoCodec(release.videoCodec);
    if (video != null && has(video) == false) {
      return DecodeGap(
        codec: video,
        sound: false,
        osReleaseContents: _osReleaseContents,
      );
    }
    final audio = mpvAudioCodec(release.audioCodec);
    if (audio != null && has(audio) == false) {
      return DecodeGap(
        codec: audio,
        sound: true,
        osReleaseContents: _osReleaseContents,
      );
    }
    return null;
  }
}

/// A codec this machine plays with the wrong decoder. Not a [DecodeGap]:
/// the film is watchable, so it never marks a copy unplayable; it is said
/// once, before the player gets blamed.
class BrokenDecoder {
  const BrokenDecoder({
    required this.codec,
    required this.driver,
    this.osReleaseContents,
  });

  final String codec;

  /// mpv's name for the decoder actually doing the work.
  final String driver;
  final String? osReleaseContents;

  /// What is wrong, without what to do about it, for a page that prints the
  /// commands underneath.
  String fact(AppLocalizations l10n) => l10n.playerDecoderBroken(codec, driver);

  String sentence(AppLocalizations l10n) => [
    fact(l10n),
    if (osReleaseContents != null) ?codecInstallHint(osReleaseContents!, l10n),
  ].join(' ');
}

/// Something in a copy that this machine cannot decode.
class DecodeGap {
  const DecodeGap({
    required this.codec,
    required this.sound,
    this.osReleaseContents,
  });

  /// mpv's name for it, which is also the name mpv prints when it fails.
  final String codec;

  /// Which half of the film goes missing.
  final bool sound;
  final String? osReleaseContents;

  /// Short enough for a table row, and about this machine rather than the
  /// copy.
  String mark(AppLocalizations l10n) => sound
      ? l10n.playerDecoderNoSoundMark(codec)
      : l10n.playerDecoderMissingMark(codec);

  /// What is missing, without what to do about it.
  String fact(AppLocalizations l10n) => sound
      ? l10n.playerDecoderNoSound(codec)
      : l10n.playerDecoderMissing(codec);

  /// The whole of it, for the row that is being looked at and for the player.
  String sentence(AppLocalizations l10n) => [
    fact(l10n),
    if (osReleaseContents != null) ?codecInstallHint(osReleaseContents!, l10n),
  ].join(' ');
}

/// The codec names our release parser prints, in mpv's spelling (x265 is
/// hevc). An unknown name is not a missing decoder.
const _videoCodecs = <String, String>{
  'AVC': 'h264',
  'HEVC': 'hevc',
  'AV1': 'av1',
  'VP9': 'vp9',
  'XviD': 'mpeg4',
  'DivX': 'mpeg4',
  'MPEG-2': 'mpeg2video',
};

/// DTS-HD and DTS-X are dts with more in the stream: one decoder. PCM is
/// absent: a dozen codec names, and nothing ships without it.
const _audioCodecs = <String, String>{
  'AAC': 'aac',
  'AC3': 'ac3',
  'EAC3': 'eac3',
  'DTS': 'dts',
  'DTS-HD': 'dts',
  'DTS-X': 'dts',
  'TrueHD': 'truehd',
  'FLAC': 'flac',
  'Opus': 'opus',
  'MP3': 'mp3',
};

String? mpvVideoCodec(String releaseCodec) => _videoCodecs[releaseCodec];

String? mpvAudioCodec(String releaseCodec) => _audioCodecs[releaseCodec];

/// Which kind of track in mpv's track list is in [codec]: "audio", "video",
/// or null. mpv words a failed decoder the same for picture and sound, and
/// the difference decides between a full-screen message and one line over a
/// playing film; a failed track stays in the list with its codec.
String? trackTypeFor(String json, String codec) {
  if (json.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    final wanted = codec.toLowerCase();
    for (final entry in decoded) {
      if (entry is Map &&
          entry['codec'] is String &&
          (entry['codec'] as String).toLowerCase() == wanted &&
          entry['type'] is String) {
        return entry['type'] as String;
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// mpv's decoder list, as codec names against the drivers offered for each:
/// a codec whose own driver is missing is still listed under a substitute
/// (see [DeviceDecoders.unreliable]). Null when the value was not a decoder
/// list, so a failed query is not a machine that decodes nothing.
Map<String, Set<String>>? decoderDrivers(String json) {
  if (json.trim().isEmpty) return null;

  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    final drivers = <String, Set<String>>{};
    for (final entry in decoded) {
      if (entry is! Map || entry['codec'] is! String) continue;
      final codec = (entry['codec'] as String).toLowerCase();
      final driver = entry['driver'];
      (drivers[codec] ??= <String>{}).add(
        driver is String ? driver.toLowerCase() : codec,
      );
    }
    return drivers;
  } on FormatException {
    return null;
  }
}

/// The codec names in mpv's decoder list.
Set<String>? decoderCodecs(String json) => decoderDrivers(json)?.keys.toSet();

/// Whether mpv's decoder list contains [codec].
bool? decoderListHas(String json, String codec) =>
    decoderCodecs(json)?.contains(codec.toLowerCase());

/// How to add a missing decoder where they are packaged separately; the
/// repositories ship the whole set as one package.
String? codecInstallHint(String osReleaseContents, AppLocalizations l10n) {
  final ids = _distributions(osReleaseContents);
  if (ids.contains('fedora')) {
    return l10n.settingsCodecFedoraHint;
  }
  if (ids.contains('opensuse') || ids.contains('suse')) {
    return l10n.settingsCodecSuseHint;
  }
  return null;
}

/// The same advice as shell commands, in the order they run. Two on Fedora:
/// the package is in RPM Fusion, which Fedora does not enable; where it is
/// enabled, the first is a no-op. None for openSUSE: adding Packman differs
/// between Leap and Tumbleweed.
List<String> codecInstallCommands(String osReleaseContents) {
  if (!_distributions(osReleaseContents).contains('fedora')) return const [];
  return const [
    // The release number from rpm, so it never goes stale here.
    r'sudo dnf install https://mirrors.rpmfusion.org/free/fedora/'
        r'rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm',
    'sudo dnf install libavcodec-freeworld',
  ];
}

/// What the machine calls itself, its family included.
Set<String> _distributions(String osReleaseContents) {
  final fields = _osReleaseFields(osReleaseContents);
  return '${fields['ID'] ?? ''} ${fields['ID_LIKE'] ?? ''}'
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .toSet();
}

Map<String, String> _osReleaseFields(String contents) {
  final fields = <String, String>{};
  for (final line in const LineSplitter().convert(contents)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final equals = trimmed.indexOf('=');
    if (equals <= 0) continue;
    final key = trimmed.substring(0, equals);
    var value = trimmed.substring(equals + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    fields[key] = value;
  }
  return fields;
}

/// Reads the operating-system identity separately from its parser so the
/// distribution rules stay deterministic and filesystem-free in tests.
Future<String?> readOsRelease() async {
  try {
    return await File('/etc/os-release').readAsString();
  } on FileSystemException {
    return null;
  }
}

/// mpv, asked before it has been given anything to play: the answer is
/// needed while a title is chosen. One libmpv handle with no window, video
/// output or file, disposed once it has answered.
Future<String> _askMpv() async {
  final player = Player();
  try {
    final platform = player.platform;
    if (platform is! NativePlayer) return '';
    return await platform.getProperty('decoder-list');
  } finally {
    await player.dispose();
  }
}
