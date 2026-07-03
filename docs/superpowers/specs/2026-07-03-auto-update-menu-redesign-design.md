# CC HUD 自动更新 + 菜单重组 设计

日期:2026-07-03
状态:已与作者确认

## 背景与目标

CC HUD 目前的升级方式是用户手动去 GitHub Releases 下载 dmg、右键打开、拖拽覆盖安装。目标是提供 clash-verge-rev 式的应用内更新体验:发现新版 → 菜单提示 → 查看更新日志 → 一键下载安装并重启。约束:无自建服务器,更新包托管在 GitHub Releases;持续使用免费 Apple Development 证书签名(无公证)。

同时,菜单栏菜单已增长到顶层 13 项(含 3 行灰色信息),本次一并重组,原则是**正常时零噪音、异常时显眼可点**。

## 关键决策记录

1. **自研轻量更新器,不用 Sparkle。**
   Sparkle 需要:构建脚本嵌入 framework 并逐层签名、生成并长期保管 EdDSA 私钥(丢失则老用户永远收不到更新)、每次发版跑 generate_appcast 并把 appcast.xml 推到固定 URL。这些是每次发版的流程税 + 两个长期维护物;而其增益(EdDSA 端到端校验、增量更新)对 2.8MB 的包和单人项目边际价值低。自研方案发布侧零改动,防篡改由 codesign 身份校验承担(见下)。
2. **提示式更新,不做全自动静默。**
   CC HUD 是常驻监控工具,静默重启会闪断 HUD。自动检查、手动确认。
3. **更新源直接用 GitHub API**(`GET /repos/shiyaming1994/cc-hud/releases/latest`),tag、changelog(release body)、dmg 直链都是现成的,无需任何额外托管物。
4. **签名前提已实测核实**:GitHub Releases 上的包与本机安装的包为同一张 Apple Development 证书(Team `Y42ZECHCL6`)签名,更新替换后签名身份不变,TCC(辅助功能/自动化)授权不会失效。

## 更新机制

### 用户体验

- 启动后约 10 秒静默检查一次;之后每 24 小时一次;菜单「检查更新…」可随时手动查。
- 发现新版:菜单状态行下方出现高亮项「⬆ 有新版本 v1.3.0,点击更新」。
- 点击后弹窗:标题为新版本号,正文为 release body 的中文更新日志(`AttributedString(markdown:)` 简单渲染,失败退回纯文本),按钮 [立即更新] [稍后]。
- 立即更新:菜单项变「正在下载更新… 45%」→ 下载完自动校验、替换、重启。
- 手动检查已是最新:弹「已是最新版本(v1.2.1)」;自动检查失败(断网等)完全静默。

### 组件划分

| 组件 | 位置 | 职责 |
|---|---|---|
| `UpdateChecker` | CCHudCore(可单测) | 查 GitHub API,解析 tag_name / body / CC-HUD.dmg 资产直链与大小;语义化版本比较。网络层可注入,测试用 fixture JSON |
| `UpdateInstaller` | CCHudCore(副作用层,不依赖 AppKit,替换序列可单测) | 下载 dmg(进度回调)→ hdiutil 挂载 → 签名校验 → 原子替换 → 重启。目标目录可注入,rename 序列在临时目录中测试 |
| `UpdateController` | CCHud(状态机+调度+UI) | `idle → checking → updateAvailable → downloading(进度) → installing / failed / upToDate`,驱动菜单显示与弹窗;定时调度 |

### 版本比较规则

- release tag 形如 `vX.Y.Z`,去掉前缀 `v` 后按 major.minor.patch **数值**比较(`1.10.0 > 1.9.9`),与 `AppInfo.version` 对比,严格大于才算有新版。
- tag 解析失败(不符合 X.Y.Z)按无更新处理并记 DebugLog,不弹错。
- prerelease/draft 不会出现在 `releases/latest` 响应中,天然过滤。

### 下载、校验与安装

1. URLSession 下载 dmg 到临时目录,校验字节数与 API 返回的资产 size 一致。
2. `hdiutil attach -nobrowse -readonly -plist` 挂载,定位卷内 `CC HUD.app`。
3. **签名校验(安全关卡)**:用 Security framework(`SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` + `SecCodeCopySigningInformation`)验证新 app 签名有效,且 TeamIdentifier 等于当前运行 app 的 TeamIdentifier(`Y42ZECHCL6`)。不匹配一律拒装——攻击者拿不到证书私钥即无法伪造。
4. **原子替换**(全程同目录 rename,可回滚):
   - `ditto` 新 app 到 `/Applications/.CC HUD.app.new`
   - 旧 app rename 为 `/Applications/.CC HUD.app.old`
   - `.new` rename 为 `/Applications/CC HUD.app`(运行中的进程不受影响,二进制已映射内存)
   - detach dmg,删 `.old` 与临时文件
5. 重启:起游离进程 `/bin/sh -c 'sleep 1; open "/Applications/CC HUD.app"'`,随即 `NSApp.terminate`。

quarantine 说明:app 自身经 URLSession 下载的文件不带 quarantine 属性(仅声明 `LSFileQuarantineEnabled` 的应用如浏览器才会打标),因此替换后的 app 不过 Gatekeeper,无需右键打开。这也是 Sparkle 等更新框架在无公证应用上可工作的原理。

### 错误处理

| 场景 | 行为 |
|---|---|
| 自动检查失败(断网、GitHub 限流) | 静默跳过,下个周期再试 |
| 手动检查失败 | 弹「检查更新失败,请稍后重试」 |
| 下载失败 / 大小不符 | 提示,可重试 |
| 签名校验失败 | 中止并提示「更新包校验失败,已取消」,绝不安装 |
| 替换失败(权限异常等) | 将 `.old` rename 回原位回滚,提示并附「前往 Releases 页面」按钮 |

更新器整体旁路于主功能:任何失败不影响 HUD 正常工作。GitHub 匿名 API 限流为 60 次/小时/IP,每日 1~2 次检查远低于阈值。

## 菜单重组(「设置留顶层」方案)

### 常态结构(9 项 + 3 分隔线,现为 13 项 + 5 分隔线)

```
CC HUD v1.2.1 · 运行正常          ← 原三行信息合并,灰色不可点
──────────────
显示 / 隐藏 HUD
──────────────
提示动画(完成 / 提问)      ▸
焦点会话不提示               ✓
额度燃尽预警                 ✓
登录时启动                   ✓
──────────────
权限与排障                   ▸
检查更新…
退出
```

「权限与排障」子菜单:

```
最近收到事件:3 秒前(解析失败 2)   ← 原顶层「事件:…」移入,文案改自解释;灰色
辅助功能:已授权 ✓ / 授权辅助功能(Ghostty 跳转)…
自动化授权设置(iTerm2/终端跳转)…
──────────────
重新安装接入
卸载接入(还原 settings.json)
```

### 状态行异常态(正常零噪音,异常显眼可点)

| 状态 | 显示 | 点击行为 |
|---|---|---|
| 正常 | `CC HUD v1.2.1 · 运行正常`(灰) | 不可点 |
| 接入失败 | `⚠ 接入失败 · 点击重新安装` | 直接执行重装(runInstall force) |
| 已卸载 | `已卸载接入 · 点击恢复` | 执行重装并清除卸载标记 |
| 事件服务启动失败 | `⚠ 事件服务启动失败`(含原因) | 不可点(重装无法修复端口类错误) |

### 更新状态的菜单形态

| UpdateController 状态 | 菜单表现 |
|---|---|
| idle / upToDate | 无额外行;「检查更新…」可点 |
| checking(手动触发) | 「检查更新…」变灰显示「正在检查…」 |
| updateAvailable | 状态行下方插入高亮行「⬆ 有新版本 vX.Y.Z,点击更新」 |
| downloading | 该行变「正在下载更新… N%」(不可点) |
| installing | 该行变「正在安装更新…」 |
| failed | 弹窗提示,菜单行恢复 idle 形态 |

## 测试策略

- **单测**(CCHudCore):版本比较(前缀 v、多位数、非法 tag)、GitHub API JSON 解析(fixture 文件)、UpdateController 状态机转换、rename 替换序列(临时目录模拟 /Applications,验证成功路径与回滚路径)。
- **端到端手动验证**:本机装回 v1.2.0,让更新器发现真实 v1.2.1 并走完整链路;更新后核验:版本号变化、AX 授权仍在(参照部署验证三件套:Read plist 版本 + 二进制 mtime + 进程启动时间)。

## 发布侧约定(零新增步骤,固化现状)

- tag 必须为 `vX.Y.Z`;资产名固定 `CC-HUD.dmg`;release body 写中文 changelog(会原样展示给用户)。
- 以上写入 README 发版说明。发版流程保持:改 `AppInfo.version` → build-app.sh → make-dmg.sh → 上传。

## 风险与边界

- **换签名证书会导致一次性授权失效**:Apple Development 证书续期(同团队)不影响;若换成不同身份(如将来的 Developer ID),更新后 AX 授权失效一次,需在该版 changelog 中提醒用户重新授权。
- **非 admin 用户** `/Applications` 不可写:落入「替换失败」路径,回滚并引导手动更新。
- **CFBundleVersion 目前硬编码 14**:更新器只比较 `CFBundleShortVersionString`(源头 `AppInfo.version`),不受影响;本次不改动。
