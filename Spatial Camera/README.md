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

完整架构、限制和验收清单见
`../docs/SPATIAL_CAMERA_BRIDGE.md`。
