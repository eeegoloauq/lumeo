// The downloads panel under the bar.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

import 'app.dart';

void main() {
  uiTest('the downloads panel opens and its stop button can be pressed', (
    tester,
  ) async {
    // The panel was clipped inside the 68-point bar, leaving its stop button
    // unreachable. Tapping it catches clipping that a rectangle assertion
    // misses.
    final stopped = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload(waitingSince: DateTime.now())],
          stopped: stopped,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop and discard'));
    await waitFor(
      tester,
      () async =>
          stopped.contains('d1') &&
          find.byKey(const ValueKey('downloads')).evaluate().isEmpty,
      what: 'the download stopped and its row went',
    );
    expect(stopped, contains('d1'), reason: 'the core was told to stop it');
    expect(
      find.byKey(const ValueKey('downloads')),
      findsNothing,
      reason: 'and the row goes at once, not on the next poll',
    );
  });

  uiTest('a download starting moves nothing else in the bar', (tester) async {
    // Starting a download used to shift search and window controls out from
    // under the pointer.
    await openHome(tester);
    final quietTabs = tester.getCenter(find.text('Home'));
    final quietSearch = tester.getCenter(find.byTooltip('Search  ·  Ctrl+F'));

    // A new key forces a new State; otherwise the second pump reuses the first
    // core.
    await tester.pumpWidget(
      testApp(
        key: UniqueKey(),
        api: fakeCore(downloads: [fakeDownload()]),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('downloads')),
      findsOneWidget,
      reason: 'the indicator is there to have moved something',
    );
    expect(tester.getCenter(find.text('Home')), quietTabs);
    expect(tester.getCenter(find.byTooltip('Search  ·  Ctrl+F')), quietSearch);
  });

  uiTest('the downloads panel hangs to the left of its button', (tester) async {
    // The panel used to open past the window edge, hiding the release name and
    // peer count. Measure from the indicator because the menu clamps to the
    // window edge.
    await openHome(tester, downloads: [fakeDownload()]);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    final panel = tester.getRect(find.byKey(const ValueKey('download:d1')));
    final button = tester.getRect(find.byKey(const ValueKey('downloads')));
    expect(
      panel.right,
      closeTo(button.right, 1),
      reason: 'to the right of the button there is only the window edge',
    );
    expect(panel.left, greaterThanOrEqualTo(0));
  });

  uiTest('a download with nothing to play yet opens its title', (tester) async {
    // The title of what is arriving used to be two clicks away, through a
    // catalogue that does not know it is downloading.
    await openHome(tester, downloads: [fakeDownload(ready: false)]);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    // Select by key; the title also appears on a shelf behind the dismissible
    // panel.
    await tester.tap(find.byKey(const ValueKey('download:d1')));
    await tester.pumpAndSettle();
    expect(find.text('Popular films'), findsNothing, reason: 'on the title');
  });

  uiTest('a download with something to play plays from the panel', (
    tester,
  ) async {
    await openHome(tester, downloads: [fakeDownload()]);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download:d1')));
    await tester.pump();
    expect(playing(tester), 'd1');
  });

  uiTest('Storage in the downloads panel opens the downloads settings', (
    tester,
  ) async {
    await openHome(tester, downloads: [fakeDownload()]);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Storage ›'));
    await tester.pumpAndSettle();
    expect(find.text('ARRIVING'), findsNothing, reason: 'the panel closed');
    final limit = find.text('Disk limit');
    expect(limit, findsOneWidget);
    final window = tester.view.physicalSize / tester.view.devicePixelRatio;
    final rect = tester.getRect(limit);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(window.height));

    // Reopening Storage on the same page must scroll back to Downloads.
    await tester.drag(find.text('Disk limit'), const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(tester.getRect(limit).bottom, greaterThan(window.height));
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Storage ›'));
    await tester.pumpAndSettle();
    expect(tester.getRect(limit).top, greaterThanOrEqualTo(0));
    expect(tester.getRect(limit).bottom, lessThanOrEqualTo(window.height));
  });
}
