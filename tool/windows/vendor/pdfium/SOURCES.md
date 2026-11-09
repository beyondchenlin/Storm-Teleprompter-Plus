# 文档解析组件的分发声明来源

本目录用于随应用安装包分发许可声明。原始许可证文件保持下载归档中的完整字节内容；不得只保留引擎主许可证而删除第三方声明。

## 固定运行时版本

- PDFium（文档解析引擎）：`chromium/7811`，归档版本文件为 `149.0.7811.0`。
- 平台：Windows x64（微软桌面操作系统 64 位）。
- 原始二进制发布项目：<https://github.com/bblanchon/pdfium-binaries>。
- 版本页面：<https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F7811>。
- 本目录实际使用的发布归档：<https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7811/pdfium-win-x64.tgz>。
- 归档大小：3,718,879 字节。
- 归档 SHA-256（文件摘要）：`2e7af12674ac3716cb0e20369bb9fb269ceadfa2f0b0597097a520e6834175a0`。
- 归档中的 `bin/pdfium.dll`（原生动态库）大小：7,176,704 字节。
- 该动态库 SHA-256（文件摘要）：`019b6ee6e54e5508002e43c5199b00f6caca26d32dd23c7bb229ff6855cd5394`。

以下 17 个文件直接从此归档提取：根目录 `LICENSE`（构建与分发项目许可证）、`VERSION`（引擎版本）以及 `licenses/`（引擎及第三方许可证）下全部 15 个文件。`licenses/pdfium.txt` 保留归档中的完整组合文本，并非仅摘录主许可证。

第三方声明包括：Abseil（基础工具库）、AGG（图形渲染库）、fast_float（浮点数解析库）、FreeType（字体引擎）、ICU（国际化库）、Little CMS（色彩管理库）、libjpeg-turbo（图像编解码库）的两份许可、OpenJPEG（图像编解码库）、libpng（图像编解码库）、LibTIFF（图像编解码库）、LLVM libc（基础运行库）、PDFium（文档解析引擎）、simdutf（字符编码库）和 zlib（压缩库）。

## 接口包许可

`bindings/`（接口包许可证目录）包含两个固定版本发布包中的完整 `LICENSE`（许可证）文件：

| 接口包 | 原始发布归档 | 归档 SHA-256（文件摘要） |
| --- | --- | --- |
| `pdfium_dart`（底层接口绑定）0.2.1 | <https://pub.dev/api/archives/pdfium_dart-0.2.1.tar.gz> | `a339ed67ff9bcca950481fceeeee68ffd602d2147e01d833e4254d84132a6bda` |
| `pdfium_flutter`（原生部署与接口包）0.2.1 | <https://pub.dev/api/archives/pdfium_flutter-0.2.1.tar.gz> | `97ccb5cf207b66ba5549f09047e935376d967c6311ec3c5314405d1d04569fd2` |

两个接口包发布归档中的许可证文本完全一致，均分别保留。项目源码来源为 <https://github.com/espresso3389/pdfrx>。

## 发布与核验

1. 将本目录连同全部子目录复制到安装包的第三方声明目录，保留相对结构。
2. 运行时动态库由固定版本接口包的构建钩子下载和部署，本目录不重复存放动态库。
3. `SHA256SUMS`（原始声明文件摘要清单）记录从三个归档提取的全部 19 个原始文件，可用于核对版权文本是否完整。
4. 升级接口包或引擎修订版本时，重新从实际部署的发布归档提取全部声明，并更新来源与摘要；不能继续沿用旧版文件。

以上来源于固定版本发布归档的实际内容，不以当前开发分支的许可证文件替代所部署版本。
