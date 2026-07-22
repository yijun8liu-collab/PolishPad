import SwiftUI

enum DiffSegmentKind {
    case same, inserted, removed
}

struct DiffSegment: Equatable {
    let kind: DiffSegmentKind
    let text: String
}

enum DiffRenderer {
    /// 性能保护：超过这个总长度就不做逐字对比
    static let maxLength = 8000

    /// 字符级 diff：把 old → new 的变化合并成一条带增删标记的序列
    static func segments(from old: String, to new: String) -> [DiffSegment]? {
        guard old.count + new.count <= maxLength else { return nil }
        let oldChars = Array(old)
        let newChars = Array(new)
        let difference = newChars.difference(from: oldChars)

        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }

        var segments: [DiffSegment] = []
        var buffer = ""
        var bufferKind: DiffSegmentKind = .same

        func flush() {
            if !buffer.isEmpty {
                segments.append(DiffSegment(kind: bufferKind, text: buffer))
                buffer = ""
            }
        }
        func emit(_ kind: DiffSegmentKind, _ char: Character) {
            if kind != bufferKind {
                flush()
                bufferKind = kind
            }
            buffer.append(char)
        }

        var i = 0
        var j = 0
        while i < oldChars.count || j < newChars.count {
            if i < oldChars.count, removals.contains(i) {
                emit(.removed, oldChars[i])
                i += 1
            } else if j < newChars.count, insertions.contains(j) {
                emit(.inserted, newChars[j])
                j += 1
            } else if i < oldChars.count, j < newChars.count {
                emit(.same, newChars[j])
                i += 1
                j += 1
            } else {
                break
            }
        }
        flush()
        return segments
    }

    /// 渲染为富文本：新增绿底、删除红字划线
    static func attributedString(from old: String, to new: String) -> AttributedString? {
        guard let segments = segments(from: old, to: new) else { return nil }
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            switch segment.kind {
            case .same:
                break
            case .inserted:
                part.backgroundColor = Color.green.opacity(0.28)
            case .removed:
                part.foregroundColor = Color.red.opacity(0.75)
                part.strikethroughStyle = .single
            }
            result += part
        }
        return result
    }
}
