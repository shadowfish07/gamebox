import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'design_system/gamebox_theme.dart';
import 'features/scratch/card_draw_preview.dart';
import 'features/scratch/scratch_page.dart';

Future<void> main() async {
  if (!kDebugMode) {
    throw StateError('The card draw preview requires a debug build.');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      theme: GameboxTheme.light(),
      darkTheme: GameboxTheme.dark(),
      home: const CardDrawPreviewPage(),
    ),
  );
}

class CardDrawPreviewPage extends StatefulWidget {
  const CardDrawPreviewPage({super.key});

  @override
  State<CardDrawPreviewPage> createState() => _CardDrawPreviewPageState();
}

class _CardDrawPreviewPageState extends State<CardDrawPreviewPage> {
  final _controller = createCardDrawPreviewController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScratchPage(
    controller: _controller,
    socialApi: const CardDrawPreviewSocialApi(),
  );
}
