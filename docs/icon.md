# LocationBridge 图标

正式图标为蓝青渐变底上的磨砂白色定位针，定位针内部使用单拱桥和短桥面构成负形。图标不含文字或地点信息。

## 资源与来源

- `Resources/AppIcon.png`：正式 1024×1024 PNG 母版，无 alpha。
- `Resources/AppIcon.icns`：macOS 图标包，包含 16、32、128、256、512 点各自的 1×/2× 表示，最大 1024 像素。
- `scripts/build-icon.sh`：使用 macOS 自带的 `sips` 和 `iconutil` 从 PNG 重建图标包，并回解核对全部十种表示。
- 生成时间：2026-11-06。
- 生成来源：OpenAI 内置 `image_gen`，按本项目的独立提示词生成，没有输入参考图。没有复用第三方图标素材；WLoc 的源码许可证与本图的生成来源分别记录。
- 生成工具实际返回 1254×1254 PNG；原始结果保留在本机 Codex 生成目录。项目副本仅经 `sips` 等比例下采样为 1024×1024，再生成各尺寸并打包，没有另外重绘图像。

正式 PNG SHA-256：`b5743e7bb4e2670da74f4c16c34d984879b266462201bc14c71a17a4c246c3e9`。

## 重建与核对

在仓库根目录运行：

```sh
./scripts/build-icon.sh
```

脚本先要求母版恰为 1024×1024，生成完整 iconset，调用 `iconutil` 打包，再解回 iconset 核对每个文件及实际像素尺寸。母版 PNG 保持不变。

本轮已实际检查 16、32、64 像素预览：定位针的主轮廓及内部桥洞可辨，16 像素时细微材质自然弱化。十种图标表示均通过回解尺寸核验。App 资源接线和安装后的 Dock/Finder 显示属于后续制品验收。

## 完整生成提示词

生成时设置 `transparent_background=false`，使用内置工具，没有使用 CLI/API 后备方式。

```text
Use case: logo-brand.
Asset type: the final production macOS application icon for LocationBridge, one single 1024 by 1024 square raster image.
Create a polished, original, immediately recognizable icon: one bold centered location-pin emblem that subtly incorporates a single bridge arch as its interior negative space, with a simple short bridge deck. A unified geometric mark, generous breathing room, very strong silhouette that remains clear at 16 and 32 pixels. Blue, teal and white palette. Smooth edge-to-edge deep blue to luminous teal background, a softly frosted white glass emblem with very restrained depth, gentle top-left light and a tiny grounded shadow. Sophisticated native macOS visual quality, restrained material, crisp edges and large simple forms; avoid decorative detail and avoid excess gloss. Square full-bleed artwork ready to package into an app icon, with the graphic itself as the entire deliverable, not an app screenshot or a product mockup.
No text, letters, digits, flags, map, road grid, address, coordinates, watermarks, badges, logo imitations, surrounding mockup frame, or additional objects.
```
