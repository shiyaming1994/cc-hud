import SwiftUI

/// 丝滑的行拖拽排序容器：被拖行实时跟手（拎起效果由调用方加），
/// 其余行在拖动过程中用 offset 弹簧让位——ForEach 顺序在拖动期间保持不变
/// （手势进行中改 ForEach 顺序会和活跃手势打架，让位只用 offset 模拟），
/// 松手才提交新顺序。行高逐行实测，支持不等高行。
struct ReorderableRows<Content: View>: View {
    let ids: [String]
    let enabled: Bool
    let onReorder: ([String]) -> Void
    @ViewBuilder let row: (String, Bool) -> Content

    @State private var heights: [String: CGFloat] = [:]
    @State private var draggingId: String? = nil
    @State private var startIndex = 0
    @State private var targetIndex = 0
    @State private var translation: CGFloat = 0
    /// 松手时冻结的最终顺序：在父级数据跟上之前按它渲染，
    /// 保证提交瞬间与父级刷新无论是否同帧都零跳变。
    @State private var committedOrder: [String]? = nil

    private var displayIds: [String] { committedOrder ?? ids }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayIds.enumerated()), id: \.element) { i, id in
                row(id, draggingId == id)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height },
                                      action: { heights[id] = $0 })
                    .offset(y: rowOffset(id, at: i))
                    .zIndex(draggingId == id ? 1 : 0)
                    .gesture(dragGesture(id), isEnabled: enabled && displayIds.count > 1)
            }
        }
        .onChange(of: ids) { _, _ in committedOrder = nil }   // 父级已按新顺序渲染，解除冻结
    }

    private func h(_ id: String) -> CGFloat { heights[id] ?? 28 }
    private func slotY(_ index: Int) -> CGFloat {
        displayIds.prefix(index).reduce(0) { $0 + h($1) }
    }

    /// 被拖行跟手；位于起点与目标槽之间的行平移一个被拖行的高度让位
    private func rowOffset(_ id: String, at i: Int) -> CGFloat {
        guard let did = draggingId else { return 0 }
        if id == did { return translation }
        let hD = h(did)
        if startIndex < targetIndex, i > startIndex, i <= targetIndex { return -hD }
        if targetIndex < startIndex, i >= targetIndex, i < startIndex { return hD }
        return 0
    }

    private func dragGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { v in
                if draggingId == nil {
                    draggingId = id
                    startIndex = displayIds.firstIndex(of: id) ?? 0
                    targetIndex = startIndex
                }
                guard draggingId == id else { return }
                // 夹紧：被拖行不能越出列表区（顶 = 第一行槽位，底 = 最后一行槽位）
                let totalH = displayIds.reduce(0) { $0 + h($1) }
                let minT = -slotY(startIndex)
                let maxT = totalH - h(id) - slotY(startIndex)
                translation = min(max(v.translation.height, minT), maxT)
                // 被拖行中心 → 在"去掉自己"的序列里找插入位
                let centerY = slotY(startIndex) + h(id) / 2 + translation
                var target = 0
                var acc: CGFloat = 0
                for other in displayIds where other != id {
                    if centerY > acc + h(other) / 2 { target += 1 }
                    acc += h(other)
                }
                if target != targetIndex {
                    withAnimation(.spring(duration: 0.28, bounce: 0.18)) { targetIndex = target }
                }
            }
            .onEnded { _ in
                guard let did = draggingId, let from = displayIds.firstIndex(of: did) else { return }
                var final = displayIds
                final.remove(at: from)
                let to = min(targetIndex, final.count)
                final.insert(did, at: to)

                // 松手瞬间的视觉 Y 与新顺序下的槽位 Y
                let visualY = slotY(startIndex) + translation
                let newSlotY = final.prefix(to).reduce(0) { $0 + h($1) }

                // 同一无动画事务：容器内部先冻结新顺序（行瞬时进新槽）+ 位移补偿 → 视觉零跳变；
                // 其余行新槽位恰好等于让位后的位置，start==target 让它们 offset 归零。
                // 父级随后送达的同序 ids 只会触发解除冻结（onChange），不再产生布局变化。
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    committedOrder = final
                    translation = visualY - newSlotY
                    startIndex = to
                    targetIndex = to
                }
                onReorder(final)
                // 只对补偿量做弹簧沉降，落定后再解除"拎起"态
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                    translation = 0
                } completion: {
                    draggingId = nil
                }
            }
    }
}
