import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:happy_drive/main.dart';

void main() {
  testWidgets('connection screen fits a phone and obscures the token', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HappyDriveApp());
    await tester.pumpAndSettle();
    expect(find.text('Connect private library'), findsOneWidget);
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.last.obscureText, true);
    await tester.tap(find.text('Connect private library'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a dataset name'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
