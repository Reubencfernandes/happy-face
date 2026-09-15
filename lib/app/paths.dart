import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where the local database and encrypted thumbnail cache live. Shared by the
/// app and the background backup task so both see the same state.
Future<Directory> appDataDir() async =>
    Directory('${(await getApplicationSupportDirectory()).path}/happy_drive');
