import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'hf_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HappyDriveApp());
}

class HappyDriveApp extends StatelessWidget {
  const HappyDriveApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Happy Drive',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff195b47)),
      scaffoldBackgroundColor: const Color(0xfff6f8f7),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white,
      ),
    ),
    home: const LibraryScreen(),
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final storage = const FlutterSecureStorage();
  final repoController = TextEditingController();
  final tokenController = TextEditingController();
  HfService? service;
  List<Photo> photos = [];
  bool loading = true, uploading = false, obscure = true;
  String query = '', status = '';
  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    try {
      final repo = await storage.read(key: 'hf_repo');
      final token = await storage.read(key: 'hf_token');
      if (!mounted) return;
      if (repo != null && token != null) {
        repoController.text = repo;
        tokenController.text = token;
        await connect();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => status = 'Could not read secure storage. Please reconnect.',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String friendly(Object error) => error is DriveException
      ? error.message
      : 'The operation failed. Check your connection and try again.';
  Future<void> connect() async {
    setState(() {
      loading = true;
      status = '';
    });
    final candidate = HfService(
      repo: repoController.text.trim(),
      token: tokenController.text.trim(),
    );
    try {
      final result = await candidate.listPhotos();
      await storage.write(key: 'hf_repo', value: candidate.repo);
      await storage.write(key: 'hf_token', value: candidate.token);
      if (!mounted) {
        candidate.close();
        return;
      }
      service?.close();
      setState(() {
        service = candidate;
        photos = result;
        tokenController.clear();
      });
    } catch (e) {
      candidate.close();
      if (mounted) setState(() => status = friendly(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> refresh() async {
    setState(() {
      loading = true;
      status = '';
    });
    try {
      final result = await service!.listPhotos();
      if (mounted) setState(() => photos = result);
    } catch (e) {
      if (mounted) setState(() => status = friendly(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> upload() async {
    setState(() => uploading = true);
    final errors = <String>[];
    int done = 0, total = 0;
    try {
      final selected = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
      );
      if (selected.isEmpty) return;
      total = selected.length;
      for (final file in selected) {
        if (!mounted) return;
        setState(
          () => status =
              'Uploading ${done + errors.length + 1} of $total: ${file.name}',
        );
        try {
          if ((await file.length() ?? 26 * 1024 * 1024) > 25 * 1024 * 1024) {
            throw DriveException('Larger than 25 MB.');
          }
          final bytes = await file.readAsBytes();
          await service!.upload(file.name, bytes);
          done++;
        } catch (e) {
          errors.add('${file.name}: ${friendly(e)}');
        }
      }
      await refresh();
      if (mounted) {
        setState(
          () => status =
              '$done of $total photos uploaded.${errors.isEmpty ? '' : '\n${errors.join('\n')}'}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => status = friendly(e));
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> disconnect() async {
    try {
      await storage.delete(key: 'hf_token');
      await storage.delete(key: 'hf_repo');
      service?.close();
      if (mounted) {
        setState(() {
          service = null;
          photos = [];
          status = '';
          query = '';
          tokenController.clear();
        });
      }
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {
      if (mounted) {
        setState(
          () => status = 'Could not clear saved credentials. Please try again.',
        );
      }
    }
  }

  @override
  void dispose() {
    repoController.dispose();
    tokenController.dispose();
    service?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = service != null;
    final filtered = photos
        .where((p) => p.name.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.photo_library_outlined),
            SizedBox(width: 12),
            Text('Happy Drive', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          if (connected)
            IconButton(
              onPressed: loading || uploading ? null : disconnect,
              icon: const Icon(Icons.logout),
              tooltip: 'Disconnect and forget token',
            ),
          const SizedBox(width: 12),
        ],
      ),
      floatingActionButton: connected
          ? FloatingActionButton.extended(
              onPressed: loading || uploading ? null : upload,
              icon: Icon(
                uploading
                    ? Icons.hourglass_top
                    : Icons.add_photo_alternate_outlined,
              ),
              label: Text(uploading ? 'Uploading…' : 'Upload photos'),
            )
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (loading || uploading) const LinearProgressIndicator(),
                if (status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        status,
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                if (!connected)
                  Expanded(
                    child: ListView(
                      children: [
                        const SizedBox(height: 40),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Icon(
                            Icons.cloud_outlined,
                            size: 54,
                            color: Color(0xff195b47),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'A home for\nyour photos.',
                          style: TextStyle(
                            fontSize: 38,
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Connect a private Hugging Face dataset to start your personal library.',
                          style: TextStyle(fontSize: 17),
                        ),
                        const SizedBox(height: 32),
                        TextField(
                          controller: repoController,
                          enabled: !loading,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Dataset',
                            hintText: 'username/my-photos',
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: tokenController,
                          enabled: !loading,
                          obscureText: obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'Hugging Face write token',
                            hintText: 'hf_…',
                            suffixIcon: IconButton(
                              onPressed: () =>
                                  setState(() => obscure = !obscure),
                              icon: Icon(
                                obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              tooltip: 'Show or hide token',
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: loading ? null : connect,
                          icon: const Icon(Icons.lock_outline),
                          label: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Text('Connect private library'),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'First, create a dataset at huggingface.co/new-dataset and select Private. Generate a token with read and write access at huggingface.co/settings/tokens.\n\nYour token is saved in secure device storage. Photos go directly to Hugging Face.',
                          style: TextStyle(
                            height: 1.6,
                            color: Color(0xff52675e),
                          ),
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                  )
                else ...[
                  const SizedBox(height: 24),
                  const Text(
                    'All photos',
                    style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${photos.length} photos · Private library',
                    style: const TextStyle(color: Color(0xff52675e)),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: (v) => setState(() => query = v),
                          decoration: const InputDecoration(
                            hintText: 'Search photos',
                            prefixIcon: Icon(Icons.search),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: loading || uploading ? null : refresh,
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Refresh library',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.photo_library_outlined,
                                  size: 64,
                                  color: Color(0xff79958a),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  photos.isEmpty
                                      ? 'Your memories start here'
                                      : 'No matching photos',
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'JPEG, PNG, GIF, WebP · Up to 25 MB each',
                                ),
                                const SizedBox(height: 70),
                              ],
                            ),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.only(bottom: 100),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 260,
                                  mainAxisSpacing: 14,
                                  crossAxisSpacing: 14,
                                  childAspectRatio: .88,
                                ),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) => PhotoTile(
                              key: ValueKey(filtered[index].path),
                              photo: filtered[index],
                              service: service!,
                            ),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PhotoTile extends StatefulWidget {
  final Photo photo;
  final HfService service;
  const PhotoTile({super.key, required this.photo, required this.service});
  @override
  State<PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<PhotoTile> {
  late Future<Uint8List> data;
  @override
  void initState() {
    super.initState();
    data = widget.service.download(widget.photo);
  }

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    margin: EdgeInsets.zero,
    elevation: 0,
    child: InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PhotoScreen(photo: widget.photo, data: data),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: FutureBuilder<Uint8List>(
              future: data,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Retry preview',
                    onPressed: () => setState(
                      () => data = widget.service.download(widget.photo),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                return Image.memory(
                  snapshot.data!,
                  fit: BoxFit.cover,
                  cacheWidth: 450,
                  errorBuilder: (_, error, stack) =>
                      const Center(child: Icon(Icons.broken_image_outlined)),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              widget.photo.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

class PhotoScreen extends StatefulWidget {
  final Photo photo;
  final Future<Uint8List> data;
  const PhotoScreen({super.key, required this.photo, required this.data});
  @override
  State<PhotoScreen> createState() => _PhotoScreenState();
}

class _PhotoScreenState extends State<PhotoScreen> {
  bool saving = false;
  Future<void> save() async {
    setState(() => saving = true);
    try {
      final bytes = await widget.data;
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save original photo',
        fileName: widget.photo.name,
        bytes: bytes,
      );
      if (path != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Photo saved.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the photo. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.photo.name),
      actions: [
        IconButton(
          onPressed: saving ? null : save,
          icon: const Icon(Icons.download_outlined),
          tooltip: 'Save original',
        ),
      ],
    ),
    body: Center(
      child: FutureBuilder<Uint8List>(
        future: widget.data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Text('Could not load this photo. Go back and retry.');
          }
          if (!snapshot.hasData) return const CircularProgressIndicator();
          return InteractiveViewer(
            minScale: .5,
            maxScale: 5,
            child: Image.memory(
              snapshot.data!,
              errorBuilder: (_, error, stack) => const Text(
                'This image could not be displayed. You can still save it.',
              ),
            ),
          );
        },
      ),
    ),
  );
}
