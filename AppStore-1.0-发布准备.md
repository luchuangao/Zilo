# Zilo 1.0 App Store 发布准备

- Mac：`com.gaoluchuan.ownlist`，版本 1.0，构建 60，归档 `.release/20261119-appstore/Zilo-Mac-Final.xcarchive`；已声明生产力分类。
- iPhone：`com.gaoluchuan.ownlist.ios`，版本 1.0，构建 44，归档 `.release/20261119-appstore/Zilo-iPhone-Final.xcarchive`；已包含本地 UserDefaults 用途的隐私清单。
- Mac 主应用、小组件和分享扩展构建号一致。两端 Release 归档成功，173 项 Swift 测试通过，plist 校验通过。
- Apple 协议已由账户持有人处理。App Store Connect 已创建 iPhone 应用「Zilo：任务清单与便签」（Apple ID 6836645730）和 Mac 应用「Zilo Mac：任务清单与便签」（Apple ID 6836649094），均为 1.0 准备提交。
- iPhone 构建 44 已上传，Xcode 返回 `Upload succeeded`，当时 Apple 后台状态为处理中。最终处理结果尚待核实；没有提交审核或上架。
- Mac 构建 60 已准备好；解锁后自动上传重试仍报 `Failed to Use Accounts`。尝试导出 App Store 包进一步报告本机缺少 Mac App Distribution、Mac Installer Distribution 签名证书及描述文件。账户持有人已获知需在 Xcode 管理证书中检查和恢复签名身份；不要撤销现有证书。图形操作工具当前不可用，无法继续通过 Xcode 图形界面验收。完成后重试上传并核对 Apple 处理结果。
- 审核前需在商店后台核对商店资料、隐私信息、截图、定价和发布设置；具体缺项以后台显示为准。
- 个人开发者账号的协议、付费及税务事项由账户持有人处理，不在代码中推断或代为接受。
