import 'package:flutter/material.dart';

/// Material's spinner, held back for [delay]: most answers from a local core
/// come sooner, and a spinner that flashes for a frame reads as a glitch.
class Loading extends StatefulWidget {
  const Loading({super.key, this.size = 32});

  @visibleForTesting
  static const delay = Duration(milliseconds: 300);

  final double size;

  @override
  State<Loading> createState() => _LoadingState();
}

class _LoadingState extends State<Loading> {
  // Kept in the state: a parent rebuilding mid-wait must not restart it.
  final _shown = Future<void>.delayed(Loading.delay);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _shown,
      builder: (context, snapshot) => SizedBox.square(
        dimension: widget.size,
        child: snapshot.connectionState == ConnectionState.done
            ? const CircularProgressIndicator(
                semanticsLabel: 'Loading',
                strokeWidth: 3,
                strokeCap: StrokeCap.round,
              )
            : null,
      ),
    );
  }
}
