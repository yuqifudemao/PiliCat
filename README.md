<div align="center">
  <img src="assets/images/logo/logo.png" width="96" height="96" alt="PiliNara 图标" />
  <h1>PiliCat</h1>
  <p>鱼欺负的猫的 B 站客户端</p>
  <p>基于 PiliNara 的第三方哔哩哔哩 Android 客户端，支持保存多套 AI 接口配置，并在视频详情页直接切换模型。</p>
  <p><a href="https://github.com/yuqifudemao/PiliNara/releases/latest"><strong>下载最新版 APK</strong></a> · <a href="https://github.com/yuqifudemao/PiliNara/releases">全部版本</a> · <a href="https://github.com/Starfallan/PiliNara">上游项目</a></p>
</div>

PiliCat 由「PiliNara 个人版」更名而来。

## 下载与安装

1. 打开 [Releases](https://github.com/yuqifudemao/PiliNara/releases/latest)，在 **Assets** 中下载文件名以 `arm64-v8a.apk` 结尾的安装包。个人版后续仅发布 Android `arm64-v8a` 安装包。
2. 安装后，桌面显示为「PiliCat」。个人版使用独立包名，可与原版 PiliNara 同时安装，两边的登录状态和设置各自保存。

**升级个人版**

- **已安装 `v2.2.0-personal.3` 或更新版本**：个人版从该版本起使用固定签名，可直接覆盖安装更新版本。
- **从 `personal.1` 或 `personal.2` 升级**：先在旧个人版的「关于 → 导入/导出所有数据」中导出备份。确认备份文件已保存后，卸载旧的个人版，再安装最新版并导入备份。

## AI 视频助手

1. 打开「AI 视频总结设置」，启用 AI 视频助手。点「新增」，为每套配置填写名称、OpenAI 兼容接口地址、API Key 和模型，可按需设置思考强度。
2. 打开视频详情页的「AI 视频助手」，点「分析」上方的模型名称，选择已保存的 API 配置。可从模型列表选择，也可手动输入模型名。
3. 切换后，当前视频的后续分析和追问会使用所选模型。其他视频仍从全局默认配置开始。

个人版也继承了上游的双语字幕、应用内小窗、弹幕过滤和离线缓存等功能。完整功能清单与其他平台的安装说明见 [PiliNara 上游文档](https://github.com/Starfallan/PiliNara#readme)。

## 番剧漫游

在「设置 → 其它设置 → 番剧漫游」填入自有或可信的 HTTPS 解析地址。可以填服务根地址，也可以填完整的 Web 播放接口。服务如果要求地区参数，可随地址填写，例如 `https://example.com?area=hk`。留空保存即可关闭。

PiliCat 优先使用 B 站接口。遇到部分详情加载错误、空集数或播放地区限制时，会通过该服务重试。解析请求会发送番剧集号等参数，应用不会附带 B 站登录 Cookie 或 Token。要支持详情重试和播放，服务需要提供 `/pgc/view/web/season` 及兼容的 Web 播放接口。

<details>
<summary>查看上游界面截图</summary>

<img src="assets/screenshots/510shots_so.png" width="32%" alt="PiliNara 界面截图一" />
<img src="assets/screenshots/174shots_so.png" width="32%" alt="PiliNara 界面截图二" />
<img src="assets/screenshots/850shots_so.png" width="32%" alt="PiliNara 界面截图三" />

</details>

## 开源与致谢

本项目供个人学习和测试使用，按 [GPL-3.0](LICENSE) 开源。感谢 [PiliNara](https://github.com/Starfallan/PiliNara)、[PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)、[PiliPalaX](https://github.com/orz12/PiliPalaX)、[PiliPala](https://github.com/guozhigq/pilipala) 及[上游文档列出的开源项目和贡献者](https://github.com/Starfallan/PiliNara#致谢)。
