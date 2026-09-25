// What the player shows instead of, or over, the picture: the wait for a film,
// the reason it did not start, and short notices.
import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/artwork_image.dart';
import '../widgets/buttons.dart';
import '../widgets/loading.dart';

/// Translate mpv failures into actionable playback messages.
String playbackTrouble(Object error) {
  final text = '$error';
  final codec = decoderErrorCodec(error);
  if (codec != null) {
    // Ask mpv about decoder availability before claiming it is missing.
    return 'The player could not decode $codec.';
  }
  if (text.contains('Failed to open')) {
    // Startup retries are exhausted; the failing layer remains unknown.
    return 'The player could not start this file.';
  }
  return text;
}

/// The codec an mpv error says it had no decoder for.
String? decoderErrorCodec(Object error) =>
    RegExp(r"decoder for codec '([^']+)'").firstMatch('$error')?.group(1);

class PlayerNotice extends StatelessWidget {
  const PlayerNotice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Palette.floating.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(Shape.control),
        border: Border.all(color: Palette.rim),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Text(text, style: Typo.cardTitle.copyWith(color: Palette.dim)),
      ),
    );
  }
}

/// Dim artwork behind loading text; decode it at its display width.
class PlayerBackdrop extends StatelessWidget {
  const PlayerBackdrop({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    // AnimatedSwitcher lays children out loosely; fill the screen explicitly.
    return IgnorePointer(
      child: SizedBox.expand(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Image(
            image: ResizeImage.resizeIfNeeded(
              (MediaQuery.sizeOf(context).width *
                      MediaQuery.devicePixelRatioOf(context))
                  .round(),
              null,
              ArtworkImage(url),
            ),
            fit: BoxFit.cover,
            color: const Color(0xA8000000),
            colorBlendMode: BlendMode.darken,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
            frameBuilder: (_, child, frame, loadedSync) => loadedSync
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 300),
                    child: child,
                  ),
          ),
        ),
      ),
    );
  }
}

class PlayerWaiting extends StatefulWidget {
  const PlayerWaiting({
    super.key,
    required this.title,
    required this.percent,
    required this.error,
    required this.choiceError,
    required this.choiceEmpty,
    required this.overPicture,
    required this.playbackError,
    required this.decoderMissing,
    required this.decoderInstallHint,
    required this.onRetry,
    required this.onBack,
    required this.showBack,
  });

  final String title;
  final double? percent;
  final Object? error;
  final Object? choiceError;
  final bool choiceEmpty;
  final bool overPicture;
  final Object? playbackError;
  final bool? decoderMissing;
  final String? decoderInstallHint;
  final VoidCallback onRetry;
  final VoidCallback onBack;
  final bool showBack;

  @override
  State<PlayerWaiting> createState() => _PlayerWaitingState();
}

class _PlayerWaitingState extends State<PlayerWaiting> {
  bool _showPresentation = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(Loading.delay, () {
      if (mounted) setState(() => _showPresentation = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failed =
        widget.error != null ||
        widget.choiceError != null ||
        widget.choiceEmpty ||
        widget.playbackError != null;
    final codec = widget.playbackError == null
        ? null
        : decoderErrorCodec(widget.playbackError!);
    final message = widget.choiceEmpty
        ? 'No copy of ${widget.title}'
        : widget.choiceError != null
        ? 'Could not start this copy'
        : widget.error != null
        ? 'The core stopped answering'
        : widget.playbackError != null
        ? widget.decoderMissing == true && codec != null
              ? 'Nothing installed here decodes $codec'
              : 'This copy would not start'
        : '';
    return Stack(
      children: [
        if (widget.overPicture)
          const Positioned.fill(child: ColoredBox(color: Color(0x99000000))),
        if (failed || _showPresentation)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!failed) ...[
                  const SizedBox(
                    width: 56,
                    height: 56,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                      backgroundColor: Color(0x33FFFFFF),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (!failed &&
                    widget.percent != null &&
                    widget.percent! < 1) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${(widget.percent! * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0x99FFFFFF),
                    ),
                  ),
                ],
                if (failed) ...[
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: const TextStyle(
                      color: Color(0xFFAAAAAA),
                      fontSize: 13,
                    ),
                  ),
                  if (widget.decoderMissing == true &&
                      widget.decoderInstallHint != null) ...[
                    const SizedBox(height: 6),
                    SelectableText(
                      widget.decoderInstallHint!,
                      textAlign: TextAlign.center,
                      style: Typo.data,
                    ),
                  ],
                  const SizedBox(height: 16),
                  QuietButton(label: 'Try again', onPressed: widget.onRetry),
                ],
              ],
            ),
          ),
        if (widget.showBack)
          Positioned(
            left: 24,
            top: 16,
            child: IconButton(
              onPressed: widget.onBack,
              tooltip: 'Back (Esc)',
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          ),
      ],
    );
  }
}
