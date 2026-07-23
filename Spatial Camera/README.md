# Spatial Camera

Spatial Camera 是 Spatial Slides 的独立 iPhone 第三视角应用。它通过相机显示
真实房间，并在标定后的物理位置重建 Vision Pro 当前正在演示的空间内容。

## 在 Xcode 中运行

1. 打开 `Spatial Camera.xcodeproj`。
2. 选择 `Spatial Camera` scheme。
3. 在 Signing & Capabilities 中确认 Team 是你的开发者团队。
4. 用数据线或已配对的无线连接选择真实 iPhone。
5. 点击 Run，并允许相机、本地网络、麦克风和照片权限。

iOS Simulator 可以用于编译和普通 UI 检查，但不能代替 ARKit 真机验收。

## 标定

Vision Pro 与 iPhone 必须使用同一个物理原点和同一个水平方向：

1. Vision Pro 用户移动青色箭头到双方都能确认的位置。
2. iPhone 第一次点按箭头原点。
3. iPhone 第二次点按箭头指向上至少 8 cm 外的位置。
4. 状态显示“空间已对齐”后，普通点按不会修改标定；使用左下角准星按钮重来。

## P3 真机复测

1. 连接后停留几秒，让 USDZ 在后台传输并预解析；首次打开模型页时不应重新长时间等待。
2. 移动、旋转或缩放 Vision Pro 中的 USDZ，确认 iPhone 只更新位置，不闪回占位模型。
3. 确认 `float`、`spin`、`breathe` 等循环动画在 iPhone 第三视角中持续运行。
4. 离开模型页再返回，确认模型从内容哈希缓存和内存模板快速恢复。
5. 关闭并重开 Vision Pro 应用，确认 iPhone 自动重新发现并继续同步。
6. 在 iOS 27 上录制并停止，确认视频完成封装后成功保存到照片。
7. 在 Vision Pro 打开“摆放空间元素”，连续移动、旋转和缩放主 Slides 面板；
   iPhone 中的面板应实时跟随，松手后位置应完全一致。
8. 让一位真人站到 iPhone 与 Slides 之间并与面板重叠；相机预览和最终录像中，
   真人身体应遮住后方的 Slides。快速挥手和头发边缘允许有轻微分割误差。

协议 v3 要求 Vision Pro 与 iPhone 两端同时安装本版本；旧版任一端都会显示
“协议版本不兼容”。

完整架构、限制和验收清单见
`../docs/SPATIAL_CAMERA_BRIDGE.md`。
