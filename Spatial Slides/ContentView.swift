//
//  ContentView.swift
//  Spatial Slides
//
//  The presenter's 2D remote: open a show, start / stop it, step pages, and toggle
//  editing of the near-field spatial elements. In-headset the carousel and the
//  glass control bar do the navigating; this is the flat companion.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(PresentationModel.self) private var presentation
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var showImporter = false
    @State private var openError: String?
    @State private var saveMessage: String?
    @State private var isDraggingModelScale = false

    private var isPresenting: Bool { appModel.immersiveSpaceState == .open }

    var body: some View {
        VStack(spacing: 22) {
            header
            presentButton
            openButton
            reloadBundledButton
            if presentation.hasContent {
                navigationControls
                stageControls
                editControls
            }
            Spacer(minLength: 0)
            hint
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(presentation.show.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(presentation.hasContent ? "第 \(presentation.counterText) 页 · \(presentation.currentTitle)" : "还没有打开演示")
                .font(.title3).foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
    }

    private var presentButton: some View {
        Button(action: toggleImmersiveSpace) {
            Label(isPresenting ? "结束演示" : "开始演示",
                  systemImage: isPresenting ? "stop.circle.fill" : "play.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.extraLarge).buttonStyle(.borderedProminent)
        .tint(isPresenting ? .red : .green)
        .disabled(appModel.immersiveSpaceState == .inTransition || !presentation.hasContent)
    }

    private var openButton: some View {
        Button { showImporter = true } label: {
            Label("打开演示包（.sslides）…", systemImage: "folder")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large).buttonStyle(.bordered)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder, .json],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if let show = DeckLoader.importPickedShow(at: url) {
                    presentation.replace(with: show); openError = nil
                } else {
                    openError = "无法读取所选文件夹（需要一个含 show.json 的 .sslides 包）。"
                }
            case .failure(let error):
                openError = error.localizedDescription
            }
        }
        .alert("打开失败", isPresented: .constant(openError != nil)) {
            Button("好", role: .cancel) { openError = nil }
        } message: { Text(openError ?? "") }
    }

    /// Force-loads the freshly BUNDLED package, bypassing (and discarding) whatever is
    /// cached in Documents/CurrentShow. `loadDefault` prefers CurrentShow, so after we
    /// bake a new show.json into the app, a stale imported copy would otherwise shadow
    /// it — this is the one-tap way to pick up the latest bundled deck on device.
    private var reloadBundledButton: some View {
        Button {
            if let show = DeckLoader.loadBundled() {
                presentation.replace(with: show); openError = nil
            } else {
                openError = "内置演示包读取失败（bundle 里没有 show.json）。"
            }
        } label: {
            Label("重载内置包（丢弃已导入/编辑）", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large).buttonStyle(.bordered).tint(.orange)
    }

    private var navigationControls: some View {
        HStack(spacing: 20) {
            Button { withAnimation(.snappy) { presentation.previous() } } label: {
                Label("上一页", systemImage: "chevron.left").frame(maxWidth: .infinity)
            }.disabled(!presentation.canGoPrevious)
            // #4: forward builds the page's remaining attention beats, then turns the page.
            Button { withAnimation(.snappy) { presentation.advance() } } label: {
                Label(presentation.beatsRemaining ? "下一拍 \(presentation.beatLabel)" : "下一页",
                      systemImage: presentation.beatsRemaining ? "arrow.forward.circle.fill" : "chevron.right")
                    .frame(maxWidth: .infinity)
            }.disabled(!presentation.canGoNext && !presentation.beatsRemaining)
                .tint(presentation.beatsRemaining ? .orange : nil)
        }
        .controlSize(.extraLarge).buttonStyle(.borderedProminent)
    }

    /// Stage-level controls: reposition the carousel, resize the current model,
    /// and toggle the immersive environment.
    private var stageControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.snappy) { presentation.carouselAdjust.toggle() }
                } label: {
                    Label(presentation.carouselAdjust ? "轮盘：调整中" : "调整轮盘",
                          systemImage: "dial.medium")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.bordered)
                .tint(presentation.carouselAdjust ? .orange : .gray)

                Button {
                    appModel.fullImmersion.toggle()
                } label: {
                    Label(appModel.fullImmersion ? "沉浸：开" : "沉浸环境",
                          systemImage: appModel.fullImmersion ? "mountain.2.fill" : "mountain.2")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.bordered)
                .tint(appModel.fullImmersion ? .teal : .gray)
            }

            Button {
                withAnimation(.snappy) { presentation.motionMode.toggle() }
            } label: {
                Label(presentation.motionMode ? "HTML 动效：开（保留幻灯动画，可能掉帧）" : "HTML 动效：关（静态 · 流畅）",
                      systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.bordered)
            .tint(presentation.motionMode ? .pink : .gray)

            if presentation.currentHasModel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "cube.fill").foregroundStyle(.blue)
                        Text(presentation.currentModelCount > 1 ? "3D 模型 ×\(presentation.currentModelCount)" : "本页 3D 模型")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(String(format: "%.2f×", Double(PresentationModel.scale(fromSlider: presentation.modelScaleSlider))))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "minus.magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                        Slider(value: Binding(get: { presentation.modelScaleSlider },
                                              set: { presentation.modelScaleSlider = $0 }),
                               in: 0...1) { editing in isDraggingModelScale = editing }
                        Image(systemName: "plus.magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(presentation.currentModelCount > 1
                         ? "拖滑块无级缩放「激活的」模型——头显里点一下某个模型即切换（也可直接双手捏合缩放）。"
                         : "拖滑块无级缩放，或在头显里双手捏合直接缩放。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .onChange(of: presentation.modelScaleSlider) { _, _ in
                    if isDraggingModelScale { presentation.applyModelScaleSlider() }
                }
            }

            if presentation.hasEnvironment {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "mountain.2.fill").foregroundStyle(.teal)
                        Text("3D 环境").font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { presentation.nudgeEnvScale(0.9) } label: { Image(systemName: "minus.magnifyingglass") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button { presentation.nudgeEnvScale(1.11) } label: { Image(systemName: "plus.magnifyingglass") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    HStack(spacing: 8) {
                        Text("位置").font(.caption).foregroundStyle(.tertiary)
                        Button { presentation.nudgeEnvHeight(0.15) } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button { presentation.nudgeEnvHeight(-0.15) } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button { presentation.nudgeEnvDepth(-0.2) } label: { Image(systemName: "arrow.up.forward") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button { presentation.nudgeEnvDepth(0.2) } label: { Image(systemName: "arrow.down.backward") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button { presentation.nudgeEnvYaw(.pi / 12) } label: { Image(systemName: "rotate.right") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Spacer(minLength: 0)
                    }
                    Text("先开「沉浸环境」，再调场景大小/高低/远近/转向；「保存」写回演示包。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }

            HStack(spacing: 10) {
                Image(systemName: "textformat.size").foregroundStyle(.teal)
                Text("讲稿字号").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { withAnimation(.snappy) { presentation.nudgeTranscriptScale(-0.1) } } label: {
                    Image(systemName: "textformat.size.smaller")
                }.buttonStyle(.bordered).controlSize(.small)
                Text("\(Int((presentation.transcriptScale * 100).rounded()))%")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 52).contentTransition(.numericText())
                Button { withAnimation(.snappy) { presentation.nudgeTranscriptScale(0.1) } } label: {
                    Image(systemName: "textformat.size.larger")
                }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.teal)
                Text("讲稿板").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { presentation.nudgeTranscriptBoardScale(0.9) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { presentation.nudgeTranscriptBoardScale(1.11) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { presentation.nudgeTranscriptBoardYaw(-.pi / 18) } label: { Image(systemName: "rotate.left") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { presentation.nudgeTranscriptBoardYaw(.pi / 18) } label: { Image(systemName: "rotate.right") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))

            // Right reference board (grammar §5) — only relevant on pages that carry asides,
            // where the board is actually shown in-headset.
            if presentation.currentHasAsides {
                HStack(spacing: 10) {
                    Image(systemName: "text.quote").foregroundStyle(Color(hex: "#5AC8FA"))
                    Text("参考板").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { presentation.nudgeAsideBoardScale(0.9) } label: { Image(systemName: "minus.magnifyingglass") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button { presentation.nudgeAsideBoardScale(1.11) } label: { Image(systemName: "plus.magnifyingglass") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button { presentation.nudgeAsideBoardYaw(.pi / 18) } label: { Image(systemName: "rotate.left") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button { presentation.nudgeAsideBoardYaw(-.pi / 18) } label: { Image(systemName: "rotate.right") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color(hex: "#5AC8FA").opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var editControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { withAnimation(.snappy) { presentation.setEditing(!presentation.isEditing) } } label: {
                    Label(presentation.isEditing ? "完成摆放" : "摆放空间元素",
                          systemImage: presentation.isEditing ? "checkmark.circle.fill" : "hand.draw.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .tint(presentation.isEditing ? .orange : .blue)

                Button { saveEdits() } label: {
                    Label("保存", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.bordered)
                .disabled(!presentation.hasUnsavedEdits)
            }

            if presentation.isEditing {
                HStack(spacing: 10) {
                    Image(systemName: "cube.transparent").foregroundStyle(.orange)
                    Text(presentation.currentElements.isEmpty
                         ? "本页没有空间元素"
                         : "在头显里拖动 / 转动本页的空间元素；点选后可复位")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("复位") {
                        if let id = presentation.selectedElementID {
                            withAnimation(.snappy) { presentation.resetTransform(elementID: id) }
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(presentation.selectedElementID == nil)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(.orange)
                    Text("主屏大小（可抓着移动主屏）").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { presentation.nudgeDeckScale(0.9) } label: { Image(systemName: "minus.magnifyingglass") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button { presentation.nudgeDeckScale(1.12) } label: { Image(systemName: "plus.magnifyingglass") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }

            if let saveMessage {
                Text(saveMessage).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var hint: some View {
        Text(presentation.hasContent
             ? "远处是完整 HTML 幻灯；正下方缩略图轮盘——看住捏住左右拖翻页，或点某张跳过去。「调整轮盘」开启后，抓正下方那根发光横杆把整个轮盘挪到顺手的位置（松手即停，退出后翻页照常）。近前浮着本页空间元素：3D 模型单手抓着移动/转动、双手捏合缩放（多个物体各缩各的），也可用上方缩放条无级缩放激活的那个。左侧同步讲稿板可拖顶部把手移动、用「讲稿字号 ±」调大小。"
             : "点「打开演示包」选择一个 .sslides 文件夹（由 spatial-authoring 的 spatialize 从一体版 HTML 生成）。")
            .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
    }

    private func saveEdits() {
        if let url = presentation.save() {
            saveMessage = "已保存到 \(url.lastPathComponent)"
        } else {
            saveMessage = "保存失败，请查看控制台日志。"
        }
    }

    private func toggleImmersiveSpace() {
        Task { @MainActor in
            switch appModel.immersiveSpaceState {
            case .open:
                appModel.immersiveSpaceState = .inTransition
                await dismissImmersiveSpace()
            case .closed:
                appModel.immersiveSpaceState = .inTransition
                switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
                case .opened: break
                case .userCancelled, .error: fallthrough
                @unknown default: appModel.immersiveSpaceState = .closed
                }
            case .inTransition: break
            }
        }
    }
}

#Preview(windowStyle: .plain) {
    ContentView()
        .environment(AppModel())
        .environment(PresentationModel())
}
