# 文档批注导入依赖与版权说明

## 运行时组件

导入功能使用以下免费开源组件，不使用付费文档软件开发包：

- `pdfium_flutter`（原生部署与接口包）0.2.1。
- `pdfium_dart`（底层接口绑定）0.2.1。
- PDFium（文档解析引擎），由上述版本的构建脚本固定下载 `chromium/7811`（引擎修订版本）。

发布包源码来源：

- https://pub.dev/api/archives/pdfium_flutter-0.2.1.tar.gz
- https://pub.dev/api/archives/pdfium_dart-0.2.1.tar.gz
- https://github.com/espresso3389/pdfrx
- https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F7811

发布包已检查要求 Dart（编程语言）3.10 及 Flutter（界面框架）3.41；与本项目 Dart（编程语言）3.12.1、Flutter（界面框架）3.44.1 兼容。安装包需包含构建产物中的解析动态库。

## 分发要求

两个接口包采用 MIT（宽松开源许可证）。PDFium（文档解析引擎）采用允许源码及二进制分发的开源许可，并包含多个第三方组件。构建钩子只从下载归档提取动态库；**发布流程还必须保留该引擎归档的完整版权声明、许可文本及第三方声明**，不能把下面的主许可证当成全部第三方许可的替代品。

固定版本归档中的完整声明已放入 `tool/windows/vendor/pdfium/`（安装包版权资源目录）：包括根许可证、版本文件、全部 15 个引擎及第三方声明文件、两个接口包许可证原文，以及来源和文件摘要。发布脚本须递归复制此目录；准确来源与核验信息见该目录内 `SOURCES.md`（来源说明）。

引擎及二进制项目的官方许可入口：

- https://pdfium.googlesource.com/pdfium/+/chromium/7811/LICENSE
- https://pdfium.googlesource.com/pdfium/+/chromium/7811/third_party/
- https://github.com/bblanchon/pdfium-binaries

本文件供发布流程并入安装包的第三方声明。测试样例生成工具不属于运行时依赖；其用途及字体来源单独记录在 `test/fixtures/annotations/pdf_README.md`（样例说明）。

## 接口包许可证原文

```text
The MIT License (MIT)
===============

Copyright (c) 2025 @espresso3389 (Takashi Kawasaki)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## 引擎主许可证原文

```text
Copyright 2014 The PDFium Authors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above
  copyright notice, this list of conditions and the following disclaimer
  in the documentation and/or other materials provided with the
  distribution.
* Neither the name of Google Inc. nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## 导入行为说明

文字标记的四边形仅用于导入匹配，最终批注保存为正文半开字符区间。未选中文字的便笺、自由文本、箭头及无法匹配的选区保留为待定位备注。批注内容与正文分开存储。无正文文字层的整份文档、需要密码的文档、禁止文字提取的文档会返回中文说明，不生成空稿或绕过限制。

原生解析串行执行，所有句柄和缓冲区在后台任务内释放。后续若增加其他使用同一引擎的阅读器，须协调全进程引擎生命周期与调用顺序。
