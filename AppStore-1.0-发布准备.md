# Zilo 1.0 App Store 发布准备

- Mac：`com.gaoluchuan.ownlist`，版本 1.0，构建 60，归档 `.release/20261119-appstore/Zilo-Mac-Final.xcarchive`；已声明生产力分类。
- iPhone：`com.gaoluchuan.ownlist.ios`，版本 1.0，构建 44，归档 `.release/20261119-appstore/Zilo-iPhone-Final.xcarchive`；已包含本地 UserDefaults 用途的隐私清单。
- Mac 主应用、小组件和分享扩展构建号一致。两端 Release 归档成功，173 项 Swift 测试通过，plist 校验通过。
- 使用 Xcode 的 `app-store-connect` 上传配置，最终上传尝试均返回 `Failed to Use Accounts`；Xcode Apple Accounts 列表为空。尚未上传、尚未通过商店处理、尚未提交审核或上架。
- 等账号恢复后，先确认 App Store Connect 中两个 bundle ID 的应用记录及对应构建号，再用 `.release/20261119-appstore/AppStoreUploadOptions.plist` 上传最终归档并检查处理结果。审核前需在商店后台核对商店资料、隐私信息、截图、定价和发布设置；具体缺项以后台显示为准。
- 个人开发者账号的协议、付费及税务事项由账户持有人处理，不在代码中推断或代为接受。
