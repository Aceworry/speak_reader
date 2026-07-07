import 'package:flutter/material.dart';

import '../models/document.dart';
import '../services/tts_service.dart';
import '../services/storage_service.dart';

class ReaderPage extends StatefulWidget {
  final Document document;
  const ReaderPage({super.key, required this.document});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _tts = TtsService();
  final _storage = StorageService();
  final _scrollController = ScrollController();

  late Document _doc;
  int _currentSentence = -1;
  TtsState _state = TtsState.stopped;
  bool _editing = false;
  late TextEditingController _editController;

  final _sentenceKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    _editController = TextEditingController(text: _doc.content);

    _tts.onSentenceChanged = (i) {
      if (!mounted) return;
      setState(() => _currentSentence = i);
      _autoScrollTo(i);
    };
    _tts.onStateChanged = (s) {
      if (mounted) setState(() => _state = s);
    };
    _tts.onComplete = () {
      if (mounted) setState(() => _currentSentence = -1);
    };

    _tts.init().then((_) => _tts.setText(_doc.content));
  }

  @override
  void dispose() {
    _tts.dispose();
    _scrollController.dispose();
    _editController.dispose();
    super.dispose();
  }

  void _autoScrollTo(int index) {
    final key = _sentenceKeys[index];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.3,
      );
    }
  }

  // ---------------- 朗读控制 ----------------

  Future<void> _togglePlay() async {
    switch (_state) {
      case TtsState.playing:
        await _tts.pause();
        break;
      case TtsState.paused:
        await _tts.resume();
        break;
      case TtsState.stopped:
        await _tts.play();
        break;
    }
  }

  Future<void> _stop() => _tts.stop();

  // ---------------- 编辑 ----------------

  Future<void> _toggleEdit() async {
    if (_editing) {
      // 保存
      await _tts.stop();
      setState(() {
        _doc.content = _editController.text;
        _editing = false;
      });
      _tts.setText(_doc.content);
      await _storage.upsert(_doc);
      _toast('已保存');
    } else {
      await _tts.stop();
      _editController.text = _doc.content;
      setState(() => _editing = true);
    }
  }

  Future<void> _renameDialog() async {
    final controller = TextEditingController(text: _doc.title);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入标题'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      setState(() => _doc.title = name);
      await _storage.upsert(_doc);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _editing ? null : _renameDialog,
          child: Text(_doc.title, overflow: TextOverflow.ellipsis),
        ),
        actions: [
          IconButton(
            icon: Icon(_editing ? Icons.check : Icons.edit),
            tooltip: _editing ? '保存' : '编辑文字',
            onPressed: _toggleEdit,
          ),
        ],
      ),
      body: _editing ? _buildEditor() : _buildReader(),
      bottomNavigationBar: _editing ? null : _buildControls(),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _editController,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: '在此纠正识别的文字…',
        ),
      ),
    );
  }

  Widget _buildReader() {
    final sentences = _tts.sentences;
    if (sentences.isEmpty) {
      return const Center(child: Text('没有可朗读的内容'));
    }
    final baseStyle = TextStyle(
      fontSize: 20,
      height: 1.8,
      color: Theme.of(context).colorScheme.onSurface,
    );
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: RichText(
        text: TextSpan(
          style: baseStyle,
          children: [
            for (int i = 0; i < sentences.length; i++)
              WidgetSpan(
                child: GestureDetector(
                  onTap: () => _tts.playFrom(i),
                  child: Container(
                    key: _sentenceKeys.putIfAbsent(i, () => GlobalKey()),
                    decoration: BoxDecoration(
                      color: i == _currentSentence
                          ? Theme.of(context)
                              .colorScheme
                              .primaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(sentences[i], style: baseStyle),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    final playing = _state == TtsState.playing;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 语速
            Row(
              children: [
                const Icon(Icons.speed, size: 20),
                const SizedBox(width: 8),
                const Text('语速'),
                Expanded(
                  child: Slider(
                    value: _tts.rate,
                    min: 0.1,
                    max: 1.0,
                    divisions: 9,
                    label: '${(_tts.rate * 100).round()}%',
                    onChanged: (v) => setState(() => _tts.setRate(v)),
                  ),
                ),
              ],
            ),
            // 音调
            Row(
              children: [
                const Icon(Icons.music_note, size: 20),
                const SizedBox(width: 8),
                const Text('音调'),
                Expanded(
                  child: Slider(
                    value: _tts.pitch,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: _tts.pitch.toStringAsFixed(1),
                    onChanged: (v) => setState(() => _tts.setPitch(v)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 播放按钮组
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  iconSize: 32,
                  onPressed: _stop,
                  icon: const Icon(Icons.stop),
                ),
                const SizedBox(width: 24),
                FloatingActionButton.large(
                  onPressed: _togglePlay,
                  child: Icon(playing ? Icons.pause : Icons.play_arrow,
                      size: 40),
                ),
                const SizedBox(width: 24),
                IconButton.filledTonal(
                  iconSize: 32,
                  onPressed: () {
                    // 跳到下一句
                    final next = _currentSentence + 1;
                    if (next < _tts.sentences.length) {
                      _tts.playFrom(next);
                    }
                  },
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
