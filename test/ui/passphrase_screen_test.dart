import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/password_manager.dart';
import 'package:happy_drive/ui/passphrase_screen.dart';
import 'package:happy_drive/ui/theme.dart';

const account = StoredAccount(
  namespace: 'reuben',
  bucket: 'happy-drive',
  accessKeyId: 'HFAKTEST',
  secretAccessKey: 'x',
);

class FakePasswords extends PasswordManager {
  @override
  final bool available;
  final saved = <(String, String)>[];
  String? stored;
  FakePasswords({this.available = true, this.stored});

  @override
  Future<SaveResult> save(StoredAccount account, String passphrase) async {
    saved.add((account.id, passphrase));
    return SaveResult.saved;
  }

  @override
  Future<String?> load(StoredAccount account) async => stored;
}

Future<void> pump(
  WidgetTester tester,
  PasswordManager passwords, {
  bool hasLibrary = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: PassphraseScreen(
        account: account,
        hasLibrary: hasLibrary,
        onUnlocked: (_) {},
        onBack: () {},
        passwords: passwords,
      ),
    ),
  );
}

void main() {
  const save = 'Save to Google Password Manager';

  testWidgets('saves the new passphrase under the library\'s name', (
    tester,
  ) async {
    final passwords = FakePasswords();
    await pump(tester, passwords);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'mango kite river 42');
    await tester.enterText(fields.at(1), 'mango kite river 42');
    await tester.pump();
    await tester.ensureVisible(find.text(save));
    await tester.tap(find.text(save));
    await tester.pumpAndSettle();
    expect(passwords.saved, [('reuben/happy-drive', 'mango kite river 42')]);
    expect(find.text('Saved to Google Password Manager'), findsOneWidget);

    // A changed passphrase isn't the one that was saved.
    await tester.enterText(fields.at(0), 'mango kite river 43');
    await tester.pump();
    expect(find.text(save), findsOneWidget);
  });

  testWidgets('nothing is saved while the two entries differ', (tester) async {
    final passwords = FakePasswords();
    await pump(tester, passwords);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'mango kite river 42');
    await tester.enterText(fields.at(1), 'mango kite river');
    await tester.ensureVisible(find.text(save));
    await tester.tap(find.text(save));
    await tester.pumpAndSettle();
    expect(passwords.saved, isEmpty);
    expect(find.text('The passphrases don\'t match'), findsOneWidget);
  });

  testWidgets('no password manager, no buttons', (tester) async {
    await pump(tester, FakePasswords(available: false));
    expect(find.text(save), findsNothing);
    await pump(tester, FakePasswords(available: false), hasLibrary: true);
    expect(find.text('Use saved passphrase'), findsNothing);
  });

  testWidgets('unlocking offers the saved passphrase', (tester) async {
    await pump(tester, FakePasswords(), hasLibrary: true);
    expect(find.text('Use saved passphrase'), findsOneWidget);
    expect(find.text(save), findsNothing);
  });
}
