# Spatial Camera Bridge

更新日期：2026-07-23

## 目标

Spatial Slides 负责在 Vision Pro 中呈现演示；独立的 iOS 应用
`Spatial Camera` 使用 iPhone 相机观察同一物理空间，并在相同位置重建当前
幻灯片和空间元素。iPhone 可以直接录制“真实房间 + 空间演示”的第三视角视频。

这不是 Vision Pro 画面的镜像。两端共享的是语义场景、素材和空间变换，
iPhone 使用自己的 ARKit 相机重新渲染，因此画面没有 Vision Pro 视野遮罩，
也更适合录制。

## 当前实现

- `Packages/SpatialBridgeKit`：跨 visionOS/iOS 的协议、矩阵、消息分帧、
  SHA-256 校验和 Bonjour TCP 传输。
- `SpatialSlidesBridgeHost`：发布当前页、当前 build beat、空间元素、
  资源清单和按需素材。
- `Spatial Camera`：独立 iOS Xcode 工程，运行 ARKit world tracking，
  完成两点标定、场景重建和 ReplayKit 录制。
- 连接方式：同一局域网中的 `_spatialbridge._tcp` Bonjour 服务。
- 坐标方式：两端分别放置同一个“原点 + 朝向”箭头，不要求 ARKit world
  origin 本身一致。

## 坐标契约

共享空间采用右手坐标系：

- 箭头球心是共享原点 `(0, 0, 0)`。
- 箭头指向共享 `+Z`。
- 重力反方向是共享 `+Y`。
- `+X = +Y cross +Z`。

Vision Pro 中，青色箭头可以抓取、平移和旋转。释放时会自动消除俯仰与翻滚，
只保留水平朝向。演示内容先从 Stage 坐标转换到箭头坐标：

```text
sharedFromStage = inverse(stageFromSharedArrow)
sharedContent = sharedFromStage * stageContent
```

iPhone 先点箭头球心，再点箭头方向上至少 8 cm 外的第二点，由
`SharedAlignmentFrame` 建立 `phoneWorldFromShared`：

```text
phoneWorldContent = phoneWorldFromShared * sharedContent
```

所有内容挂在 iPhone 的一个共享根实体下。重新标定只移动这个根实体，不逐个
重写场景中的卡片和模型。

## 数据流

1. Vision Pro 启动 Bonjour server。
2. iPhone 自动发现并连接，发送 `hello` 和 `requestSnapshot`。
3. Vision Pro 返回 deck manifest 和当前 `BridgeSlidesSnapshot`。
4. iPhone 按当前页需要的路径请求 PNG/JPEG/USDZ。
5. Vision Pro 返回带 SHA-256 的素材；iPhone 校验后写入 cache。
6. 翻页、build beat 或空间元素变换后，Vision Pro 发布新 snapshot。
7. iPhone 保留 AR session，只替换共享根节点下的演示内容。

素材清单只在 `PresentationModel.version` 变化，也就是更换或重载演示包时重建。
普通翻页不会重新扫描和哈希全部文件。

## 真机测试

1. 在 Xcode 打开 `Spatial Slides.xcodeproj`，部署到 Vision Pro。
2. 在另一个 Xcode 窗口打开 `Spatial Camera/Spatial Camera.xcodeproj`，
   部署到 iPhone。
3. 两台设备连接同一 Wi-Fi，并允许“本地网络”和“相机”权限。
4. 先启动 Spatial Slides 并进入演示，再启动 Spatial Camera。
5. Vision Pro 状态显示已连接后，抓住青色箭头，把它放到一个双方都容易指认的
   物理位置，并让箭头沿桌边、地砖缝或其他明确方向。
6. iPhone 对准同一位置，第一次点球心，第二次点箭头方向上的一点。
7. 确认 iPhone 状态变为“空间已对齐”，走动观察内容是否锁定在房间中。
8. 点红色录制键。控制栏会自动隐藏；录制中点一下画面可重新显示停止键。
9. 首次停止录制时允许添加到照片，检查视频和麦克风音轨。

## 验收记录

- 2026-07-23：Vision Pro 与 iPhone 真机测试通过。Nearby 发现与连接、
  双端箭头标定、Spatial Slides 页面重建和第三视角显示均可正常工作。
- 当前提交是第一个可用的跨设备 Spatial Slides 第三视角基线。

## 已知边界

- 目前同步静态 slide 图、文本/数值面板、柱状图、散点和 USDZ。HTML 内部
  DOM 动画尚未跨端复现；motion mode 只同步状态标记。
- 当前 iPhone 自动连接发现到的第一个 Spatial Slides。多演示选择器待实现。
- 本地传输尚未加入配对码或 TLS，只适合可信局域网测试。
- 大素材使用 JSON `Data` 传输，尚未做二进制分块、压缩和断点续传。
- Vision 端运行时拖动过的 deck 主面板、轮盘和讲稿板不属于观众场景。
- ReplayKit 在新 SDK 中已标记弃用。当前版本用于先完成可用录制闭环，
  后续应迁移到 ScreenCaptureKit，并验证应用内 AR 画面和麦克风的输出策略。
- SharePlay 尚未接入。它适合远程参与和邀请，但同房间第三视角优先使用
  无账号门槛的 Nearby 连接。

## 后续阶段

### P2 真机验收与修正（已通过基础验收）

- [x] 双端连接、手动标定和页面同步基础链路。
- [ ] 断线重连、重复标定和长时间连续翻页压力测试。
- [ ] PNG/USDZ 首次加载延迟和缓存命中测试。
- [ ] 标定误差、漂移以及横竖屏行为测试。
- [ ] 录制视频中的控制 UI、音轨和长时间稳定性测试。

### P3 视觉保真

- 复用 Spatial Slides 的元素材质和布局规则，而不是 iPhone 端近似重绘。
- 同步运行时 deck/entity 变换。
- 为可复现的 HTML build 动画定义语义动画事件。

### P4 通用 Spatial Camera

- Bonjour 会话列表和手动选择。
- 把 `slidesSnapshot` 扩展为可注册的 scene adapter，而不是继续堆积 case。
- 为 SpatialPen、Spatial Memo 等应用提供各自 adapter，共享连接、标定、
  缓存和录制壳。
- 加入配对码、会话 token、TLS 和素材大小限制。

### P5 发布质量

- ScreenCaptureKit 录制和完整的中断恢复。
- 二进制素材流、分块、取消、缓存清理和容量上限。
- 网络与渲染性能埋点。
- 多设备和不同 Apple Account 的 SharePlay 验收。
