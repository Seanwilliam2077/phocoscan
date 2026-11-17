import SwiftUI

struct ExploreView: View {
    @EnvironmentObject private var store: GameStore
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("风景就在日常里").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                    Text("一处室内角落，或几步之外的街景。\n一次只收集一小片，给它一个小站里的位置。")
                        .foregroundStyle(Palette.muted).lineSpacing(4)
                    Panel {
                        Label("一封风景，三枚邮戳", systemImage: "postage.stamp.fill").font(.headline).foregroundStyle(Palette.forest)
                        Text("先稳稳看正面，再缓慢侧移，最后补一点地面与边缘。前后画面保留共同参照。")
                            .font(.subheadline).foregroundStyle(Palette.muted)
                        Text("邮戳是拍摄提示，不代表质量已通过。请在安全、获准拍摄的位置完成。")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                    ForEach(store.quests) { quest in
                        let unlocked = store.isUnlocked(quest)
                        NavigationLink {
                            QuestDetailView(quest: quest)
                        } label: {
                            HStack(alignment: .top, spacing: 15) {
                                Image(systemName: quest.cardKind.symbol).font(.system(size: 27)).foregroundStyle(quest.cardKind.color)
                                    .frame(width: 55, height: 60).background(quest.cardKind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { Text(quest.title).font(.headline).foregroundStyle(Palette.ink); Spacer(); Image(systemName: unlocked ? "arrow.up.right" : "lock.fill").font(.caption).foregroundStyle(Palette.muted) }
                                    Text(quest.npc).font(.caption).foregroundStyle(Palette.muted)
                                    Text(quest.subtitle).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(3)
                                    if store.state.completedQuests.contains(quest.id) { StatusPill(text: "已收藏 · 可探索新地点", symbol: "checkmark") }
                                    else if !unlocked { Text("先完成：\(quest.unlockAfter.compactMap { store.quest($0)?.title }.joined(separator: "、"))").font(.caption).foregroundStyle(Palette.muted) }
                                }
                            }.padding(18).background(Palette.paper, in: RoundedRectangle(cornerRadius: 22)).opacity(unlocked ? 1 : 0.65)
                        }.disabled(!unlocked).buttonStyle(.plain)
                    }
                    if store.quests.isEmpty { Text("任务暂时未加载，请重新打开或联系测试管理员。").foregroundStyle(.red) }
                    Text("不需要连续打卡，也不需要一次扫完整栋楼。今天只想布置小站，随时可以回去。")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }.padding(20)
            }.background(Palette.cream).navigationBarHidden(true)
        }
    }
}

struct QuestDetailView: View {
    @EnvironmentObject private var store: GameStore
    let quest: Quest
    @State private var environment = "indoor"
    @State private var mode = "in_app_rgb"
    @State private var consent = false
    @State private var destination: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CardArt(card: WorldCard(id: "quest", kind: quest.cardKind)).frame(height: 180)
                Text(quest.npc).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                Text(quest.title).font(.largeTitle.bold()).foregroundStyle(Palette.ink)
                Text(quest.subtitle).foregroundStyle(Palette.muted).lineSpacing(4)
                Panel {
                    Text("选一处你方便到达的地方").font(.headline)
                    Picker("探索环境", selection: $environment) { Text("室内一角").tag("indoor"); Text("室外街角").tag("outdoor") }.pickerStyle(.segmented)
                    Text(environment == "indoor" ? quest.indoorTip : quest.outdoorTip).font(.subheadline).foregroundStyle(Palette.muted)
                }
                Panel {
                    Text("这次怎样收集？").font(.headline)
                    Picker("采集方式", selection: $mode) { Text("游戏内录像").tag("in_app_rgb"); Text("外部扫描导入").tag("external_app") }.pickerStyle(.segmented)
                    Text(mode == "in_app_rgb" ? "拍摄真实视频并保存在手机上。提交后由测试操作员用兼容工具重建，结果再寄回游戏。当前版本不采集相机轨迹。" : "先保存任务，再手动切换 Scaniverse 采集与重建。导出 Gaussian PLY 或 .splat 到「文件」，回来导入。只导入模型时不包含原始视频或轨迹。")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                }
                Panel {
                    Toggle(isOn: $consent) {
                        Text("我有权拍摄这处场景，同意将本次影像用于此 MVP 的重建与研究验证。").font(.subheadline)
                    }
                    Text("避开人脸、门牌、私人文件与屏幕；可随时从探索记录删除影像与结果。首版不采集音频或定位。机器人与视频模型的数据可用性仍需独立审核。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                PrimaryAction(title: store.isBusy ? "正在准备探索…" : "保存任务，出发", symbol: "arrow.up.right", disabled: !consent || store.isBusy) {
                    Task { destination = await store.startSession(questId: quest.id, environment: environment, mode: mode) }
                }
            }.padding(20)
        }.background(Palette.cream)
            .navigationTitle("一封新的风景").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $destination) { id in SessionDetailView(sessionId: id) }
    }
}
