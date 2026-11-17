import Foundation

struct ResidentWish: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let wish: String
    let satisfied: Bool
    let feedback: String
}

enum GameRules {
    static func card(at index: Int, in state: GameSnapshot) -> WorldCard? {
        guard state.grid.indices.contains(index), let id = state.grid[index] else { return nil }
        return state.cards.first { $0.id == id }
    }
    static func neighbor(of index: Int, direction: Int) -> Int? {
        guard (0..<9).contains(index) else { return nil }
        switch direction {
        case 0: return index >= 3 ? index - 3 : nil
        case 1: return index % 3 < 2 ? index + 1 : nil
        case 2: return index < 6 ? index + 3 : nil
        case 3: return index % 3 > 0 ? index - 1 : nil
        default: return nil
        }
    }
    static func positions(_ kind: CardKind, in state: GameSnapshot) -> [Int] {
        (0..<9).filter { card(at: $0, in: state)?.kind == kind }
    }
    // Buildings are destinations. They never serve as invisible roads for paths through the town.
    static func connectedFromEntrance(to target: CardKind, in state: GameSnapshot) -> Bool {
        guard let entrance = positions(.entrance, in: state).first else { return false }
        var visited: Set<Int> = [entrance]
        var queue = [entrance]
        while !queue.isEmpty {
            let index = queue.removeFirst()
            guard let current = card(at: index, in: state) else { continue }
            for direction in current.connectors {
                guard let otherIndex = neighbor(of: index, direction: direction),
                      let other = card(at: otherIndex, in: state),
                      other.connectors.contains((direction + 2) % 4) else { continue }
                if other.kind == target { return true }
                if other.kind == .road, !visited.contains(otherIndex) {
                    visited.insert(otherIndex); queue.append(otherIndex)
                }
            }
        }
        return false
    }
    static func adjacent(_ a: CardKind, _ b: CardKind, in state: GameSnapshot) -> Bool {
        positions(a, in: state).contains { index in
            (0..<4).contains { direction in
                guard let next = neighbor(of: index, direction: direction) else { return false }
                return card(at: next, in: state)?.kind == b
            }
        }
    }
    static func distance(_ first: Int, _ second: Int) -> Int { abs(first / 3 - second / 3) + abs(first % 3 - second % 3) }
    static func wishes(in state: GameSnapshot) -> [ResidentWish] {
        let postal = connectedFromEntrance(to: .post, in: state) && connectedFromEntrance(to: .rest, in: state)
        let painter = adjacent(.rest, .green, in: state) && !adjacent(.rest, .stall, in: state)
        let vendor = positions(.stall, in: state).contains { stall in
            positions(.entrance, in: state).contains { distance(stall, $0) <= 2 }
        }
        return [
            ResidentWish(id: "postman", name: "阿灯", symbol: "envelope.badge.fill", wish: "入口连到邮局与休息区", satisfied: postal, feedback: postal ? "信和好心情，都能顺路送到。" : "转转路卡，让入口通到邮局和休息区吧。"),
            ResidentWish(id: "painter", name: "小禾", symbol: "paintpalette.fill", wish: "休息区挨着绿地，远离小摊", satisfied: painter, feedback: painter ? "这个位置太适合画画了。" : "我想坐在绿地旁，和小摊隔开一点。"),
            ResidentWish(id: "gardener", name: "阿栗", symbol: "carrot.fill", wish: "小摊距入口不超过两格", satisfied: vendor, feedback: vendor ? "新来的旅人一眼就能看见我！" : "把小摊放到入口附近，方便打招呼。")
        ]
    }
    static func canCelebrate(_ state: GameSnapshot) -> Bool {
        state.completedQuests.contains("first_light") && state.completedQuests.contains("rest_stop") && state.pureBuildCompleted && wishes(in: state).filter(\.satisfied).count >= 2
    }
    static func validGrid(_ state: GameSnapshot) -> Bool {
        guard state.grid.count == 9 else { return false }
        let placed = state.grid.compactMap { $0 }
        return Set(placed).count == placed.count && placed.allSatisfy { id in state.cards.contains { $0.id == id } }
    }
}
