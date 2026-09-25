import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';

import 'mpv_host.dart' show openLibmpv;

const _options = {
  'vo': 'null',
  'aid': 'no',
  'sid': 'no',
  'pause': 'yes',
  'keep-open': 'always',
  'hwdec': 'auto-copy',
  // Keyframes only, and nothing read ahead: every byte of a torrent that is
  // read is a byte fetched.
  'hr-seek': 'no',
  'cache': 'no',
  'demuxer-readahead-secs': '0',
  'demuxer-max-bytes': '128KiB',
  // mpv scales, so a 4K frame never crosses into Dart or onto disk.
  'vf': 'scale=480:-2',
  'load-scripts': 'no',
  'ytdl': 'no',
};

const _load = 1, _seek = 2, _grab = 3;

/// Single frames out of a video, from an mpv of our own: a keyframe seek,
/// then `screenshot-raw` (pixels handed to this client) or
/// `screenshot-to-file`. One request at a time; the caller waits for each.
class FrameGrabber {
  FrameGrabber(String url, {Map<String, String> headers = const {}}) {
    final mpv = _mpv = openLibmpv();
    _handle = mpv.mpv_create();
    if (_handle == nullptr) {
      _opened.complete(false);
      return;
    }
    final options = {
      ..._options,
      // A string list, which mpv splits at commas; a header has none.
      if (headers.isNotEmpty)
        'http-header-fields': [
          for (final MapEntry(:key, :value) in headers.entries) '$key: $value',
        ].join(','),
    };
    for (final MapEntry(:key, :value) in options.entries) {
      final name = key.toNativeUtf8(), data = value.toNativeUtf8();
      mpv.mpv_set_option_string(_handle, name.cast(), data.cast());
      calloc.free(name);
      calloc.free(data);
    }
    if (mpv.mpv_initialize(_handle) < 0) {
      mpv.mpv_destroy(_handle);
      _handle = nullptr;
      _opened.complete(false);
      return;
    }
    _wakeup = NativeCallable<Void Function(Pointer<Void>)>.listener(
      (Pointer<Void> _) => _drain(),
    );
    mpv.mpv_set_wakeup_callback(_handle, _wakeup!.nativeFunction, nullptr);
    if (_command(_load, ['loadfile', url]) < 0) _fail();
  }

  late final MPV _mpv;
  Pointer<mpv_handle> _handle = nullptr;
  NativeCallable<Void Function(Pointer<Void>)>? _wakeup;
  final _opened = Completer<bool>();
  bool _dead = false;
  bool _disposed = false;

  // The request in flight: where its frame goes (null for Dart), and who
  // waits for it.
  String? _file;
  Completer<Object?>? _pending;
  bool _seeking = false;

  /// True once the file is loaded, false if it never will be.
  Future<bool> get opened => _opened.future;

  /// The frame at [at], as mpv's `seek` takes it with [flags]; null when
  /// there is none.
  Future<ui.Image?> frame(String at, String flags) async =>
      await _request(at, flags, null) as ui.Image?;

  /// Writes the frame at [at] to [path], in the format its extension names;
  /// false when it did not.
  Future<bool> save(String at, String flags, String path) async =>
      await _request(at, flags, path) == true;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _fail();
    // libmpv's asynchronous teardown: quit, then destroy on the shutdown
    // event; mpv_terminate_destroy would block this thread.
    if (_handle != nullptr) _command(0, ['quit']);
  }

  Future<Object?> _request(String at, String flags, String? file) {
    if (_dead) return Future.value();
    final pending = _pending = Completer<Object?>();
    _file = file;
    _seeking = true;
    if (_command(_seek, ['seek', at, flags]) < 0) _finish(null);
    return pending.future;
  }

  void _finish(Object? result) {
    final pending = _pending;
    _pending = null;
    _seeking = false;
    pending?.complete(result);
  }

  void _fail() {
    _dead = true;
    if (!_opened.isCompleted) _opened.complete(false);
    _finish(null);
  }

  void _drain() {
    while (_handle != nullptr) {
      final event = _mpv.mpv_wait_event(_handle, 0).ref;
      switch (event.event_id) {
        case mpv_event_id.MPV_EVENT_NONE:
          return;
        case mpv_event_id.MPV_EVENT_PLAYBACK_RESTART:
          if (!_opened.isCompleted) {
            _opened.complete(true);
          } else if (_seeking) {
            _seeking = false;
            final file = _file;
            final grab = file == null
                ? ['screenshot-raw', 'video']
                : ['screenshot-to-file', file, 'video'];
            if (_command(_grab, grab) < 0) _finish(null);
          }
        case mpv_event_id.MPV_EVENT_COMMAND_REPLY:
          if (_dead) break;
          if (event.reply_userdata == _load && event.error < 0) {
            _fail();
          } else if (event.reply_userdata == _seek && event.error < 0) {
            _finish(null);
          } else if (event.reply_userdata == _grab) {
            if (event.error < 0) {
              _finish(null);
            } else if (_file != null) {
              _finish(true);
            } else {
              _decode(event.data.cast<mpv_event_command>().ref.result);
            }
          }
        case mpv_event_id.MPV_EVENT_END_FILE:
          _fail(); // the stream failed; with keep-open, EOF is no end
        case mpv_event_id.MPV_EVENT_SHUTDOWN:
          _mpv.mpv_set_wakeup_callback(_handle, nullptr, nullptr);
          _wakeup!.close();
          _mpv.mpv_destroy(_handle);
          _handle = nullptr;
      }
    }
  }

  // The node is mpv's until the next mpv_wait_event, so the pixels are copied
  // before anything else happens.
  void _decode(mpv_node result) {
    final map = result.u.list.ref;
    var width = 0, height = 0, stride = 0;
    var pixels = Uint8List(0);
    for (var i = 0; i < map.num; i++) {
      final value = map.values[i];
      switch (map.keys[i].cast<Utf8>().toDartString()) {
        case 'w':
          width = value.u.int64;
        case 'h':
          height = value.u.int64;
        case 'stride':
          stride = value.u.int64;
        case 'data':
          final bytes = value.u.ba.ref;
          pixels = Uint8List.fromList(
            bytes.data.cast<Uint8>().asTypedList(bytes.size),
          );
      }
    }
    // bgr0 leaves the fourth byte undefined; mpv writes 0, which is clear.
    for (var i = 3; i < pixels.length; i += 4) {
      pixels[i] = 0xFF;
    }
    ui.decodeImageFromPixels(pixels, width, height, ui.PixelFormat.bgra8888, (
      image,
    ) {
      if (_pending == null) {
        image.dispose(); // disposed while decoding
      } else {
        _finish(image);
      }
    }, rowBytes: stride);
  }

  int _command(int reply, List<String> args) {
    final strings = [for (final arg in args) arg.toNativeUtf8()];
    final argv = calloc<Pointer<Int8>>(strings.length + 1);
    for (var i = 0; i < strings.length; i++) {
      argv[i] = strings[i].cast();
    }
    argv[strings.length] = nullptr;
    final result = _mpv.mpv_command_async(_handle, reply, argv);
    for (final string in strings) {
      calloc.free(string);
    }
    calloc.free(argv);
    return result;
  }
}
