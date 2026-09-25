import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/client.dart';
import '../../../api/models.dart';
import '../../../api/preferences_store.dart';
import '../../../platform/decoders.dart';
import '../../../platform/dirs.dart';
import '../../../platform/folders.dart';
import '../../../platform/local_settings.dart';
import '../../player/mpv_facts.dart';
import '../../theme.dart';
import '../../widgets/setting_row.dart';
import 'controls.dart';

/// Keep this to codecs a catalogue copy is likely to use.
const _video = ['h264', 'hevc', 'av1', 'vp9'];
const _audio = ['aac', 'ac3', 'eac3', 'dts', 'truehd'];

/// What is running, whether the core answers, what this machine decodes, and
/// what a bug report needs.
class AboutSection extends StatefulWidget {
  const AboutSection({
    super.key,
    required this.api,
    required this.preferences,
    required this.settings,
    required this.about,
    required this.onReset,
    required this.error,
  });

  final LumeoApi api;
  final PreferencesStore preferences;
  final LocalSettings settings;
  final Future<CoreAbout> about;

  /// Called before a reset, so its failure is said here.
  final VoidCallback onReset;
  final Object? error;

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  late Future<CoreHealth> _health = widget.api.health();
  late final Future<void> _decoders = DeviceDecoders.instance.load();
  final _facts = MpvFacts.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_facts.load());
  }

  Future<void> _reset() async {
    final sure = await confirm(
      context,
      message:
          'Put every setting back as it was? Downloads, your list and '
          'history stay.',
      action: 'Reset',
    );
    if (!sure) return;
    widget.onReset();
    widget.settings.resetChoices();
    await widget.preferences.reset();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsBlock(
      title: 'About',
      children: [
        FutureBuilder<CoreAbout>(
          future: widget.about,
          builder: (context, about) => FutureBuilder<CoreHealth>(
            future: _health,
            builder: (context, health) => ListenableBuilder(
              listenable: _facts,
              builder: (context, _) => FutureBuilder<void>(
                future: _decoders,
                builder: (context, decoders) => SettingRows([
                  ..._rows(about, health),
                  if (decoders.connectionState == ConnectionState.done)
                    ..._decoderRows()
                  else
                    const SettingsLoading(),
                  SettingRow(
                    label: 'Reset settings',
                    hint: 'Downloads, your list and history stay.',
                    value: RowButton(label: 'Reset…', onPressed: _reset),
                  ),
                  if (widget.error != null) ErrorRow(widget.error!),
                  SettingRow(
                    label: 'For a bug report',
                    hint: _logHint(about.data),
                    value: _CopyButton(
                      label: 'Copy details',
                      text: () => _details(about.data, health),
                    ),
                    trailing: RowButton(
                      label: 'Open logs',
                      onPressed: () => openFolder(stateDir()),
                    ),
                  ),
                  if (_coreLogDir(about.data) case final dir?)
                    SettingRow(
                      label: 'Core log',
                      value: PathText(about.data!.logPath),
                      trailing: RowButton(
                        label: 'Open',
                        onPressed: () => openFolder(dir),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The core's own log, when it keeps one somewhere the player's logs are
  /// not, and on this machine.
  String? _coreLogDir(CoreAbout? about) {
    final path = about?.logPath ?? '';
    if (path.isEmpty || !widget.api.isLocal) return null;
    final dir = File(path).parent.path;
    return _samePath(dir, stateDir()) ? null : dir;
  }

  static bool _samePath(String a, String b) =>
      a.replaceAll('\\', '/').toLowerCase() ==
      b.replaceAll('\\', '/').toLowerCase();

  String _logHint(CoreAbout? about) {
    final player = 'The player’s logs are mpv.log and mpv.old.log.';
    final path = about?.logPath ?? '';
    if (path.isNotEmpty) return player;
    return '$player The core logs to the system journal.';
  }

  List<Widget> _rows(
    AsyncSnapshot<CoreAbout> about,
    AsyncSnapshot<CoreHealth> health,
  ) {
    final version = about.data?.version ?? '';
    final waiting = !health.hasData && !health.hasError;
    final (colour, word) = switch ((waiting, health.error)) {
      (true, _) => (Palette.muted, 'asking…'),
      (_, final Object _) => (Palette.down, 'not answering'),
      _ => (Palette.up, 'answering'),
    };
    final providers = health.data?.providers;
    final player = [
      if (_facts.version.isNotEmpty) 'mpv ${_facts.version}',
      if (_facts.hardware.isNotEmpty) _facts.hardware,
    ].join(' · ');
    return [
      SettingRow(
        label: 'Lumeo',
        value: Text(
          version.isEmpty ? (about.hasError ? 'unknown' : '…') : version,
          style: SettingsType.value,
        ),
      ),
      SettingRow(
        label: 'Core',
        hint: providers == null
            ? null
            : providers == 1
            ? '1 source provider'
            : '$providers source providers',
        value: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StateDot(colour),
            const SizedBox(width: 8),
            PathText(_address(about.data)),
            const SizedBox(width: 12),
            Text(word, style: SettingsType.hint.copyWith(color: colour)),
          ],
        ),
        trailing: health.hasError
            ? RowButton(
                label: 'Try again',
                onPressed: () => setState(() {
                  _health = widget.api.health();
                }),
              )
            : null,
      ),
      if (health.hasError)
        SettingRow(
          label: 'What it said',
          value: Text(
            errorMessage(health.error!),
            style: Typo.data.copyWith(color: Palette.warn),
          ),
        ),
      if (providers == 0)
        SettingRow(
          label: 'Source providers',
          value: Text(
            'None: the core can browse and play nothing.',
            style: Typo.data.copyWith(color: Palette.warn),
          ),
        ),
      SettingRow(
        label: 'Player',
        hint: _facts.hardware.isEmpty && _facts.version.isNotEmpty
            ? 'The hardware decoder is named once a film has played.'
            : null,
        value: Text(
          player.isEmpty ? (_facts.done ? 'mpv did not answer' : '…') : player,
          style: SettingsType.value,
        ),
      ),
    ];
  }

  /// The address the core says it listens on, else the one this client uses.
  String _address(CoreAbout? about) {
    final addr = about?.addr ?? '';
    if (addr.isNotEmpty) return addr;
    final uri = widget.api.baseUri;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  List<Widget> _decoderRows() {
    final decoders = DeviceDecoders.instance;
    if (!decoders.answered) {
      return [
        const SettingRow(
          label: 'Decoders',
          value: Text(
            'mpv did not answer, so nothing is claimed here',
            style: Typo.data,
          ),
        ),
      ];
    }
    final broken = [for (final codec in _video) decoders.unreliable(codec)]
        .nonNulls
        .toList();
    final commands = decoders.installCommands;
    return [
      const SettingRow(
        label: 'Picture',
        value: _Codecs(codecs: _video),
      ),
      const SettingRow(
        label: 'Sound',
        value: _Codecs(codecs: _audio),
      ),
      for (final one in broken)
        SettingRow(
          label: 'Warning',
          value: Text(
            one.fact,
            style: Typo.body.copyWith(fontSize: 13, color: Palette.warn),
          ),
        ),
      // Printed for the viewer, never run with elevated access.
      if (broken.isNotEmpty && commands.isNotEmpty)
        SettingRow(
          label: 'To fix it',
          value: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final command in commands)
                SelectableText(
                  command,
                  style: Typo.code.copyWith(color: Palette.text),
                ),
            ],
          ),
          trailing: _CopyButton(text: () => commands.join('\n')),
        ),
    ];
  }

  /// Everything a report needs, in one paste.
  String _details(CoreAbout? about, AsyncSnapshot<CoreHealth> health) {
    final decoders = DeviceDecoders.instance;
    final missing = [
      for (final codec in [..._video, ..._audio])
        if (decoders.has(codec) == false) codec,
    ];
    final broken = [
      for (final codec in _video) decoders.unreliable(codec)?.fact,
    ].nonNulls;
    return [
      'Lumeo ${about?.version.isNotEmpty == true ? about!.version : 'unknown'}',
      'Core ${_address(about)}, '
          '${health.hasError ? 'not answering' : 'answering'}'
          '${health.data == null ? '' : ', ${health.data!.providers} providers'}',
      'Player mpv ${_facts.version.isEmpty ? 'unknown' : _facts.version}'
          '${_facts.hardware.isEmpty ? '' : ', ${_facts.hardware}'}',
      'System ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      if (missing.isNotEmpty) 'No decoder for ${missing.join(', ')}',
      ...broken,
      'Logs ${stateDir()}/mpv.log'
          '${(about?.logPath ?? '').isEmpty ? '' : ', ${about!.logPath}'}',
    ].join('\n');
  }
}

class _Codecs extends StatelessWidget {
  const _Codecs({required this.codecs});

  final List<String> codecs;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final codec in codecs)
          Text(
            codec,
            style: DeviceDecoders.instance.has(codec) == false
                ? Typo.code.copyWith(
                    fontSize: 13,
                    color: Palette.warn,
                    decoration: TextDecoration.lineThrough,
                    decorationColor: Palette.warn,
                  )
                : Typo.code.copyWith(fontSize: 13, color: Palette.text),
          ),
      ],
    );
  }
}

/// Copies, and says so for a moment: a button that looks the same afterwards
/// is pressed twice. With a [label] it is a row button, without one an icon.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text, this.label});

  final String Function() text;
  final String? label;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  Timer? _said;
  bool _copied = false;

  @override
  void dispose() {
    _said?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text()));
    if (!mounted) return;
    setState(() => _copied = true);
    _said?.cancel();
    _said = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.label != null) {
      return RowButton(
        label: _copied ? 'Copied' : widget.label!,
        icon: _copied ? Icons.check : null,
        onPressed: _copy,
      );
    }
    return IconButton(
      onPressed: _copy,
      tooltip: _copied ? 'Copied' : 'Copy',
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      color: _copied ? Palette.text : Palette.dim,
      icon: Icon(_copied ? Icons.check : Icons.content_copy),
    );
  }
}
