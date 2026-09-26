import '../../../l10n/app_localizations.dart';

/// The parts of the settings page, in the order it shows them. Its own file
/// so the shell and the downloads panel can name one without the page.
enum SettingsSection {
  general,
  appearance,
  playback,
  subtitles,
  downloads,
  sources,
  shortcuts,
  about;

  String title(AppLocalizations l10n) => switch (this) {
    general => l10n.settingsGeneral,
    appearance => l10n.settingsAppearance,
    playback => l10n.settingsPlayback,
    subtitles => l10n.settingsSubtitles,
    downloads => l10n.settingsDownloads,
    sources => l10n.settingsSources,
    shortcuts => l10n.settingsShortcuts,
    about => l10n.settingsAbout,
  };
}
