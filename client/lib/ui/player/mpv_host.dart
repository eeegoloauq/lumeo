import 'dart:async';
import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';
import 'package:media_kit/media_kit.dart';

/// Same names, in the same order, as media_kit's own loader.
MPV openLibmpv() {
  try {
    return MPV(DynamicLibrary.open('libmpv.so'));
  } on ArgumentError {
    return MPV(DynamicLibrary.open('libmpv.so.2'));
  }
}

/// A second libmpv client on the player's core. media_kit keeps
/// client-message and shutdown events to itself; this one hears them, and
/// reads properties without blocking the Dart thread.
class MpvHost {
  MpvHost._(this._mpv, this._handle) {
    _wakeup = NativeCallable<Void Function(Pointer<Void>)>.listener((
      Pointer<Void> _,
    ) {
      while (true) {
        final event = _mpv.mpv_wait_event(_handle, 0).ref;
        if (event.event_id == mpv_event_id.MPV_EVENT_NONE) break;
        switch (event.event_id) {
          case mpv_event_id.MPV_EVENT_CLIENT_MESSAGE:
            final message = event.data.cast<mpv_event_client_message>().ref;
            _messages.add([
              for (var i = 0; i < message.num_args; i++)
                message.args[i].cast<Utf8>().toDartString(),
            ]);
            break;
          case mpv_event_id.MPV_EVENT_SHUTDOWN:
            if (!_shutdown.isCompleted) _shutdown.complete();
            for (final pending in _reads.values) {
              pending.complete(null);
            }
            _reads.clear();
            break;
          case mpv_event_id.MPV_EVENT_GET_PROPERTY_REPLY:
            final pending = _reads.remove(event.reply_userdata);
            if (pending == null) break;
            final property = event.data.cast<mpv_event_property>().ref;
            pending.complete(
              event.error < 0 || property.data == nullptr
                  ? null
                  : property.data.cast<Pointer<Utf8>>().value.toDartString(),
            );
            break;
        }
      }
    });
    _mpv.mpv_set_wakeup_callback(_handle, _wakeup.nativeFunction, nullptr);
  }

  static Future<MpvHost> attach(NativePlayer platform) async {
    final mpv = openLibmpv();
    final name = 'lumeo'.toNativeUtf8();
    final handle = mpv.mpv_create_client(
      Pointer<mpv_handle>.fromAddress(await platform.handle),
      name.cast(),
    );
    calloc.free(name);
    if (handle == nullptr) throw StateError('Could not create mpv client');
    return MpvHost._(mpv, handle);
  }

  final MPV _mpv;
  final Pointer<mpv_handle> _handle;
  late final NativeCallable<Void Function(Pointer<Void>)> _wakeup;
  final _messages = StreamController<List<String>>.broadcast();
  final _shutdown = Completer<void>();
  final _reads = <int, Completer<String?>>{};
  int _nextReply = 0;
  bool _disposed = false;

  Stream<List<String>> get messages => _messages.stream;
  Future<void> get shutdown => _shutdown.future;

  Future<String?> get(String property) {
    if (_disposed || _shutdown.isCompleted) return Future.value(null);
    final reply = ++_nextReply;
    final pending = _reads[reply] = Completer<String?>();
    final name = property.toNativeUtf8();
    final result = _mpv.mpv_get_property_async(
      _handle,
      reply,
      name.cast(),
      mpv_format.MPV_FORMAT_STRING,
    );
    calloc.free(name);
    if (result < 0) {
      _reads.remove(reply);
      pending.complete(null);
    }
    return pending.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _mpv.mpv_set_wakeup_callback(_handle, nullptr, nullptr);
    _wakeup.close();
    for (final pending in _reads.values) {
      pending.complete(null);
    }
    _reads.clear();
    _messages.close();
    _mpv.mpv_destroy(_handle);
  }
}
