# 点点衣橱（Clog）iOS 版

用原生 iOS（SwiftUI + UIKit）把小程序「我的衣橱」重写了一遍：功能、页面结构、数据层、事件机制
都和原来一一对应，只有两处按要求换成了 iOS 系统能力——

| 能力 | 小程序 | iOS 版 |
| --- | --- | --- |
| 抠图 | 云端 AI 抠图接口（自己搭服务 + 配置合法域名） | **Vision 框架** `VNGenerateForegroundInstanceMaskRequest`，本机完成，不需要接口和 Key |
| 天气 | 和风天气接口（需要申请 Key + 配置域名） | 默认 **WeatherKit**（系统自带），另外补了一条**和风天气备用通道**，两条二选一 |

App 名称：中文 **点点衣橱**，英文 **Clog**；bundle id 是 `com.wardrobe.clog`。
当前版本 **1.1.0**（build 2），写在 `project.pbxproj` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`；
设置页「关于 → 版本」直接读 App 包里的值，不用手动同步。

## 打开与运行

1. 用 Xcode 打开 `ios/Wardrobe.xcodeproj`
2. 选 `Wardrobe` target → Signing & Capabilities，选好自己的 Team（`PRODUCT_BUNDLE_IDENTIFIER` 默认是
   `com.wardrobe.clog`，可以改成自己的）
3. 真机或模拟器直接 Run（最低 iOS 17.0，因为系统抠图需要 iOS 17）

**关于天气**：两条通道，在「设置 → 天气」里二选一。

- **系统 WeatherKit**（默认）：需要**付费**开发者账号（个人免费账号用不了），所以工程里默认
  **没有**打开这个 entitlement —— 这样免费账号也能直接装真机。
- **和风天气**（备用通道）：免费开发者账号也能用，去 [dev.qweather.com](https://dev.qweather.com)
  申请一个 Key 填进「设置 → 天气 → API Key」即可，不用改代码。填完会自动测一次连通性。
  老账号的 API Host 是 `devapi.qweather.com`（默认值），2024 年之后的新账号在控制台里会给一个
  专属域名（形如 `abc123.re.qweatherapi.com`），把它填到 API Host 那一栏就行。
  免费版提供实况 + 未来 3 天预报，过去的日子仍然手填。

不管用哪条通道，天气卡片都可以直接手填城市 / 温度 / 天气，配好来源之后打开日记页也会自动把
当天天气抓回来（只在已经有城市坐标时自动跑，不会一进页面就弹定位权限）。

之后开通了付费账号，想启用自动获取，两步即可（代码不用改）：

1. [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers & Profiles →
   Identifiers → 选中当前 bundle id 对应的 App ID → Capabilities 勾上 **WeatherKit** → Save
2. 把 `Config/Wardrobe.entitlements` 里注释掉的这两行恢复（文件里有注释说明）：

   ```xml
   <key>com.apple.developer.weatherkit</key>
   <true/>
   ```

程序里做了自动判断：拿到权限错误就不再重复请求，天气卡片与设置页都会明确告诉用户「当前签名没有权限」，
并且会提示改用和风天气或手填，不会卡住流程。

## 真机测试

**自动抠图（Vision）和天气（WeatherKit）只能在真机上真正跑起来**：模拟器没有 Vision 的推理后端，
也没有天气授权，这两处会走降级提示。真机步骤：

### 1. 手机侧准备

1. 系统要求 iOS 17 及以上（抠图需要 17，建议 18+）。
2. 数据线连 Mac，手机上弹「要信任此电脑吗」→ 选**信任**。
3. 开启开发者模式：**设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启 → 重启后确认**。
   （如果找不到这一项，先用 Xcode 连一次手机，或随便装一次 App，它就会出现。）

### 2. Xcode 里配置签名

1. Xcode → Settings → Accounts，加入你的 Apple ID（个人免费账号也能装真机）。
2. 打开 `ios/Wardrobe.xcodeproj` → 选 **Wardrobe** target → **Signing & Capabilities**：
   - Team 选你的账号，勾上 *Automatically manage signing*
   - Bundle Identifier 改成你自己的（例如 `com.yourname.wardrobe`；默认的
     `com.wardrobe.clog` 用在你账号下可能要改）
3. **天气（可选）**：工程默认没开 WeatherKit 权限，**免费个人账号可以直接跳过这一步**：签名不会有任何
   问题，想要自动获取天气就到「设置 → 天气」把来源切成「和风天气」并填上 Key（免费账号也能用）；
   付费账号想用系统 WeatherKit，按上面「关于天气」那两步做即可。
   （如果自己把 entitlement 加回来了、又换成免费账号签名，就会报
   *"Provisioning profile doesn't include the com.apple.developer.weatherkit entitlement"*，
   把那两行再注释掉即可。）
4. 顶部运行目标从模拟器切换成你的 iPhone，按 **⌘R**。
5. 手机上如果提示「不受信任的开发者」：**设置 → 通用 → VPN与设备管理 → 开发者 App → 信任**。
   免费账号签的 App 7 天后会失效，重跑一次 ⌘R 即可；付费账号的证书有效期一年。

> 换了 bundle id（`com.wardrobe.clog`）之后，手机上以前那份 `vip.looklog.wardrobe` 是另一个 App：
> 新的这份和它的数据不互通，确认新版本没问题后可以把旧的那份直接删掉。

### 3. 真机上重点验这几件事（模拟器验不了的）

1. **抠图**：衣橱 → `+` → 选一张衣服照片 → 进编辑器会**自动跑一次系统抠图**，直接给出抠好的透明背景图；
   想只要其中一件时**长按画面里的衣物主体**，只抠出手指底下那件（和系统相册的长按抠图同一个道理）；
   抠多了用橡皮擦、抠少了用「画笔恢复」涂回来，不满意可以撤销 / 重做 / 裁剪。
2. **首次权限弹窗**：相册（选图）、相机（拍照）、定位（点「获取天气」时）。拒绝定位也不影响手填。
3. **天气**：日记页 → 城市（搜索或「用当前位置」）→ 获取天气；今天取实况、未来几天取预报，
   过去的日子会提示手填。两条通道都试一下（设置里切换来源）。
4. **手感**：试衣间拖动 / 双指缩放旋转、编辑器涂抹跟手度、还有相机原图（4000×3000）的处理速度。
5. **完整闭环**：加几件衣物 → 记一套穿搭 → 试衣间摆好保存搭配（生成封面）→ 设置里看图片占用 →
   导出 JSON 走系统分享面板。

### 4. 不想开 Xcode 界面，用命令行装（可选）

```bash
# 看手机是否连上（拿到标识符/名字）
xcrun devicectl list devices

# 真机构建（DEVELOPMENT_TEAM 换成你的 Team ID：developer.apple.com → Membership → Team ID）
xcodebuild -project ios/Wardrobe.xcodeproj -scheme Wardrobe \
  -destination 'platform=iOS,name=<你的设备名>' \
  -derivedDataPath build-ios \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<你的 Team ID> build

# 安装并启动
xcrun devicectl device install app --device <设备标识> \
  build-ios/Build/Products/Debug-iphoneos/Wardrobe.app
xcrun devicectl device process launch --device <设备标识> com.wardrobe.clog
```

真机上的数据和模拟器是完全独立的两份（都存在各自设备的沙箱里）；卸载 App 会连图片一起删掉。

### 5. 免费账号 7 天过期后怎么续

免费个人账号签出来的 App 只有 **7 天**有效期（从最后一次安装 / 重新签名算起）。

- **过期时的症状**：点图标提示「无法验证 App」或闪一下就退回桌面。不是代码出问题，续一次即可。
- **数据不会丢**：续期做的是「覆盖安装」，App 沙箱里的衣物、图片、穿搭、设置都保留。
  只有手动删除 App（或换机）才会连数据一起清掉。
- **续期方式**（两选一）：
  1. 手机连上 Mac，Xcode 里选好这台设备按 **⌘R**；
  2. 一行命令：`./ios/refresh-device.sh` —— 自动找设备、重新签名构建、覆盖安装，最后顺手把 App 打开。
     指定设备名或 Team 的用法见脚本头部注释。
- **免费账号的其他限制**：同时最多装 3 个自己签名调试的 App；7 天内最多创建 10 个 App ID
  （用同一个 bundle id 反复续期不消耗这个额度，所以别改 bundle id）。
- **想彻底摆脱 7 天**：升级付费开发者账号（$99/年），之后用 TestFlight 装到手机（构建 90 天有效，
  可反复上传），或者直接上架 App Store；顺带 WeatherKit（自动获取天气）也能开了。
- **备份建议**：设置页的「导出 JSON」导的是**数据 + 图片文件名**，图片本身在 App 沙箱里，
  所以那份 JSON 不能单独恢复图片。如果哪天要删 App、换机，或者想要能一键恢复的完整备份，
  可以再加一个「打包图片的 zip 备份 / 恢复」功能。

## 目录与小程序对照

| 小程序 | iOS | 说明 |
| --- | --- | --- |
| `app.js` | `Wardrobe/App/WardrobeApp.swift` | 入口：初始化数据层 + 全局状态 |
| `app.json` | `Wardrobe/App/RootTabView.swift` | 四个 tab：衣橱 / 日记 / 试衣间 / 设置（图标复用 `assets/tabbar`） |
| `store/global.js` | `Wardrobe/App/AppState.swift` | 全局状态 + 事件总线（`bus.on / emit / offByCtx` 一一对应） |
| `utils/storage.js` | `Wardrobe/Data/Storage.swift` | 本地存储底座（每个 key 一个 json 文件） |
| `utils/db.js` | `Wardrobe/Data/Database.swift` | 数据层，函数名与行为一一对应 |
| `utils/date.js` | `Wardrobe/Utils/DateUtil.swift` | 日期与月历网格 |
| `utils/image.js` | `Wardrobe/Utils/ImageStore.swift` | 沙箱图片读写、下采样缓存 |
| `utils/cutout.js` | `Wardrobe/Utils/CutoutService.swift` | 抠图（改为系统 Vision） |
| `utils/weather.js` | `Wardrobe/Utils/WeatherService.swift` + `Wardrobe/Utils/QWeatherService.swift` | 天气：系统 WeatherKit 与和风天气两条通道，设置里二选一 |
| `assets/tabbar/*.png` | `Wardrobe/Assets.xcassets/TabBar/*` | tab 图标，原样搬过来 |
| `assets/*.png`（App 图标） | `Wardrobe/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` | 1024×1024 的图标（线稿 T 恤那版） |
| `pages/wardrobe` | `Wardrobe/Views/WardrobeView.swift` | 衣橱 |
| `pages/diary` | `Wardrobe/Views/DiaryView.swift` | 穿搭日记（月历 + 天气卡片 + 当天穿搭） |
| `pages/fitting` | `Wardrobe/Views/FittingView.swift` + `FittingModel.swift` | 试衣间（画布 + 灵感） |
| `pages/settings` | `Wardrobe/Views/SettingsView.swift` | 设置 |
| `pages/clothing-edit` | `Wardrobe/Views/ClothingEditView.swift` | 添加 / 编辑衣物 |
| `pages/clothing-detail` | `Wardrobe/Views/ClothingDetailView.swift` | 衣物详情 |
| `pages/outfit-edit` | `Wardrobe/Views/OutfitEditView.swift` | 记录 / 编辑穿搭 |
| `pages/outfit-detail` | `Wardrobe/Views/OutfitDetailView.swift` | 穿搭详情 |
| `pages/image-editor` | `Wardrobe/Views/ImageEditorView.swift` + `Components/EditorCanvas*.swift` | 抠图编辑器 |
| `components/clothing-card` | `Wardrobe/Components/ClothingCard.swift` | 衣物卡片 |
| `components/clothing-selector` | `Wardrobe/Components/ClothingSelectorSheet.swift` | 选衣弹层 |
| `components/empty-state` | `Wardrobe/Components/EmptyStateView`（在 `Theme.swift` 里） | 空状态 |
| `components/image-canvas` | `Wardrobe/Components/EditorCanvas.swift` | 画布（画什么由页面决定） |
| 「分类」固定值 | `Wardrobe/Views/CategoryEditorSheet.swift` | 分类改成可自定义：内置六个是默认值，可改名 / 增删 |
| `app.wxss` | `Wardrobe/Components/Theme.swift` | 设计变量与公共样式（rpx → pt，1rpx = 0.5pt） |
| `wx.showToast / showModal / showActionSheet / chooseImage / vibrateShort / previewImage` | `Wardrobe/Components/UIKitBridges.swift` | 这些小程序 API 在 iOS 上的对应实现 |

## 与小程序的两处必要差异

1. **图片只存文件名，不存绝对路径**（`ImageStore`）。iOS 沙箱目录在升级 / 重装后会变，
   存绝对路径会全部失效；`ImageStore.url(for:)` 同时兼容老数据里的绝对路径写法。
2. **「云端抠图接口配置」这一项没有了**。抠图走系统能力后不再需要接口地址和 Key，
   设置页里改成了展示「抠图方式 / 是否需要联网」。

## 这几处和小程序不一样（按需求改的）

1. **抠图流程**：进编辑器先自动调一次系统抠图（`VNGenerateForegroundInstanceMaskRequest` 的所有实例），
   再模仿系统相册那套：**长按画面里的衣物主体只抠出那一件**（取实例遮罩里「手指底下最小面积」的那个），
   之后可以用橡皮擦 / 画笔恢复 / 裁剪细修。界面布局：模式行（橡皮擦 / 画笔恢复 / 裁剪 + 笔刷滑块）在上，
   撤销 / 自动抠图 / 重做（带图标）固定在画面底部，撤销重做会把换底图那一步也一起回滚。
2. **衣物分类可自定义**：内置的上衣 / 裤子 / 裙子 / 鞋 / 配饰 / 套装只是默认值，
   在「设置 → 衣物分类」或衣物表单右上角的「管理分类」里改名、删除、新增；改名会同步更新
   已经用了这个分类的衣物，删掉的分类里的衣物会挪到第一个分类（至少保留一个分类）。
3. **天气两条通道**：系统 WeatherKit（默认，需付费账号 + 后台开能力）与和风天气
   （免费账号也能用，填 Key 即通，免费版实况 + 未来 3 天）。填完 Key 自动测一次连通性；
   配好来源后日记页会静默补上当天天气（只在已有城市坐标时）。
4. **命名**：中文名「点点衣橱」、英文名「Clog」、bundle id `com.wardrobe.clog`（英文名通过
   `Wardrobe/en.lproj/InfoPlist.strings` 覆盖，系统语言是英文时显示 Clog）。
5. **主菜单底栏**：图标 26 → 30pt、文字 10 → 12pt（选中加粗），小屏上更清楚。
6. **抠完的图按衣服范围裁紧**：抠图结果保留的是原图尺寸，衣服常常只占中间一块，
   直接存下去会「衣服小、定位框大」（试衣间里最难摆）。现在
   - 编辑器点「确定」导出时，按不透明像素的外接矩形裁一刀（外面留 2% 边），存下来的就是衣服本身的尺寸；
   - 编辑画布、试衣间画布、衣柜卡片、搭配封面都改成按「有内容的那块」来量尺寸和绘制，
     所以**以前存的老图**也会自动按衣服范围显示，不用重新抠一遍。
7. **操作表挂在被点的控件上**：所有 `confirmationDialog`（选照片 / 重新抠图 / 设置封面 / 移动到哪里 /
   文件夹操作 / 导出 JSON）都从「页面根节点」挪到了触发它的那个控件上。系统弹层是按挂载点定位的 ——
   挂在整页时 iOS 26 会把它摆到页面最下边（还压住底栏），挂到控件上就贴着哪儿点哪儿弹。
8. **开屏页**（`Views/SplashView.swift`）：启动时中间显示 App 图标、下面一行字「做给点点的衣橱」，
   停留 1.5 秒后淡出到衣橱页（这 1.5 秒里数据已经在后台读好，等于把启动等待藏起来）。
   图标取的是应用自己的 `AppIcon`（`UIImage(named: "AppIcon")`，取不到再走 Info.plist 的图标清单），
   所以以后换图标，开屏页会跟着变，不用改代码；系统的启动屏（`UILaunchScreen`）用的是同一个背景色
   `LaunchBackground`，从系统启动屏到开屏页不会闪一下。开了「减弱动态效果」时不做缩放动画。
9. **悬浮毛玻璃底栏**：底部导航改成浮起来的胶囊，左右各留 20pt；iOS 26 及以上直接用系统的
   **Liquid Glass**（`glassEffect(.regular, in: Capsule())`），更早的系统退回 `.ultraThinMaterial`，
   两种都是真·半透明。**页面铺满整屏，滚动内容从玻璃下面穿过去**，不像之前那样被一条不透明的
   矩形色块截断。选中的 tab 仍用小程序那套橙色图标，未选中的图标改成模板渲染并用 `Theme.textSub`
   上色，所以深浅色切换时会跟着变。
   底栏浮在页面之上，所以：
   - 页面滚动内容统一留 `Theme.floatingBarSpace`（82pt）的底部空白，滚到底时最后一行不会贴着玻璃；
     「+」悬浮按钮也会抬到底栏上方；
   - 页面里自己固定在底部的操作栏（试衣间、衣物编辑 / 穿搭编辑的保存栏、衣物 / 穿搭详情的操作栏、
     图片编辑器的确认栏）通过 `@Environment(\.floatingBarInset)` 往上让开，不会被压在后面。
10. **深色模式**：`Theme` 里每个颜色都给了浅色 / 深色两套值（背景是暖黑 `0x151413`、卡片 `0x232120`，
    主色在深色下稍微提亮），图片占位底色、编辑器棋盘格、轻提示底色也都有对应深色值；卡片在深色下
    改用一圈描边代替看不见的阴影。设置页多了「显示 → 外观」：**跟随系统（默认）/ 浅色 / 深色**，
    写在设置里，由 App 入口统一应用；`Info.plist` 里锁死浅色的 `UIUserInterfaceStyle` 已经去掉。
11. **衣物详情的「历史穿搭」**：按时间倒序列出这件衣物参与过的每套穿搭（封面缩略图、日期、备注、
    件数与季节），点一行直接进那套穿搭的详情；没有记录时给一句引导文案。

## 数据兼容

JSON 字段、id 规则（`c/o/i/f` + 36 进制自增）、`createTime` 毫秒时间戳、季节顺序、
导出结构都与小程序保持一致，`Database.exportData()` 出来的 JSON 和小程序可以直接对照。
天气记录里的 `cityId` 在 iOS 版存的是「纬度,经度」（形如 `30.2741,120.1551`），
这样字段不变、又能给 WeatherKit 用。

## 验证情况

- **构建**：Xcode 26.3 + iOS 26.2 SDK，`xcodebuild -scheme Wardrobe -destination 'iPhone 17'` 的
  Debug 模拟器构建 **0 错误 0 警告**；真机 SDK（iOS 17 目标）也能完整 typecheck、emit-module 并链接成
  arm64 可执行文件（SwiftUI / UIKit / Vision / WeatherKit / CoreLocation / PhotosUI 全部通过）。
- **实机跑通**：装进 iPhone 17 模拟器，四个 tab 逐个看过截图；用一段临时的自检代码在模拟器里跑了
  **34 项功能检查（全部通过）**，覆盖：数据层增删改查与连带清理、id 归一化、季节排序、
  天气记录空值自动清除、月历 42 格与今天/昨天文案、图片落盘与透明通道、
  编辑器的擦除 / 撤销 / 重做 / 画笔恢复 / 裁剪 / 重置（含裁剪后取景范围跟随）、搭配封面合成尺寸与透明区域。
  > 自检过程中据此修掉了一个真实 bug：裁剪后计算「原图取景范围」时用到了已经换过的底图尺寸，
  > 会导致裁剪后画笔恢复取错区域。

这一轮改动（图标 / 底栏 / 可自定义分类 / 抠图流程 / 改名 / 和风天气通道）另外验了这些：

- **模拟器截图**：衣橱（7 个自定义分类、底栏放大）、日记（天气来源显示「自动获取（和风天气）」）、
  试衣间、设置（新的「衣橱 → 衣物分类」与「天气」卡片）、添加 / 编辑衣物（分类胶囊 + 管理分类入口）、
  分类管理弹层、抠图编辑器的整块布局 —— 逐张看过对齐。
- **和风天气通道**：把 `QWeatherService` 单独编译成命令行程序在 macOS 上跑了 13 项检查（全部通过）：
  API Host 归一化、用假 Key 真打 `devapi.qweather.com` 与服务端返回的 HTTP 状态被翻成给用户看的话、
  实况 / 逐日 / 城市搜索的返回体解析、图标码映射。又在模拟器里把「日记 → 获取天气」整条链路跑通：
  假 Key 会在 App 里弹出「和风天气返回 HTTP 403，检查 Key 和 API Host 是否与账号匹配」。
  （真 Key 的实际取数需要你自己填一次 Key 验证。）
- **长按抠图的命中测试**：在 macOS 上用同一套 Vision 调用序列 + 同一套 alpha 命中逻辑跑了检查（全部通过）：
  两张合成照片里，点衬衫命中衬衫那个实例、点包命中包那个实例、点背景不命中；多实例同时命中时挑最具体的那个。
  > 这一步抓到一个真 bug：算实例遮罩的 alpha 时多翻了一次坐标，会导致长按上半部分命中下半部分的主体。
  > 已修（`CutoutService.alphaBuffer`），修完复测通过。

第二轮的补充改动（弹层挂载点 + 保存时裁到衣服范围）另外验了这些：

- **弹层位置**：同一台模拟器（iOS 26.3）前后截图对比 —— 改之前「试衣间 → 导入图片」的气泡会落到
  屏幕最底部、压住底栏并被裁掉一截；把挂载点移到「灵感」那一块之后，气泡贴着它弹、完整可见。
- **裁边数学**：把 `ImageStore.contentRect / cropToContent` 抽出来在 macOS 上跑了 8 项检查（全部通过）：
  中间一块内容时量出的外接矩形与位置、裁完的尺寸（内容 + 2% 边）、裁完内容贴边、
  整张都有内容 / 全透明 / 上下贴边 / 内容不足 1% 这四种「不该裁」的情况。
- **显示效果**：用一张「衣服只占画面中间一小块」的 1600×1600 图分别看了三处（截图逐张确认）——
  衣柜卡片里衣服撑满卡片、编辑画布里衣服撑满画布（涂抹精度跟着提高）、试衣间的虚线定位框紧贴衣服轮廓。

第三轮的两处改动（改名 + 开屏页）也验了：

- **改名**：`Config/Info.plist` 的 `CFBundleDisplayName` 由「欣欣衣橱」改成「点点衣橱」
  （英文名仍是 Clog，由 `Wardrobe/en.lproj/InfoPlist.strings` 覆盖，系统语言为英文时才显示 Clog）。
  装到模拟器后，桌面图标下面的名字确认是「点点衣橱」。
- **开屏页**：连着截了 22 张图逐张比对，确认三段衔接 —— 系统启动屏（纯背景色 `LaunchBackground`）
  → 开屏页（App 图标 + 「做给点点的衣橱」，停留 1.5 秒）→ 淡出进入衣橱页，中间没有闪白或跳一下。
  图标确认是从 `UIImage(named: "AppIcon")` 取到的（就是桌面上那张手绘 T 恤），
  以后换图标开屏页会自动跟着变。

第四轮（**版本 1.1.0**：悬浮磨砂底栏 / 深色模式 / 衣物历史穿搭）的验证：

- **深色模式**：把模拟器切成深色后逐个 tab 截图看（衣橱、日记、试衣间、设置），
  背景 / 卡片 / 文字 / 描边 / 图片占位底色都跟着变，主色在深底上依然清楚；
  再切回浅色对照一遍，确认浅色下与之前一致。
- **悬浮底栏**：深浅两套截图确认胶囊形态、磨砂材质与描边；未选中图标改成模板渲染后，
  深浅色下都能正确变灰；试衣间那条自带的底部操作栏（添加衣物 / 保存搭配）与底栏不再互相遮挡。
- **历史穿搭**：拿数据里的「白色亚麻衬衫」（参与了 1 套穿搭）和「碎花连衣裙」（0 套）
  各截了一张图，确认有记录时列出封面 / 日期 / 备注 / 件数与季节、点一行能进穿搭详情，
  没记录时显示引导文案。
- **外观设置**：把设置写成 `light` / `dark` 后重启，确认 App 会按设置锁定外观；选「跟随系统」时
  跟随系统切换。

第五轮（底栏换成系统毛玻璃 + 内容从玻璃下穿过）的验证：

- **玻璃效果**：设置页最长，正好当对照 —— 改之前「天气来源」那一行会被底栏上方的一条不透明色块
  截断（就是反馈里的 P2）；改之后同一位置的内容是**透过玻璃**看到的（模糊但仍可辨认），
  与 P1 的系统底栏一致。深浅两套外观各截了一张。
- **页面自带操作栏让位**：试衣间的「添加衣物 / 复制 / 清空 / 保存搭配」在深色下截图确认落在
  悬浮底栏上方，不再被压住（衣物编辑 / 穿搭编辑 / 两个详情页 / 图片编辑器用的是同一套
  `floatingBarInset` 内边距）。
- **「+」悬浮按钮**：衣橱页截图确认已经抬到玻璃底栏之上。

**这两个系统能力在模拟器上跑不了，需要在真机验证**（代码里都已经做了降级处理，不会卡住流程）：

| 能力 | 模拟器 | 真机 |
| --- | --- | --- |
| 系统抠图 | 会报 `Could not create inference context`（模拟器没有推理后端），界面提示「这台设备（或模拟器）不支持系统抠图」，并提示可以长按或手擦 | iOS 17+ 真机可用；已在 macOS 上用同一套 Vision 调用序列实测：单个主体、多个主体、长按命中都对 |
| 系统天气 | WeatherKit 报授权错误（模拟器没有 Apple 账号/许可），界面提示换来源或手填 | 需要在 Apple Developer 后台给 App ID 打开 WeatherKit 能力后可用 |
| 和风天气 | 可用（走网络，模拟器能跑通错误分支） | 可用；填真 Key 即可取到实况 / 3 天预报 |

## 已知的取舍（可以按需打磨）

- 试衣间的双指缩放是绕图层中心缩放（小程序是绕捏合中点缩放并同步挪位置），手感差别很小；
  旋转保留了接近 90° 的整数倍时自动吸附。
- 编辑器的画面同步方式是「每段笔画后把位图快照给 ImageView」，超大图（超过 2048 长边）会先缩小，
  真机上如果觉得涂抹不够跟手，可以改成只重绘脏区域。
- 长按抠图依赖 Vision 的实例分割：画面里只有一件衣物时它就是那一件；叠在一起 / 贴得很近的两件可能被
  当成一个主体（系统相册也一样），这种情况用橡皮擦擦掉多余的那件即可。
- 和风天气免费版只有实况 + 3 天预报，且没有历史天气；付费版才有多天预报和历史。
- App 图标是单张 1024 通用图（`AppIcon-1024.png`），没有做深色 / 着色变体。
- App 目前只做了浅色外观（`Info.plist` 里 `UIUserInterfaceStyle = Light`），和小程序一致。
