import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show lerpDouble;

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
                              Image.asset(
                                'assets/brand/mascot.png',
                                height: 64,
                                semanticLabel: 'Happy Drive',
                              ),
                              const SizedBox(height: 24),
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

/// The sunrise: one wide arc of light over the ink, peach at its crown,
/// then orange, then red, fading to nothing inside — like the rim of a sun
/// seen through haze. Drawn rather than shipped as an image, so it is sharp
/// at any size, with a fine grain over it so it reads as light rather than
/// a flat gradient.
///
/// It rises from below the screen into place when the screen opens, then
/// keeps rippling gently: the rim wavers and the hot side drifts. With
/// Reduce Motion on it simply sits there.
class _Glow extends StatefulWidget {
  const _Glow();

  @override
  State<_Glow> createState() => _GlowState();
}

class _GlowState extends State<_Glow> with TickerProviderStateMixin {
  late final AnimationController _rise = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  );
  ui.Image? _grain;

  @override
  void initState() {
    super.initState();
    _makeGrain();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _rise.value = 1;
      _ripple.stop();
    } else if (!_rise.isAnimating && _rise.value == 0) {
      _rise.forward();
      _ripple.repeat();
    }
  }

  /// A tile of random light and dark specks, laid over the glow only.
  void _makeGrain() {
    const size = 160;
    final random = math.Random(7);
    final pixels = Uint8List(size * size * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      final alpha = random.nextInt(34);
      // Premultiplied, as the engine expects: a white speck's colour can't
      // be brighter than its own opacity.
      final v = random.nextBool() ? alpha : 0;
      pixels
        ..[i] = v
        ..[i + 1] = v
        ..[i + 2] = v
        ..[i + 3] = alpha;
    }
    ui.decodeImageFromPixels(pixels, size, size, ui.PixelFormat.rgba8888, (
      image,
    ) {
      if (mounted) {
        setState(() => _grain = image);
      } else {
        image.dispose();
      }
    });
  }

  @override
  void dispose() {
    _rise.dispose();
    _ripple.dispose();
    _grain?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: Listenable.merge([_rise, _ripple]),
      builder: (context, _) => CustomPaint(
        size: Size.infinite,
        painter: _SunrisePainter(
          rise: Curves.easeOutCubic.transform(_rise.value),
          ripple: _ripple.value,
          grain: _grain,
        ),
      ),
    ),
  );
}

class _SunrisePainter extends CustomPainter {
  /// 0 below the screen, 1 in place.
  final double rise;

  /// Where the ripple is in its loop, 0 to 1.
  final double ripple;
  final ui.Image? grain;

  _SunrisePainter({required this.rise, required this.ripple, this.grain});

  static const _peach = Color(0xFFFFD0A6);
  static const _orange = Color(0xFFFF7A1F);
  static const _red = Color(0xFFE3262D);
  static const _maroon = Color(0xFF6E0F1F);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w == 0 || h == 0 || rise == 0) return;
    final t = ripple * 2 * math.pi;
    // Wide enough that the arc falls away past the screen's edges, but not
    // so wide on a tablet that it flattens into a band.
    final radius = math.min(w * 0.56, h * 0.34);
    final crown = lerpDouble(h * 1.05, h * 0.13, rise)!;
    final centre = Offset(w / 2, crown + radius);

    // The rim, wavering: a circle whose edge is pushed in and out by two
    // slow waves, so it never looks drawn with a compass.
    final path = Path();
    const steps = 120;
    for (var i = 0; i <= steps; i++) {
      final a = i / steps * 2 * math.pi;
      final r =
          radius *
          (1 +
              0.018 * math.sin(3 * a + t) +
              0.01 * math.sin(5 * a - 2 * t) * rise);
      final p = centre + Offset(math.cos(a) * r, math.sin(a) * r);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();

    final bounds = Offset.zero & size;
    // Faint while it climbs past the words, full once it's up.
    canvas.saveLayer(
      bounds,
      Paint()..color = Colors.white.withValues(alpha: 0.25 + 0.75 * rise),
    );
    // The hot side drifts a little left and right, so the colour moves
    // through the arc instead of sitting still — slowly and not far, or the
    // whole arc seems to swing.
    final drift = Offset(math.sin(t) * radius * 0.05, 0);
    canvas.drawPath(
      path,
      Paint()
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.11)
        ..shader = RadialGradient(
          stops: const [0.0, 0.42, 0.62, 0.78, 0.9, 0.97, 1.0],
          colors: [
            Colors.transparent,
            Colors.transparent,
            _maroon.withValues(alpha: 0.55),
            _red.withValues(alpha: 0.85),
            _orange,
            _peach,
            _peach.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: centre + drift, radius: radius)),
    );
    // Only the crown shows: the lower half of the ring fades out before it
    // reaches the words.
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Colors.white, Colors.white, Colors.transparent],
          stops: [
            0,
            ((centre.dy - radius * 0.55) / h).clamp(0.0, 1.0),
            ((centre.dy - radius * 0.05) / h).clamp(0.0, 1.0),
          ],
        ).createShader(bounds),
    );
    // Grain on the light only, never on the ink around it.
    final grain = this.grain;
    if (grain != null) {
      canvas.drawRect(
        bounds,
        Paint()
          ..blendMode = BlendMode.srcATop
          ..shader = ImageShader(
            grain,
            TileMode.repeated,
            TileMode.repeated,
            Matrix4.identity().storage,
          ),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SunrisePainter old) =>
      old.rise != rise || old.ripple != ripple || old.grain != grain;
}
