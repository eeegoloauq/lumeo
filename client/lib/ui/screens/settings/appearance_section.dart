import 'package:flutter/material.dart';

import '../../../api/preferences_store.dart';
import '../../../l10n/l10n.dart';
import '../../../platform/local_settings.dart';
import '../../theme.dart';
import '../../widgets/setting_row.dart';
import 'controls.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({
    super.key,
    required this.preferences,
    required this.settings,
    required this.patch,
    required this.error,
  });

  final PreferencesStore preferences;
  final LocalSettings settings;
  final Future<void> Function(Map<String, Object?>) patch;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final current = preferences.current;
    return SettingsBlock(
      title: context.l10n.settingsAppearance,
      children: [
        SettingRows([
          if (current != null)
            SettingRow(
              label: context.l10n.settingsAccent,
              value: ColourDots(
                colours: Palette.accents,
                selected: current.accent,
                onSelected: (accent) => patch({'accent': accent}),
              ),
            ),
          // This screen's, so it is kept in client.json.
          SettingRow(
            label: context.l10n.settingsTextSize,
            value: Segments<String>(
              choices: [
                ('small', context.l10n.settingsSmall),
                ('default', context.l10n.settingsTextDefault),
                ('large', context.l10n.settingsLarge),
              ],
              selected: settings.textScale,
              onSelected: (scale) => settings.textScale = scale,
            ),
          ),
          if (current != null)
            SettingRow(
              label: context.l10n.settingsEpisodeStills,
              hint: context.l10n.settingsEpisodeStillsBlurHint,
              value: Segments<String>(
                choices: [
                  ('show', context.l10n.settingsShow),
                  ('blur', context.l10n.settingsBlur),
                  ('hide', context.l10n.settingsHide),
                ],
                selected: current.episodeArtwork,
                onSelected: (value) => patch({'episodeArtwork': value}),
              ),
            ),
          if (current == null && error == null) const SettingsLoading(),
          if (error != null) ErrorRow(error!),
        ]),
      ],
    );
  }
}
