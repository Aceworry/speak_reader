import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../services/audio_export_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../services/tts_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _service = SettingsService();
  final _translation = TranslationService();
  final _tts = TtsService();
  final _audioExport = AudioExportService();

  AppSettings _s = AppSettings();
  bool _loaded = false;
  bool _obscureKey = true;
  bool _testing = false;
  bool _voicesLoading = true;
  bool _previewing = false;
  String? _outputDir;

  List<String> _languages = [];

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
    // 把已保存的音色参数同步给 TTS 引擎,再枚举可用声音
    _tts.voiceLanguage = s.voiceLanguage;
    _tts.voiceName = s.voiceName;
    _tts.pitch = s.pitch;
    _tts.dictationRate = s.dictationRate;
    await _tts.init();
    await _tts.applyVoiceSettings();
    _languages = _tts.availableLanguages;
    _audioExport.customDir = s.customOutputDir;
    try {
      _outputDir = await _audioExport.outputDirPath();
    } catch (_) {}
    setState(() {
      _s = s;
      _baseCtrl.text = s.baseUrl;
      _keyCtrl.text = s.apiKey;
      _modelCtrl.text = s.model;
      _loaded = true;
      _voicesLoading = false;
    });
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _tts.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await _persist();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存')));
    }
  }

  /// 持久化当前设置(同步文本框内容后保存)。音色/音频即时改动也走这里。
  Future<void> _persist() async {
    _s.baseUrl = _baseCtrl.text;
    _s.apiKey = _keyCtrl.text;
    _s.model = _modelCtrl.text;
    await _service.save(_s);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _langLabel(String code) {
    const map = {
      'zh-CN': '中文(简体)', 'zh-TW': '中文(繁体)', 'zh-HK': '中文(香港)',
      'en-US': '美式英语', 'en-GB': '英式英语', 'en-AU': '英语(澳洲)',
      'en-IN': '英语(印度)', 'en-CA': '英语(加拿大)',
      'ja-JP': '日语', 'ko-KR': '韩语', 'fr-FR': '法语', 'de-DE': '德语',
      'es-ES': '西班牙语', 'es-US': '西班牙语(美)', 'ru-RU': '俄语',
      'it-IT': '意大利语', 'pt-BR': '葡萄牙语(巴西)', 'pt-PT': '葡萄牙语',
      'th-TH': '泰语', 'vi-VN': '越南语', 'ar-SA': '阿拉伯语', 'hi-IN': '印地语',
    };
    if (code.isEmpty) return '系统默认';
    return map[code] ?? code;
  }

  List<String> _buildLangItems() {
    final list = <String>['', ..._languages];
    if (_s.voiceLanguage.isNotEmpty && !list.contains(_s.voiceLanguage)) {
      list.add(_s.voiceLanguage);
    }
    return list;
  }

  Future<void> _applyPreset(VoicePreset p) async {
    final matched = await _tts.applyPreset(p);
    setState(() {
      _s.voicePreset = p;
      _s.voiceLanguage = _tts.voiceLanguage;
      _s.voiceName = _tts.voiceName;
      _s.pitch = _tts.pitch;
    });
    await _persist();
    if (!matched && p.gender != 'any') {
      _toast('未找到明确的${p.gender == 'female' ? '女' : '男'}声,已用默认声音;可在下方列表手动选择');
    }
  }

  Future<void> _changeLanguage(String? v) async {
    if (v == null) return;
    _tts.voiceLanguage = v;
    _tts.voiceName = null;
    await _tts.applyVoiceSettings();
    setState(() {
      _s.voiceLanguage = v;
      _s.voiceName = null;
      _s.voicePreset = VoicePreset.system;
    });
    await _persist();
  }

  Future<void> _changeVoice(String? v) async {
    final name = (v == null || v.isEmpty) ? null : v;
    _tts.voiceName = name;
    await _tts.applyVoiceSettings();
    setState(() {
      _s.voiceName = name;
      _s.voicePreset = VoicePreset.system;
    });
    await _persist();
  }

  Future<void> _changePitch(double v) async {
    _tts.pitch = v;
    await _tts.applyVoiceSettings();
    setState(() => _s.pitch = v);
    await _persist();
  }

  Future<void> _preview() async {
    if (_previewing) {
      await _tts.stop();
      setState(() => _previewing = false);
      return;
    }
    setState(() => _previewing = true);
    final sample = _s.voiceLanguage.startsWith('en')
        ? 'Hello, this is a voice preview.'
        : '你好,这是音色试听示例。';
    try {
      await _tts.speakPreview(sample);
    } catch (_) {}
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) setState(() => _previewing = false);
    });
  }

  Future<void> _installVoice() async {
    try {
      await _tts.openInstallVoiceData();
      _toast('已打开系统语音数据安装页,请选择并下载所需语言');
    } catch (e) {
      _toast('无法打开安装页:$e');
    }
  }

  Future<void> _pickOutputDir() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) return; // 用户取消
      final writable = await _audioExport.isDirWritable(dir);
      if (!writable) {
        _toast('该目录不可写(可能受系统限制),已保留原目录');
        return;
      }
      setState(() => _s.customOutputDir = dir);
      _audioExport.customDir = dir;
      _outputDir = dir;
      await _persist();
      _toast('导出目录已设为:$dir');
    } catch (e) {
      _toast('选择目录失败:$e');
    }
  }

  Future<void> _resetOutputDir() async {
    setState(() => _s.customOutputDir = null);
    _audioExport.customDir = null;
    try {
      _outputDir = await _audioExport.outputDirPath();
    } catch (_) {}
    await _persist();
    setState(() {});
    _toast('已恢复默认目录');
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

          // ================= 文字识别 / 翻译方式 =================
          _sectionTitle('文字识别(OCR)方式'),
          const Text(
            '离线识别:完全本地运行、无需联网和 API,识别中英文;\n'
            '在线视觉模型:调用上面配置的视觉大模型,联网、需 API,识别更准。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 8),
          for (final m in OcrMode.values)
            RadioListTile<OcrMode>(
              title: Text(m.label),
              value: m,
              groupValue: _s.ocrMode,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _s.ocrMode = v);
                await _persist();
              },
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('优先离线翻译'),
            subtitle: const Text('用设备内 ML Kit 离线翻译(首次需联网下载语言模型);'
                '不可用时自动回退到上面的在线 API'),
            value: _s.preferOfflineTranslation,
            onChanged: (v) async {
              setState(() => _s.preferOfflineTranslation = v);
              await _persist();
            },
            contentPadding: EdgeInsets.zero,
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
          _slider(
            '听写·单词语速(部分单词读太快可调慢)',
            _s.dictationRate,
            0.1,
            1.0,
            (v) => setState(() {
              _s.dictationRate = v;
              _tts.dictationRate = v;
            }),
            '${(_s.dictationRate * 100).round()}%',
          ),
          _stepper(
            '每个词重复遍数',
            _s.repeatCount,
            1,
            10,
            (v) => setState(() => _s.repeatCount = v),
          ),
          _slider(
            '每词重复之间的间隔(重复≥2遍时生效)',
            _s.repeatGapSeconds,
            0.0,
            5.0,
            (v) => setState(() {
              _s.repeatGapSeconds = v;
              _tts.repeatGapSeconds = v;
            }),
            '${_s.repeatGapSeconds.toStringAsFixed(1)} 秒',
          ),
          _slider(
            '听写·词间停顿(留书写时间)',
            _s.dictationGapSeconds,
            0.5,
            10.0,
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

          // ================= 音色选择 =================
          const Divider(height: 40),
          _sectionTitle('音色选择'),
          const Text(
            '语言/口音(中文、美式、英式等)引擎可靠支持;\n'
            '男声/女声取决于手机已安装的 TTS 声音,可在"具体声音"列表选择;\n'
            '童声通过提高音调模拟。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in VoicePreset.values)
                ChoiceChip(
                  label: Text(p.label),
                  selected: _s.voicePreset == p,
                  onSelected: _voicesLoading ? null : (_) => _applyPreset(p),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.language, size: 20),
              const SizedBox(width: 8),
              const Text('语言/口音'),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _s.voiceLanguage,
                  decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder()),
                  items: [
                    for (final l in _buildLangItems())
                      DropdownMenuItem(value: l, child: Text(_langLabel(l))),
                  ],
                  onChanged: _voicesLoading ? null : _changeLanguage,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Builder(builder: (context) {
            final voiceItems = _tts.voicesForLanguage(_s.voiceLanguage);
            // 当前声音若不在该语言下则回退显示"引擎默认",避免下拉断言
            final current = (_s.voiceName != null &&
                    voiceItems.any((v) => v.name == _s.voiceName))
                ? _s.voiceName!
                : '';
            return Row(
              children: [
                const Icon(Icons.record_voice_over, size: 20),
                const SizedBox(width: 8),
                const Text('具体声音'),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: current,
                    decoration: const InputDecoration(
                        isDense: true, border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem<String>(
                          value: '', child: Text('引擎默认')),
                      for (final v in voiceItems)
                        DropdownMenuItem<String>(
                          value: v.name,
                          child: Text('${v.name}  (${_langLabel(v.locale)})',
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _voicesLoading ? null : (v) => _changeVoice(v),
                  ),
                ),
              ],
            );
          }),
          const SizedBox(height: 12),
          _slider(
            '音调(越高越接近童声)',
            _s.pitch,
            0.5,
            2.0,
            (v) => _changePitch(v),
            '×${_s.pitch.toStringAsFixed(1)}',
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: _installVoice,
                icon: const Icon(Icons.download),
                label: const Text('下载更多声音'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _voicesLoading ? null : _preview,
                icon: Icon(_previewing ? Icons.stop : Icons.play_arrow),
                label: Text(_previewing ? '停止试听' : '试听当前音色'),
              ),
            ],
          ),
          const Text(
            '缺少中文/英文声音的手机:点"下载更多声音"跳转系统设置安装(安卓限制,'
            '声音包由系统 TTS 引擎管理,App 无法内置)。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),

          // ================= 音频导出 =================
          const Divider(height: 40),
          _sectionTitle('音频导出'),
          SwitchListTile(
            title: const Text('朗读时自动生成音频文件'),
            subtitle: const Text('开启后,进入阅读页时后台自动导出一份 WAV'),
            value: _s.autoExportAudio,
            onChanged: (v) async {
              setState(() => _s.autoExportAudio = v);
              await _persist();
            },
            contentPadding: EdgeInsets.zero,
          ),
          Row(
            children: [
              const Text('格式'),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<AudioFormat>(
                  value: _s.audioFormat,
                  decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder()),
                  items: [
                    for (final f in AudioFormat.values)
                      DropdownMenuItem(value: f, child: Text(f.label)),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _s.audioFormat = v);
                    await _persist();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickOutputDir,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择导出目录'),
                ),
              ),
              if (_s.customOutputDir != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _resetOutputDir,
                  child: const Text('恢复默认'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '当前输出目录:\n$_outputDir\n'
            '${_s.customOutputDir != null ? "(自定义)" : "(默认:应用私有目录,无需权限)"}\n'
            '文件可用系统文件管理器查看;阅读页也可手动"导出音频"并分享。\n'
            '若所选目录不可写会自动回退默认目录。MP3 暂不支持(Android 离线 TTS 仅产出 WAV)。',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
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
