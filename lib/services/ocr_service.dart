import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// 图片文字识别(OCR)服务。
///
/// 使用 Google ML Kit 离线识别,默认中文脚本(同时能识别其中的英文/数字)。
/// 首次使用时 ML Kit 会自动下载对应语言模型(需一次联网)。
class OcrService {
  // 中文识别器(内部含拉丁字符,能同时识别中英文混排)
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.chinese);

  /// 识别指定图片文件,返回纯文本(段落间用换行)。
  Future<String> recognizeFile(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw Exception('图片文件不存在');
    }
    final inputImage = InputImage.fromFilePath(imagePath);
    final RecognizedText result = await _recognizer.processImage(inputImage);

    if (result.text.trim().isEmpty) {
      return '';
    }

    // 按识别到的文本块拼接,块内保留原换行,块间加空行
    final buffer = StringBuffer();
    for (final block in result.blocks) {
      buffer.writeln(block.text.trim());
    }
    return buffer.toString().trim();
  }

  Future<void> dispose() async {
    await _recognizer.close();
  }
}
