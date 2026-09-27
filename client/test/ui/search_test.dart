// Search: the field, the panel under it and the results page.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';

import 'fake_core.dart';

import 'app.dart';

void main() {
  uiTest('backspace deletes in the search field', (tester) async {
    // The shell's Backspace shortcut once took the key from search editing.
    await openHome(tester);
    await pressCtrlF(tester);
    await tester.enterText(find.byType(TextField), 'breaking bad');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'breaking ba',
    );
  });

  uiTest('a search gone through is offered again under the empty field', (
    tester,
  ) async {
    await openHome(tester);
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'breaking bad');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await pressCtrlF(tester);
    final recent = find.byKey(const ValueKey('recent:breaking bad'));
    await waitFor(
      tester,
      () async => recent.evaluate().isNotEmpty,
      what: 'the word from before under the empty field',
    );

    await tester.tap(recent);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(panelRow('tt0903747'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: recent, matching: find.byTooltip('Forget')),
    );
    await tester.pumpAndSettle();
    expect(recent, findsNothing);
  });

  uiTest('ctrl+F opens search and gives it the keyboard', (tester) async {
    // Ctrl+F must open and focus the search field in one press; the field does
    // not exist beforehand.
    await openHome(tester, downloads: [fakeDownload()]);
    await pressCtrlF(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: 'the field has the keyboard, without anything being clicked',
    );
    // Send the key to the window; enterText would focus the field itself.
    tester.testTextInput.enterText('breaking bad');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.textContaining('results for'), findsOneWidget);
  });

  uiTest('escape leaves the search field instead of going back', (
    tester,
  ) async {
    // Escape once navigated the page beneath search while leaving the field
    // open.
    await openHome(tester);
    await pressCtrlF(tester);
    tester.testTextInput.enterText('breaking bad');
    await tester.pumpAndSettle();
    expect(find.text('breaking bad'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'the panel closes');
    expect(find.text('breaking bad'), findsNothing, reason: 'the word goes');
    expect(
      find.text('Popular films'),
      findsWidgets,
      reason: 'and the page under it stayed where it was',
    );

    // Focus must land in the shell or its shortcuts stop receiving keys.
    await pressCtrlF(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: 'ctrl+F still works after escape',
    );
    expect(
      find.text('breaking bad'),
      findsNothing,
      reason: 'and the word does not come back with the field',
    );
  });

  uiTest('ctrl+F still finds the field after a title and back', (tester) async {
    // Returning from a result once left focus nowhere, disabling shell
    // shortcuts.
    await openHome(tester);
    await pressCtrlF(tester);
    tester.testTextInput.enterText('breaking bad');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await pressCtrlF(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: 'the shell still hears its own shortcuts',
    );
  });

  uiTest('titles appear under the field without Enter being pressed', (
    tester,
  ) async {
    // Search once waited for Enter and replaced the page instead of showing
    // results while typing.
    await openHome(tester);
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'night');
    expect(
      find.descendant(
        of: panelRow('tt0063350'),
        matching: find.text('Night of the Living Dead'),
      ),
      findsOneWidget,
    );
    expect(
      panelRow('tt0903747'),
      findsOneWidget,
      reason: 'both kinds, without being asked which one',
    );
    expect(
      find.text('Popular films'),
      findsWidgets,
      reason: 'the page underneath is still the page underneath',
    );
  });

  uiTest('one kind failing does not empty the panel', (tester) async {
    // Future.wait once let a film-provider timeout hide valid series results.
    await tester.pumpWidget(testApp(api: fakeCore(searchFails: 'movie')));
    await tester.pumpAndSettle();
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'breaking');
    expect(
      panelRow('tt0903747'),
      findsOneWidget,
      reason: 'the kind that did answer is still worth showing',
    );
    expect(find.textContaining('All results'), findsOneWidget);
  });

  uiTest('a core that answers nothing says so, in the panel', (tester) async {
    // A core failure must not be reported as "Nothing found" or link to the
    // same failing results page.
    await tester.pumpWidget(testApp(api: fakeCore(searchFails: 'all')));
    await tester.pumpAndSettle();
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'breaking');
    expect(find.text('The catalogue is not answering'), findsOneWidget);
    expect(find.textContaining('All results'), findsNothing);
  });

  uiTest('arrows walk the panel and Enter opens the row they are on', (
    tester,
  ) async {
    // Text fields consume arrow intents; a binding above Navigator lets keys
    // reach panel results.
    await openHome(tester);
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'night');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'the panel closed');
    expect(
      find.text('Popular films'),
      findsNothing,
      reason: 'on the title the keyboard was standing on',
    );
  });

  uiTest('a title in the panel opens that title', (tester) async {
    await openHome(tester);
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'night');
    await tester.tap(panelRow('tt0063350'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'the panel closed');
    expect(find.text('Popular films'), findsNothing, reason: 'on the title');
  });

  uiTest('the results page names every title under its poster', (tester) async {
    // Result artwork may be missing or unfamiliar, so its captions are needed
    // to identify titles.
    await openHome(tester);
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'night');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.textContaining('results for'), findsOneWidget);
    final tile = find.byWidgetPredicate(
      (w) => w is PosterTile && w.item.id == 'tt0063350',
    );
    expect(
      find.descendant(
        of: tile,
        matching: find.text('Night of the Living Dead'),
      ),
      findsOneWidget,
      reason: 'once under the poster, not twice on it',
    );
    expect(
      find.descendant(of: tile, matching: find.text('1968')),
      findsOneWidget,
    );
  });
}
