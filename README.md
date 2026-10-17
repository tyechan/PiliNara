<div align="center">
    <img width="200" height="200" src="assets/images/logo/logo.png">
    <h1>PiliPala</h1>
    <p>Starfallan/PiliNara 的个人分支，仅供自用测试</p>
</div>

本仓库是 [Starfallan/PiliNara](https://github.com/Starfallan/PiliNara) 的个人 fork，上游再往上是 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)。在官方功能之外，只额外保留点播多连接加速。

> 桌面显示名是 **PiliPala**，仓库仍叫 `tyechan/PiliNara`，Dart 包名仍是 `PiliPlus`（与上游一致，避免大范围改 import）。

## 和官方有什么不同

| 项目 | 本分支 | 官方 PiliNara |
| --- | --- | --- |
| 应用名 | `PiliPala`（debug 为 `PiliPala debug`） | `PiliNara` |
| 包名 `applicationId` | `com.tychen.pilipala` | `com.example.pilinara` |
| 应用内检查更新 | [tyechan/PiliNara Releases](https://github.com/tyechan/PiliNara/releases) | Starfallan 官方 Releases |
| 版本号 | `2.1.6-MMDDa` + `versionCode=YYYYMMDDNN`（关于页一行显示） | `2.1.6-<commit>` + `git rev-list` |
| 点播加速 | 设置里有「多线程加速（实验）」 | 无 |

**多线程加速（实验）**：应用内 `127.0.0.1` VOD 代理按 Range 并行拉流，可调连接数，带 host 池、节点耗时日志；探测失败或播放器打不开代理时回退直连。默认关闭，按需在播放设置里打开。

**不会覆盖官方 App。** 包名不同，会作为另一个应用安装。登录态、设置、缓存也不会自动迁移。

## 安装

1. 打开 [Releases](https://github.com/tyechan/PiliNara/releases)，下载 `PiliPala-*-arm64-v8a.apk`（目前只打 arm64）。
2. 允许未知来源后安装。
3. 若手机上已有官方 PiliNara 或本分支早期 debug 包（`com.example.pilinara.debug`），可以同时保留；本包不会覆盖它们。
4. 首次安装需重新登录。如需沿用旧设置，请在旧 App「关于」里导出，再在本 App 导入。

## 版本与更新

- `versionName`：`2.1.6-MMDDa`（例如 `2.1.6-1016c`，不超过 16 字符）
- 关于页一行：`2.1.6 · 1016 · <短哈希>`
- `versionCode`：`YYYYMMDD` + 当日序号，例如 `2026101603`
- Git 标签：`v2.1.6-1016c+<短哈希>`
- 应用内检查更新只看本仓库 Release，用 `versionCode` 比较，不再用官方构建时间。

## 如何同步上游

官方发行版来自 **Starfallan/PiliNara**（例如 `2.1.6 [Arcane]` / `2b33fc0f7`）。PiliPlus 的改动通常已由官方合入。

同步步骤（人工，不自动合）：

```bash
git remote add nara https://github.com/Starfallan/PiliNara.git   # 只需一次
git fetch nara
git merge nara/main   # 或指定 tag / commit
```

冲突时优先保留：

- `lib/plugin/vod_proxy/` 以及播放器里的代理包装
- 「多线程加速（实验）」设置项
- 小窗 `PipPlayPauseButton`（避免 Obx 读非 Rx 状态变成灰块）
- 本仓库的更新源、包名、应用名

合完后跑：

```bash
flutter test test/plugin/pl_player/player_controls_widget_test.dart \
  test/plugin/vod_proxy test/utils/update_version_test.dart
```

## 构建

```bash
bash lib/scripts/build_fork.sh
flutter build apk --release --split-per-abi --dart-define-from-file=pili_release.json
```

Release 签名需要 `android/key.properties` 指向专用 keystore。CI 从 GitHub Secrets 写入：

- `SIGN_KEYSTORE_BASE64`
- `KEYSTORE_PASSWORD`
- `KEY_ALIAS`
- `KEY_PASSWORD`

打 `v*-btr-proxy*` 标签会触发 Android Release 工作流。不要用上游的 `lib/scripts/build.ps1`（它会把 `versionCode` 改成 commit 计数）。

## 致谢与许可

- [Starfallan/PiliNara](https://github.com/Starfallan/PiliNara)
- [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)
- 以及 PiliPlus / PiliPala 一线更早的贡献者

本仓库与上游一样采用 [GPL-3.0](LICENSE)。仅供个人学习测试，请遵守 B 站用户协议与当地法律。
