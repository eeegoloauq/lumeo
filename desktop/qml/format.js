.pragma library

// How the catalogue's values read on screen, the same on every page.

// An address from the core as an Image source: through the artwork
// provider, which asks again when the core could not fetch it.
function art(url) {
    return url ? "image://artwork/" + encodeURIComponent(url) : ""
}

// A title card, its ink repainted white when it would vanish on our ground.
function logo(url) {
    return url ? "image://logo/" + encodeURIComponent(url) : ""
}

// "2022", or "2015–2019" for a series that has ended: an unspaced en dash,
// a range; a spaced dash under a poster reads as two separate years.
function years(item) {
    if (!item.year)
        return ""
    if (item.kind !== "series")
        return String(item.year)
    return item.yearEnd ? item.year + "–" + item.yearEnd : item.year + "–"
}

// The catalogue's rating as a fact, "7.8", in the reader's digits; empty
// when the provider has none.
function rating(value, locale) {
    return value > 0 ? Number(value).toLocaleString(locale, "f", 1) : ""
}
