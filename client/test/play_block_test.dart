import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/l10n/app_localizations.dart';
import 'package:lumeo/ui/widgets/play_block.dart';

void main() {
  setUpAll(initializeDateFormatting);
  final l10n = lookupAppLocalizations(const Locale('en'));
  final now = DateTime.utc(2026, 9, 24, 15);

  group('emptySources', () {
    test('an episode not out yet gives its date and nothing to retry', () {
      final empty = emptySources(
        failed: const [],
        released: DateTime.utc(2026, 10, 3),
        now: now,
        l10n: l10n,
      );
      expect(empty.text, 'Out Oct 3');
      expect(empty.retry, isFalse);
    });

    test('a date that is not out wins over a refusal', () {
      final empty = emptySources(
        failed: const [ProviderFailure(provider: 'Torrentio', status: 403)],
        released: DateTime.utc(2026, 10, 3),
        now: now,
        l10n: l10n,
      );
      expect(empty.text, 'Out Oct 3');
    });

    test('a refusal is the reason, whatever the date', () {
      final empty = emptySources(
        failed: const [ProviderFailure(provider: 'Torrentio', status: 403)],
        released: DateTime.utc(2026, 9, 24),
        now: now,
        l10n: l10n,
      );
      expect(empty.text, 'Torrentio is blocking requests from here (403)');
      expect(empty.retry, isTrue);
    });

    test('each provider that failed is named with its own reason', () {
      final empty = emptySources(
        failed: const [
          ProviderFailure(provider: 'Torrentio', status: 429),
          ProviderFailure(provider: 'MediaFusion', reason: 'no answer'),
        ],
        now: now,
        l10n: l10n,
      );
      expect(
        empty.text,
        'Torrentio is limiting requests (429) · MediaFusion did not answer',
      );
    });

    test('out today or yesterday means no copies yet, not none', () {
      // Cinemeta's date is midnight UTC of the release day: from then until
      // the episode airs and gets shared, an empty list is normal.
      expect(
        emptySources(
          failed: const [],
          released: DateTime.utc(2026, 9, 24),
          now: now,
          l10n: l10n,
        ).text,
        'Out today, no copies yet',
      );
      expect(
        emptySources(
          failed: const [],
          released: DateTime.utc(2026, 9, 23),
          now: now,
          l10n: l10n,
        ).text,
        'Out yesterday, no copies yet',
      );
    });

    test('an old title or a film with nothing listed has no copies', () {
      final empty = emptySources(
        failed: const [],
        released: DateTime.utc(2008, 1, 20),
        now: now,
        l10n: l10n,
      );
      expect(empty.text, 'No copies found');
      expect(empty.retry, isTrue);
      expect(
        emptySources(failed: const [], now: now, l10n: l10n).text,
        'No copies found',
      );
    });
  });

  test('a provider failure is said as what it means', () {
    String say(int status, [String reason = '']) => ProviderFailure(
      provider: 'X',
      status: status,
      reason: reason,
    ).phrase(l10n);
    expect(say(0, 'no answer'), 'X did not answer');
    expect(say(401), 'X is blocking requests from here (401)');
    expect(say(503), 'X is down (503)');
    expect(say(404, '404 Not Found'), 'X: 404 Not Found');
  });

  test('the core reports a refusal with its status', () {
    final failure = ProviderFailure.fromJson(const {
      'provider': 'Torrentio',
      'reason': '403 Forbidden',
      'status': 403,
    });
    expect(failure.status, 403);
    expect(failure.reason, '403 Forbidden');
  });
}
