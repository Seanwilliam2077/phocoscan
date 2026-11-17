import SwiftUI
import UIKit

/// Black + purple design tokens. Purple is the only brand color; green, amber
/// and red appear only as small status indicators.
enum Theme {
    static let background = Color.black
    static let surface = Color(red: 0.075, green: 0.071, blue: 0.094)      // #131218
    static let surfaceHigh = Color(red: 0.122, green: 0.114, blue: 0.157)  // #1F1D28
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let accent = Color(red: 0.545, green: 0.361, blue: 0.965)       // #8B5CF6
    static let accentStart = Color(red: 0.486, green: 0.227, blue: 0.929)  // #7C3AED
    static let accentEnd = Color(red: 0.753, green: 0.518, blue: 0.988)    // #C084FC
    static let accentSoft = Color(red: 0.769, green: 0.710, blue: 0.992)   // #C4B5FD
    static let success = Color(red: 0.25, green: 0.84, blue: 0.62)
    static let warning = Color(red: 1.0, green: 0.70, blue: 0.20)
    static let danger = Color(red: 1.0, green: 0.30, blue: 0.37)
    static let record = Color(red: 1.0, green: 0.27, blue: 0.34)
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentStart, Color(red: 0.659, green: 0.333, blue: 0.969)], // → #A855F7
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// Legacy names kept for the historical prototype views; mapped onto the dark theme.
enum Palette {
    static let cream = Theme.background
    static let paper = Theme.surface
    static let forest = Theme.accent
    static let apricot = Color(red: 0.95, green: 0.72, blue: 0.48)
    static let ink = Theme.text
    static let muted = Theme.secondary
}

/// In-app version of the phocoscan logo: the app icon's ring and anchor dot.
struct BrandMark: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).fill(Theme.accentStart)
            Circle()
                .stroke(.white, lineWidth: size * 0.055)
                .frame(width: size * 0.586, height: size * 0.586)
            Circle().fill(.white).frame(width: size * 0.121, height: size * 0.121)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The look of the primary action, reusable as a `ShareLink`/`Link` label.
struct GradientLabel: View {
    let title: String
    var symbol: String?
    var isEnabled = true
    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.5))
        .frame(maxWidth: .infinity, minHeight: 54)
        .background {
            if isEnabled { Capsule().fill(Theme.accentGradient) }
            else { Capsule().fill(Theme.surfaceHigh) }
        }
    }
}

/// Full-width gradient call to action.
struct GradientButton: View {
    let title: String
    var symbol: String?
    var isEnabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            GradientLabel(title: title, symbol: symbol, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// User-given scan names, stored locally (never sent to the server).
@MainActor
final class ScanNameStore: ObservableObject {
    static let shared = ScanNameStore()
    private static let key = "PocketWorld.scanNames"
    private static let numbersKey = "PocketWorld.scanNumbers"
    private let defaults: UserDefaults
    /// Names the user typed. Optional: every scan also has an automatic number.
    @Published private(set) var names: [String: String]
    /// Automatic sequence numbers, given oldest first and never reused or changed.
    @Published private(set) var numbers: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        numbers = defaults.dictionary(forKey: Self.numbersKey) as? [String: Int] ?? [:]
    }

    /// The custom name, else 「扫描 07」 from the scan's number.
    func displayName(for captureID: String) -> String {
        names[captureID] ?? numbers[captureID].map(Self.autoName) ?? "扫描"
    }

    func customName(for captureID: String) -> String? { names[captureID] }

    static func autoName(_ number: Int) -> String { String(format: "扫描 %02d", number) }

    /// Numbers every scan that has none yet, continuing after the highest number given
    /// so far (a deleted scan's number is not handed out again).
    func assignNumbers(oldestFirst captureIDs: [String]) {
        var next = (numbers.values.max() ?? 0) + 1
        var changed = false
        for id in captureIDs where numbers[id] == nil {
            numbers[id] = next
            next += 1
            changed = true
        }
        if changed { defaults.set(numbers, forKey: Self.numbersKey) }
    }

    /// An empty name clears the custom name, so the automatic one shows again.
    func setName(_ name: String, for captureID: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        names[captureID] = trimmed.isEmpty ? nil : trimmed
        defaults.set(names, forKey: Self.key)
    }
}

/// Secondary pill button on dark surfaces.
struct GhostButton: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.text
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(tint)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .background(Theme.surfaceHigh, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Round translucent icon button used over camera and 3D content.
struct GlassIconButton: View {
    let symbol: String
    var label: String
    var size: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Small colored status capsule: a dot plus a short label.
struct StatusBadge: View {
    let text: String
    let color: Color
    var pulsing = false
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color, pulsing: pulsing)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }
}

/// A 7-pt status dot. Pulsing animates only its opacity: a repeat-forever animation
/// attached with `.animation(_:value:)` also animated layout changes, which left the
/// dot drifting outside its badge once the text next to it changed.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .phaseAnimator(pulsing ? [1.0, 0.35] : [1.0]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.8) }
    }
}

/// Dark rounded card container.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    let content: Content
    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }
}

struct Panel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct PrimaryAction: View {
    let title: String
    var symbol: String = "arrow.right"
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { Text(title).fontWeight(.semibold); Spacer(); Image(systemName: symbol) }
                .padding(.horizontal, 18).padding(.vertical, 15)
                .foregroundStyle(.white)
                .background(disabled ? Palette.muted : Palette.forest, in: RoundedRectangle(cornerRadius: 16))
        }.disabled(disabled)
    }
}

struct SectionTitle: View {
    let title: String
    var caption: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(Palette.ink)
            Spacer()
            if let caption { Text(caption).font(.caption).foregroundStyle(Palette.muted) }
        }
    }
}

struct StatusPill: View {
    let text: String
    var symbol: String = "sparkle"
    var body: some View {
        Label(text, systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(Palette.forest).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.forest.opacity(0.08), in: Capsule())
    }
}

struct RoadDrawing: View {
    let card: WorldCard
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            Path { path in
                for direction in card.connectors {
                    path.move(to: center)
                    switch direction {
                    case 0: path.addLine(to: CGPoint(x: center.x, y: 0))
                    case 1: path.addLine(to: CGPoint(x: geometry.size.width, y: center.y))
                    case 2: path.addLine(to: CGPoint(x: center.x, y: geometry.size.height))
                    default: path.addLine(to: CGPoint(x: 0, y: center.y))
                    }
                }
            }.stroke(Color(red: 0.85, green: 0.73, blue: 0.53), style: StrokeStyle(lineWidth: 16, lineCap: .round))
            Path { path in
                for direction in card.connectors {
                    path.move(to: center)
                    let destination: CGPoint
                    switch direction {
                    case 0: destination = CGPoint(x: center.x, y: 0)
                    case 1: destination = CGPoint(x: geometry.size.width, y: center.y)
                    case 2: destination = CGPoint(x: center.x, y: geometry.size.height)
                    default: destination = CGPoint(x: 0, y: center.y)
                    }
                    path.addLine(to: destination)
                }
            }.stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
        }
    }
}

struct CardArt: View {
    let card: WorldCard
    var compact = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 14 : 20).fill(card.kind.color.opacity(0.13))
            if card.kind == .road {
                RoadDrawing(card: card).padding(8)
            } else {
                VStack(spacing: compact ? 5 : 12) {
                    Image(systemName: card.kind.symbol).font(.system(size: compact ? 26 : 48, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                    if !compact { Text(card.kind.title).font(.headline) }
                }.foregroundStyle(card.kind.color)
            }
            if card.sessionId != nil {
                VStack { HStack { Spacer(); Image(systemName: "camera.fill").font(.system(size: 9)).padding(5).background(.white.opacity(0.8), in: Circle()) }; Spacer() }.padding(6)
            }
        }
    }
}

struct IDSelection: Identifiable { let id: String }
struct URLSelection: Identifiable { let id = UUID(); let url: URL }

/// Cover images rendered on this phone from a scan's 3D result (JPEG, local only).
@MainActor
final class ScanPosterStore: ObservableObject {
    static let shared = ScanPosterStore()
    /// Bumped whenever a scan's cover changes, so thumbnails reload.
    @Published private(set) var versions: [String: Int] = [:]

    private var directory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent("ScanPosters", isDirectory: true)
    }

    func posterURL(for captureID: String) -> URL? {
        guard UUID(uuidString: captureID) != nil, let directory else { return nil }
        return directory.appendingPathComponent(captureID.lowercased() + ".jpg")
    }

    func hasPoster(for captureID: String) -> Bool {
        posterURL(for: captureID).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func save(_ image: CGImage, captureID: String) {
        guard let url = posterURL(for: captureID), let directory else { return }
        let ui = UIImage(cgImage: image)
        Task.detached(priority: .utility) {
            guard let data = ui.jpegData(compressionQuality: 0.85) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            await MainActor.run { self.versions[captureID, default: 0] += 1 }
        }
    }
}
