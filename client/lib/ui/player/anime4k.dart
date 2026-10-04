import 'dart:io';

/// Anime4K 4.0.1's high-end mpv presets: A for 1080p anime, B for 720p, C
/// for 480p. They run as mpv user shaders; off is an empty list.
enum Anime4k {
  off([]),
  a([
    'Clamp_Highlights',
    'Restore_CNN_VL',
    'Upscale_CNN_x2_VL',
    'AutoDownscalePre_x2',
    'AutoDownscalePre_x4',
    'Upscale_CNN_x2_M',
  ]),
  b([
    'Clamp_Highlights',
    'Restore_CNN_Soft_VL',
    'Upscale_CNN_x2_VL',
    'AutoDownscalePre_x2',
    'AutoDownscalePre_x4',
    'Upscale_CNN_x2_M',
  ]),
  c([
    'Clamp_Highlights',
    'Upscale_Denoise_CNN_x2_VL',
    'AutoDownscalePre_x2',
    'AutoDownscalePre_x4',
    'Upscale_CNN_x2_M',
  ]);

  const Anime4k(this.shaders);

  final List<String> shaders;

  // mpv reads files, so the shaders are taken from the bundle on disk, which
  // keeps assets in data/flutter_assets beside the executable on Linux and
  // Windows.
  static final _dir =
      '${File(Platform.resolvedExecutable).parent.path}/data/flutter_assets/assets/anime4k';

  /// The value of mpv's `glsl-shaders`, a path list.
  String get paths =>
      [for (final shader in shaders) '$_dir/Anime4K_$shader.glsl']
          .join(Platform.isWindows ? ';' : ':');

  /// The preset whose shaders mpv runs, or null for a list of someone else's.
  /// mpv joins the list with `:` or `,` depending on its version, and a
  /// Windows path has a `:` of its own, so only the file names are compared.
  static Anime4k? of(String paths) {
    final files = [
      for (final match in RegExp(r'[^/\\:;,]+\.glsl').allMatches(paths))
        match[0],
    ].join(',');
    for (final preset in values) {
      if (files == preset.shaders.map((s) => 'Anime4K_$s.glsl').join(',')) {
        return preset;
      }
    }
    return null;
  }
}
