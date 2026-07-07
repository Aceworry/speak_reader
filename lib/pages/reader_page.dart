import 'package:flutter/material.dart';

import '../models/document.dart';
import '../services/tts_service.dart';
import '../services/storage_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';

class ReaderPage extends StatefulWidget {
  final Document document;
  const ReaderPage({super.key, required this.document});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _tts = TtsService();
  final _storage = StorageService();
  final _settingsService = SettingsService();
  final _translation = TranslationService();
  final _scrollController = ScrollController();

  late Document _doc;
  AppSettings _settings = AppSettings();

  int _currentToken = -1;
  TtsState _state = TtsState.stopped;
  bool _editing = false;
  bool _translating = false;
  String? _translated; // 译文(为 null 时不显示)
  late TextEditingController _editController;

  final _tokenKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    _editController = TextEditingController(text: _doc.content);

    _tts.onTokenChanged = (i) {
      if (!mounted) return;
      setState(() => _currentToken = i);
      _autoScrollTo(i);
    };
    _tts.onStateChanged = (s) {
      if (mounted) setState(() => _state = s);
    };
    _tts.onComplete = () {
      if (mounted) setState(() => _currentToken = -1);
    };

    _init();
  }

  Future<void> _init() async {
    _settings = await _settingsService.load();
    // 把设置里的参数灌进 TTS 引擎
    _tts.wordGapSeconds = _settings.wordGapSeconds;
    _tts.repeatCount = _settings.repeatCount;
    _tts.dictationGapSeconds = _settings.dictationGapSeconds;
    _tts.loop = _settings.loop;
    await _tts.init();
    _tts.setText(_doc.content);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tts.dispose();
    _scrollController.dispose();
    _editController.dispose();
    super.dispose();
  }

  void _autoScrollTo(int index) {
    final ctx = _tokenKeys[index]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
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

  void _toggleDictation(bool v) {
    setState(() => _tts.dictationMode = v);
  }

  // ---------------- 翻译 ----------------

  Future<void> _translate() async {
    if (!_settings.translationReady) {
      _toast('请先到「设置」配置翻译 API');
      return;
    }
    final text = _doc.content.trim();
    if (text.isEmpty) {
      _toast('没有可翻译的内容');
      return;
    }
    setState(() => _translating = true);
    try {
      final r = await _translation.translate(text, settings: _settings);
      setState(() => _translated = r);
    } catch (e) {
      _toast('翻译失败:$e');
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  // ---------------- 编辑 ----------------

  Future<void> _toggleEdit() async {
    if (_editing) {
      await _tts.stop();
      setState(() {
        _doc.content = _editController.text;
        _editing = false;
        _translated = null;
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
          if (!_editing)
            IconButton(
              icon: _translating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.translate),
              tooltip: '翻译',
              onPressed: _translating ? null : _translate,
            ),
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
    final tokens = _tts.tokens;
    if (tokens.isEmpty) {
      return const Center(child: Text('没有可朗读的内容'));
    }
    final baseStyle = TextStyle(
      fontSize: 20,
      height: 1.9,
      color: Theme.of(context).colorScheme.onSurface,
    );
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              for (int i = 0; i < tokens.length; i++)
                GestureDetector(
                  onTap: () => _tts.playFrom(i),
                  child: Container(
                    key: _tokenKeys.putIfAbsent(i, () => GlobalKey()),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                    decoration: BoxDecoration(
                      color: i == _currentToken
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      tokens[i],
                      style: i == _currentToken
                          ? baseStyle.copyWith(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontWeight: FontWeight.bold)
                          : baseStyle,
                    ),
                  ),
                ),
            ],
          ),
          if (_translated != null) ...[
            const SizedBox(height: 20),
            const Divider(),
            Row(
              children: [
                const Icon(Icons.translate, size: 18),
                const SizedBox(width: 6),
                const Text('译文',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _translated = null),
                ),
              ],
            ),
            SelectableText(
              _translated!,
              style: const TextStyle(fontSize: 18, height: 1.7),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildControls() {
    final playing = _state == TtsState.playing;
    final dictation = _tts.dictationMode;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 听写模式开关
            Row(
              children: [
                const Icon(Icons.spellcheck, size: 20),
                const SizedBox(width: 8),
                const Text('听写模式'),
                const Spacer(),
                Switch(value: dictation, onChanged: _toggleDictation),
              ],
            ),
            // 间隔滑块:普通模式=词间间隔;听写模式=词间停顿
            Row(
              children: [
                const Icon(Icons.more_horiz, size: 20),
                const SizedBox(width: 8),
                Text(dictation ? '书写停顿' : '词间间隔'),
                Expanded(
                  child: dictation
                      ? Slider(
                          value: _tts.dictationGapSeconds.clamp(0.5, 6.0),
                          min: 0.5,
                          max: 6.0,
                          divisions: 11,
                          label:
                              '${_tts.dictationGapSeconds.toStringAsFixed(1)}s',
                          onChanged: (v) =>
                              setState(() => _tts.dictationGapSeconds = v),
                        )
                      : Slider(
                          value: _tts.wordGapSeconds.clamp(0.0, 2.0),
                          min: 0.0,
                          max: 2.0,
                          divisions: 20,
                          label: '${_tts.wordGapSeconds.toStringAsFixed(1)}s',
                          onChanged: (v) =>
                              setState(() => _tts.wordGapSeconds = v),
                        ),
                ),
              ],
            ),
            // 听写模式:重复遍数
            if (dictation)
              Row(
                children: [
                  const Icon(Icons.repeat, size: 20),
                  const SizedBox(width: 8),
                  const Text('每词重复'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: _tts.repeatCount > 1
                        ? () => setState(() => _tts.repeatCount--)
                        : null,
                  ),
                  Text('${_tts.repeatCount} 遍',
                      style: const TextStyle(fontSize: 16)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: _tts.repeatCount < 5
                        ? () => setState(() => _tts.repeatCount++)
                        : null,
                  ),
                ],
              ),
            const SizedBox(height: 2),
            // 播放按钮组
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  iconSize: 30,
                  onPressed: _stop,
                  icon: const Icon(Icons.stop),
                ),
                const SizedBox(width: 24),
                FloatingActionButton.large(
                  onPressed: _togglePlay,
                  child:
                      Icon(playing ? Icons.pause : Icons.play_arrow, size: 40),
                ),
                const SizedBox(width: 24),
                IconButton.filledTonal(
                  iconSize: 30,
                  onPressed: () {
                    final next = _currentToken + 1;
                    if (next < _tts.tokens.length) {
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
