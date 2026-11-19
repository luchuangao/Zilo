# Zilo 1.0 App Store 发布准备

- Mac：`com.gaoluchuan.ownlist`，版本 1.0，构建 60，归档 `.release/20261119-appstore/Zilo-Mac-Final.xcarchive`；已声明生产力分类。
- iPhone：`com.gaoluchuan.ownlist.ios`，版本 1.0，构建 44，归档 `.release/20261119-appstore/Zilo-iPhone-Final.xcarchive`；已包含本地 UserDefaults 用途的隐私清单。
- Mac 主应用、小组件和分享扩展构建号一致。两端 Release 归档成功，173 项 Swift 测试通过，plist 校验通过。
- Apple 协议已由账户持有人处理。App Store Connect 已创建 iPhone 应用「Zilo：任务清单与便签」（Apple ID 6836645730）和 Mac 应用「Zilo Mac：任务清单与便签」（Apple ID 6836649094），均为 1.0 准备提交。
- iPhone 构建 44 已上传，Xcode 返回 `Upload succeeded`，当时 Apple 后台状态为处理中。最终处理结果尚待核实；没有提交审核或上架。
- Mac 构建 60 已准备好，上传时 Xcode 报 `Failed to Use Accounts` / 钥匙串凭据失效（缺少 Xcode-Username）。电脑操作工具同时检测到 Mac 锁屏；请解锁并恢复 Xcode Apple Account 后重试上传，完成后核对 Apple 处理结果。
- 审核前需在商店后台核对商店资料、隐私信息、截图、定价和发布设置；具体缺项以后台显示为准。
- 个人开发者账号的协议、付费及税务事项由账户持有人处理，不在代码中推断或代为接受。
