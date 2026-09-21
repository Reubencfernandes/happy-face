// Temporary preview entrypoint: shows the welcome and connect screens.
import 'package:flutter/material.dart';

import 'ui/theme.dart';
import 'ui/welcome_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      title: 'Happy Drive',
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      home: WelcomeScreen(onConnected: (_) {}),
    ),
  );
}
