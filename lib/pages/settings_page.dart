import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../services/translation_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _service = SettingsService();
  final _translation = TranslationService();

  AppSettings _s = AppSettings();
  bool _loaded = false;
  bool _obscureKey = true;
  bool _testing = false;

  late TextEditingController _baseCtrl;
  late TextEditingController _keyCtrl;
  late TextEditingController _modelCtrl;

  @override
  void initState() {
    super.initState();
    _baseCtrl = TextEditingController();
    _keyCtrl = TextEditingController();
    _modelCtrl = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final s = await _service.load();
    setState(() {
      _s = s;
      _baseCtrl.text = s.baseUrl;
      _keyCtrl.text = s.apiKey;
      _modelCtrl.text = s.model;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _s.baseUrl = _baseCtrl.text;
    _s.apiKey = _keyCtrl.text;
    _s.model = _modelCtrl.text;
    await _service.save(_s);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存')));
    }
  }

  Future<void> _testConnection() async {
    _s.baseUrl = _baseCtrl.text;
    _s.apiKey = _keyCtrl.text;
    _s.model = _modelCtrl.text;
    await _service.save(_s);
    setState(() => _testing = true);
    try {
      final r = await _translation.translate('Hello, world.', settings: _s);
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('连接成功 ✅'),
            content: Text('测试翻译结果:\n$r'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('好的')),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('连接失败 ❌'),
            content: Text('$e'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('好的')),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('翻译 / 图片识别 API(OpenAI 兼容)'),
          const Text(
            '支持 OpenAI / DeepSeek / 通义千问 / 智谱 / Kimi 等。\n'
            '填对方的接口地址(到 /v1 为止)、密钥、模型名。\n'
            '📷 拍照/选图的文字识别用视觉大模型完成,'
            '请填写支持图片输入的模型(如 gpt-4o、qwen-vl-max、glm-4v)。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseCtrl,
            decoration: const InputDecoration(
              labelText: '接口地址 (baseURL)',
              hintText: 'https://api.deepseek.com/v1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyCtrl,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              labelText: 'API 密钥 (Key)',
              hintText: 'sk-...',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                    _obscureKey ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              labelText: '模型名 (model)',
              hintText: 'gpt-4o-mini / deepseek-chat / qwen-plus',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _testing ? null : _testConnection,
            icon: _testing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_tethering),
            label: Text(_testing ? '测试中…' : '测试连接'),
          ),
          const Divider(height: 40),

          _sectionTitle('朗读参数'),
          _slider(
            '常规模式·语速',
            _s.speechRate,
            0.1,
            1.0,
            (v) => setState(() => _s.speechRate = v),
            '${(_s.speechRate * 100).round()}%',
          ),
          const Divider(height: 24),
          _sectionTitle('听写模式'),
          _stepper(
            '每个词重复遍数',
            _s.repeatCount,
            1,
            5,
            (v) => setState(() => _s.repeatCount = v),
          ),
          _slider(
            '听写·词间停顿(留书写时间)',
            _s.dictationGapSeconds,
            0.5,
            6.0,
            (v) => setState(() => _s.dictationGapSeconds = v),
            '${_s.dictationGapSeconds.toStringAsFixed(1)} 秒',
          ),
          SwitchListTile(
            title: const Text('整篇读完后循环'),
            value: _s.loop,
            onChanged: (v) => setState(() => _s.loop = v),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          const Text(
            '提示:这些是默认值,阅读页里也能随时快速调整。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      );

  Widget _slider(String label, double value, double min, double max,
      ValueChanged<double> onChanged, String valueText) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(valueText, style: const TextStyle(color: Colors.grey)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) / 0.1).round(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _stepper(
      String label, int value, int min, int max, ValueChanged<int> onChanged) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: value > min ? () => onChanged(value - 1) : null,
            ),
            Text('$value', style: const TextStyle(fontSize: 16)),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: value < max ? () => onChanged(value + 1) : null,
            ),
          ],
        ),
      ],
    );
  }
}
