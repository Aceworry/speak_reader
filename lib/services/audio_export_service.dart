import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'tts_service.dart';

/// 音频导出服务:把文本离线合成为 WAV 文件并落盘,
/// 支持长文本分块合成 + PCM 拼接,以及列出/分享已生成的文件。
///
/// 导出**按当前朗读模式**进行:
/// - 常规模式:整段连读(分块合成再拼接),用常规语速。
/// - 听写模式:逐词组合成 → 每词重复 N 遍 → 词间插入书写停顿(静音 PCM),
///   用听写语速。音色/音调始终按当前设置。
///
/// - 输出目录:优先用用户自定义目录(可写时),否则 `<外部存储>/speak_reader_audio/`。
/// - 格式:Android TTS `synthesizeToFile` 原生只产出 WAV(PCM),
///   MP3 需额外转码依赖(会拖累 CI 构建),故仅导出 WAV。
class AudioExportService {
  static const _dirName = 'speak_reader_audio';
  // 单次合成字符上限(留余量,Android TTS 上限约 4000 字符)
  static const _maxChunk = 2000;

  String? customDir;

  Future<Directory> outputDir() async {
    // 优先自定义目录(可写才用),否则回退应用私有外部存储
    if (customDir != null && customDir!.trim().isNotEmpty) {
      final d = Directory(customDir!);
      if (await _isWritable(d)) return d;
    }
    final base =
        await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> outputDirPath() async => (await outputDir()).path;

  /// 校验目录可写(能创建并删除测试文件)。用于自定义目录选择后的验证。
  Future<bool> isDirWritable(String path) async => _isWritable(Directory(path));

  Future<bool> _isWritable(Directory d) async {
    try {
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File('${d.path}/.sr_write_test');
      await probe.writeAsBytes(const [0]);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 导出整篇文本为一个 WAV,**按当前朗读模式**。
  /// - [dictation]=false: 常规连读,语速用 [rate]。
  /// - [dictation]=true: 逐词重复 [repeatCount] 遍、词间插 [gapSeconds] 秒静音,语速用 [rate]。
  /// [stableName]=true 用固定文件名(自动导出覆盖),false 带时间戳(手动导出保留多版本)。
  Future<String> exportDocument(
    TtsService tts,
    String text, {
    required bool dictation,
    required double rate,
    int repeatCount = 1,
    double gapSeconds = 0,
    double repeatGapSeconds = 0,
    String? baseName,
    bool stableName = false,
    void Function(double progress)? onProgress,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) throw Exception('没有可朗读的内容');

    final dir = await outputDir();
    final name =
        (baseName != null && baseName.trim().isNotEmpty) ? _sanitize(baseName) : '朗读';
    final suffix = dictation ? '_听写' : '';
    final outPath = stableName
        ? '${dir.path}/$name$suffix.wav'
        : '${dir.path}/$name${suffix}_${_timestamp()}.wav';

    if (dictation) {
      return _exportDictation(tts, clean, outPath, dir,
          rate: rate,
          repeatCount: repeatCount,
          gapSeconds: gapSeconds,
          repeatGapSeconds: repeatGapSeconds,
          onProgress: onProgress);
    }
    return _exportRegular(tts, clean, outPath, dir, rate: rate, onProgress: onProgress);
  }

  // ---------- 常规模式:整段连读 ----------
  Future<String> _exportRegular(
    TtsService tts,
    String text,
    String outPath,
    Directory dir, {
    required double rate,
    void Function(double)? onProgress,
  }) async {
    final chunks = _chunkText(text, _maxChunk);
    if (chunks.length == 1) {
      onProgress?.call(0.2);
      final ok = await tts.synthToFile(chunks.first, outPath, rate: rate);
      if (!ok) throw Exception('合成失败,当前 TTS 引擎可能不支持离线合成到文件');
      onProgress?.call(1.0);
      return outPath;
    }
    final tempPaths = <String>[];
    try {
      for (var i = 0; i < chunks.length; i++) {
        final tmp = '${dir.path}/.tmp_chunk_$i.wav';
        final ok = await tts.synthToFile(chunks[i], tmp, rate: rate);
        if (!ok) throw Exception('第 ${i + 1} 段合成失败');
        tempPaths.add(tmp);
        onProgress?.call(0.1 + 0.8 * (i + 1) / chunks.length);
      }
      final ok = await _concatWav(tempPaths, outPath);
      if (!ok) throw Exception('音频拼接失败');
      onProgress?.call(1.0);
      return outPath;
    } finally {
      await _cleanup(tempPaths);
    }
  }

  // ---------- 听写模式:逐词重复 + 词间静音 ----------
  Future<String> _exportDictation(
    TtsService tts,
    String text,
    String outPath,
    Directory dir, {
    required double rate,
    required int repeatCount,
    required double gapSeconds,
    double repeatGapSeconds = 0,
    void Function(double)? onProgress,
  }) async {
    // 复用 TtsService 的听写切词逻辑,保证与朗读一致
    final tokens = tts.tokenizeForDictation(text);
    if (tokens.isEmpty) throw Exception('没有可朗读的词');
    final reps = repeatCount < 1 ? 1 : repeatCount;

    final tempPaths = <String>[];
    try {
      // 逐词合成一份临时 WAV
      final tokenWavs = <String>[];
      for (var i = 0; i < tokens.length; i++) {
        final tmp = '${dir.path}/.tmp_tok_$i.wav';
        final ok = await tts.synthToFile(tokens[i], tmp, rate: rate);
        if (!ok) throw Exception('第 ${i + 1} 个词合成失败');
        tokenWavs.add(tmp);
        tempPaths.add(tmp);
        onProgress?.call(0.1 + 0.7 * (i + 1) / tokens.length);
      }

      // 用首个词的音频参数生成"书写停顿"与"重复间隔"静音 PCM
      final firstInfo = _parseWav(await File(tokenWavs.first).readAsBytes());
      if (firstInfo == null) throw Exception('音频解析失败');
      final wordSilence =
          gapSeconds > 0 ? _silencePcm(firstInfo, gapSeconds) : Uint8List(0);
      final repeatSilence = repeatGapSeconds > 0
          ? _silencePcm(firstInfo, repeatGapSeconds)
          : Uint8List(0);

      // 组装 PCM 序列:每词 reps 遍,重复遍之间插重复间隔、词之间插书写停顿
      final pcm = BytesBuilder();
      for (var i = 0; i < tokens.length; i++) {
        final info = _parseWav(await File(tokenWavs[i]).readAsBytes());
        if (info == null) throw Exception('第 ${i + 1} 个词解析失败');
        for (var r = 0; r < reps; r++) {
          pcm.add(info.data);
          // 同一词的重复遍之间:插重复间隔静音
          if (repeatSilence.isNotEmpty && r < reps - 1) {
            pcm.add(repeatSilence);
          }
        }
        // 词与词之间:插书写停顿静音(最后一个词后不插)
        if (wordSilence.isNotEmpty && i < tokens.length - 1) {
          pcm.add(wordSilence);
        }
        onProgress?.call(0.8 + 0.15 * (i + 1) / tokens.length);
      }

      await _writeWav(outPath, firstInfo, pcm.toBytes());
      onProgress?.call(1.0);
      return outPath;
    } finally {
      await _cleanup(tempPaths);
    }
  }

  /// 列出已生成的音频文件(按修改时间倒序)。
  Future<List<File>> listFiles() async {
    try {
      final dir = await outputDir();
      final entities = await dir.list().toList();
      final files = entities
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.wav'))
          .toList();
      files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      return files;
    } catch (_) {
      return [];
    }
  }

  /// 通过系统分享/打开指定音频文件。
  Future<void> shareFile(String path) async {
    final result = await Share.shareXFiles(
      [XFile(path)],
      text: '语音朗读导出的音频',
    );
    if (result.status == ShareResultStatus.unavailable) {
      throw Exception('系统没有可用的分享目标');
    }
  }

  Future<void> deleteFile(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  Future<void> _cleanup(List<String> paths) async {
    for (final p in paths) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  // ---------------- 文本分块(尽量不切断句子) ----------------

  List<String> _chunkText(String text, int max) {
    if (text.length <= max) return [text];
    final result = <String>[];
    final sentences = text.split(RegExp(r'(?<=[。!?！？\n])'));
    var buf = '';
    for (final s in sentences) {
      if ((buf + s).length > max && buf.isNotEmpty) {
        result.add(buf);
        buf = s;
      } else {
        buf += s;
      }
      while (buf.length > max) {
        result.add(buf.substring(0, max));
        buf = buf.substring(max);
      }
    }
    if (buf.trim().isNotEmpty) result.add(buf);
    return result;
  }

  String _sanitize(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_').trim();
    if (cleaned.isEmpty) return '朗读';
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  String _timestamp() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  // ---------------- WAV 处理 ----------------

  /// 生成一段静音 PCM(全 0),时长 [seconds],参数取自 [info]。
  Uint8List _silencePcm(_WavInfo info, double seconds) {
    final bytesPerSample = info.bitsPerSample ~/ 8;
    final frames = (info.sampleRate * seconds).round();
    final len = frames * info.channels * bytesPerSample;
    return Uint8List(len); // 全 0 = 静音
  }

  Future<bool> _concatWav(List<String> paths, String outPath) async {
    if (paths.isEmpty) return false;
    _WavInfo? ref;
    final data = BytesBuilder();
    for (final p in paths) {
      final info = _parseWav(await File(p).readAsBytes());
      if (info == null) return false;
      ref ??= info;
      if (info.sampleRate != ref.sampleRate ||
          info.channels != ref.channels ||
          info.bitsPerSample != ref.bitsPerSample) {
        return false;
      }
      data.add(info.data);
    }
    await _writeWav(outPath, ref!, data.toBytes());
    return true;
  }

  Future<void> _writeWav(String outPath, _WavInfo fmt, Uint8List dataBytes) async {
    final out = File(outPath);
    final sink = out.openWrite();
    try {
      final sr = fmt.sampleRate, ch = fmt.channels, bps = fmt.bitsPerSample;
      final byteRate = sr * ch * bps ~/ 8;
      final blockAlign = ch * bps ~/ 8;
      final dataSize = dataBytes.length;
      sink.add(_ascii('RIFF'));
      sink.add(_int32(36 + dataSize));
      sink.add(_ascii('WAVE'));
      sink.add(_ascii('fmt '));
      sink.add(_int32(16));
      sink.add(_int16(1)); // PCM
      sink.add(_int16(ch));
      sink.add(_int32(sr));
      sink.add(_int32(byteRate));
      sink.add(_int16(blockAlign));
      sink.add(_int16(bps));
      sink.add(_ascii('data'));
      sink.add(_int32(dataSize));
      sink.add(dataBytes);
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  _WavInfo? _parseWav(Uint8List bytes) {
    if (bytes.length < 44) return null;
    final bd = ByteData.sublistView(bytes);
    if (_str(bytes, 0, 4) != 'RIFF' || _str(bytes, 8, 4) != 'WAVE') return null;

    int offset = 12;
    int? sampleRate, channels, bits;
    Uint8List? data;
    while (offset + 8 <= bytes.length) {
      final id = _str(bytes, offset, 4);
      final size = bd.getUint32(offset + 4, Endian.little);
      final bodyStart = offset + 8;
      if (id == 'fmt ') {
        channels = bd.getUint16(bodyStart + 2, Endian.little);
        sampleRate = bd.getUint32(bodyStart + 4, Endian.little);
        bits = bd.getUint16(bodyStart + 14, Endian.little);
      } else if (id == 'data') {
        final end = bodyStart + size;
        data = Uint8List.sublistView(
          bytes,
          bodyStart,
          end > bytes.length ? bytes.length : end,
        );
      }
      offset = bodyStart + size + (size.isOdd ? 1 : 0);
      if (id == 'data' && data != null) break;
    }
    if (sampleRate == null || channels == null || bits == null || data == null) {
      return null;
    }
    return _WavInfo(sampleRate, channels, bits, data);
  }

  static String _str(Uint8List b, int start, int len) =>
      String.fromCharCodes(b.sublist(start, start + len));
  static List<int> _ascii(String s) => s.codeUnits;
  static List<int> _int32(int v) =>
      [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];
  static List<int> _int16(int v) => [v & 0xff, (v >> 8) & 0xff];
}

class _WavInfo {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final Uint8List data;
  _WavInfo(this.sampleRate, this.channels, this.bitsPerSample, this.data);
}
