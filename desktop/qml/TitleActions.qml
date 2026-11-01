pragma Singleton
import QtQuick

// The way from any poster or card to the one title menu the shell holds
// (TitleMenu), and back: a page showing a title reads it again on changed().
QtObject {
    // What the menu is asked for, opened at ([x], [y]) in [source]:
    // {item, source, x, y} and, where they apply, episode ({season, number,
    // released}) for a card about one episode, season (a number) for a
    // season's tab, continuing for a card in Continue watching, page "title"
    // for the title's own page, and play and download, functions doing those
    // the way the page does.
    signal asked(var target)
    // The core has a change to [itemId]'s progress, list or score.
    signal changed(string itemId)

    function ask(target) {
        asked(target)
    }
}
