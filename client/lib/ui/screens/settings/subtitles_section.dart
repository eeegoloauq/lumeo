import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../api/preferences_store.dart';
import '../../player/menus.dart';
import '../../player/subtitle_style.dart';
import '../../widgets/setting_row.dart';
import 'controls.dart';

class SubtitlesSection extends StatelessWidget {
  const SubtitlesSection({
    super.key,
    required this.preferences,
    required this.patch,
    required this.error,
  });

  final PreferencesStore preferences;
  final Future<void> Function(Map<String, Object?>) patch;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final current = preferences.current;
    return SettingsBlock(
      title: 'Subtitles',
      children: [
        if (current != null) ...[
          _Preview(preferences: current),
          const SizedBox(height: 8),
        ],
        SettingRows([
          if (current != null) ...[
            SettingRow(
              label: 'Languages',
              value: LanguageList(
                preference: 'subtitleLanguages',
                chosen: current.subtitleLanguages,
                preferences: preferences,
                onPatch: patch,
              ),
            ),
            SettingRow(
              label: 'Turn on',
              hint: 'Foreign audio: when the sound isn’t in these languages.',
              value: Segments<String>(
                choices: const [
                  ('always', 'Always'),
                  ('foreign', 'Foreign audio'),
                  ('manual', 'Manual'),
                ],
                selected: current.subtitleMode,
                onSelected: (mode) => patch({'subtitleMode': mode}),
              ),
            ),
            SettingRow(
              label: 'Size',
              value: Segments<double>(
                choices: [
                  for (final (i, label) in TracksMenu.scaleLabels.indexed)
                    (TracksMenu.scales[i], label),
                ],
                selected: TracksMenu.scales
                    .where((s) => (s - current.subtitleScale).abs() < 0.01)
                    .firstOrNull,
                onSelected: (scale) => patch({'subtitleScale': scale}),
              ),
            ),
            SettingRow(
              label: 'Colour',
              value: ColourDots(
                colours: subtitleColours,
                selected: current.subtitleColor,
                onSelected: (colour) => patch({'subtitleColor': colour}),
              ),
            ),
            SettingRow(
              label: 'Background',
              value: Segments<String>(
                choices: const [
                  ('none', 'None'),
                  ('shadow', 'Shadow'),
                  ('box', 'Box'),
                ],
                selected: current.subtitleBackground,
                onSelected: (value) => patch({'subtitleBackground': value}),
              ),
            ),
            SettingRow(
              label: 'Height',
              // Stepped as a lift: mpv's sub-pos is 100 at the bottom edge
              // and lower numbers raise the line.
              value: PreferenceStepper(
                stored: 100 - current.subtitlePosition,
                min: 0,
                max: 30,
                step: 5,
                width: 120,
                describe: (lift) => lift <= 0 ? 'bottom' : '$lift% up',
                lessLabel: 'Lower',
                moreLabel: 'Higher',
                onChosen: (lift) => patch({'subtitlePosition': 100 - lift}),
              ),
            ),
            SettingRow(
              label: 'Keep the file’s styling',
              hint:
                  'Styled subtitles, like anime signs, stay as drawn. Off, '
                  'the colour and background above apply to them too.',
              value: SettingSwitch(
                label: 'Keep the file’s styling',
                value: current.subtitleKeepStyling,
                onChanged: (on) => patch({'subtitleKeepStyling': on}),
              ),
            ),
          ],
          if (current == null && error == null) const SettingsLoading(),
          if (error != null) ErrorRow(error!),
        ]),
      ],
    );
  }
}

/// A sample line drawn the way the choices below would have mpv draw it:
/// close enough to judge a colour and a size, not a promise about a font.
class _Preview extends StatelessWidget {
  const _Preview({required this.preferences});

  final Preferences preferences;

  @override
  Widget build(BuildContext context) {
    final colour =
        subtitleColours[preferences.subtitleColor] ?? subtitleColours['white']!;
    final background = preferences.subtitleBackground;
    // mpv draws a default line at about 1/20 of the picture's height.
    const height = 180.0;
    final size = height / 20 * 2.2 * preferences.subtitleScale;
    final lift = (100 - preferences.subtitlePosition) / 100 * height;
    final text = Text(
      'Don’t go. One more episode.',
      textAlign: TextAlign.center,
      textScaler: TextScaler.noScaling,
      style: TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: colour,
        shadows: [
          const Shadow(color: Color(0xFF000000), blurRadius: 2),
          if (background == 'shadow')
            const Shadow(
              color: Color(0xC0000000),
              blurRadius: 6,
              offset: Offset(0, 3),
            ),
        ],
      ),
    );
    return ExcludeSemantics(
      child: Container(
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4A4740), Color(0xFF26272B)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 14 + lift,
              child: Center(
                child: background == 'box'
                    ? DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Color(0xC0000000),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: text,
                        ),
                      )
                    : text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
