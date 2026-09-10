# Trashcall 上架 Checklist

## 当前状态 (v1.1.2)
- ✅ Bundle ID: `com.trashcall.app`
- ✅ 版本: 1.1.2 (11)
- ✅ 双扩展架构: TrashcallCallDirectory (识别) + TrashcallBlockDirectory (挂断)
- ✅ 隐私清单: PrivacyInfo.xcprivacy 已添加
- ✅ 图标: AppIcon.png (1024x1024)
- ✅ 测试套件: 14/14 通过
- ❌ **Apple Developer 账号**: 免费个人账号，需升级到付费会员 ($99/年)
- ❌ **App Store 截图**: 未提供 (需要 iPhone 6.7" 和 6.1" 尺寸)
- ❌ **App Store Connect 应用**: 需在 appstoreconnect.apple.com 创建

---

## 上架前准备工作

### Step 1: 升级 Apple Developer 账号
- 登录 https://developer.apple.com/account
- 点击 "Enroll" 或 "Upgrade"
- 支付 $99/年
- 等待账号审核通过 (通常 1-3 个工作日)

### Step 2: 创建 App Store Connect 应用
1. 登录 https://appstoreconnect.apple.com
2. 点击 "我的 App" → "+" 新建 App
3. 填写:
   - 平台: iOS
   - Name: Trashcall
   - Bundle ID: `com.trashcall.app` (从开发者后台选择)
   - 语言: Simplified Chinese
   - 主类别: Utilities / 工具
   - 副类别: 效率工具
4. 提交应用信息

### Step 3: 上传屏幕截图
需要以下尺寸 (iPhone):
- iPhone 6.7": 1290 x 2796 px
- iPhone 6.1": 1170 x 2532 px
- 至少 3 张截图

建议使用 Xcode 自带的 Simulator 截图功能，或手动使用 1080p/2K 模拟器导出。

### Step 4: 配置 App 信息
在 App Store Connect 中填写:
- 描述 (中文 + 英文)
- 关键词 (spam call, 骚扰拦截, 电话屏蔽, 垃圾电话)
- 支持页面 URL (可选)
- 隐私政策 URL (可选)
- 联系方式

### Step 5: 构建并上传
**方法 A: Xcode GUI (推荐)**
1. 在 Xcode 中选择目标为 "My Mac"
2. Product → Archive
3. 在 Organizer 中点击 "Distribute App"
4. 选择 "App Store Connect" → "Upload"
5. 等待上传完成

**方法 B: CLI (自动化)**
```bash
# 构建 Archive
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
/usr/bin/xcodebuild -project Trashcall.xcodeproj \
-scheme Trashcall -configuration Release \
-destination "generic/platform=iOS" \
-productArchive /tmp/Trashcall.xcarchive archive

# 导出 IPA
/usr/bin/xcodebuild -exportArchive \
-exportPath /tmp/Trashcall_build \
-archivePath /tmp/Trashcall.xcarchive \
-exportOptionsPlist exportOptions.plist
```

exportOptions.plist 内容:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>provisioningProfiles</key>
    <dict>
        <key>com.trashcall.app</key>
        <string>Trashcall Distribution</string>
        <key>com.trashcall.app.CallDirectoryExtension</key>
        <string>TrashcallCallDirectory Distribution</string>
        <key>com.trashcall.app.BlockDirectoryExtension</key>
        <string>TrashcallBlockDirectory Distribution</string>
    </dict>
</dict>
</plist>
```

### Step 6: TestFlight 分发
上传成功后，在 App Store Connect 的 TestFlight 标签页中:
1. 创建一个 TestFlight Group (内部测试组或外部测试组)
2. 添加测试人员邮箱
3. 提交审核 (TestFlight 不需要 App Store 审核，但需要确认合规)

### Step 7: App Store 审核提交
1. 在 App Store Connect 中找到你的 App
2. 点击 "App Store" 标签
3. 填写所有必填字段
4. 上传截图
5. 设置价格 (可以设为免费)
6. 提交审核

---

## 注意事项

### 扩展架构影响
本项目的双扩展架构 (识别 + 挂断) 在 App Store 审核时需要注意:
- Call Directory Extension 需要在 App Store 描述中说明用途
- 可能需要额外说明拦截行为 (静音挂断 vs 显示标记)

### 隐私政策
建议准备一个隐私政策页面 (GitHub Pages 即可)，说明:
- 号码数据存储方式 (本地 SQLite)
- 是否上传到服务器 (否)
- 如何管理拦截规则

### 合规要求
- 不能声称能"阻止运营商来电" (只能本地拦截)
- 需要明确说明是"标记"还是"拦截"
- 需要符合 Apple 的 CallKit 使用政策

---

## 紧急待办 (必须完成才能上架)
1. [ ] 升级到付费 Apple Developer 账号 ($99/年)
2. [ ] 创建 App Store Connect 应用
3. [ ] 提供 3-5 张屏幕截图
4. [ ] 填写应用描述和关键词
5. [ ] 构建 Release 版本 Archive
6. [ ] 上传到 App Store Connect
7. [ ] 提交 TestFlight 测试 (可选)
8. [ ] 提交 App Store 审核
