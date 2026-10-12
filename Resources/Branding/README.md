# Zilo 蓝色缎带 Z

2026-10-11 用户选定第 1 款，并明确要求作为新的 Zilo logo。

- `zilo-icon-master.png`：无字、全出血方形母版，使用内置 imagegen 从选定样图提取，保留白色连续缎带 Z、浅蓝折叠面和钴蓝背景。
- `zilo-logo-approved-preview.png`：用户选定的预览设计。
- `zilo-icon-web.png`：512 像素透明圆角图标，用于网站。
- `zilo-icon-mac.png`：1024 像素 Mac 图标画布，保留标准外边距。
- `../AppIcon-zhixing.icns`、`../AppIcon.icns`：Mac 多尺寸图标及兼容文件名。
- `../../Mobile/Assets.xcassets/`：iPhone 图标及应用内品牌图片，1024 像素不透明 RGB；系统负责应用图标圆角。

通过 `python3 scripts/export-brand-icons.py` 从母版统一导出。仅做尺寸、平台圆角及透明边距适配，不重新绘制已选定的标志。

生成母版使用的最终提示词：

> Use case: logo-brand. Asset type: final full-bleed square iOS app icon master. Extract ONLY the large selected blue ribbon Z icon in the input image and make it the entire output square. Preserve the white continuous folded rounded Z ribbon, pale blue fold shading, identical silhouette, exact proportions and cobalt blue background gradient. The final blue tile fills the entire canvas EDGE TO EDGE, all four corners BLUE and square (Apple applies rounded corners automatically), no white surround, no margins outside the tile, no wordmark, no text, no smaller examples, no shadow. Keep generous original blue margin between Z and the canvas boundary. Do not redesign the mark. Crisp production quality clean logo, square composition.
