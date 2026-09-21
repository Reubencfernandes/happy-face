import 'package:flutter/material.dart';

import 'theme.dart';

/// The look every way-in shares: ink, a small Back row, one very large
/// title, then the fields and a white button at the end.
class AuthPage extends StatelessWidget {
  /// Shown large. Line breaks are deliberate: they set the rhythm.
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget> children;

  const AuthPage({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: ink,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              children: [
                if (onBack != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: InkWell(
                      onTap: onBack,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              size: 15,
                              color: inkText,
                            ),
                            const SizedBox(width: 7),
                            Text('Back', style: theme.textTheme.titleSmall),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 26),
                Text(
                  title,
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: inkText,
                    fontWeight: FontWeight.w600,
                    height: 1.08,
                    letterSpacing: -1,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: inkMuted,
                      height: 1.45,
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A field on an [AuthPage]: a dark slab with the hint inside it, no label
/// floating above.
InputDecoration authField({
  required String hint,
  required IconData icon,
  Widget? suffix,
  String? helper,
}) => InputDecoration(
  hintText: hint,
  helperText: helper,
  prefixIcon: Icon(icon, size: 19, color: inkMuted),
  suffixIcon: suffix,
  filled: true,
  fillColor: inkSurface,
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
  border: _slab,
  enabledBorder: _slab,
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: accent, width: 1.5),
  ),
);

final _slab = OutlineInputBorder(
  borderRadius: BorderRadius.circular(12),
  borderSide: BorderSide.none,
);

/// The white pill that finishes every one of these pages.
class AuthButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final String? busyLabel;

  const AuthButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.busyLabel,
  });

  @override
  Widget build(BuildContext context) => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: inkText,
      foregroundColor: ink,
      disabledBackgroundColor: inkText.withValues(alpha: 0.35),
      disabledForegroundColor: ink.withValues(alpha: 0.6),
      minimumSize: const Size.fromHeight(52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    onPressed: busy ? null : onPressed,
    child: busy
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 19,
                height: 19,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: ink),
              ),
              if (busyLabel != null) ...[
                const SizedBox(width: 12),
                Flexible(
                  child: Text(busyLabel!, overflow: TextOverflow.ellipsis),
                ),
              ],
            ],
          )
        : Text(label),
  );
}

/// The quiet line under the button: grey sentence, one thing to tap.
class AuthFootnote extends StatelessWidget {
  final String text;
  final String action;
  final VoidCallback? onTap;

  const AuthFootnote({
    super.key,
    required this.text,
    required this.action,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '$text ',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: inkMuted),
          ),
          InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                action,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: inkText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What went wrong, said plainly under the fields.
class AuthBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const AuthBanner({
    super.key,
    required this.icon,
    required this.text,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.error;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: tint, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: inkText, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
