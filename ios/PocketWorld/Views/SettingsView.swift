import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: GameStore
    @State private var endpoint = ""
    @State private var name = ""
    @State private var theme = ""
    @State private var showNotices = false
    var body: some View {
        NavigationStack {
            Form {
                Section("小站") {
                    TextField("小站名字", text: $name)
                    Picker("小站气氛", selection: $theme) { ForEach(["花园小站", "热闹街坊", "安静旅店"], id: \.self) { Text($0).tag($0) } }
                    Button("保存小站偏好") { store.finishOnboarding(name: name, theme: theme); store.statusMessage = "小站换上了你喜欢的名字与气氛。" }
                }
                Section {
                    TextField("https://your-server.example", text: $endpoint)
                        .keyboardType(.URL).textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Label(store.connectionLabel, systemImage: "network").font(.footnote)
                    Button(store.isBusy ? "正在连接…" : "连接测试服务器") { Task { await store.configureServer(endpoint) } }.disabled(store.isBusy)
                    if let id = store.api.auth?.userId { LabeledContent("测试用户", value: String(id.prefix(8))).font(.caption) }
                } header: { Text("测试连接") } footer: {
                    Text("填写电脑上运行的服务地址。iPhone 上的 localhost 指手机自己；局域网测试应填电脑 IP，并让两台设备连接同一 Wi-Fi。更换服务器地址会切换到独立本地存档，原存档仍保留。Debug 支持局域网 HTTP，发布版本要求 HTTPS。")
                }
                Section("数据与本次试验") {
                    Label("默认不采集音频与定位", systemImage: "mic.slash")
                    Label("录像与风景结果默认私有", systemImage: "lock.fill")
                    Text("游戏内采集：保存原始视频，当前没有可靠逐帧位姿。\n外部扫描：只导入模型时，来源记为 external_asset_only。\n能展示 3DGS 不代表已经具备机器人碰撞网格或训练数据质量。")
                        .font(.footnote).foregroundStyle(Palette.muted)
                    Text("在「风景邮袋」打开任一探索，可删除该次原始影像与模型。建设卡会保留为虚拟卡。")
                        .font(.footnote)
                    Button("同步任务与研究事件") { Task { await store.refresh() } }.disabled(store.isBusy)
                    LabeledContent("待同步事件", value: "\(store.state.events.count)").font(.footnote)
                }
                Section("关于") {
                    LabeledContent("口袋世界", value: "MVP 0.1.0")
                    Text("为三位旅人，收集日常的一角。内容按进度开放，没有七天等待锁。")
                    Button("开源许可与致谢") { showNotices = true }
                }
            }.scrollContentBackground(.hidden).background(Palette.cream).navigationTitle("小站设置")
                .onAppear { endpoint = store.serverURL; name = store.state.townName; theme = store.state.theme }
                .sheet(isPresented: $showNotices) {
                    NavigationStack {
                        ScrollView { Text(acknowledgments).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding() }
                            .navigationTitle("开源许可").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showNotices = false } } }
                    }
                }
        }
    }
    private var acknowledgments: String {
        guard let url = Bundle.main.url(forResource: "Acknowledgments", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "MetalSplatter — scier — MIT License. Full license is provided with this project in docs/THIRD-PARTY-NOTICES.md."
        }
        return text
    }
}
