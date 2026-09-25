/// The parts of the settings page, in the order it shows them. Its own file
/// so the shell and the downloads panel can name one without the page.
enum SettingsSection {
  general('General'),
  appearance('Appearance'),
  playback('Playback'),
  subtitles('Subtitles'),
  downloads('Downloads'),
  sources('Sources'),
  shortcuts('Shortcuts'),
  about('About');

  const SettingsSection(this.title);

  final String title;
}
