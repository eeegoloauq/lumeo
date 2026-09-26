import 'package:flutter/material.dart';

import '../../../api/addons_store.dart';
import '../../../api/models.dart';
import '../../../l10n/l10n.dart';
import '../../theme.dart';
import '../../widgets/setting_row.dart';
import 'controls.dart';

/// The addons the core reads from. Their order breaks ties when two provide
/// the same copy, so the list is dragged into order.
class SourcesSection extends StatelessWidget {
  const SourcesSection({super.key, required this.addons});

  final AddonsStore addons;

  @override
  Widget build(BuildContext context) {
    return SettingsBlock(
      title: context.l10n.settingsSources,
      children: [
        ListenableBuilder(
          listenable: addons,
          builder: (context, _) {
            final current = addons.current;
            final error = addons.error;
            if (current == null && error == null) {
              return const SettingsLoading();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null) ErrorRow(error),
                if (current != null)
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    proxyDecorator: (child, _, _) => Material(
                      color: Palette.raised,
                      borderRadius: const BorderRadius.all(Shape.controlRadius),
                      child: child,
                    ),
                    onReorderItem: (from, to) =>
                        addons.move(current[from].id, to),
                    children: [
                      for (final (i, addon) in current.indexed)
                        _AddonRow(
                          key: ValueKey(addon.id),
                          index: i,
                          addon: addon,
                          addons: addons,
                        ),
                    ],
                  ),
                const Divider(height: 1, thickness: 1, color: Palette.divider),
                _AddAddon(addons: addons),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _AddonRow extends StatelessWidget {
  const _AddonRow({
    super.key,
    required this.index,
    required this.addon,
    required this.addons,
  });

  final int index;
  final Addon addon;
  final AddonsStore addons;

  @override
  Widget build(BuildContext context) {
    final provides = addon.provides(context.l10n);
    final failing = addon.error.isNotEmpty && provides.isEmpty;
    final (line, lineColour) = switch (addon) {
      _ when failing => (
        context.l10n.settingsSourceError(addon.error),
        Palette.warn,
      ),
      _ when provides.isEmpty => (
        context.l10n.settingsSourceNotAnsweredYet,
        Palette.muted,
      ),
      _ => (provides.join(' · '), Palette.muted),
    };
    final (state, stateColour) = switch (addon) {
      Addon(enabled: false) => (context.l10n.settingsSourceOff, Palette.muted),
      _ when failing => (context.l10n.settingsSourceNotAnswering, Palette.down),
      _ when provides.isEmpty => (
        context.l10n.settingsSourceWaiting,
        Palette.muted,
      ),
      _ => (context.l10n.settingsSourceWorking, Palette.up),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (index > 0)
          const Divider(height: 1, thickness: 1, color: Palette.divider),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Tooltip(
                  message: context.l10n.settingsSourcesReorder,
                  child: const MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Icon(
                      Icons.drag_indicator,
                      size: 20,
                      color: Palette.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(addon.name, style: Typo.cardTitle),
                    const SizedBox(height: 2),
                    Text(
                      line,
                      style: SettingsType.hint.copyWith(color: lineColour),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (addon.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(addon.description, style: SettingsType.hint),
                    ],
                    const SizedBox(height: 2),
                    SelectableText(
                      [
                        if (addon.version.isNotEmpty)
                          context.l10n.settingsAddonVersion(addon.version),
                        addon.url,
                      ].join('  ·  '),
                      style: Typo.code,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 110,
                child: Row(
                  children: [
                    StateDot(stateColour),
                    const SizedBox(width: 8),
                    Flexible(child: Text(state, style: SettingsType.hint)),
                  ],
                ),
              ),
              SettingSwitch(
                label: context.l10n.settingsUseAddon(addon.name),
                value: addon.enabled,
                onChanged: (on) => addons.setEnabled(addon.id, on),
              ),
              const SizedBox(width: 8),
              RowButton(
                label: context.l10n.commonRemove,
                onPressed: () => addons.remove(addon.id),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The core checks the manifest before accepting an addon address.
class _AddAddon extends StatefulWidget {
  const _AddAddon({required this.addons});

  final AddonsStore addons;

  @override
  State<_AddAddon> createState() => _AddAddonState();
}

class _AddAddonState extends State<_AddAddon> {
  final _url = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    if (await widget.addons.add(url)) _url.clear();
  }

  static const _edge = OutlineInputBorder(
    borderRadius: BorderRadius.all(Shape.controlRadius),
    borderSide: BorderSide(color: Palette.line),
  );

  static const _refused = OutlineInputBorder(
    borderRadius: BorderRadius.all(Shape.controlRadius),
    borderSide: BorderSide(color: Palette.warn),
  );

  @override
  Widget build(BuildContext context) {
    final addons = widget.addons;
    final error = addons.addError;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _url,
              enabled: !addons.adding,
              style: Typo.code.copyWith(fontSize: 13, color: Palette.text),
              decoration: InputDecoration(
                hintText: context.l10n.settingsAddonAddress,
                hintStyle: Typo.data,
                errorText: error == null ? null : errorMessage(error),
                errorStyle: Typo.data.copyWith(color: Palette.warn),
                errorMaxLines: 3,
                isDense: true,
                filled: true,
                fillColor: Palette.surface,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                border: _edge,
                enabledBorder: _edge,
                focusedBorder: _edge.copyWith(
                  borderSide: const BorderSide(color: Palette.dim),
                ),
                errorBorder: _refused,
                focusedErrorBorder: _refused,
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 12),
          RowButton(
            label: addons.adding
                ? context.l10n.settingsSourcesAsking
                : context.l10n.commonAdd,
            onPressed: addons.adding ? null : _add,
          ),
        ],
      ),
    );
  }
}
