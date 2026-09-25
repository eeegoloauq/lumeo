import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/client.dart';
import '../../../api/models.dart';
import '../../../api/preferences_store.dart';
import '../../theme.dart';
import '../../widgets/loading.dart';
import '../../widgets/setting_row.dart';

/// The controls every section is built from. Each is one of Flutter's own
/// buttons underneath — focusable, pressed with Enter or Space, announced
/// by what it is — dressed the way the mockup draws it.

/// A section of the page: its heading and its rows.
class SettingsBlock extends StatelessWidget {
  const SettingsBlock({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  /// The air above a heading, which is also where a section scrolled to
  /// puts it.
  static const headingTop = 56.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: headingTop),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: SettingsType.heading),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

/// What a section shows while the core has not answered yet.
class SettingsLoading extends StatelessWidget {
  const SettingsLoading({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 12),
    child: Align(alignment: Alignment.centerLeft, child: Loading()),
  );
}

String errorMessage(Object error) =>
    error is LumeoApiException ? error.message : '$error';

/// The core's refusal, said in the section where it happened.
class ErrorRow extends StatelessWidget {
  const ErrorRow(this.error, {super.key});

  final Object error;

  @override
  Widget build(BuildContext context) => SettingRow(
    label: 'What it said',
    value: Text(
      errorMessage(error),
      style: Typo.data.copyWith(color: Palette.warn),
    ),
  );
}

/// One of a few, in a strip. A value that is not one of the [choices] (set
/// by another client, or by Custom) is shown by [other] when given.
class Segments<T> extends StatelessWidget {
  const Segments({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelected,
    this.tooltips = const {},
    this.reselect = false,
  });

  final List<(T, String)> choices;
  final T? selected;
  final ValueChanged<T> onSelected;
  final Map<T, String> tooltips;

  /// Whether pressing the lit segment again is a choice of its own: a
  /// Custom that asks for its number again.
  final bool reselect;

  @override
  Widget build(BuildContext context) {
    final values = {for (final (value, _) in choices) value};
    return SegmentedButton<T>(
      segments: [
        for (final (value, label) in choices)
          ButtonSegment(
            value: value,
            label: Text(label, softWrap: false),
            tooltip: tooltips[value],
          ),
      ],
      selected: {?selected}.where(values.contains).toSet(),
      emptySelectionAllowed: true,
      showSelectedIcon: false,
      onSelectionChanged: (chosen) {
        if (chosen.isNotEmpty) {
          onSelected(chosen.first);
        } else if (reselect && selected != null) {
          onSelected(selected as T);
        }
      },
      style: _segmentStyle,
    );
  }
}

/// The chosen segment is lit the way the mockup lights it: white on the
/// dark strip, the one bright thing in the row.
final _segmentStyle = ButtonStyle(
  backgroundColor: WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.selected) ? Palette.text : Palette.surface,
  ),
  foregroundColor: WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.selected) ? Palette.page : Palette.dim,
  ),
  textStyle: const WidgetStatePropertyAll(
    TextStyle(fontFamily: Typo.sans, fontSize: 13, fontWeight: FontWeight.w500),
  ),
);

/// A choice among presets with a Custom at the end that asks for a number.
/// A value outside the presets lights Custom and says what it is.
class PresetChoice extends StatelessWidget {
  const PresetChoice({
    super.key,
    required this.presets,
    required this.value,
    required this.onSelected,
    required this.describe,
    required this.askCustom,
    this.tooltips = const {},
  });

  final List<(int, String)> presets;
  final int value;
  final ValueChanged<int> onSelected;

  /// How a custom value reads on its segment.
  final String Function(int) describe;

  /// Asks for a custom value; null when the question was dismissed.
  final Future<int?> Function(BuildContext) askCustom;
  final Map<int, String> tooltips;

  static const _custom = -1;

  @override
  Widget build(BuildContext context) {
    final preset = presets.any((p) => p.$1 == value);
    return Segments<int>(
      reselect: !preset,
      choices: [...presets, (_custom, preset ? 'Custom' : describe(value))],
      selected: preset ? value : _custom,
      tooltips: tooltips,
      onSelected: (chosen) async {
        if (chosen != _custom) {
          onSelected(chosen);
          return;
        }
        final asked = await askCustom(context);
        if (asked != null) onSelected(asked);
      },
    );
  }
}

/// A switch named for what it switches, so it is announced as that.
class SettingSwitch extends StatelessWidget {
  const SettingSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Switch(value: value, onChanged: onChanged),
  );
}

/// A value stepped with − and +.
class ValueStepper extends StatelessWidget {
  const ValueStepper({
    super.key,
    required this.value,
    required this.onLess,
    required this.onMore,
    required this.lessLabel,
    required this.moreLabel,
    this.width = 80,
  });

  final String value;

  /// Null at the end of the range.
  final VoidCallback? onLess;
  final VoidCallback? onMore;
  final String lessLabel;
  final String moreLabel;
  final double width;

  @override
  Widget build(BuildContext context) {
    final style = IconButton.styleFrom(
      foregroundColor: Palette.text,
      disabledForegroundColor: Palette.muted,
      fixedSize: const Size.square(34),
      minimumSize: const Size.square(34),
      padding: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Shape.controlRadius),
      ),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.all(Shape.controlRadius),
        border: Border.fromBorderSide(BorderSide(color: Palette.line)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: lessLabel,
            onPressed: onLess,
            style: style,
            icon: const Icon(Icons.remove, size: 18),
          ),
          SizedBox(
            width: width,
            child: Semantics(
              liveRegion: true,
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: SettingsType.value.copyWith(color: Palette.text),
              ),
            ),
          ),
          IconButton(
            tooltip: moreLabel,
            onPressed: onMore,
            style: style,
            icon: const Icon(Icons.add, size: 18),
          ),
        ],
      ),
    );
  }
}

/// A stepped number kept by the core. The step shows at once, and only the
/// last of a burst of presses is sent: a reply to an earlier one arriving
/// after a later one must not step the display back.
class PreferenceStepper extends StatefulWidget {
  const PreferenceStepper({
    super.key,
    required this.stored,
    required this.min,
    required this.max,
    required this.step,
    required this.describe,
    required this.onChosen,
    required this.lessLabel,
    required this.moreLabel,
    this.width = 80,
  });

  final int stored;
  final int min;
  final int max;
  final int step;
  final String Function(int) describe;
  final ValueChanged<int> onChosen;
  final String lessLabel;
  final String moreLabel;
  final double width;

  @override
  State<PreferenceStepper> createState() => _PreferenceStepperState();
}

class _PreferenceStepperState extends State<PreferenceStepper> {
  static const _burst = Duration(milliseconds: 400);

  int? _chosen;
  Timer? _send;

  @override
  void didUpdateWidget(PreferenceStepper old) {
    super.didUpdateWidget(old);
    // Once sent, what the store holds is the truth again: the new value, or
    // the old one beside the core's refusal.
    if (_send == null) _chosen = null;
  }

  @override
  void dispose() {
    if (_send?.isActive ?? false) {
      _send!.cancel();
      widget.onChosen(_chosen!);
    }
    super.dispose();
  }

  void _step(int by) {
    final next = ((_chosen ?? widget.stored) + by).clamp(
      widget.min,
      widget.max,
    );
    setState(() => _chosen = next);
    _send?.cancel();
    _send = Timer(_burst, () {
      _send = null;
      widget.onChosen(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final value = _chosen ?? widget.stored;
    return ValueStepper(
      value: widget.describe(value),
      lessLabel: widget.lessLabel,
      moreLabel: widget.moreLabel,
      width: widget.width,
      onLess: value > widget.min ? () => _step(-widget.step) : null,
      onMore: value < widget.max ? () => _step(widget.step) : null,
    );
  }
}

/// Round swatches, the chosen one checked. Each is a toggle button named by
/// its tooltip.
class ColourDots extends StatelessWidget {
  const ColourDots({
    super.key,
    required this.colours,
    required this.selected,
    required this.onSelected,
  });

  final Map<String, Color> colours;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      children: [
        for (final MapEntry(key: name, value: colour) in colours.entries)
          IconButton(
            tooltip: '${name[0].toUpperCase()}${name.substring(1)}',
            isSelected: name == selected,
            onPressed: () => onSelected(name),
            style: IconButton.styleFrom(
              fixedSize: const Size.square(40),
              padding: EdgeInsets.zero,
            ),
            icon: Container(
              width: 30,
              height: 30,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: name == selected
                    ? Border.all(color: Palette.text, width: 2)
                    : null,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colour,
                  shape: BoxShape.circle,
                ),
                child: name == selected
                    ? const Icon(Icons.check, size: 16, color: Palette.page)
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// The page's plain button: a quiet outline that is still plainly a button.
class RowButton extends StatelessWidget {
  const RowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      foregroundColor: Palette.text,
      backgroundColor: Palette.raised,
      disabledForegroundColor: Palette.muted,
      side: const BorderSide(color: Palette.line),
      minimumSize: const Size(0, 34),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      textStyle: const TextStyle(
        fontFamily: Typo.sans,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Shape.controlRadius),
      ),
    );
    if (icon != null) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        style: style,
        icon: Icon(icon, size: 16),
        label: Text(label),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: style,
      child: Text(label),
    );
  }
}

/// A path someone may copy into a terminal, set as the page sets those.
class PathText extends StatelessWidget {
  const PathText(this.path, {super.key});

  final String path;

  @override
  Widget build(BuildContext context) => SelectableText(
    path,
    style: Typo.code.copyWith(fontSize: 13, color: Palette.dim),
  );
}

/// A small dot that says whether something works.
class StateDot extends StatelessWidget {
  const StateDot(this.colour, {super.key});

  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
  );
}

/// Asks for a whole number between [min] and [max]; null when dismissed.
Future<int?> askNumber(
  BuildContext context, {
  required String title,
  required String unit,
  required int initial,
  required int min,
  required int max,
}) {
  return showDialog<int>(
    context: context,
    builder: (context) => _NumberDialog(
      title: title,
      unit: unit,
      initial: initial,
      min: min,
      max: max,
    ),
  );
}

class _NumberDialog extends StatefulWidget {
  const _NumberDialog({
    required this.title,
    required this.unit,
    required this.initial,
    required this.min,
    required this.max,
  });

  final String title;
  final String unit;
  final int initial;
  final int min;
  final int max;

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  late final _field = TextEditingController(
    text: '${widget.initial.clamp(widget.min, widget.max)}',
  );

  int? get _value {
    final value = int.tryParse(_field.text.trim());
    return value == null || value < widget.min || value > widget.max
        ? null
        : value;
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _done() {
    final value = _value;
    if (value != null) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: Typo.shelfLabel),
      content: SizedBox(
        width: 260,
        child: TextField(
          controller: _field,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _done(),
          decoration: InputDecoration(
            suffixText: widget.unit,
            helperText: '${widget.min}–${widget.max} ${widget.unit}',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _value == null ? null : _done,
          child: const Text('Set'),
        ),
      ],
    );
  }
}

/// Asks before something that cannot be taken back.
Future<bool> confirm(
  BuildContext context, {
  required String message,
  required String action,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Languages as chips, best first, and a picker to add one.
class LanguageList extends StatelessWidget {
  const LanguageList({
    super.key,
    required this.preference,
    required this.chosen,
    required this.preferences,
    required this.onPatch,
    this.empty,
  });

  final String preference;
  final List<String> chosen;
  final PreferencesStore preferences;
  final Future<void> Function(Map<String, Object?>) onPatch;

  /// What an empty list means, said in its place.
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final languages = preferences.languages;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (chosen.isEmpty && empty != null)
          Text(empty!, style: SettingsType.value),
        for (final code in chosen)
          InputChip(
            label: Text(
              languages.name(code).isEmpty
                  ? code.toUpperCase()
                  : languages.name(code),
            ),
            labelStyle: Typo.cardTitle.copyWith(fontSize: 13),
            backgroundColor: Palette.raised,
            deleteIconColor: Palette.muted,
            deleteButtonTooltipMessage: 'Remove',
            side: const BorderSide(color: Palette.line),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Shape.controlRadius),
            ),
            onDeleted: () => onPatch({
              preference: [
                for (final language in chosen)
                  if (language != code) language,
              ],
            }),
          ),
        _LanguagePicker(
          languages: [
            for (final language in languages.list)
              if (!chosen.contains(language.code)) language,
          ],
          onSelected: (code) => onPatch({
            preference: [...chosen, code],
          }),
        ),
      ],
    );
  }
}

class _LanguagePicker extends StatefulWidget {
  const _LanguagePicker({required this.languages, required this.onSelected});

  final List<NamedLanguage> languages;
  final void Function(String) onSelected;

  @override
  State<_LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<_LanguagePicker> {
  int _generation = 0;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        menuButtonTheme: const MenuButtonThemeData(
          style: ButtonStyle(
            foregroundColor: WidgetStatePropertyAll(Palette.text),
            textStyle: WidgetStatePropertyAll(Typo.cardTitle),
            overlayColor: WidgetStatePropertyAll(Palette.hover),
          ),
        ),
      ),
      child: DropdownMenu<String>(
        key: ValueKey(_generation),
        width: 190,
        enableFilter: true,
        requestFocusOnTap: true,
        hintText: 'Add a language',
        // Left to itself the list of every language runs to the window's foot.
        menuHeight: 320,
        menuStyle: const MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Palette.floating),
          surfaceTintColor: WidgetStatePropertyAll(Palette.floating),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Shape.floatingRadius),
              side: BorderSide(color: Palette.rim),
            ),
          ),
        ),
        dropdownMenuEntries: [
          for (final language in widget.languages)
            DropdownMenuEntry(value: language.code, label: language.name),
        ],
        onSelected: (code) {
          if (code == null) return;
          widget.onSelected(code);
          setState(() => _generation++);
        },
      ),
    );
  }
}
