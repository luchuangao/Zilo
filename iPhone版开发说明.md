# Zilo iPhone 版与通知窗口更新

工程：`ZiloMobile.xcodeproj`，Scheme：`ZiloMobile`。最低 iOS 17，原生 SwiftUI；版本 1.0，构建 31。Mac 工程继续使用 `OwnList.xcodeproj`。

## 已实现

- 底部导航：任务、日历、专注、习惯、更多；清单抽屉、清单颜色、搜索、标签、过滤器和智能清单显示设置。
- 任务：快捷添加，识别中文日期和标签，点击打开详情直接编辑名称，优先级、收藏、日期、提醒、常用重复规则，检查项，展开子任务，滑动完成／回收站，排序和“移动位置”选择父任务。层级移动拒绝循环，父任务完成／恢复和重复时处理子任务。
- 正文：Markdown 编辑、离线预览、代码高亮与语言切换、复制代码、链接和思维导图；原生富文本编辑及加粗、斜体、下划线、插入链接。富文本使用白色文档画布，保留已有文档颜色；修改名称不会转换正文。附件支持文件选择、存储、同步及 Quick Look 预览。
- 日历：月份切换、今天、任务日期标记、按日查看和添加任务。
- 四象限：优先级与截止日期分类，查看任务、通过长按菜单调整象限。
- 专注：番茄／正计时、关联任务、暂停／继续、结束保存、短休息／长休息、四轮后长休息，后台与重启恢复、概览和记录。暂停时间不计入专注。
- 习惯：周视图、指定日打卡、目标、连续天数、重复日及提醒。
- 倒数纪念日：分类卡片、日期、年重复、置顶、提前提醒。
- 统计：完成任务与专注分钟、每日完成图和清单分布。
- 设置：外观、整页主题色、功能模块、智能清单、日期识别、提醒、iCloud 开关、完整备份导入／导出。
- 通知：系统授权、任务／习惯／专注／纪念日提醒，任务通知支持完成及稍后提醒；应用内通知／活动记录和已读状态。iOS 有 64 个待发通知限制，优先安排最近的提醒并预留当前专注提醒。

Mac 通知窗口改为 350 × 470 pt，居中胶囊标签，去掉“消息类型”和刷新按钮；整理空状态、消息间距和未读圆点，仅有未读通知时显示“全部已读”。读取键包含送达时间，后续重复提醒不会被旧的已读状态误判。

## 数据与同步

Mac 与 iPhone 直接共享 `Models.swift`、`Persistence.swift` 和离线 Markdown 渲染器。CloudKit 容器沿用 `iCloud.com.gaoluchuan.ownlist`；Core Data 的 `FieldVersion`、`AttachmentBlob` 结构保持一致，没有重置生产数据库。

iPhone Bundle ID：`com.gaoluchuan.ownlist.ios`。模拟器使用本地存储；真机需要包含 CloudKit 和 Push Notifications 权限的描述文件。Mac 正式版使用 Production 数据库，因此真机互通验收必须使用 Production 环境的签名包，普通开发签名的 Development 数据库不能作为生产同步通过的证据。

备份格式沿用 `.ownlist.json`，包括任务、清单、过滤器、习惯、专注、纪念日、日历订阅和附件。导入按 ID 合并已有记录，不删除备份外的本机记录；同 ID 记录可能覆盖对应数据，导入前有确认。附件路径拒绝越界。

## 验证与当前限制

- Mac：111 项测试通过，Release 通用架构归档编译通过。
- iPhone：9 项测试通过，包括正文属性保留、重复任务子树、删除／恢复层级、移动防循环、备份互通、附件路径限制、离线 Markdown／思维导图、暂停时间排除及计时重启恢复。arm64 真机 SDK 的 Release 归档编译通过。
- 模拟器已验证任务创建、直接改名、子任务保存及展开、Markdown 预览与代码语言切换、计时开始与暂停、习惯打卡、日历、纪念日卡片、主题切换和通知中心；截图来自隔离的本地模拟器验收数据。
- Mac build 31 已完成 Developer ID 签名、Apple 公证及票据验证，已更新 `/Applications/Zilo.app`；通知窗口尺寸、通知／活动切换和列表已经检查。旧 build 30 已归档备份，用户任务未修改。
- iPhone 已完成自动签名，导出 release-testing IPA，确认 CloudKit 和 APNs 都使用 Production 环境；已安装到连接的 iPhone 15 并成功启动。
- 两端真实同步及 iPhone 系统提醒送达仍需真机确认。启用通知：Zilo「更多 → 设置 → 提醒与通知 → 允许系统通知」。后台 CloudKit 推送注册与 Remote notifications 能力已接入。
- 本次没有上架 App Store、上传 TestFlight 或更新个人网站。手机端尚未移植 Mac 的系统日历／提醒事项导入、日历订阅展示、多日时间轴、任务看板、桌面小组件等桌面集成功能。订阅数据仍会保留及备份。

## 构建与安装

Xcode 开发者账户已恢复登录。打开 iPhone 工程，选择已连接手机及对应团队即可运行开发版。

已交付的 `Zilo-iPhone-1.0-31.ipa` 为已登记设备的 Production 测试包，不能通过在 iPhone「文件」中直接点击安装，也未上架 App Store。开发 Mac 可重新构建并安装：

```bash
ZILO_DEVICE=08D5F48D-81B8-589D-A7D5-E08D6B2A8BB6 scripts/build-iphone.sh
```

脚本会归档、导出 Production 环境的测试 IPA，并安装到指定设备。首次安装／启动时，手机需解锁，且设备必须加入测试描述文件。已确认当前连接的 iPhone 15 开启了开发者模式。

模拟器测试：

```bash
xcodebuild -project ZiloMobile.xcodeproj -scheme ZiloMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

## 本轮界面修正

- 全天任务当天不会误显示为逾期；有具体时间的任务仍按时间判断。
- 暂停专注时显示“已暂停”。
- 任务备注、标签和子任务进度使用中性灰色，主题色用于日期和交互控件。

## 界面参考

以提供的截图、实际打开的滴答清单 Mac 通知面板，以及[滴答清单官方功能说明](https://ticktick.com/features)和[官方 iPhone App Store 页面](https://apps.apple.com/cn/app/id626144601)为参考，重新实现 Zilo 原生界面及交互。没有获取或复制滴答清单的私有源码、账号数据和安装包。

后台推送注册依据：[Apple UIApplication.registerForRemoteNotifications](https://developer.apple.com/documentation/uikit/uiapplication/registerforremotenotifications())。系统同步仍由 CloudKit 调度，签名权限正确不等于已验证两端数据送达。
