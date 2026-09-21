import 'package:flutter/material.dart';

import '../app/credentials.dart';
import 'connect_screen.dart';
import 'theme.dart';

/// The first thing a new phone sees: a dark hero with the app's glow, then
/// one way in. The details live behind "Get started", so the screen asks for
/// nothing until the user has said yes.
class WelcomeScreen extends StatelessWidget {
  final void Function(ConnectResult result) onConnected;
  final BucketClientFactory clientFactory;
  final StoredAccount? previous;

  const WelcomeScreen({
    super.key,
    required this.onConnected,
    this.clientFactory = defaultBucketClient,
    this.previous,
  });

  static const _ink = ink;
  static const _onInk = Color(0xFFF7F3EC);

  void _open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => ConnectScreen(
        onConnected: onConnected,
        clientFactory: clientFactory,
        previous: previous,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = _onInk.withValues(alpha: 0.62);
    return Scaffold(
      backgroundColor: _ink,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const _Glow(),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                // The spacers give the hero its room; the scroll view is
                // there for small screens and large text sizes.
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                          child: Column(
                            children: [
                              const Spacer(flex: 5),
                              Text(
                                'Welcome to Happy Drive',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  color: _onInk,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Your photos, encrypted on this phone and backed up '
                                'to storage you own.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: muted,
                                  height: 1.4,
                                ),
                              ),
                              const Spacer(flex: 3),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _onInk.withValues(alpha: 0.22),
                                      blurRadius: 36,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _onInk,
                                    foregroundColor: _ink,
                                  ),
                                  onPressed: () => _open(context),
                                  child: const Text('Get started'),
                                ),
                              ),
                              const Spacer(),
                              Text(
                                'Happy Drive keeps your keys on this phone and only '
                                'ever sends them to Hugging Face. Nobody else — not '
                                'even us — can read your photos.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _onInk.withValues(alpha: 0.38),
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The sunrise: the bottom rim of three huge circles sitting above the
/// screen, so what shows is an arc of light over the ink. Drawn rather than
/// shipped as an image, so it is sharp at any size.
class _Glow extends StatelessWidget {
  const _Glow();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final height = constraints.maxHeight;

      /// A circle of [diameter] whose lowest point sits at [bottom], lit
      /// along its rim and empty in the middle.
      Widget dome(double diameter, double bottom, Color color, double alpha) =>
          Positioned(
            left: (width - diameter) / 2,
            top: bottom - diameter,
            width: diameter,
            height: diameter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  stops: const [0.0, 0.55, 0.78, 0.92, 1.0],
                  colors: [
                    Colors.transparent,
                    color.withValues(alpha: alpha * 0.10),
                    color.withValues(alpha: alpha * 0.55),
                    color.withValues(alpha: alpha),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          );

      return ClipRect(
        child: Stack(
          children: [
            // Haze, sun, then ember: cool cream outside, hot centre.
            dome(width * 2.7, height * 0.50, glowHaze, 0.20),
            dome(width * 2.15, height * 0.45, glowSun, 0.34),
            dome(width * 1.55, height * 0.38, glowEmber, 0.30),
            // A breath of warmth at the very top so the arc doesn't float.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: height * 0.55,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      glowSun.withValues(alpha: 0.05),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
