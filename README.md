# Watermark - 批量图片/PDF 水印工具

一款 macOS 命令行水印工具，支持对 PNG、JPG、HEIC 和 PDF 文件进行批量水印处理。用户通过系统原生对话框输入水印文字，在终端中选择字体和颜色，然后拖入文件或文件夹即可自动完成批量处理。

## 功能特性

- **批量处理** — 支持单个文件或整个文件夹拖入，自动递归遍历子目录
- **多格式支持** — 支持 PNG、JPG、JPEG、HEIC、PDF 格式
- **多行水印** — 使用 `|` 分隔符实现多行文字水印
- **字体选择** — 内置 10 种中文字体（苹方、黑体、楷体、宋体、仿宋、圆体等）
- **颜色选择** — 内置颜色方案，易于扩展
- **智能渲染策略**：
  - 透明图片（PNG）使用 SourceOver 混合模式，保留透明度
  - 不透明图片（JPG）使用 Multiply 混合模式，叠加用户所选颜色与透明度强度，水印清晰可见且画面干净
  - PDF 使用 CoreText 精确绘制，支持旋转页面的自适应对齐
- **EXIF 方向修正** — 自动应用 EXIF Orientation，竖拍照片不会躺倒，水印位置始终正确
- **镜像目录结构** — 拖入文件夹时，输出在 `watermarked/` 下保持与源目录相同的子目录结构；输出文件名中的空格自动替换为下划线（如 `my photo.jpg` → `my_photo.jpg`，目录名中的空格保留）；同目录内重名（如 `photo.heic` 与 `photo.png`）自动编号，绝不静默覆盖
- **图片元数据保留** — 输出保留 EXIF/GPS/IPTC 等元数据与色彩空间（广色域照片不偏色）
- **HEIC 自动转换** — HEIC 格式自动转为 PNG 输出，保证兼容性
- **PDF 元数据保留** — 处理时保留原始文档的标题、作者、主题、创建者、关键词等元信息
- **进度反馈** — 实时显示处理进度和渲染策略
- **优雅退出** — 支持 Ctrl+C 中断并自动清理临时文件

## 环境要求

- Apple Silicon macOS 11.0 (Big Sur) 或更高版本
- Swift 5.0+
- 需要终端 App 拥有 **辅助功能** 权限（用于系统输入对话框）

## 安装

```bash
brew install --formula watermark
```
## 使用方法

### 快速开始

1. 运行程序：

```bash
./watermark
```

2. 在弹出的系统对话框中输入水印文字，多行文本用 `|` 分隔（例如：`版权所有|请勿转载`）

3. 在终端中选择水印颜色

4. 在终端中选择水印字体

5. 确认信息后，将文件或文件夹拖入终端窗口，按回车开始处理

6. 处理完成后，在原始文件所在目录会生成 `watermarked/` 子文件夹，内含所有已添加水印的文件。拖入文件夹时，`watermarked/` 内部会镜像源目录的子目录结构

### 操作示例

```
💡 Tip: If the dialog doesn't appear, please grant 'Accessibility' permission to your Terminal in System Settings > Privacy & Security.

⏳ Invoking system input dialog...
🔔 Please select watermark font (Press Enter for default):
 1. System Default (PingFangSC-Bold) (Default)
 2. KaiTi
 3. PingFangSC-Regular
 ...

🎨 Please select watermark color (Press Enter for default):
 1. Neutral Gray (Default)
 2. Yellow

📝 Watermark text confirmation:
 | 版权所有
 | 请勿转载
🎨 Watermark color: Neutral Gray
🔔 Watermark font: System Default (PingFangSC-Bold)

Please drag and drop the files or folders to be processed here
/Users/me/Photos /Users/me/document.pdf

🔍 Found 12 files.
🚀 Starting batch processing...

[1/2] ✔︎ [PDF] document.pdf -> watermarked/document.pdf (5 pages)
[1/10] ✔︎ [Image] photo1.png -> watermarked/photo1.png (Alpha+SourceOver)
[2/10] ✔︎ [Image] photo2.jpg -> watermarked/photo2.jpg (Opaque+Multiply)
...

✔︎ All 12 files processed successfully!
```

### 注意事项

- **辅助功能权限**：首次使用时，如果系统对话框无法弹出，请前往 **系统设置 > 隐私与安全性 > 辅助功能** 中为你的终端 App 授权
- 水印文字中的 `|` 会被识别为换行符，如果水印本身需要 `|` 字符，需修改代码中的分隔逻辑
- HEIC 文件会自动转换为 PNG 格式输出
- 拖入文件夹时，输出会镜像源目录的子目录结构（如 `Photos/sub/a.jpg` → `watermarked/sub/a.jpg`）；输出文件名中的空格会被替换为下划线，连续空格合并为一个（`my  photo.jpg` → `my_photo.jpg`，目录名中的空格不受影响）；若同目录下出现重名输出（如 `photo.heic` 与 `photo.png`），后者会自动编号为 `photo_2.png`，不会静默覆盖

### 核心设计

- **零外部依赖** — 仅使用 Apple 内置框架（AppKit、PDFKit、CoreText、CoreGraphics、ImageIO）
- **配置与 UI 分离** — `WatermarkStyleSettings` 统一管理样式参数，`TerminalUI` 只负责交互
- **角度自适应** — 水印以 45 度对角线绘制于画面中央，PDF 页面旋转自动适配
- **动态字体缩放** — 根据图片/页面尺寸动态计算最优字号
- **方向自适应** — 自动修正 EXIF Orientation，竖拍照片输出方向正确

## 开源协议

本项目基于 MIT 协议开源。
