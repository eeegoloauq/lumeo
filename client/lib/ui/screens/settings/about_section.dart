import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/client.dart';
import '../../../api/models.dart';
import '../../../api/preferences_store.dart';
import '../../../l10n/l10n.dart';
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
      message: context.l10n.settingsResetConfirm,
      action: context.l10n.commonReset,
    );
    if (!sure) return;
    widget.onReset();
    widget.settings.resetChoices();
    await widget.preferences.reset();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsBlock(
      title: context.l10n.settingsAbout,
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
                    label: context.l10n.settingsResetSettings,
                    hint: context.l10n.settingsResetHint,
                    value: RowButton(
                      label: context.l10n.settingsResetAction,
                      onPressed: _reset,
                    ),
                  ),
                  if (widget.error != null) ErrorRow(widget.error!),
                  SettingRow(
                    label: context.l10n.settingsBugReport,
                    hint: _logHint(about.data),
                    value: _CopyButton(
                      label: context.l10n.settingsCopyDetails,
                      text: () => _details(about.data, health),
                    ),
                    trailing: RowButton(
                      label: context.l10n.settingsOpenLogs,
                      onPressed: () => openFolder(stateDir()),
                    ),
                  ),
                  if (_coreLogDir(about.data) case final dir?)
                    SettingRow(
                      label: context.l10n.settingsCoreLog,
                      value: PathText(about.data!.logPath),
                      trailing: RowButton(
                        label: context.l10n.commonOpen,
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
    final player = context.l10n.settingsPlayerLogHint;
    final path = about?.logPath ?? '';
    if (path.isNotEmpty) return player;
    return context.l10n.settingsJournalLogHint;
  }

  List<Widget> _rows(
    AsyncSnapshot<CoreAbout> about,
    AsyncSnapshot<CoreHealth> health,
  ) {
    final version = about.data?.version ?? '';
    final waiting = !health.hasData && !health.hasError;
    final (colour, word) = switch ((waiting, health.error)) {
      (true, _) => (Palette.muted, context.l10n.commonAsking),
      (_, final Object _) => (Palette.down, context.l10n.commonNotAnswering),
      _ => (Palette.up, context.l10n.commonAnswering),
    };
    final providers = health.data?.providers;
    final player = [
      if (_facts.version.isNotEmpty)
        context.l10n.settingsMpvVersion(_facts.version),
      if (_facts.hardware.isNotEmpty) _facts.hardware,
    ].join(' · ');
    return [
      SettingRow(
        label: 'Lumeo',
        value: Text(
          version.isEmpty
              ? (about.hasError ? context.l10n.commonUnknown : '…')
              : version,
          style: SettingsType.value,
        ),
      ),
      SettingRow(
        label: context.l10n.settingsCore,
        hint: providers == null
            ? null
            : context.l10n.settingsProviderCount(providers),
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
                label: context.l10n.commonTryAgain,
                onPressed: () => setState(() {
                  _health = widget.api.health();
                }),
              )
            : null,
      ),
      if (health.hasError)
        SettingRow(
          label: context.l10n.commonWhatItSaid,
          value: Text(
            errorMessage(health.error!),
            style: Typo.data.copyWith(color: Palette.warn),
          ),
        ),
      if (providers == 0)
        SettingRow(
          label: context.l10n.settingsSourceProviders,
          value: Text(
            context.l10n.settingsNoProviders,
            style: Typo.data.copyWith(color: Palette.warn),
          ),
        ),
      SettingRow(
        label: context.l10n.settingsPlayer,
        hint: _facts.hardware.isEmpty && _facts.version.isNotEmpty
            ? context.l10n.settingsHardwareDecoderHint
            : null,
        value: Text(
          player.isEmpty
              ? (_facts.done ? context.l10n.settingsMpvNoAnswer : '…')
              : player,
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
        SettingRow(
          label: context.l10n.settingsDecoders,
          value: Text(context.l10n.settingsNoDecoderInfo, style: Typo.data),
        ),
      ];
    }
    final broken = [for (final codec in _video) decoders.unreliable(codec)]
        .nonNulls
        .toList();
    final commands = decoders.installCommands;
    return [
      SettingRow(
        label: context.l10n.settingsPicture,
        value: _Codecs(codecs: _video),
      ),
      SettingRow(
        label: context.l10n.settingsSound,
        value: _Codecs(codecs: _audio),
      ),
      for (final one in broken)
        SettingRow(
          label: context.l10n.settingsWarning,
          value: Text(
            one.fact(context.l10n),
            style: Typo.body.copyWith(fontSize: 13, color: Palette.warn),
          ),
        ),
      // Printed for the viewer, never run with elevated access.
      if (broken.isNotEmpty && commands.isNotEmpty)
        SettingRow(
          label: context.l10n.settingsHowToFix,
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
    final l10n = context.l10n;
    final decoders = DeviceDecoders.instance;
    final missing = [
      for (final codec in [..._video, ..._audio])
        if (decoders.has(codec) == false) codec,
    ];
    final broken = [
      for (final codec in _video)
        decoders.unreliable(codec)?.fact(context.l10n),
    ].nonNulls;
    final status = health.hasError
        ? l10n.commonNotAnswering
        : l10n.commonAnswering;
    final version = _facts.version.isEmpty
        ? l10n.commonUnknown
        : _facts.version;
    final playerLog = '${stateDir()}/mpv.log';
    return [
      l10n.settingsDetailsLumeo(
        about?.version.isNotEmpty == true ? about!.version : l10n.commonUnknown,
      ),
      if (health.data case final data?)
        l10n.settingsDetailsCoreProviders(
          _address(about),
          status,
          data.providers,
        )
      else
        l10n.settingsDetailsCore(_address(about), status),
      if (_facts.hardware.isEmpty)
        l10n.settingsDetailsPlayer(version)
      else
        l10n.settingsDetailsPlayerHardware(version, _facts.hardware),
      l10n.settingsDetailsSystem(
        Platform.operatingSystem,
        Platform.operatingSystemVersion,
      ),
      if (missing.isNotEmpty)
        l10n.settingsDetailsMissingDecoder(missing.join(', ')),
      ...broken,
      if ((about?.logPath ?? '').isEmpty)
        l10n.settingsDetailsLogs(playerLog)
      else
        l10n.settingsDetailsLogsCore(playerLog, about!.logPath),
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
        label: _copied ? context.l10n.commonCopied : widget.label!,
        icon: _copied ? Icons.check : null,
        onPressed: _copy,
      );
    }
    return IconButton(
      onPressed: _copy,
      tooltip: _copied ? context.l10n.commonCopied : context.l10n.commonCopy,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      color: _copied ? Palette.text : Palette.dim,
      icon: Icon(_copied ? Icons.check : Icons.content_copy),
    );
  }
}
