// SPDX-License-Identifier: MIT OR Apache-2.0

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:yaru/yaru.dart';

import 'ui_style.dart';

/// Carries the selected content-area style independently from the host OS.
class PlatformStyleScope extends InheritedWidget {
  const PlatformStyleScope({
    super.key,
    required this.style,
    required super.child,
  });

  final UiStyle style;

  static UiStyle of(BuildContext context) => resolveUiStyle(
    context.dependOnInheritedWidgetOfExactType<PlatformStyleScope>()?.style ??
        UiStyle.system,
  );

  @override
  bool updateShouldNotify(PlatformStyleScope oldWidget) =>
      style != oldWidget.style;
}

enum PlatformButtonKind { normal, primary, quiet, tonal }

Widget _withMinimumSize(Widget child, ButtonStyle? style) {
  final size = style?.minimumSize?.resolve({});
  if (size == null) return child;
  return ConstrainedBox(
    constraints: BoxConstraints(minWidth: size.width, minHeight: size.height),
    child: child,
  );
}

/// A semantic button whose implementation follows the chosen visual style.
class PlatformButton extends StatelessWidget {
  const PlatformButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
    this.focusNode,
    this.autofocus = false,
  }) : kind = PlatformButtonKind.normal,
       icon = null;

  const PlatformButton.primary({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
    this.focusNode,
    this.autofocus = false,
  }) : kind = PlatformButtonKind.primary,
       icon = null;

  const PlatformButton.quiet({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
    this.focusNode,
    this.autofocus = false,
  }) : kind = PlatformButtonKind.quiet,
       icon = null;

  const PlatformButton.tonal({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
    this.focusNode,
    this.autofocus = false,
  }) : kind = PlatformButtonKind.tonal,
       icon = null;

  const PlatformButton.icon({
    super.key,
    required this.onPressed,
    required this.icon,
    required Widget label,
    this.kind = PlatformButtonKind.normal,
    this.style,
    this.focusNode,
    this.autofocus = false,
  }) : child = label;

  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final PlatformButtonKind kind;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final body = icon == null
        ? child
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon!,
              const SizedBox(width: 7),
              Flexible(child: child),
            ],
          );
    switch (PlatformStyleScope.of(context)) {
      case UiStyle.windowsFluent:
        final buttonStyle = fluent.ButtonStyle(
          padding: style?.padding,
          foregroundColor: style?.foregroundColor,
          backgroundColor: style?.backgroundColor,
          textStyle: style?.textStyle,
          shape: style?.shape,
        );
        if (kind == PlatformButtonKind.primary) {
          return _withMinimumSize(
            fluent.FilledButton(
              onPressed: onPressed,
              focusNode: focusNode,
              autofocus: autofocus,
              style: buttonStyle,
              child: body,
            ),
            style,
          );
        }
        if (kind == PlatformButtonKind.quiet) {
          return _withMinimumSize(
            fluent.HyperlinkButton(
              onPressed: onPressed,
              focusNode: focusNode,
              autofocus: autofocus,
              style: buttonStyle,
              child: body,
            ),
            style,
          );
        }
        return _withMinimumSize(
          fluent.Button(
            onPressed: onPressed,
            focusNode: focusNode,
            autofocus: autofocus,
            style: buttonStyle,
            child: body,
          ),
          style,
        );
      case UiStyle.macos:
        final quiet = kind == PlatformButtonKind.quiet;
        return _MacosAction(
          onPressed: onPressed,
          focusNode: focusNode,
          autofocus: autofocus,
          child: macos.PushButton(
            controlSize: macos.ControlSize.large,
            onPressed: onPressed,
            secondary: kind != PlatformButtonKind.primary,
            color: quiet ? Colors.transparent : null,
            padding:
                style?.padding?.resolve({}) ??
                const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: body,
          ),
        );
      case UiStyle.linuxYaru:
      case UiStyle.material:
      case UiStyle.system:
        return switch (kind) {
          PlatformButtonKind.primary => FilledButton(
            onPressed: onPressed,
            focusNode: focusNode,
            autofocus: autofocus,
            style: style,
            child: body,
          ),
          PlatformButtonKind.tonal => FilledButton.tonal(
            onPressed: onPressed,
            focusNode: focusNode,
            autofocus: autofocus,
            style: style,
            child: body,
          ),
          PlatformButtonKind.quiet => TextButton(
            onPressed: onPressed,
            focusNode: focusNode,
            autofocus: autofocus,
            style: style,
            child: body,
          ),
          PlatformButtonKind.normal => OutlinedButton(
            onPressed: onPressed,
            focusNode: focusNode,
            autofocus: autofocus,
            style: style,
            child: body,
          ),
        };
    }
  }
}

class PlatformIconButton extends StatelessWidget {
  const PlatformIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.iconSize,
    this.color,
    this.style,
    this.visualDensity,
    this.isSelected = false,
  }) : _filled = false;

  const PlatformIconButton.filledTonal({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.iconSize,
    this.color,
    this.style,
    this.visualDensity,
    this.isSelected = false,
  }) : _filled = true;

  final VoidCallback? onPressed;
  final Widget icon;
  final String? tooltip;
  final double? iconSize;
  final Color? color;
  final ButtonStyle? style;
  final VisualDensity? visualDensity;
  final bool isSelected;
  final bool _filled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final highlighted = isSelected || _filled;
    final body = IconTheme.merge(
      data: IconThemeData(size: iconSize, color: color),
      child: icon,
    );
    Widget button;
    switch (PlatformStyleScope.of(context)) {
      case UiStyle.windowsFluent:
        button = fluent.IconButton(
          onPressed: onPressed,
          icon: body,
          style: fluent.ButtonStyle(
            padding: style?.padding,
            iconSize: iconSize == null
                ? null
                : WidgetStatePropertyAll(iconSize),
            foregroundColor: color == null
                ? null
                : WidgetStatePropertyAll(color),
            backgroundColor: highlighted
                ? WidgetStatePropertyAll(colors.primary.withValues(alpha: .14))
                : style?.backgroundColor,
          ),
        );
      case UiStyle.macos:
        button = _MacosAction(
          onPressed: onPressed,
          child: macos.MacosIconButton(
            onPressed: onPressed,
            icon: body,
            semanticLabel: tooltip,
            backgroundColor: highlighted
                ? colors.primary.withValues(alpha: .14)
                : Colors.transparent,
            boxConstraints: BoxConstraints.tightFor(
              width: visualDensity == VisualDensity.compact ? 28 : 34,
              height: visualDensity == VisualDensity.compact ? 28 : 34,
            ),
          ),
        );
      default:
        button = _filled
            ? IconButton.filledTonal(
                onPressed: onPressed,
                icon: body,
                iconSize: iconSize,
                color: color,
                style: style,
                visualDensity: visualDensity,
                isSelected: isSelected,
              )
            : IconButton(
                onPressed: onPressed,
                icon: body,
                iconSize: iconSize,
                color: color,
                style: style,
                visualDensity: visualDensity,
                isSelected: isSelected,
              );
    }
    if (tooltip != null) button = Tooltip(message: tooltip!, child: button);
    return Semantics(selected: isSelected, child: button);
  }
}

/// Adds keyboard activation and a focus ring to macos_ui mouse-only buttons.
class _MacosAction extends StatefulWidget {
  const _MacosAction({
    required this.onPressed,
    required this.child,
    this.focusNode,
    this.autofocus = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<_MacosAction> createState() => _MacosActionState();
}

class _MacosActionState extends State<_MacosAction> {
  bool highlight = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    enabled: widget.onPressed != null,
    focusNode: widget.focusNode,
    autofocus: widget.autofocus,
    onShowFocusHighlight: (value) => setState(() => highlight = value),
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    },
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        },
      ),
    },
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          width: 2,
          color: highlight
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
        ),
      ),
      child: widget.child,
    ),
  );
}

/// A controlled single-selection toolbar group.
class PlatformSegments<T> extends StatelessWidget {
  const PlatformSegments({
    super.key,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.style,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool showSelectedIcon;
  final ButtonStyle? style;

  Widget _body(ButtonSegment<T> segment) {
    Widget body = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSelectedIcon && selected.contains(segment.value))
          const Icon(Icons.check, size: 16)
        else if (segment.icon != null)
          segment.icon!,
        if (segment.label != null) ...[
          if (segment.icon != null ||
              showSelectedIcon && selected.contains(segment.value))
            const SizedBox(width: 6),
          segment.label!,
        ],
      ],
    );
    if (segment.tooltip != null) {
      body = Tooltip(message: segment.tooltip!, child: body);
    }
    return body;
  }

  @override
  Widget build(BuildContext context) {
    switch (PlatformStyleScope.of(context)) {
      case UiStyle.windowsFluent:
        final toggleStyle = fluent.ButtonStyle(
          padding: style?.padding,
          textStyle: style?.textStyle,
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < segments.length; index++) ...[
              if (index > 0) const SizedBox(width: 2),
              _withMinimumSize(
                fluent.ToggleButton(
                  checked: selected.contains(segments[index].value),
                  onChanged:
                      onSelectionChanged == null || !segments[index].enabled
                      ? null
                      : (_) => onSelectionChanged!({segments[index].value}),
                  style: fluent.ToggleButtonThemeData(
                    checkedButtonStyle: toggleStyle,
                    uncheckedButtonStyle: toggleStyle,
                  ),
                  child: _body(segments[index]),
                ),
                style,
              ),
            ],
          ],
        );
      case UiStyle.macos:
        return _MacosSegments<T>(
          segments: segments,
          selected: selected,
          onSelectionChanged: onSelectionChanged,
          body: _body,
          style: style,
        );
      default:
        return SegmentedButton<T>(
          segments: segments,
          selected: selected,
          onSelectionChanged: onSelectionChanged,
          showSelectedIcon: showSelectedIcon,
          style: style,
        );
    }
  }
}

class _MacosSegments<T> extends StatefulWidget {
  const _MacosSegments({
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    required this.body,
    this.style,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final Widget Function(ButtonSegment<T>) body;
  final ButtonStyle? style;

  @override
  State<_MacosSegments<T>> createState() => _MacosSegmentsState<T>();
}

class _MacosSegmentsState<T> extends State<_MacosSegments<T>> {
  late macos.MacosTabController controller;
  bool syncing = false;

  int get selectedIndex {
    final index = widget.segments.indexWhere(
      (segment) => widget.selected.contains(segment.value),
    );
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _createController();
  }

  void _createController() {
    controller = macos.MacosTabController(
      length: widget.segments.length,
      initialIndex: selectedIndex,
    )..addListener(_changed);
  }

  void _sync() {
    syncing = true;
    controller.index = selectedIndex;
    syncing = false;
  }

  void _changed() {
    if (syncing) return;
    final segment = widget.segments[controller.index];
    _sync();
    if (segment.enabled) widget.onSelectionChanged?.call({segment.value});
  }

  @override
  void didUpdateWidget(_MacosSegments<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segments.length != widget.segments.length) {
      controller.dispose();
      _createController();
    } else {
      _sync();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => macos.MacosSegmentedControl(
    controller: controller,
    tabs: [
      for (var index = 0; index < widget.segments.length; index++)
        _MacosRichTab(
          onPressed:
              widget.onSelectionChanged == null ||
                  !widget.segments[index].enabled
              ? null
              : () => controller.index = index,
          padding:
              widget.style?.padding?.resolve({}) ??
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: widget.body(widget.segments[index]),
        ),
    ],
  );
}

/// Preserves icons and tooltips in macos_ui's text-only tab slots.
class _MacosRichTab extends macos.MacosTab {
  const _MacosRichTab({
    required this.child,
    required this.onPressed,
    required this.padding,
    super.active,
  }) : super(label: '');

  final Widget child;
  final VoidCallback? onPressed;
  final EdgeInsetsGeometry padding;

  @override
  macos.MacosTab copyWith({String? label, bool? active}) => _MacosRichTab(
    onPressed: onPressed,
    padding: padding,
    active: active ?? this.active,
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _MacosAction(
      onPressed: onPressed,
      child: Semantics(
        button: true,
        selected: active,
        enabled: onPressed != null,
        child: Opacity(
          opacity: onPressed == null ? .5 : 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: active
                  ? dark
                        ? const Color(0xff646669)
                        : Colors.white
                  : Colors.transparent,
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// A desktop text input preserving its editing state while styles change.
class PlatformTextField extends StatefulWidget {
  const PlatformTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.enabled,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.maxLength,
    this.expands = false,
    this.obscureText = false,
    this.readOnly = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.style,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTap,
    this.scrollController,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final bool? enabled;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final int? maxLength;
  final bool expands;
  final bool obscureText;
  final bool readOnly;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextStyle? style;
  final TextAlign textAlign;
  final TextAlignVertical? textAlignVertical;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final VoidCallback? onTap;
  final ScrollController? scrollController;

  @override
  State<PlatformTextField> createState() => _PlatformTextFieldState();
}

class _PlatformTextFieldState extends State<PlatformTextField> {
  TextEditingController? _ownedController;
  FocusNode? _ownedFocusNode;

  TextEditingController get _controller =>
      widget.controller ?? (_ownedController ??= TextEditingController());
  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void didUpdateWidget(PlatformTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != null && widget.controller == null) {
      _ownedController?.dispose();
      _ownedController = TextEditingController.fromValue(
        oldWidget.controller!.value,
      );
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final decoration = widget.decoration;
    final padding =
        decoration?.contentPadding ??
        const EdgeInsets.symmetric(horizontal: 10, vertical: 9);
    final prefix = decoration?.prefixIcon ?? decoration?.prefix;
    final suffix = decoration?.suffixIcon ?? decoration?.suffix;
    final selectedStyle = PlatformStyleScope.of(context);
    Widget field;
    switch (selectedStyle) {
      case UiStyle.windowsFluent:
        field = fluent.TextBox(
          controller: _controller,
          focusNode: _focusNode,
          enabled: widget.enabled ?? true,
          autofocus: widget.autofocus,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          maxLength: widget.maxLength,
          expands: widget.expands,
          obscureText: widget.obscureText,
          readOnly: widget.readOnly,
          autocorrect: widget.autocorrect,
          enableSuggestions: widget.enableSuggestions,
          style: widget.style,
          textAlign: widget.textAlign,
          textAlignVertical: widget.textAlignVertical,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.textCapitalization,
          inputFormatters: widget.inputFormatters,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          onEditingComplete: widget.onEditingComplete,
          onTap: widget.onTap,
          scrollController: widget.scrollController,
          placeholder: decoration?.hintText,
          prefix: prefix,
          suffix: suffix,
          padding: padding.resolve(Directionality.of(context)),
        );
      case UiStyle.macos:
        field = macos.MacosTextField(
          controller: _controller,
          focusNode: _focusNode,
          enabled: widget.enabled,
          autofocus: widget.autofocus,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          maxLength: widget.maxLength,
          expands: widget.expands,
          obscureText: widget.obscureText,
          readOnly: widget.readOnly,
          autocorrect: widget.autocorrect,
          enableSuggestions: widget.enableSuggestions,
          style: widget.style,
          textAlign: widget.textAlign,
          textAlignVertical: widget.textAlignVertical,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.textCapitalization,
          inputFormatters: widget.inputFormatters,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          onEditingComplete: widget.onEditingComplete,
          onTap: widget.onTap,
          scrollController: widget.scrollController,
          placeholder: decoration?.hintText,
          prefix: prefix,
          suffix: suffix,
          padding: padding.resolve(Directionality.of(context)),
        );
      case UiStyle.linuxYaru:
      case UiStyle.material:
      case UiStyle.system:
        return TextField(
          controller: _controller,
          focusNode: _focusNode,
          decoration: decoration,
          enabled: widget.enabled,
          autofocus: widget.autofocus,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          maxLength: widget.maxLength,
          expands: widget.expands,
          obscureText: widget.obscureText,
          readOnly: widget.readOnly,
          autocorrect: widget.autocorrect,
          enableSuggestions: widget.enableSuggestions,
          style: widget.style,
          textAlign: widget.textAlign,
          textAlignVertical: widget.textAlignVertical,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.textCapitalization,
          inputFormatters: widget.inputFormatters,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          onEditingComplete: widget.onEditingComplete,
          onTap: widget.onTap,
          scrollController: widget.scrollController,
        );
    }
    return _NativeFieldFrame(
      label:
          decoration?.label ??
          (decoration?.labelText == null ? null : Text(decoration!.labelText!)),
      helper:
          decoration?.error ??
          decoration?.helper ??
          (decoration?.errorText != null
              ? Text(decoration!.errorText!)
              : decoration?.helperText != null
              ? Text(decoration!.helperText!)
              : null),
      error: decoration?.error != null || decoration?.errorText != null,
      expands: widget.expands,
      child: Semantics(label: decoration?.labelText, child: field),
    );
  }
}

class PlatformSelect<T> extends StatelessWidget {
  const PlatformSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.label,
    this.hint,
    this.isExpanded = false,
  });

  final T? value;
  final Map<T, String> items;
  final ValueChanged<T?>? onChanged;
  final String? label;
  final Widget? hint;
  final bool isExpanded;

  @override
  Widget build(BuildContext context) {
    final selected = items.containsKey(value) ? value : null;
    final placeholder = hint ?? (label == null ? null : Text(label!));
    final Widget field;
    switch (PlatformStyleScope.of(context)) {
      case UiStyle.windowsFluent:
        field = fluent.ComboBox<T>(
          value: selected,
          items: [
            for (final entry in items.entries)
              fluent.ComboBoxItem(
                value: entry.key,
                child: _selectText(entry.value),
              ),
          ],
          onChanged: onChanged,
          placeholder: placeholder,
          isExpanded: isExpanded,
        );
      case UiStyle.macos:
        field = _MacosSelect<T>(
          value: selected,
          items: items,
          onChanged: onChanged,
          hint: placeholder,
          isExpanded: isExpanded,
        );
      case UiStyle.linuxYaru:
      case UiStyle.material:
      case UiStyle.system:
        final input = InputDecorator(
          decoration: const InputDecoration(isDense: true),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: selected,
              items: [
                for (final entry in items.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: _selectText(entry.value),
                  ),
              ],
              onChanged: onChanged,
              hint: placeholder,
              isExpanded: isExpanded,
              isDense: true,
            ),
          ),
        );
        field = isExpanded ? input : IntrinsicWidth(child: input);
    }
    return _NativeFieldFrame(
      label: label == null ? null : Text(label!),
      child: field,
    );
  }
}

Widget _selectText(String value) => Tooltip(
  message: value,
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
  ),
);

/// macos_ui fixes popup height to 20 pixels, so scale its control geometry along
/// with text and explicitly constrain the selected label in narrow forms.
class _MacosSelect<T> extends StatelessWidget {
  const _MacosSelect({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.hint,
    required this.isExpanded,
  });

  final T? value;
  final Map<T, String> items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;
  final bool isExpanded;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textStyle = macos.MacosTheme.of(context).typography.body;
      final fontSize = textStyle.fontSize ?? 13;
      final scale = MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
      final painter = TextPainter(textDirection: Directionality.of(context));
      var naturalWidth = 80.0;
      for (final text in [
        ...items.values,
        if (hint is Text) (hint as Text).data ?? '',
      ]) {
        painter.text = TextSpan(text: text, style: textStyle);
        painter.layout();
        if (painter.width + 36 > naturalWidth) {
          naturalWidth = painter.width + 36;
        }
      }
      painter.dispose();
      final available = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : naturalWidth * scale;
      final width = isExpanded
          ? available
          : (naturalWidth * scale).clamp(0.0, available);
      final labelWidth = (width / scale - 36).clamp(0.0, double.infinity);
      Widget constrained(Widget child) => SizedBox(
        width: labelWidth,
        child: DefaultTextStyle.merge(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          child: child,
        ),
      );
      return SizedBox(
        width: width,
        height: 28 * scale,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.centerLeft,
            child: MediaQuery.withNoTextScaling(
              child: macos.MacosPopupButton<T>(
                value: value,
                items: [
                  for (final entry in items.entries)
                    macos.MacosPopupMenuItem(
                      value: entry.key,
                      child: _selectText(entry.value),
                    ),
                ],
                selectedItemBuilder: (_) => [
                  for (final text in items.values)
                    constrained(_selectText(text)),
                ],
                onChanged: onChanged,
                hint: hint == null ? null : constrained(hint!),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class PlatformSwitch extends StatelessWidget {
  const PlatformSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) =>
      switch (PlatformStyleScope.of(context)) {
        UiStyle.windowsFluent => fluent.ToggleSwitch(
          checked: value,
          onChanged: onChanged,
        ),
        UiStyle.macos => macos.MacosSwitch(value: value, onChanged: onChanged),
        UiStyle.linuxYaru => YaruSwitch(value: value, onChanged: onChanged),
        _ => Switch(value: value, onChanged: onChanged),
      };
}

/// A desktop dialog supporting the application's forms and multiple actions.
class PlatformDialog extends StatelessWidget {
  const PlatformDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.scrollable = false,
    this.contentPadding,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final bool scrollable;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final style = PlatformStyleScope.of(context);
    final declaredWidth = content is SizedBox
        ? (content as SizedBox).width
        : null;
    final width = declaredWidth != null && declaredWidth.isFinite
        ? (declaredWidth + 48).clamp(320.0, 1100.0)
        : 560.0;
    if (style == UiStyle.windowsFluent) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: fluent.ContentDialog(
          title: title,
          content: content == null
              ? null
              : scrollable
              ? SingleChildScrollView(child: content)
              : content,
          actions: actions,
          constraints: BoxConstraints(maxWidth: width),
          style: contentPadding == null
              ? null
              : fluent.ContentDialogThemeData(bodyPadding: contentPadding),
        ),
      );
    }
    if (style == UiStyle.macos) {
      final theme = Theme.of(context);
      return Dialog(
        backgroundColor: theme.colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                DefaultTextStyle(
                  style: theme.textTheme.titleMedium!,
                  child: title!,
                ),
              if (content != null)
                Flexible(
                  child: Padding(
                    padding:
                        contentPadding ??
                        const EdgeInsets.symmetric(vertical: 18),
                    child: scrollable
                        ? SingleChildScrollView(child: content)
                        : content,
                  ),
                ),
              if (actions != null)
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions!,
                ),
            ],
          ),
        ),
      );
    }
    return AlertDialog(
      title: title,
      content: content,
      actions: actions,
      scrollable: scrollable,
      contentPadding: contentPadding,
      constraints: BoxConstraints(maxWidth: width),
    );
  }
}

class _NativeFieldFrame extends StatelessWidget {
  const _NativeFieldFrame({
    required this.child,
    this.label,
    this.helper,
    this.error = false,
    this.expands = false,
  });

  final Widget child;
  final Widget? label;
  final Widget? helper;
  final bool error;
  final bool expands;

  @override
  Widget build(BuildContext context) {
    if (label == null && helper == null) return child;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: expands ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: DefaultTextStyle(
              style: theme.textTheme.bodySmall!,
              child: label!,
            ),
          ),
        if (expands) Expanded(child: child) else child,
        if (helper != null)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: DefaultTextStyle(
              style: theme.textTheme.bodySmall!.copyWith(
                color: error
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
              child: helper!,
            ),
          ),
      ],
    );
  }
}
