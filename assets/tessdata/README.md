# Tesseract 训练数据目录

离线文字识别(Tesseract)所需的训练数据放这里:

- `chi_sim.traineddata`(简体中文)
- `eng.traineddata`(英文)

**这些文件不入库**(每个约 2~15MB)。GitHub Actions 在打包前会自动从
`tessdata_fast` 下载到本目录,再随 APK 打入(见
`.github/workflows/build-apk.yml` 的「下载 Tesseract 训练数据」步骤)。

本地若要调试离线识别,可手动把上述两个文件放进本目录。
数据来源:https://github.com/tesseract-ocr/tessdata_fast
