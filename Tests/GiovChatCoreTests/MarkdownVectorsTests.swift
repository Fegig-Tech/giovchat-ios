import Foundation
@testable import GiovChatCore
import Testing

/// Runs every entry of the shared markdown conformance vectors (`Fixtures/markdown-vectors.json`, a copy of the
/// protocol's vectors bundled as a test resource), normalised the way the protocol's reference runner does: marks
/// sorted, empty runs dropped, neighbours with the same marks and no link merged.
@Suite struct MarkdownVectorsTests {
    private static func vectorsFile() throws -> URL {
        guard let url = Bundle.module.url(forResource: "markdown-vectors", withExtension: "json", subdirectory: "Fixtures") else {
            throw VectorsNotFound()
        }
        return url
    }

    private struct VectorsNotFound: Error {}

    @Test func everyVectorMatches() throws {
        let data = try Data(contentsOf: try Self.vectorsFile())
        let vectors = try #require(JSONValue.parse(data)?["vectors"]?.arrayValue)
        #expect(vectors.count > 40, "the vectors file has more than 40 entries")
        var failures: [String] = []
        for vector in vectors {
            let input = try #require(vector["input"].string)
            let actual = normalizeTree(GiovChatMarkdown.parse(input).map(blockJSON))
            let expected = normalizeTree(vector["tree"].array ?? [])
            if actual != expected {
                failures.append("\(vector["name"].string ?? "?"): input=\(input)\n  expected=\(JSONValue.array(expected).serialized)\n  actual=\(JSONValue.array(actual).serialized)")
            }
        }
        #expect(failures.isEmpty, "markdown vectors failed:\n\(failures.joined(separator: "\n"))")
    }

    @Test func linksOpenOnlyForSafeSchemes() {
        #expect(GiovChatMarkdown.isOpenableHref("https://x.test"))
        #expect(GiovChatMarkdown.isOpenableHref("MAILTO:a@b.co"))
        #expect(!GiovChatMarkdown.isOpenableHref("javascript:alert(1)"))
        #expect(!GiovChatMarkdown.isOpenableHref(nil))
        #expect(GiovChatMarkdown.parse("") == [])
        #expect(GiovChatMarkdown.parse(nil) == [])
    }

    private func runJSON(_ run: GiovInlineRun) -> JSONValue {
        var marks: [String: JSONValue] = [:]
        if run.marks.bold { marks["bold"] = .bool(true) }
        if run.marks.italic { marks["italic"] = .bool(true) }
        if run.marks.strike { marks["strike"] = .bool(true) }
        if run.marks.underline { marks["underline"] = .bool(true) }
        if run.marks.code { marks["code"] = .bool(true) }
        var map: [String: JSONValue] = ["text": .string(run.text), "marks": .object(marks)]
        if let href = run.href { map["href"] = .string(href) }
        return .object(map)
    }

    private func lineJSON(_ line: [GiovInlineRun]) -> JSONValue { .array(line.map(runJSON)) }

    private func listJSON(_ list: GiovMarkdownList) -> JSONValue {
        .object([
            "type": .string("list"),
            "ordered": .bool(list.ordered),
            "start": .number(Double(list.start)),
            "items": .array(list.items.map { item in
                .object(["lines": .array(item.lines.map(lineJSON)), "children": .array(item.children.map(listJSON))])
            }),
        ])
    }

    private func blockJSON(_ block: GiovMarkdownBlock) -> JSONValue {
        switch block {
        case .paragraph(let lines): return .object(["type": .string("paragraph"), "lines": .array(lines.map(lineJSON))])
        case .quote(let lines): return .object(["type": .string("quote"), "lines": .array(lines.map(lineJSON))])
        case .heading(let content): return .object(["type": .string("heading"), "content": lineJSON(content)])
        case .code(let text): return .object(["type": .string("code"), "text": .string(text)])
        case .rule: return .object(["type": .string("rule")])
        case .list(let list): return listJSON(list)
        }
    }

    private func normalizeLine(_ runs: [JSONValue]) -> JSONValue {
        var out: [[String: JSONValue]] = []
        for run in runs {
            guard let text = run["text"].string, !text.isEmpty else { continue }
            let marks = (run["marks"].object).filter { $0.value == .bool(true) }
            let href = run["href"].string.flatMap { $0.isEmpty ? nil : $0 }
            if let last = out.last, last["href"] == nil, href == nil, last["marks"] == .object(marks) {
                out[out.count - 1]["text"] = .string((last["text"].string ?? "") + text)
            } else {
                var next: [String: JSONValue] = ["text": .string(text), "marks": .object(marks)]
                if let href { next["href"] = .string(href) }
                out.append(next)
            }
        }
        return .array(out.map(JSONValue.object))
    }

    private func normalizeTree(_ blocks: [JSONValue]) -> [JSONValue] {
        blocks.map { block in
            let type = block["type"].string ?? ""
            switch type {
            case "paragraph", "quote":
                return .object(["type": .string(type), "lines": .array((block["lines"].array ?? []).map { normalizeLine($0.arrayValue ?? []) })])
            case "heading":
                return .object(["type": .string("heading"), "content": normalizeLine(block["content"].array ?? [])])
            case "code":
                return .object(["type": .string("code"), "text": block["text"] ?? .string("")])
            case "rule":
                return .object(["type": .string("rule")])
            case "list":
                let ordered = block["ordered"].isTrue
                return .object([
                    "type": .string("list"),
                    "ordered": .bool(ordered),
                    "start": .number(ordered ? block["start"].number ?? 1 : 1),
                    "items": .array((block["items"].array ?? []).map { item in
                        .object([
                            "lines": .array((item["lines"].array ?? []).map { normalizeLine($0.arrayValue ?? []) }),
                            "children": .array(normalizeTree(item["children"].array ?? [])),
                        ])
                    }),
                ])
            default:
                return .string("unknown block \(type)")
            }
        }
    }
}
