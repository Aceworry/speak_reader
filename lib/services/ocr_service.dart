import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// 图片文字识别(OCR)服务。
///
/// 使用 Google ML Kit 离线识别,默认中文脚本(同时能识别其中的英文/数字)。
/// 首次使用时 ML Kit 会自动下载对应语言模型(需一次联网)。
///
/// 注意:超大图片可能导致原生层内存溢出而崩溃,取图时应限制尺寸
/// (见 home_page 里 image_picker 的 maxWidth/maxHeight)。
class OcrService {
  TextRecognizer? _recognizer;

  TextRecognizer get _instance {
    return _recognizer ??=
        TextRecognizer(script: TextRecognitionScript.chinese);
  }

  /// 识别指定图片文件,返回纯文本。出错时抛出带中文说明的异常(避免闪退)。
  Future<String> recognizeFile(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw Exception('图片文件不存在');
    }
    final len = await file.length();
    if (len == 0) {
      throw Exception('图片文件为空');
    }

    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText result = await _instance.processImage(inputImage);

      if (result.text.trim().isEmpty) {
        return '';
      }
      final buffer = StringBuffer();
      for (final block in result.blocks) {
        final t = block.text.trim();
        if (t.isNotEmpty) buffer.writeln(t);
      }
      return buffer.toString().trim();
    } catch (e) {
      // 捕获识别器异常,转为可读提示(原生崩溃无法在此捕获)
      throw Exception('文字识别出错:$e');
    }
  }

  Future<void> dispose() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}
