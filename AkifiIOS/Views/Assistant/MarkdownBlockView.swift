import SwiftUI

/// A block-based markdown renderer that properly handles headers, lists,
/// paragraphs, bold/italic, and code blocks with visual spacing.
struct MarkdownBlockView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Block Types

    private enum MarkdownBlock {
        case header(level: Int, text: String)
        case paragraph(text: String)
        case bulletList(items: [String])
        case numberedList(items: [String])
        case codeBlock(text: String)
        case divider
    }

    // MARK: - Parser

    private func parseBlocks() -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var currentParagraphLines: [String] = []
        var currentListItems: [String] = []
        var currentNumberedItems: [String] = []
        var inCodeBlock = false
        var codeLines: [String] = []

        func flushParagraph() {
            let joined = currentParagraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(text: joined))
            }
            currentParagraphLines = []
        }

        func flushBulletList() {
            if !currentListItems.isEmpty {
                blocks.append(.bulletList(items: currentListItems))
                currentListItems = []
            }
        }

        func flushNumberedList() {
            if !currentNumberedItems.isEmpty {
                blocks.append(.numberedList(items: currentNumberedItems))
                currentNumberedItems = []
            }
        }

        func flushAll() {
            flushParagraph()
            flushBulletList()
            flushNumberedList()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block fence
            if trimmed.hasPrefix("```") {
                flushAll()
                if inCodeBlock {
                    blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            // Empty line = paragraph break
            if trimmed.isEmpty {
                flushAll()
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.divider)
                continue
            }

            // Headers
            if let headerMatch = trimmed.prefixMatch(of: /^(#{1,4})\s+(.+)/) {
                flushAll()
                let level = headerMatch.1.count
                let headerText = String(headerMatch.2)
                blocks.append(.header(level: level, text: headerText))
                continue
            }

            // Bullet list items (-, *, +)
            if let bulletMatch = trimmed.prefixMatch(of: /^[-*+]\s+(.+)/) {
                flushParagraph()
                flushNumberedList()
                currentListItems.append(String(bulletMatch.1))
                continue
            }

            // Numbered list items
            if let numMatch = trimmed.prefixMatch(of: /^\d+[.)]\s+(.+)/) {
                flushParagraph()
                flushBulletList()
                currentNumberedItems.append(String(numMatch.1))
                continue
            }

            // Regular text line — collect into paragraph
            flushBulletList()
            flushNumberedList()
            currentParagraphLines.append(trimmed)
        }

        // Flush remaining
        if inCodeBlock && !codeLines.isEmpty {
            blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
        }
        flushAll()

        return blocks
    }

    // MARK: - Renderers

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .header(let level, let text):
            renderHeader(level: level, text: text)
        case .paragraph(let text):
            renderInlineMarkdown(text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        renderInlineMarkdown(item)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        renderInlineMarkdown(item)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .codeBlock(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func renderHeader(level: Int, text: String) -> some View {
        let headerText = renderInlineMarkdown(text)

        switch level {
        case 1:
            headerText
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.top, 4)
        case 2:
            headerText
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.top, 2)
        case 3:
            headerText
                .font(.headline)
                .foregroundStyle(.primary)
        default:
            headerText
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    /// Render inline markdown (bold, italic, code, links) using AttributedString
    private func renderInlineMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}
