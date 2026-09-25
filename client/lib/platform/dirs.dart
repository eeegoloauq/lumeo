import 'dart:io';

/// Where the client keeps what it writes, in the app's own folder: the XDG
/// base directories on Linux; on Windows settings in %APPDATA% and the rest
/// in %LOCALAPPDATA%\Lumeo, beside the core's Data and Cache.
///
/// [environment] is the seam the tests use.
String configDir([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  if (Platform.isWindows) return '${env['APPDATA'] ?? ''}/Lumeo';
  return _xdg(env, 'XDG_CONFIG_HOME', '.config');
}

String cacheDir([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  if (Platform.isWindows) return '${env['LOCALAPPDATA'] ?? ''}/Lumeo/Cache';
  return _xdg(env, 'XDG_CACHE_HOME', '.cache');
}

String stateDir([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  if (Platform.isWindows) return '${env['LOCALAPPDATA'] ?? ''}/Lumeo/State';
  return _xdg(env, 'XDG_STATE_HOME', '.local/state');
}

/// The core's data directory, where it keeps its database, its downloads
/// and the API token: the same place the core itself picks, LUMEO_DATA
/// first, so a core started by hand with one is found by a client given the
/// same.
String dataDir([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final chosen = env['LUMEO_DATA'];
  if (chosen != null && chosen.isNotEmpty) return chosen;
  if (Platform.isWindows) return '${env['LOCALAPPDATA'] ?? ''}/Lumeo/Data';
  return _xdg(env, 'XDG_DATA_HOME', '.local/share');
}

String _xdg(Map<String, String> env, String variable, String underHome) {
  final dir = env[variable];
  return dir != null && dir.isNotEmpty
      ? '$dir/lumeo'
      : '${env['HOME'] ?? ''}/$underHome/lumeo';
}
