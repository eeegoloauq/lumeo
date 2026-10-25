#!/usr/bin/env python3
"""Converts the Flutter client's translations to Qt's, once:

    desktop/tool/arb2ts.py

writes desktop/i18n/lumeo_<code>.ts from every client/lib/l10n/app_<code>.arb.
From then on the .ts files are the source; the script goes with client/
(docs/qt-port.md).

Messages keep their keys as ids, for qsTrId(). A placeholder becomes %1, %2,
... in the order the English text first names it, and the message's comment
says which is which. An ICU plural becomes a numerus message with %n, for
qsTrId(id, n). Qt has no zero form and one %n per message, so an =0 form
becomes a message of its own, <key>Zero, and a second plural in a message
becomes <key>_<variable>, put in where the plural was as the next %k.
"""

import json
import pathlib
import re
import sys
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parents[2]
ARB = ROOT / "client/lib/l10n"
OUT = ROOT / "desktop/i18n"

# Qt's numerus forms by language, as ICU names them, in Qt's order.
FORMS = {"en": ["one", "other"], "ru": ["one", "few", "many"]}


def parse(text):
    """The message as a list of strings, ("var", name) and ("plural", name, {form: parts})."""
    parts, i, plain = [], 0, ""
    while i < len(text):
        if text[i] != "{":
            plain += text[i]
            i += 1
            continue
        depth, j = 0, i
        while True:
            depth += {"{": 1, "}": -1}.get(text[j], 0)
            if depth == 0:
                break
            j += 1
        inner = text[i + 1 : j]
        if plain:
            parts.append(plain)
            plain = ""
        plural = re.match(r"\s*(\w+)\s*,\s*plural\s*,(.*)$", inner, re.S)
        if plural:
            forms, rest = {}, plural.group(2)
            for selector, body in forms_of(rest):
                forms[selector] = parse(body)
            parts.append(("plural", plural.group(1), forms))
        else:
            parts.append(("var", inner.strip()))
        i = j + 1
    if plain:
        parts.append(plain)
    return parts


def forms_of(text):
    i = 0
    while True:
        match = re.compile(r"\s*(=0|zero|one|two|few|many|other)\s*\{").match(text, i)
        if not match:
            return
        depth, j = 0, match.end() - 1
        while True:
            depth += {"{": 1, "}": -1}.get(text[j], 0)
            if depth == 0:
                break
            j += 1
        yield match.group(1), text[match.end() : j]
        i = j + 1


def variables(parts, found):
    for part in parts:
        if isinstance(part, tuple) and part[0] == "var" and part[1] not in found:
            found.append(part[1])
        elif isinstance(part, tuple) and part[0] == "plural":
            for form in part[2].values():
                variables(form, found)
    return found


def render(parts, numbers, count=None):
    out = ""
    for part in parts:
        if isinstance(part, str):
            out += part
        elif part[0] == "var":
            out += "%n" if part[1] == count else "%" + str(numbers[part[1]])
        else:
            raise ValueError("plural inside a rendered part")
    return out


class Message:
    def __init__(self, key, numerus, texts, comment):
        self.key, self.numerus, self.texts, self.comment = key, numerus, texts, comment


def convert(key, text, language, english, comment):
    """The messages one arb entry becomes in [language]; [english] fixes the numbering."""
    names = [n for n in variables(parse(english), []) if not plural_variable(english, n)]
    plurals = [p for p in parse(english) if isinstance(p, tuple) and p[0] == "plural"]
    numbers = {name: i + 1 for i, name in enumerate(names)}
    for extra in plurals[1:]:
        numbers[extra[1]] = len(numbers) + 1
    named = [f"%{number} {name}" for name, number in numbers.items()]

    def described(names):
        return f"{comment} ({', '.join(names)})" if names else comment

    note = described(([f"%n {plurals[0][1]}"] if plurals else []) + named)

    parts = parse(text)
    own = [p for p in parts if isinstance(p, tuple) and p[0] == "plural"]
    if not plurals:
        return [Message(key, False, [render(parts, numbers)], note)]

    count = plurals[0][1]
    forms = len(FORMS[language])
    # A translation may say a count without a plural ("{count} с"): every
    # form is that text.
    if not own or own[0][1] != count:
        messages = [Message(key, True, [render(parts, numbers, count)] * forms, note)]
    else:
        messages = [numerus(key, parts, count, numbers, language, note)]
    for extra in plurals[1:]:
        mine = [p for p in own if p[1] == extra[1]]
        if mine:
            messages.append(numerus(f"{key}_{extra[1]}", mine, extra[1], numbers, language,
                                    described(["%n " + extra[1]])))
        else:
            # The translation says this count in the main message.
            messages.append(Message(f"{key}_{extra[1]}", True, ["%n"] * forms,
                                    described(["%n " + extra[1]])))
    zero = own[0][2].get("=0") if own and own[0][1] == count else None
    if "=0" in plurals[0][2]:
        if zero is None:
            text = render(parts, numbers, count).replace("%n", "0")
        else:
            flat = []
            for p in parts:
                if p is own[0]:
                    flat.extend(zero)
                elif isinstance(p, tuple) and p[0] == "plural":
                    flat.append(("var", p[1]))
                else:
                    flat.append(p)
            text = render(flat, numbers, count)
        messages.append(Message(key + "Zero", False, [text], described(named)))
    return messages


def plural_variable(text, name):
    return any(isinstance(p, tuple) and p[0] == "plural" and p[1] == name for p in parse(text))


def numerus(key, parts, count, numbers, language, comment):
    texts = []
    for form in FORMS[language]:
        out = ""
        for part in parts:
            if isinstance(part, str):
                out += part
            elif part[0] == "var":
                out += "%" + str(numbers[part[1]])
            elif part[1] == count:
                chosen = part[2].get(form) or part[2]["other"]
                body = render(chosen, numbers, count)
                # "1 episode" names the number in the singular; Russian's
                # singular is also 21 and 31.
                if form == "one" and "%n" not in body:
                    body = re.sub(r"(?<![\d.,])1(?![\d.,])", "%n", body, count=1)
                out += body
            else:
                out += "%" + str(numbers[part[1]])
        texts.append(out)
    return Message(key, True, texts, comment)


def write(language, messages, english):
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<!DOCTYPE TS>",
        f'<TS version="2.1" language="{language}" sourcelanguage="en">',
        "<context>",
        "    <name></name>",
    ]
    for message in messages:
        source = english[message.key]
        attrs = f' id="{message.key}"' + (' numerus="yes"' if message.numerus else "")
        lines.append(f"    <message{attrs}>")
        lines.append(f"        <source>{escape(source.texts[-1])}</source>")
        if source.comment:
            lines.append(f"        <extracomment>{escape(source.comment)}</extracomment>")
        if message.numerus:
            lines.append("        <translation>")
            for text in message.texts:
                lines.append(f"            <numerusform>{escape(text)}</numerusform>")
            lines.append("        </translation>")
        else:
            lines.append(f"        <translation>{escape(message.texts[0])}</translation>")
        lines.append("    </message>")
    lines += ["</context>", "</TS>", ""]
    (OUT / f"lumeo_{language}.ts").write_text("\n".join(lines), encoding="utf-8")


def main():
    template = json.loads((ARB / "app_en.arb").read_text(encoding="utf-8"))
    keys = [k for k in template if not k.startswith("@")]
    OUT.mkdir(exist_ok=True)
    english = {}
    for key in keys:
        comment = template.get("@" + key, {}).get("description", "")
        for message in convert(key, template[key], "en", template[key], comment):
            english[message.key] = message
    for arb in sorted(ARB.glob("app_*.arb")):
        language = arb.stem.removeprefix("app_")
        if language not in FORMS:
            sys.exit(f"{arb.name}: no numerus forms known for {language}")
        values = json.loads(arb.read_text(encoding="utf-8"))
        messages = []
        for key in keys:
            text = values.get(key, template[key])
            messages += convert(key, text, language, template[key], "")
        write(language, messages, english)
        print(f"{arb.name}: {len(messages)} messages")


main()
