import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'tts_service.dart';

/// 音频导出服务:把文本离线合成为 WAV 文件并落盘到应用外部存储,
/// 支持长文本分块合成 + PCM 拼接,以及列出/分享已生成的文件。
///
/// - 输出目录:`<外部存储>/speak_reader_audio/`,无需运行时权限,
///   可被系统文件管理器访问。
/// - 格式:Android TTS `synthesizeToFile` 原生只产出 WAV(PCM),
///   MP3 需额外转码依赖(会拖累 CI 构建),故 v2.0.0 仅导出 WAV。
class AudioExportService {
  static const _dirName = 'speak_reader_audio';
  // 单次合成字符上限(留余量,Android TTS 上限约 4000 字符)
  static const _maxChunk = 2000;

  Future<Directory> outputDir() async {
    final base =
        await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> outputDirPath() async => (await outputDir()).path;

  /// 导出整篇文本为一个 WAV。长文本分块合成后拼接为单文件。
  /// [onProgress] 回调 0~1 进度。[stableName]=true 时用固定文件名(自动导出覆盖,
  /// 避免堆积);false 时带时间戳(手动导出,保留多版本)。成功返回路径,失败抛异常。
  Future<String> exportDocument(
    TtsService tts,
    String text, {
    String? baseName,
    bool stableName = false,
    void Function(double progress)? onProgress,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) throw Exception('没有可朗读的内容');

    final dir = await outputDir();
    final name =
        (baseName != null && baseName.trim().isNotEmpty) ? _sanitize(baseName) : '朗读';
    final outPath = stableName
        ? '${dir.path}/$name.wav'
        : '${dir.path}/${name}_${_timestamp()}.wav';

    final chunks = _chunkText(clean, _maxChunk);
    if (chunks.length == 1) {
      onProgress?.call(0.2);
      final ok = await tts.synthToFile(chunks.first, outPath);
      if (!ok) throw Exception('合成失败,当前 TTS 引擎可能不支持离线合成到文件');
      onProgress?.call(1.0);
      return outPath;
    }

    // 多块:逐块合成到临时文件,再拼接 PCM
    final tempPaths = <String>[];
    try {
      for (var i = 0; i < chunks.length; i++) {
        final tmp = '${dir.path}/.tmp_chunk_$i.wav';
        final ok = await tts.synthToFile(chunks[i], tmp);
        if (!ok) throw Exception('第 ${i + 1} 段合成失败');
        tempPaths.add(tmp);
        onProgress?.call(0.1 + 0.8 * (i + 1) / chunks.length);
      }
      final ok = await _concatWav(tempPaths, outPath);
      if (!ok) throw Exception('音频拼接失败');
      onProgress?.call(1.0);
      return outPath;
    } finally {
      for (final p in tempPaths) {
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
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
      // 兜底:单句过长时硬切
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

  // ---------------- WAV 拼接(解析 data 区,合并为单 WAV) ----------------

  Future<bool> _concatWav(List<String> paths, String outPath) async {
    if (paths.isEmpty) return false;
    int? sampleRate;
    int? channels;
    int? bitsPerSample;
    final data = BytesBuilder();

    for (final p in paths) {
      final bytes = await File(p).readAsBytes();
      final info = _parseWav(bytes);
      if (info == null) return false;
      sampleRate ??= info.sampleRate;
      channels ??= info.channels;
      bitsPerSample ??= info.bitsPerSample;
      // 各块参数必须一致才能直接拼接 PCM
      if (info.sampleRate != sampleRate ||
          info.channels != channels ||
          info.bitsPerSample != bitsPerSample) {
        return false;
      }
      data.add(info.data);
    }

    final out = File(outPath);
    final sink = out.openWrite();
    try {
      final dataBytes = data.toBytes();
      final sr = sampleRate!, ch = channels!, bps = bitsPerSample!;
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
      return dataSize > 0;
    } catch (_) {
      return false;
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
      // WAV 块按字(2字节)对齐,奇数长度后有 1 字节填充
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
