import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/player/anime4k.dart';

void main() {
  test('the preset is read back from any mpv\'s shader list', () {
    expect(Anime4k.of(''), Anime4k.off);
    expect(Anime4k.of(Anime4k.b.paths), Anime4k.b);
    // mpv 0.37 joins the list with commas; Windows paths carry a drive.
    final commas = [
      for (final s in Anime4k.c.shaders)
        r'C:\Lumeo\data\Anime4K_'
            '$s.glsl',
    ].join(',');
    expect(Anime4k.of(commas), Anime4k.c);
    expect(Anime4k.of('/home/me/shaders/FSRCNNX_x2.glsl'), isNull);
    expect(Anime4k.of(Anime4k.a.paths.split(':').skip(1).join(':')), isNull);
  });
}
