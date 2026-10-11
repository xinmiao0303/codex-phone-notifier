# 来源与致谢

这个项目的使用场景受到 [isclin123/codex-watch-notifier](https://github.com/isclin123/codex-watch-notifier) 启发。感谢该项目提供 Codex 完成通知的思路。

本仓库是面向 Windows、以中文手机通知为默认行为的独立实现，没有复制该仓库的脚本或 macOS 功能。安装、发送、卸载、配置处理及自动测试均为本仓库重新编写；本仓库代码使用 MIT 许可证。

本项目通过 Codex 官方 hooks 和 ntfy 官方 JSON 发布接口工作，与 OpenAI 或 ntfy 没有官方隶属关系。上游项目和依赖服务各自的权利与条款不受本仓库许可证影响。

## 软件图标

图标采用透明背景，以 OpenAI / ChatGPT 结形标志为主体，右下角为金色铃铛，没有蓝色底板。已生成 16、24、32、48、64、128、256 像素的 Windows 图标。窗口标题栏使用深色主体，任务栏及 Alt+Tab 使用主体稍大的浅色版本，两者均为透明背景。

结形 SVG 来自 [Lobe Icons 官方仓库](https://github.com/lobehub/lobe-icons/blob/master/packages/static-svg/icons/openai.svg)。图标库使用 MIT 许可，全文保存在 [desktop/assets/LOBE-ICONS-LICENSE.txt](desktop/assets/LOBE-ICONS-LICENSE.txt)。OpenAI / ChatGPT 标志和商标属于 OpenAI；开源许可不授予商标权，不表示本项目获得官方认可。品牌使用说明见 [OpenAI 官方页面](https://openai.com/brand/)。

铃铛轮廓采用 [Lucide 的 bell-ring 图标](https://lucide.dev/icons/bell-ring)，原始 SVG 来自 [Lucide 官方仓库](https://github.com/lucide-icons/lucide/blob/main/icons/bell-ring.svg)。本项目去掉两侧振铃线，并加入金色填色和轮廓。bell-ring 使用 ISC 许可，全文保存在 [desktop/assets/LUCIDE-LICENSE.txt](desktop/assets/LUCIDE-LICENSE.txt)。

以上许可和 [图标来源说明](desktop/assets/ICON-NOTICE.txt) 随软件内嵌。可在“安装与帮助 → 查看图标许可”打开来源说明，再在同一目录查看两个许可文件。软件自身的 MIT 许可不替代上游许可。
