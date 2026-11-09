# 合成文档批注样例

此目录中以 `pdf_` 开头的文档由本项目测试脚本创作，**不是 WPS（金山办公软件）的真实导出文件**。用于原生解析回归测试，与另行开展的真实办公软件测试分开记录。

## 样例

| 文件 | 内容与预期 |
| --- | --- |
| `pdf_annotations_synthetic.pdf` | 两页中文正文；第二个同名词批注；高亮、下划线、波浪线、删除线；不连续选区；跨行选区；字符实体与表情；父子回复；旋转页面；无选区便笺、自由文本、箭头、损坏选区和空白区域标记。共 15 条非空备注，10 条可定位，5 条待定位。 |
| `pdf_plain_synthetic.pdf` | 无批注的中文正文。 |
| `pdf_rich_comment_synthetic.pdf` | 只有 RC（富文本批注字段）、没有纯文本批注字段的高亮备注；保留两个段落及一处手动换行，精确对应“节奏”。 |
| `pdf_scanned_synthetic.pdf` | 仅含文字栅格图，没有正文文字层，但有一条原生便笺。导入应明确报错，不生成空稿。 |
| `pdf_mixed_scanned_synthetic.pdf` | 第一页有正文，第二页只有扫描图和便笺。正文正常导入，扫描页备注保留为待定位。 |
| `pdf_empty_synthetic.pdf` | 空白页，导入应明确报错。 |
| `pdf_encrypted_synthetic.pdf` | 需要用户密码的合成文档。测试密码为 `fixture-test-only`（仅供样例测试）；当前导入入口应提示加密。 |
| `pdf_restricted_synthetic.pdf` | 无打开密码，但权限禁止复制与提取；导入应说明权限限制。 |
| `pdf_invalid_synthetic.pdf` | 故意伪装为文档后缀的普通文字，用于损坏文件错误及队列恢复测试。 |

## 重建

使用 PyMuPDF（文档处理开发工具）1.26.6 运行：

```bash
python test/fixtures/annotations/pdf_generate_fixtures.py
python test/fixtures/annotations/pdf_generate_rich_comment_fixture.py
```

生成器需要 DejaVu Sans（开源字体），默认路径为 `/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf`。其他系统通过 `PDF_FIXTURE_EMOJI_FONT`（样例表情字体路径环境变量）指定包含 U+1F600（微笑表情字符）的字体。

生成器为表情字体写入标准 UTF-16BE（大端序十六位字符编码）映射，避免开发工具对补充字符生成的错误映射使测试变成普通文字测试。表情样例包含实际可提取的双编码单元。

PyMuPDF（文档处理开发工具）只用于生成测试数据，不作为应用依赖或随应用分发。样例内的 DejaVu Sans（开源字体）为子集嵌入，许可见 https://dejavu-fonts.github.io/License.html 。DejaVu（字体项目）的修改部分属于公有领域；原 Bitstream Vera（字体）的版权和许可须保留。应用运行时不需要此测试字体。

## 原生验证

```bash
flutter test test/pdf_annotation_importer_test.dart
flutter test test/pdf_annotation_rich_text_test.dart
```

此测试调用应用打包的真实 PDFium（文档解析引擎），不伪造解析器、不在动态库缺失时跳过。首次构建需由原生资源构建脚本下载对应平台解析库。测试同时检查 `AnnotationAnchors.bodyText`（应用正文偏移计算器）中的最终范围，覆盖编码、段落和实体之间的偏移一致性。
