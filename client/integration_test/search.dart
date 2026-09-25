// Search: the field, the panel under it and the results page.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/main.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';

import 'fake_core.dart';

import 'helpers.dart';

void searchTests() {
  testWidgets('backspace deletes in the search field', (tester) async {
    // A shortcut bound to Backspace on the shell took it away from the field,
    // because MaterialApp installs the text editing shortcuts above us and the
    // closer binding wins.
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

  testWidgets('a search gone through is offered again under the empty field', (
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

    // Asked again with a click: into the field, and its answers follow.
    await tester.tap(recent);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(panelRow('tt0903747'), findsOneWidget);

    // Forgotten with its cross.
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: recent, matching: find.byTooltip('Forget')),
    );
    await tester.pumpAndSettle();
    expect(recent, findsNothing);
  });

  testWidgets('ctrl+F opens search and gives it the keyboard', (tester) async {
    // There is no field on screen until this key is pressed: the middle of the
    // bar is the tabs, and search is a panel that opens over them. So the key
    // has to open the panel and land the keyboard in it in one press — it used
    // to only move the focus, which does nothing at all to a field that is not
    // built yet.
    await openHome(tester, downloads: [fakeDownload()]);
    await pressCtrlF(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: 'the field has the keyboard, without anything being clicked',
    );
    // Typed at the window rather than at the field: enterText(finder) would
    // focus the field itself and prove nothing about the key.
    tester.testTextInput.enterText('breaking bad');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.textContaining('results for'), findsOneWidget);
  });

  testWidgets('the field opens on the line the tabs stand on', (tester) async {
    // It opened against the top of the window. A SearchAnchor's panel takes
    // the top edge of whatever the anchor is, and the anchor was the whole
    // height of the bar: the field appeared at the window's frame, above the
    // line the tabs sit on, and folded back into that same edge — a panel
    // arriving from nowhere instead of a bar widening where it stands.
    await openHome(tester);
    final tabs = tester.getRect(find.text('Home'));
    await pressCtrlF(tester);
    final field = tester.getRect(find.byType(TextField));
    expect(
      field.center.dy,
      closeTo(tabs.center.dy, 1),
      reason: 'the field is centred where the tabs were, not higher up',
    );
  });

  testWidgets('the answers fold up with the panel instead of blinking out', (
    tester,
  ) async {
    // Closing used to empty the field, and emptying the field emptied the list
    // in the same frame: what the closing animation had left to fold away was
    // an empty box, so search did not shut, it vanished. The field is emptied
    // on the way in instead.
    await openHome(tester);
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'night');
    expect(panelRow('tt0063350'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      panelRow('tt0063350'),
      findsOneWidget,
      reason: 'still on screen, on its way out with the panel',
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'and then gone');
    // And the word it was searching for does not come back with the field.
    await pressCtrlF(tester);
    expect(find.text('night'), findsNothing);
  });

  testWidgets('escape leaves the search field instead of going back', (
    tester,
  ) async {
    // Escape means back everywhere else in this window, and while the field
    // had the keyboard it meant back there too: the page under it went back
    // and the field kept both the word in it and its lit border. A key is
    // delivered by climbing from whatever holds the focus, so the field's own
    // binding is the closer one and the shell's never sees it.
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

    // The keyboard has to have landed somewhere, or every shortcut this shell
    // owns quietly stops answering.
    await pressCtrlF(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: 'ctrl+F still works after escape',
    );
  });

  testWidgets('ctrl+F still finds the field after a title and back', (
    tester,
  ) async {
    // Once around the loop a person actually walks: search, open something,
    // come back. The bar rebuilds its field on the way, and if the focus goes
    // nowhere in the process, every shortcut the shell owns stops answering —
    // keys are delivered by climbing from whatever holds the focus, and
    // nothing did. Measured on the real window, where a screenshot run typed
    // three titles into a page that could not hear it.
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

  testWidgets('titles appear under the field without Enter being pressed', (
    tester,
  ) async {
    // Search used to be a field that did nothing until Enter, and then
    // replaced the page. Everything anybody looks for here is a name they half
    // remember, so the answers have to arrive while it is being typed — and
    // arrive as titles with their artwork, not as a page of words.
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

  testWidgets('one kind failing does not empty the panel', (tester) async {
    // It did. The two kinds were asked through Future.wait, so a provider
    // timing out on films took the series down with it and a word with six
    // answers behind it came back as "nothing found".
    await tester.pumpWidget(LumeoApp(api: fakeCore(searchFails: 'movie')));
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

  testWidgets('a core that answers nothing says so, in the panel', (
    tester,
  ) async {
    // "Nothing found" is about the word; this is about the core, and offering
    // a page of all results for it would open a page that fails the same way.
    await tester.pumpWidget(LumeoApp(api: fakeCore(searchFails: 'all')));
    await tester.pumpAndSettle();
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'breaking');
    expect(find.text('The catalogue is not answering'), findsOneWidget);
    expect(find.textContaining('All results'), findsNothing);
  });

  testWidgets('arrows walk the panel and Enter opens the row they are on', (
    tester,
  ) async {
    // A list under a field is a combobox, and a combobox without arrow keys is
    // half a control. Flutter does not give this away: a text field registers
    // `DirectionalFocusAction.forTextField`, whose whole job is to swallow the
    // intent so that arrows in a paragraph move the caret. The binding that
    // undoes that is in main.dart, above the Navigator, because the panel is a
    // route and nothing inside the application is an ancestor of its field.
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

  testWidgets('a title in the panel opens that title', (tester) async {
    await openHome(tester);
    await pressCtrlF(tester);
    await typeIntoSearch(tester, 'night');
    await tester.tap(panelRow('tt0063350'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'the panel closed');
    expect(find.text('Popular films'), findsNothing, reason: 'on the title');
  });

  testWidgets('the results page names every title under its poster', (
    tester,
  ) async {
    // The shelves do without captions on purpose — a poster is a title card
    // already. A page of search results is not a shelf: the answers are
    // unfamiliar by definition, some of that artwork is in another language or
    // simply missing, and a grid of pictures nobody recognises is a grid
    // nobody can use.
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
