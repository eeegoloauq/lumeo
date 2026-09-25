import 'package:flutter/material.dart';

import '../../../api/preferences_store.dart';
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
      title: 'Appearance',
      children: [
        SettingRows([
          if (current != null)
            SettingRow(
              label: 'Accent',
              value: ColourDots(
                colours: Palette.accents,
                selected: current.accent,
                onSelected: (accent) => patch({'accent': accent}),
              ),
            ),
          // This screen's, so it is kept in client.json.
          SettingRow(
            label: 'Text size',
            value: Segments<String>(
              choices: const [
                ('small', 'Small'),
                ('default', 'Default'),
                ('large', 'Large'),
              ],
              selected: settings.textScale,
              onSelected: (scale) => settings.textScale = scale,
            ),
          ),
          if (current != null)
            SettingRow(
              label: 'Episode stills',
              hint: 'Blur keeps an episode’s still hidden until it is watched.',
              value: Segments<String>(
                choices: const [
                  ('show', 'Show'),
                  ('blur', 'Blur'),
                  ('hide', 'Hide'),
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
