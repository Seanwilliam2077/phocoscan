import SwiftUI

struct CommunityView: View {
    @EnvironmentObject private var store: GameStore
    let explore: () -> Void
    @State private var detail: IDSelection?
    @State private var showCelebration = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    community
                    inventory
                    story
                    residents
                    Panel {
                        HStack { Image(systemName: "party.popper.fill").foregroundStyle(Palette.apricot); Text("开站庆典").font(.title3.bold()) }
                        Text(store.state.chapterCelebrated ? "小站已经迎来第一次庆典。你可以继续收集风景，也可以把现有的世界布置得更喜欢。" : "收下前两封风景，完成一个安静午后，再让至少两位居民满意，就能一起庆祝。")
                            .font(.subheadline).foregroundStyle(Palette.muted)
                        PrimaryAction(title: store.state.chapterCelebrated ? "查看纪念卡" : "邀请居民来庆祝", symbol: "sparkles", disabled: !store.state.chapterCelebrated && !GameRules.canCelebrate(store.state)) {
                            store.celebrate(); showCelebration = true
                        }
                    }
                }.padding(20)
            }.background(Palette.cream)
                .navigationBarHidden(true)
                .sheet(item: $detail) { item in NavigationStack { CardDetailView(cardId: item.id) } }
                .sheet(isPresented: $showCelebration) { CelebrationView() }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { StatusPill(text: store.state.theme, symbol: "sun.max.fill"); Spacer(); Text("VOL. 01").font(.caption.monospaced().bold()).foregroundStyle(Palette.muted) }
            Text(store.state.townName).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
            Text(store.state.completedQuests.isEmpty ? "阿灯在等一盏暖灯，你想从哪里开始？" : "今天，也给喜欢的风景留一个位置。")
                .font(.subheadline).foregroundStyle(Palette.muted)
            HStack(spacing: 5) {
                ForEach(0..<8) { stage in Capsule().fill(stage <= store.progress ? Palette.forest : Palette.forest.opacity(0.12)).frame(height: 5) }
            }
        }.padding(.top, 10)
    }
    private var community: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "九格，装下喜欢的日常", caption: "点击卡片来布置")
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(0..<9) { index in
                    Button {
                        if store.selectedCardID != nil { store.placeSelected(at: index) }
                        else if let card = GameRules.card(at: index, in: store.state) { store.selectedCardID = card.id }
                    } label: {
                        ZStack {
                            if let card = GameRules.card(at: index, in: store.state) {
                                CardArt(card: card, compact: true)
                                VStack { Spacer(); if card.kind != .road { Text(card.kind.title).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink).padding(.bottom, 7) } }
                            } else {
                                RoundedRectangle(cornerRadius: 14).fill(Palette.forest.opacity(0.045))
                                Image(systemName: store.selectedCardID == nil ? "plus" : "arrow.down.circle.fill").foregroundStyle(Palette.forest.opacity(0.35)).font(.title2)
                            }
                        }.aspectRatio(1, contentMode: .fit)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(store.state.grid[index] == store.selectedCardID && store.selectedCardID != nil ? Palette.forest : .clear, lineWidth: 3))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("第 \(index + 1) 格，\(GameRules.card(at: index, in: store.state)?.kind.title ?? "空地")")
                }
            }.padding(10).background(Palette.paper, in: RoundedRectangle(cornerRadius: 23))
            if let selected = store.card(store.selectedCardID) {
                Panel {
                    HStack { Text(selected.kind.title).font(.headline); Spacer(); Button("取消") { store.selectedCardID = nil } }
                    Text("再点一个格子放置。已有卡片会互换位置。").font(.caption).foregroundStyle(Palette.muted)
                    HStack {
                        Button { store.rotate(selected.id) } label: { Label("旋转", systemImage: "rotate.right") }
                        Spacer()
                        Button { detail = IDSelection(id: selected.id) } label: { Label("详情", systemImage: "postage.stamp") }
                        Spacer()
                        Button { store.removeFromGrid(selected.id) } label: { Label("收回", systemImage: "tray.and.arrow.down") }
                    }.font(.subheadline)
                    if selected.kind == .road {
                        Picker("道路形状", selection: Binding(get: { store.card(selected.id)?.roadShape ?? .cross }, set: { store.changeRoad(selected.id, shape: $0) })) {
                            ForEach(RoadShape.allCases) { shape in Text(shape.title).tag(shape) }
                        }.pickerStyle(.segmented)
                    }
                }
            }
        }
    }
    private var inventory: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "风景背包", caption: "\(store.availableCards.count) 张待放置")
            if store.availableCards.isEmpty {
                Text("卡片都住进小站了。去收一封新的风景，或点击已有卡片换个位置。")
                    .font(.subheadline).foregroundStyle(Palette.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.availableCards) { card in
                            Button { store.selectedCardID = card.id } label: {
                                VStack(spacing: 7) { CardArt(card: card, compact: true).frame(width: 82, height: 74); Text(card.kind.title).font(.caption).foregroundStyle(Palette.ink) }
                                    .padding(5).background(store.selectedCardID == card.id ? Palette.apricot.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Button(action: explore) { Label("去日常里找一封风景", systemImage: "camera.macro") }.font(.subheadline.weight(.semibold))
        }
    }
    private var story: some View {
        Panel {
            HStack { Image(systemName: "cup.and.saucer.fill").foregroundStyle(Palette.apricot); Text("一个安静午后").font(.title3.bold()) }
            Text("小禾画了一张阿灯的肖像。今天不用拍摄，挪一挪卡片，看看居民喜欢什么位置。")
                .font(.subheadline).foregroundStyle(Palette.muted)
            if store.state.pureBuildCompleted {
                Label("故事已收下 · 绿地在背包里", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Palette.forest)
            } else {
                Button("读完故事，收下小禾的绿地") { store.completePureBuild() }
                    .disabled(!store.state.completedQuests.contains("first_light"))
                if !store.state.completedQuests.contains("first_light") { Text("完成「第一盏暖灯」后开放").font(.caption).foregroundStyle(Palette.muted) }
            }
            if store.state.pureBuildCompleted {
                Divider()
                Text("下一步，你想把小站变成？").font(.subheadline.weight(.semibold))
                HStack {
                    ForEach(["花园步道", "周末集市"], id: \.self) { branch in
                        Button { store.chooseBranch(branch) } label: { Label(branch, systemImage: store.state.branch == branch ? "checkmark.circle.fill" : "circle").font(.subheadline) }
                        if branch == "花园步道" { Spacer() }
                    }
                }
            }
        }
    }
    private var residents: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "小站里的朋友", caption: "\(store.wishes.filter(\.satisfied).count) / 3 个小心愿")
            ForEach(store.wishes) { resident in
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: resident.symbol).font(.title2).frame(width: 47, height: 47).background(Palette.apricot.opacity(0.3), in: Circle()).foregroundStyle(Palette.forest)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(resident.name).font(.headline); if resident.satisfied { Image(systemName: "heart.fill").foregroundStyle(.pink.opacity(0.65)).font(.caption) } }
                        Text(resident.feedback).font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                }.padding(16).background(Palette.paper, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }
}

struct CelebrationView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    @State private var shareImage: Image?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "party.popper.fill").font(.system(size: 62)).foregroundStyle(Palette.apricot).padding(.top)
                    Text("小站，开门了！").font(.largeTitle.bold()).foregroundStyle(Palette.forest)
                    Text("阿灯送来了第一封信，小禾画下了这个下午。\n这些日常的一角，组成了你的小小世界。")
                        .multilineTextAlignment(.center).foregroundStyle(Palette.muted)
                    VirtualPostcard(state: store.state)
                    if let shareImage {
                        ShareLink(item: shareImage, preview: SharePreview("我的口袋小站", image: shareImage)) { Label("分享虚拟社区纪念卡", systemImage: "square.and.arrow.up") }
                    }
                    Text("分享卡只包含虚拟社区，不包含现场影像、地址或扫描文件。").font(.caption).foregroundStyle(Palette.muted)
                    Panel {
                        Text("下一章，听你的").font(.title3.bold())
                        ForEach(["接待新的旅人", "扩建花园", "开一家小店"], id: \.self) { next in
                            Button { store.chooseNextChapter(next) } label: {
                                HStack { Text(next); Spacer(); Image(systemName: store.state.nextChapter == next ? "checkmark.circle.fill" : "arrow.up.right") }.padding(.vertical, 8)
                            }
                        }
                        if store.state.nextChapter != nil { Text("方向已记下。当前可继续现有探索与布置，后续内容将在试玩后制作。").font(.caption).foregroundStyle(Palette.muted) }
                    }
                }.padding(24)
            }.background(Palette.cream)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .task {
                    let renderer = ImageRenderer(content: VirtualPostcard(state: store.state).frame(width: 360).padding(24).background(Palette.cream))
                    renderer.scale = 2
                    if let image = renderer.uiImage { shareImage = Image(uiImage: image) }
                }
        }
    }
}

struct VirtualPostcard: View {
    let state: GameSnapshot
    var body: some View {
        VStack(spacing: 16) {
            Text("POCKET WORLD / 口袋世界").font(.caption.monospaced().bold()).foregroundStyle(Palette.muted)
            Text(state.townName).font(.title2.bold()).foregroundStyle(Palette.forest)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                ForEach(0..<9) { index in
                    if let card = GameRules.card(at: index, in: state) {
                        // No photos or session identifiers in the share image.
                        CardArt(card: WorldCard(id: card.id, kind: card.kind, roadShape: card.roadShape, rotation: card.rotation), compact: true).aspectRatio(1, contentMode: .fit)
                    } else { RoundedRectangle(cornerRadius: 12).fill(Palette.forest.opacity(0.04)).aspectRatio(1, contentMode: .fit) }
                }
            }
            Text("把喜欢的日常，慢慢收好。").font(.caption).foregroundStyle(Palette.muted)
        }.padding(20).background(Palette.paper, in: RoundedRectangle(cornerRadius: 24))
    }
}
