import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../api/preferences_store.dart';
import '../../../l10n/l10n.dart';
import '../../player/menus.dart';
import '../../player/subtitle_style.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/setting_row.dart';
import 'controls.dart';

class AudioSubtitlesSection extends StatelessWidget {
  const AudioSubtitlesSection({
    super.key,
    required this.preferences,
    required this.picture,
    required this.patch,
    required this.error,
  });

  final PreferencesStore preferences;

  /// What the sample line is drawn over; empty for a plain backdrop.
  final Future<String> picture;
  final Future<void> Function(Map<String, Object?>) patch;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final current = preferences.current;
    return SettingsBlock(
      title: context.l10n.settingsAudioSubtitles,
      children: [
        SettingRows([
          if (current != null) ...[
            SettingRow(
              label: context.l10n.settingsAudioLanguages,
              value: LanguageList(
                preference: 'audioLanguages',
                chosen: current.audioLanguages,
                preferences: preferences,
                onPatch: patch,
                empty: context.l10n.settingsFileLanguage,
              ),
            ),
            SettingRow(
              label: context.l10n.settingsSubtitleLanguages,
              value: LanguageList(
                preference: 'subtitleLanguages',
                chosen: current.subtitleLanguages,
                preferences: preferences,
                onPatch: patch,
              ),
            ),
            SettingRow(
              label: context.l10n.settingsSubtitleMode,
              hint: context.l10n.settingsForeignAudioHint,
              value: Segments<String>(
                choices: [
                  ('always', context.l10n.settingsAlways),
                  ('foreign', context.l10n.settingsForeignAudio),
                  ('manual', context.l10n.settingsManual),
                ],
                selected: current.subtitleMode,
                onSelected: (mode) => patch({'subtitleMode': mode}),
              ),
            ),
          ],
          if (current == null && error == null) const SettingsLoading(),
          if (error != null) ErrorRow(error!),
        ]),
        if (current != null) ...[
          SettingsSubheading(context.l10n.settingsSubtitleStyle),
          _Preview(preferences: current, picture: picture),
          const SizedBox(height: 8),
          SettingRows([
            SettingRow(
              label: context.l10n.settingsSubtitleSize,
              value: Segments<double>(
                choices: [
                  for (final i in List.generate(
                    TracksMenu.scales.length,
                    (i) => i,
                  ))
                    (
                      TracksMenu.scales[i],
                      TracksMenu.scaleLabel(i, context.l10n),
                    ),
                ],
                selected: TracksMenu.scales
                    .where((s) => (s - current.subtitleScale).abs() < 0.01)
                    .firstOrNull,
                onSelected: (scale) => patch({'subtitleScale': scale}),
              ),
            ),
            SettingRow(
              label: context.l10n.settingsSubtitleColour,
              value: ColourDots(
                colours: subtitleColours,
                selected: current.subtitleColor,
                onSelected: (colour) => patch({'subtitleColor': colour}),
              ),
            ),
            SettingRow(
              label: context.l10n.settingsSubtitleBackground,
              value: Segments<String>(
                choices: [
                  ('none', context.l10n.settingsOutline),
                  ('shadow', context.l10n.settingsShadow),
                  ('box', context.l10n.settingsBox),
                ],
                selected: current.subtitleBackground,
                onSelected: (value) => patch({'subtitleBackground': value}),
              ),
            ),
            SettingRow(
              label: context.l10n.settingsSubtitleHeight,
              // Stepped as a lift: mpv's sub-pos is 100 at the bottom edge
              // and lower numbers raise the line.
              value: PreferenceStepper(
                stored: 100 - current.subtitlePosition,
                min: 0,
                max: 30,
                step: 5,
                width: 120,
                describe: (lift) => lift <= 0
                    ? context.l10n.settingsBottom
                    : context.l10n.settingsPercentUp(lift),
                lessLabel: context.l10n.settingsLower,
                moreLabel: context.l10n.settingsHigher,
                onChosen: (lift) => patch({'subtitlePosition': 100 - lift}),
              ),
            ),
            SettingRow(
              label: context.l10n.settingsKeepFileStyling,
              hint: context.l10n.settingsKeepFileStylingHint,
              value: SettingSwitch(
                label: context.l10n.settingsKeepFileStyling,
                value: current.subtitleKeepStyling,
                onChanged: (on) => patch({'subtitleKeepStyling': on}),
              ),
            ),
          ]),
        ],
      ],
    );
  }
}

/// A sample line drawn the way the choices above would have mpv draw it:
/// the same size, outline, shadow and box in mpv's units, in our font rather
/// than the system's sans.
class _Preview extends StatelessWidget {
  const _Preview({required this.preferences, required this.picture});

  final Preferences preferences;
  final Future<String> picture;

  @override
  Widget build(BuildContext context) {
    final colour =
        subtitleColours[preferences.subtitleColor] ?? subtitleColours['white']!;
    final background = preferences.subtitleBackground;
    const height = 180.0;
    // Pixels per unit of mpv's 720-line scale, twice true to scale: a line in
    // a preview this small is too small to judge. sub-scale grows the outline
    // and the shadow with the text, as libass does.
    final unit = height / 720 * 2 * preferences.subtitleScale;
    final lift = (100 - preferences.subtitlePosition) / 100 * height;
    // libass sizes a font by its OS/2 win ascent plus descent rather than
    // its em, and that line is 1.395 em of IBM Plex Sans.
    const plexLine = 1.395;
    final style = TextStyle(
      fontSize: subtitleFontSize * unit / plexLine,
      height: plexLine,
      color: colour,
    );
    Text line(TextStyle style) => Text(
      context.l10n.settingsSubtitlePreview,
      textAlign: TextAlign.center,
      textScaler: TextScaler.noScaling,
      style: style,
    );
    // mpv's outline grows the glyph by the border size, which is a stroke
    // twice as wide centred on its edge; the shadow is that outlined shape
    // again, moved down and right. The box replaces both.
    final Widget text = background == 'box'
        ? line(style)
        : Stack(
            children: [
              line(
                style.copyWith(
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = subtitleBorder(background) * unit * 2
                    ..strokeJoin = StrokeJoin.round
                    ..color = const Color(0xFF000000),
                  color: null,
                  shadows: [
                    if (background == 'shadow')
                      Shadow(
                        offset: Offset(
                          subtitleShadow * unit,
                          subtitleShadow * unit,
                        ),
                      ),
                  ],
                ),
              ),
              line(style),
            ],
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
            Positioned.fill(
              child: FutureBuilder(
                future: picture,
                builder: (context, url) => (url.data ?? '').isEmpty
                    ? const SizedBox.shrink()
                    : Image(
                        image: ArtworkImage(url.data!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: height * subtitleMargin / 720 + lift,
              child: Center(
                child: background == 'box'
                    ? DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Color(subtitleBoxColour),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(
                            subtitleBorder(background) * unit,
                          ),
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
