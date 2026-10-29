// Floating plain-text scratchpad: stays on top of everything, incl. full-screen Spaces.
// Multiple windows, tabs per window, raw / markdown / JSON views per tab.
// ⌃⌥⌘P toggles all windows (global). State auto-saves to ~/Library/Application Support/Hoverpad/state.json.
import Cocoa
import Carbon

let home = FileManager.default.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/Hoverpad")
let stateFile = supportDir.appendingPathComponent("state.json")
let launchAgent = home.appendingPathComponent("Library/LaunchAgents/local.hoverpad.plist")
let barHeight: CGFloat = 28
let codeBG = NSColor.labelColor.withAlphaComponent(0.08)

// MARK: - State

enum Mode: Int, Codable { case raw, markdown, json }

struct TabState: Codable { var text = ""; var mode = Mode.raw }

struct WindowState: Codable {
    var tabs = [TabState()]
    var selected = 0
    var frame: String?
    var alpha = 0.95
    var fontSize = 13.0
    var floating = true
    var wrap = true
}

extension WindowState {
    // Tolerate state files written by older versions (missing keys keep their defaults).
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = WindowState()
        self.init(tabs: try c.decodeIfPresent([TabState].self, forKey: .tabs) ?? def.tabs,
                  selected: try c.decodeIfPresent(Int.self, forKey: .selected) ?? def.selected,
                  frame: try c.decodeIfPresent(String.self, forKey: .frame),
                  alpha: try c.decodeIfPresent(Double.self, forKey: .alpha) ?? def.alpha,
                  fontSize: try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? def.fontSize,
                  floating: try c.decodeIfPresent(Bool.self, forKey: .floating) ?? def.floating,
                  wrap: try c.decodeIfPresent(Bool.self, forKey: .wrap) ?? def.wrap)
    }
}

struct AppState: Codable { var windows: [WindowState] }

// MARK: - Login item (LaunchAgent pointing at this binary)

var loginEnabled: Bool { FileManager.default.fileExists(atPath: launchAgent.path) }

func setLogin(_ on: Bool) {
    guard on else { try? FileManager.default.removeItem(at: launchAgent); return }
    let plist: NSDictionary = ["Label": "local.hoverpad",
                               "ProgramArguments": [Bundle.main.executablePath!],
                               "RunAtLoad": true]
    try? FileManager.default.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
    plist.write(to: launchAgent, atomically: true)
}

// MARK: - Text helpers

func configurePlain(_ tv: NSTextView, _ size: CGFloat) {
    tv.isRichText = false
    tv.allowsUndo = true
    tv.font = .monospacedSystemFont(ofSize: size, weight: .regular)
    tv.textContainerInset = NSSize(width: 6, height: 6)
    // Keep pasted commands byte-exact.
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.isAutomaticSpellingCorrectionEnabled = false
    tv.isContinuousSpellCheckingEnabled = false
    tv.isAutomaticLinkDetectionEnabled = false
}

/// Text view whose drag-selection always includes the character the drag started on
/// (NSTextView rounds the anchor to the nearest caret position, skipping it if you start past its middle).
final class PadTextView: NSTextView {
    /// Index of the character whose glyph box contains `p`, if any.
    func charUnder(_ p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let q = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let g = lm.glyphIndex(for: q, in: tc)
        guard g < lm.numberOfGlyphs,
              lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).contains(q) else { return nil }
        let c = lm.characterIndexForGlyph(at: g)
        let s = string as NSString
        return c < s.length && s.character(at: c) != 10 ? c : nil
    }

    override func mouseDown(with e: NSEvent) {
        let start = convert(e.locationInWindow, from: nil)
        let under = charUnder(start)
        guard isSelectable, e.clickCount == 1, let win = window,
              e.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              under.flatMap({ textStorage?.attribute(.link, at: $0, effectiveRange: nil) }) == nil
        else { return super.mouseDown(with: e) }

        let caret = characterIndexForInsertion(at: start)
        win.makeFirstResponder(self)
        setSelectedRange(NSRange(location: caret, length: 0))
        var dragging = false
        while let ev = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), ev.type == .leftMouseDragged {
            let p = convert(ev.locationInWindow, from: nil)
            if !dragging && hypot(p.x - start.x, p.y - start.y) < 3 { continue }
            dragging = true
            autoscroll(with: ev)
            let end = characterIndexForInsertion(at: convert(ev.locationInWindow, from: nil))
            let lo = under ?? caret              // anchor when dragging forward
            let hi = under.map { $0 + 1 } ?? caret // anchor when dragging backward
            setSelectedRange(end >= hi || (under == nil && end > lo)
                             ? NSRange(location: lo, length: end - lo)
                             : NSRange(location: min(end, lo), length: hi - min(end, lo)))
        }
    }
}

func makeTextScroll() -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    let tv = PadTextView(usingTextLayoutManager: false)
    tv.minSize = .zero
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    tv.isVerticallyResizable = true
    scroll.documentView = tv
    setWrap(scroll, true)
    return scroll
}

func setWrap(_ scroll: NSScrollView, _ on: Bool) {
    let tv = scroll.documentView as! NSTextView
    scroll.hasHorizontalScroller = !on
    tv.isHorizontallyResizable = !on
    tv.autoresizingMask = [.width]
    tv.minSize = NSSize(width: on ? 0 : scroll.contentSize.width, height: 0) // short lines still fill the view
    tv.textContainer?.widthTracksTextView = on
    tv.textContainer?.containerSize = NSSize(width: on ? scroll.contentSize.width : .greatestFiniteMagnitude,
                                             height: .greatestFiniteMagnitude)
    if on { tv.frame.size.width = scroll.contentSize.width }
    tv.sizeToFit()
}

enum Markdown {
    /// Minimal line-based renderer: headings, lists, checkboxes, quotes, rules, fenced code, inline styles.
    static func render(_ src: String, size: CGFloat, copied: Int?) -> (text: NSAttributedString, code: [String]) {
        let out = NSMutableAttributedString()
        var code: [String] = []
        let base = NSFont.systemFont(ofSize: size)
        let lines = src.components(separatedBy: "\n")

        func style(indent: CGFloat = 0, head: CGFloat? = nil, after: CGFloat = 3) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = indent
            p.headIndent = head ?? indent
            p.paragraphSpacing = after
            return p
        }
        func add(_ s: NSAttributedString, _ p: NSParagraphStyle) {
            let m = NSMutableAttributedString(attributedString: s)
            m.append(NSAttributedString(string: "\n", attributes: [.font: base]))
            m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
            out.append(m)
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            i += 1

            if t.hasPrefix("```") {
                var body: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                i += 1 // closing fence
                let text = body.joined(separator: "\n")
                let n = code.count
                code.append(text)
                add(NSAttributedString(string: n == copied ? "✓ copied" : "⧉ copy",
                                       attributes: [.font: NSFont.systemFont(ofSize: size - 3),
                                                    .link: URL(string: "hoverpad-copy://\(n)")!]),
                    style(indent: 6, after: 0))
                add(NSAttributedString(string: text,
                                       attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                                                    .foregroundColor: NSColor.labelColor, .backgroundColor: codeBG]),
                    style(indent: 6, after: 8))
                continue
            }
            if t.isEmpty { out.append(NSAttributedString(string: "\n", attributes: [.font: base])); continue }
            if ["---", "***", "___"].contains(t) {
                add(NSAttributedString(string: String(repeating: "─", count: 24),
                                       attributes: [.font: base, .foregroundColor: NSColor.tertiaryLabelColor]), style())
                continue
            }
            let hashes = t.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), t.dropFirst(hashes).first == " " {
                let f = NSFont.systemFont(ofSize: size + CGFloat(max(0, 4 - hashes)) * 2, weight: .bold)
                add(inline(String(t.dropFirst(hashes + 1)), f, .labelColor), style(after: 5))
                continue
            }
            if t.hasPrefix(">") {
                let f = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                add(inline(String(t.dropFirst()).trimmingCharacters(in: .whitespaces), f, .secondaryLabelColor), style(indent: 12))
                continue
            }
            if let (level, marker, rest) = listItem(line) {
                var body = rest, mark = marker
                if body.hasPrefix("[ ] ") { mark = "☐"; body.removeFirst(4) }
                else if body.lowercased().hasPrefix("[x] ") { mark = "☑"; body.removeFirst(4) }
                let indent = CGFloat(level) * 16 + 6
                let m = NSMutableAttributedString(string: mark + "  ", attributes: [.font: base, .foregroundColor: NSColor.secondaryLabelColor])
                m.append(inline(body, base, .labelColor))
                add(m, style(indent: indent, head: indent + 16))
                continue
            }
            add(inline(line, base, .labelColor), style())
        }
        return (out, code)
    }

    static func listItem(_ line: String) -> (Int, String, String)? {
        let ws = line.prefix(while: { $0 == " " || $0 == "\t" })
        let level = ws.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let s = line.dropFirst(ws.count)
        if let c = s.first, "-*+".contains(c), s.dropFirst().first == " " { return (level, "•", String(s.dropFirst(2))) }
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty, s.dropFirst(digits.count).hasPrefix(". ") {
            return (level, digits + ".", String(s.dropFirst(digits.count + 2)))
        }
        return nil
    }

    static func inline(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        guard let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in a.runs {
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let ii = run.inlinePresentationIntent {
                if ii.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if ii.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if ii.contains(.code) {
                    f = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attrs[.backgroundColor] = codeBG
                }
                if ii.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attrs[.link] = link }
            attrs[.font] = f
            out.append(NSAttributedString(string: String(a[run.range].characters), attributes: attrs))
        }
        return out
    }
}

enum JSONFormat {
    enum Kind { case punct, key, string, number, literal, space }

    /// Order-preserving re-formatter (tolerates invalid input; validation is separate).
    static func tokens(_ s: String, pretty: Bool) -> [(String, Kind)] {
        let a = Array(s), n = a.count
        var out: [(String, Kind)] = []
        var stack: [Character] = []
        var expectKey = false
        var i = 0
        func newline() { if pretty { out.append(("\n" + String(repeating: "  ", count: stack.count), .space)) } }
        func nextSignificant(_ from: Int) -> Int { var j = from; while j < n, a[j].isWhitespace { j += 1 }; return j }

        while i < n {
            let c = a[i]
            switch c {
            case _ where c.isWhitespace:
                i += 1
            case "{", "[":
                let close: Character = c == "{" ? "}" : "]"
                let j = nextSignificant(i + 1)
                if j < n, a[j] == close { out.append((String([c, close]), .punct)); i = j + 1; continue }
                out.append((String(c), .punct)); stack.append(c); expectKey = c == "{"; newline(); i += 1
            case "}", "]":
                _ = stack.popLast(); newline(); out.append((String(c), .punct)); i += 1
            case ",":
                out.append((",", .punct)); newline(); expectKey = stack.last == "{"; i += 1
            case ":":
                out.append((pretty ? ": " : ":", .punct)); expectKey = false; i += 1
            case "\"":
                var j = i + 1
                while j < n, a[j] != "\"" { j += a[j] == "\\" ? 2 : 1 }
                let end = min(j, n - 1)
                out.append((String(a[i...end]), expectKey && stack.last == "{" ? .key : .string)); i = end + 1
            default:
                var j = i
                while j < n, !a[j].isWhitespace, !",:[]{}\"".contains(a[j]) { j += 1 }
                if j == i { j = i + 1 }
                let tok = String(a[i..<j])
                out.append((tok, tok.first.map { $0 == "-" || $0.isNumber } == true ? .number : .literal)); i = j
            }
        }
        return out
    }

    static func format(_ s: String, pretty: Bool) -> String { tokens(s, pretty: pretty).map(\.0).joined() }

    static func error(_ s: String) -> String? {
        do { _ = try JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]); return nil }
        catch { let e = error as NSError; return (e.userInfo["NSDebugDescription"] as? String) ?? e.localizedDescription }
    }

    static func highlighted(_ s: String, size: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let out = NSMutableAttributedString()
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSAttributedString(string: "Empty. Paste JSON in raw mode (⌘1).",
                                      attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        if let err = error(s) {
            out.append(NSAttributedString(string: "⚠ Invalid JSON: \(err)\n\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: size - 1), .foregroundColor: NSColor.systemRed]))
        }
        let colors: [Kind: NSColor] = [.punct: .secondaryLabelColor, .key: .systemBlue, .string: .systemGreen,
                                       .number: .systemOrange, .literal: .systemPurple, .space: .labelColor]
        for (text, kind) in tokens(s, pretty: true) {
            out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colors[kind]!]))
        }
        return out
    }
}

// MARK: - Pad window

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { AppDelegate.shared.hideAll() }
}

final class Tab {
    var mode: Mode
    let scroll = makeTextScroll()
    var editor: NSTextView { scroll.documentView as! NSTextView }

    init(_ s: TabState, delegate: NSTextViewDelegate, fontSize: CGFloat) {
        mode = s.mode
        configurePlain(editor, fontSize)
        editor.string = s.text
        editor.delegate = delegate
    }

    var title: String {
        let first = editor.string.prefix(400).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t#>-*`")) }
            .first { !$0.isEmpty } ?? "Untitled"
        return first.count > 14 ? first.prefix(13) + "…" : first
    }
}

final class Pad: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let panel: Panel
    var tabs: [Tab] = []
    var selected = 0
    var fontSize: CGFloat
    var wrap: Bool
    var codeBlocks: [String] = []
    let tabBar = NSSegmentedControl()
    let modeControl = NSSegmentedControl()
    let container = NSView()
    let previewScroll = makeTextScroll()
    var preview: NSTextView { previewScroll.documentView as! NSTextView }
    var toolButtons: [NSButton] = []
    var wrapButton: NSButton!

    var current: Tab { tabs[selected] }
    var editor: NSTextView { current.editor }

    init(state: WindowState) {
        fontSize = state.fontSize
        wrap = state.wrap
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = state.floating ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = state.alpha
        panel.minSize = NSSize(width: 300, height: 140)
        panel.delegate = self

        let root = NSView()
        panel.contentView = root
        let bar = buildBar()
        bar.frame = NSRect(x: 0, y: root.bounds.height - barHeight, width: root.bounds.width, height: barHeight)
        bar.autoresizingMask = [.width, .minYMargin]
        container.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: root.bounds.height - barHeight)
        container.autoresizingMask = [.width, .height]
        root.addSubview(bar)
        root.addSubview(container)

        preview.isEditable = false
        preview.isSelectable = true
        preview.textContainerInset = NSSize(width: 8, height: 6)
        preview.delegate = self

        if let f = state.frame { panel.setFrame(NSRectFromString(f), display: false) } else { panel.center() }
        previewScroll.frame = container.bounds
        tabs = state.tabs.map(makeTab)
        if tabs.isEmpty { tabs = [makeTab(TabState())] }
        applyWrap()
        select(state.selected)
    }

    var state: WindowState {
        WindowState(tabs: tabs.map { TabState(text: $0.editor.string, mode: $0.mode) }, selected: selected,
                    frame: NSStringFromRect(panel.frame), alpha: panel.alphaValue,
                    fontSize: fontSize, floating: panel.level == .floating, wrap: wrap)
    }

    func makeTab(_ s: TabState) -> Tab {
        let t = Tab(s, delegate: self, fontSize: fontSize)
        t.scroll.frame = container.bounds
        setWrap(t.scroll, wrap)
        return t
    }

    // MARK: Bar

    func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        let b = img.map { NSButton(image: $0, target: self, action: action) } ?? NSButton(title: tip, target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    func separator() -> NSView {
        let s = NSBox()
        s.boxType = .separator
        s.widthAnchor.constraint(equalToConstant: 1).isActive = true
        s.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return s
    }

    func buildBar() -> NSView {
        let bar = NSView()

        tabBar.trackingMode = .selectOne
        tabBar.controlSize = .small
        tabBar.font = .systemFont(ofSize: 11)
        tabBar.target = self
        tabBar.action = #selector(tabClicked(_:))
        tabBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tabMenu = NSMenu()
        tabMenu.addItem(withTitle: "Close Current Tab", action: #selector(closeTab), keyEquivalent: "").target = self
        tabBar.menu = tabMenu

        modeControl.segmentCount = 3
        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .small
        for (i, (sym, tip)) in [("text.alignleft", "Raw text ⌘1"), ("doc.richtext", "Markdown ⌘2"), ("curlybraces", "JSON ⌘3")].enumerated() {
            modeControl.setImage(NSImage(systemSymbolName: sym, accessibilityDescription: tip), forSegment: i)
            modeControl.setWidth(24, forSegment: i)
            modeControl.setToolTip(tip, forSegment: i)
        }
        modeControl.target = self
        modeControl.action = #selector(modeClicked(_:))

        toolButtons = [
            button("bold", "Bold ⌘B", #selector(bold)),
            button("italic", "Italic ⌘I", #selector(italic)),
            button("chevron.left.forwardslash.chevron.right", "Inline code ⌘E", #selector(inlineCode)),
            button("terminal", "Code block ⇧⌘E", #selector(codeBlock)),
            button("list.bullet", "Bullet list", #selector(bulletList)),
            button("textformat.size", "Heading", #selector(heading)),
        ]
        wrapButton = button("arrow.turn.down.left", "Soft wrap", #selector(toggleWrap))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let tools: [NSView] = [separator()] + toolButtons + [separator(),
                     button("textformat.size.smaller", "Smaller font ⌘-", #selector(smallerFont)),
                     button("textformat.size.larger", "Bigger font ⌘=", #selector(biggerFont)),
                     wrapButton!, separator()]

        let stack = NSStackView(views: [button("xmark", "Close window ⇧⌘W", #selector(closeWindow)),
                                        tabBar, button("plus", "New tab ⌘T", #selector(newTab)), spacer]
                                + tools
                                + [modeControl, button("ellipsis.circle", "More", #selector(showMenu(_:))),
                                   button("macwindow.badge.plus", "New window ⌘N", #selector(newWindow))])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        // On narrow windows drop the text tools before anything else.
        for v in tools { stack.setVisibilityPriority(.detachOnlyIfNecessary, for: v) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        let line = NSBox(frame: NSRect(x: 0, y: 0, width: 100, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width]
        bar.addSubview(line)
        return bar
    }

    func refreshTabBar() {
        tabBar.isHidden = tabs.count < 2
        tabBar.segmentCount = tabs.count
        for (i, t) in tabs.enumerated() {
            tabBar.setLabel(t.title, forSegment: i)
            tabBar.setWidth(0, forSegment: i)
        }
        tabBar.selectedSegment = selected
    }

    // MARK: Tabs & modes

    func select(_ i: Int) {
        selected = max(0, min(i, tabs.count - 1))
        refreshTabBar()
        showContent()
        AppDelegate.shared.scheduleSave()
    }

    func showContent() {
        container.subviews.forEach { $0.removeFromSuperview() }
        let v: NSView = current.mode == .raw ? current.scroll : previewScroll
        if current.mode != .raw { renderPreview() }
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
        modeControl.selectedSegment = current.mode.rawValue
        panel.makeFirstResponder(current.mode == .raw ? editor : preview)
    }

    func renderPreview(copied: Int? = nil) {
        switch current.mode {
        case .raw: return
        case .markdown:
            let r = Markdown.render(editor.string, size: fontSize, copied: copied)
            codeBlocks = r.code
            preview.textStorage?.setAttributedString(r.text)
        case .json:
            preview.textStorage?.setAttributedString(JSONFormat.highlighted(editor.string, size: fontSize))
        }
    }

    func setMode(_ m: Mode) {
        current.mode = m
        showContent()
        AppDelegate.shared.scheduleSave()
    }

    func ensureRaw() { if current.mode != .raw { setMode(.raw) } }

    func focus() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(current.mode == .raw ? editor : preview)
    }

    /// App-modal, not a sheet: closing a window from a sheet's completion left it orphaned and frozen.
    /// "Keep" is the default (Return/Esc) so a reflex keypress never discards text.
    func confirm(_ message: String, _ then: () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = "Its text will be discarded."
        a.addButton(withTitle: "Keep")
        let close = a.addButton(withTitle: "Close")
        close.hasDestructiveAction = true
        close.keyEquivalent = ""
        a.buttons[0].keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { then() }
    }

    @objc func tabClicked(_ s: NSSegmentedControl) { select(s.selectedSegment) }
    @objc func modeClicked(_ s: NSSegmentedControl) { setMode(Mode(rawValue: s.selectedSegment) ?? .raw) }
    @objc func modeFromMenu(_ s: NSMenuItem) { setMode(Mode(rawValue: s.tag) ?? .raw) }
    @objc func nextTab() { select((selected + 1) % tabs.count) }
    @objc func prevTab() { select((selected - 1 + tabs.count) % tabs.count) }
    @objc func newWindow() { AppDelegate.shared.newPad(near: self) }

    @objc func newTab() {
        tabs.append(makeTab(TabState()))
        select(tabs.count - 1)
    }

    @objc func closeTab() {
        let doClose = { [self] in
            if tabs.count == 1 { AppDelegate.shared.closePad(self); return }
            tabs.remove(at: selected)
            select(selected)
        }
        if editor.string.isEmpty { doClose() } else { confirm("Close this tab?", doClose) }
    }

    @objc func closeWindow() {
        let doClose = { AppDelegate.shared.closePad(self) }
        if tabs.allSatisfy({ $0.editor.string.isEmpty }) { doClose() } else { confirm("Close this window and all its tabs?", doClose) }
    }

    func resetToEmpty() {
        tabs = [makeTab(TabState())]
        select(0)
    }

    // MARK: Editing tools

    func replace(_ range: NSRange, with s: String, select sel: NSRange) {
        guard editor.shouldChangeText(in: range, replacementString: s) else { return }
        editor.textStorage?.replaceCharacters(in: range, with: s)
        editor.didChangeText()
        editor.setSelectedRange(sel)
    }

    func wrap(_ pre: String, _ post: String) {
        ensureRaw()
        let r = editor.selectedRange()
        let inner = (editor.string as NSString).substring(with: r)
        replace(r, with: pre + inner + post, select: NSRange(location: r.location + (pre as NSString).length, length: r.length))
    }

    func toggleLinePrefix(_ p: String) {
        ensureRaw()
        let ns = editor.string as NSString
        let lr = ns.lineRange(for: editor.selectedRange())
        var block = ns.substring(with: lr)
        let trailingNL = block.hasSuffix("\n")
        if trailingNL { block.removeLast() }
        let lines = block.components(separatedBy: "\n")
        let remove = lines.contains { $0.hasPrefix(p) } && lines.allSatisfy { $0.hasPrefix(p) || $0.isEmpty }
        let changed = lines.map { l -> String in
            if remove { return l.hasPrefix(p) ? String(l.dropFirst(p.count)) : l }
            return l.isEmpty && lines.count > 1 ? l : p + l
        }
        let out = changed.joined(separator: "\n") + (trailingNL ? "\n" : "")
        replace(lr, with: out, select: NSRange(location: lr.location, length: (out as NSString).length))
    }

    /// Applies `f` to the selection, or to the whole text when nothing is selected.
    func transform(wholeLines: Bool = false, _ f: (String) -> String) {
        ensureRaw()
        let ns = editor.string as NSString
        var r = editor.selectedRange()
        if r.length == 0 { r = NSRange(location: 0, length: ns.length) } else if wholeLines { r = ns.lineRange(for: r) }
        let out = f(ns.substring(with: r))
        replace(r, with: out, select: NSRange(location: r.location, length: (out as NSString).length))
    }

    func mapLines(_ f: @escaping ([String]) -> [String]) -> (String) -> String {
        { s in
            let nl = s.hasSuffix("\n")
            let lines = (nl ? String(s.dropLast()) : s).components(separatedBy: "\n")
            return f(lines).joined(separator: "\n") + (nl ? "\n" : "")
        }
    }

    @objc func bold() { wrap("**", "**") }
    @objc func italic() { wrap("_", "_") }
    @objc func inlineCode() { wrap("`", "`") }
    @objc func codeBlock() { wrap("```\n", "\n```") }
    @objc func bulletList() { toggleLinePrefix("- ") }
    @objc func heading() { toggleLinePrefix("# ") }
    @objc func uppercase() { transform { $0.uppercased() } }
    @objc func lowercase() { transform { $0.lowercased() } }
    @objc func sortLines() { transform(wholeLines: true, mapLines { $0.sorted() }) }
    @objc func trimLines() {
        transform(wholeLines: true, mapLines { $0.map { $0.trimmingCharacters(in: .whitespaces) } })
    }
    @objc func dedupeLines() {
        transform(wholeLines: true, mapLines { var seen = Set<String>(); return $0.filter { seen.insert($0).inserted } })
    }

    @objc func formatJSON() { jsonInPlace(pretty: true) }
    @objc func minifyJSON() { jsonInPlace(pretty: false) }

    func jsonInPlace(pretty: Bool) {
        ensureRaw()
        let r = editor.selectedRange()
        let src = r.length > 0 ? (editor.string as NSString).substring(with: r) : editor.string
        if let err = JSONFormat.error(src) {
            let a = NSAlert()
            a.messageText = "Invalid JSON"
            a.informativeText = err
            a.runModal()
            return
        }
        transform { _ in JSONFormat.format(src, pretty: pretty) }
    }

    // MARK: Window options

    func applyFont() {
        for t in tabs { t.editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        renderPreview()
        AppDelegate.shared.scheduleSave()
    }

    @objc func biggerFont() { fontSize = min(fontSize + 1, 32); applyFont() }
    @objc func smallerFont() { fontSize = max(fontSize - 1, 9); applyFont() }
    @objc func setOpacity(_ s: NSMenuItem) { panel.alphaValue = CGFloat(s.tag) / 100; AppDelegate.shared.scheduleSave() }
    func applyWrap() {
        for s in tabs.map(\.scroll) + [previewScroll] { setWrap(s, wrap) }
        wrapButton.contentTintColor = wrap ? .controlAccentColor : .secondaryLabelColor
    }

    @objc func toggleWrap() { wrap.toggle(); applyWrap(); AppDelegate.shared.scheduleSave() }
    @objc func toggleFloat() { panel.level = panel.level == .floating ? .normal : .floating; AppDelegate.shared.scheduleSave() }

    @objc func showMenu(_ sender: NSButton) {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", tag: Int = 0, on: Bool = false, in menu: NSMenu? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            i.tag = tag
            i.state = on ? .on : .off
            (menu ?? m).addItem(i)
        }
        func submenu(_ title: String) -> NSMenu {
            let sub = NSMenu()
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = sub
            m.addItem(i)
            return sub
        }

        let opacity = submenu("Opacity")
        for p in [100, 90, 80, 70, 60, 50] {
            item("\(p)%", #selector(setOpacity(_:)), tag: p, on: Int((panel.alphaValue * 100).rounded()) == p, in: opacity)
        }
        let font = submenu("Font Size (\(Int(fontSize)))")
        item("Bigger", #selector(biggerFont), "=", in: font)
        item("Smaller", #selector(smallerFont), "-", in: font)
        item("Soft Wrap", #selector(toggleWrap), on: wrap)
        item("Float on Top", #selector(toggleFloat), on: panel.level == .floating)
        m.addItem(.separator())
        let json = submenu("JSON")
        item("Format", #selector(formatJSON), in: json)
        item("Minify", #selector(minifyJSON), in: json)
        let text = submenu("Transform")
        item("UPPERCASE", #selector(uppercase), in: text)
        item("lowercase", #selector(lowercase), in: text)
        item("Sort Lines", #selector(sortLines), in: text)
        item("Trim Lines", #selector(trimLines), in: text)
        item("Remove Duplicate Lines", #selector(dedupeLines), in: text)
        m.addItem(.separator())
        item("Close Tab", #selector(closeTab), "w")
        item("Close Window", #selector(closeWindow), "W")
        m.addItem(.separator())
        let start = NSMenuItem(title: "Start at Login", action: #selector(AppDelegate.toggleLogin(_:)), keyEquivalent: "")
        start.target = AppDelegate.shared
        start.state = loginEnabled ? .on : .off
        m.addItem(start)
        m.addItem(withTitle: "Quit Hoverpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: Delegates

    func textDidChange(_ n: Notification) {
        refreshTabBar()
        AppDelegate.shared.scheduleSave()
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        // Esc normally triggers completion in NSTextView; use it to hide instead.
        if sel == #selector(NSResponder.cancelOperation(_:)) || sel == #selector(NSResponder.complete(_:)) {
            AppDelegate.shared.hideAll()
            return true
        }
        return false
    }

    func textView(_ tv: NSTextView, clickedOnLink link: Any, at i: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "hoverpad-copy",
              let n = Int(url.host ?? ""), n < codeBlocks.count else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(codeBlocks[n], forType: .string)
        renderPreview(copied: n)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.renderPreview() }
        return true
    }

    func windowDidMove(_ n: Notification) { AppDelegate.shared.scheduleSave() }
    func windowDidResize(_ n: Notification) { AppDelegate.shared.scheduleSave() }
    func windowDidBecomeKey(_ n: Notification) { AppDelegate.shared.lastKey = self }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    var pads: [Pad] = []
    weak var lastKey: Pad?
    var statusItem: NSStatusItem!
    var saveWork: DispatchWorkItem?
    var selfTesting = CommandLine.arguments.contains("--selftest")

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMainMenu()
        buildStatusItem()
        registerHotKey()
        pads = loadState().windows.map { Pad(state: $0) }
        if selfTesting { selfTest(); return }
        showAll()
    }

    func loadState() -> AppState {
        if let d = try? Data(contentsOf: stateFile),
           let s = try? JSONDecoder().decode(AppState.self, from: d), !s.windows.isEmpty { return s }
        return AppState(windows: [WindowState()])
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        guard !selfTesting, !pads.isEmpty else { return }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(AppState(windows: pads.map(\.state))) {
            try? d.write(to: stateFile, options: .atomic)
        }
    }

    func applicationWillTerminate(_ n: Notification) { save() }

    func newPad(near: Pad?) {
        var s = WindowState()
        if let n = near {
            s.frame = NSStringFromRect(n.panel.frame.offsetBy(dx: 24, dy: -24))
            s.alpha = n.panel.alphaValue
            s.fontSize = n.fontSize
            s.wrap = n.wrap
        }
        let p = Pad(state: s)
        pads.append(p)
        NSApp.activate(ignoringOtherApps: true)
        p.focus()
        scheduleSave()
    }

    func closePad(_ p: Pad) {
        if pads.count == 1 {
            p.resetToEmpty()
            hideAll()
        } else {
            p.panel.close()
            pads.removeAll { $0 === p }
            (lastKey ?? pads.last)?.focus()
        }
        scheduleSave()
    }

    @objc func toggleAll() {
        if pads.contains(where: { $0.panel.isVisible }) && NSApp.isActive { hideAll() } else { showAll() }
    }

    func showAll() {
        NSApp.activate(ignoringOtherApps: true)
        pads.forEach { $0.panel.orderFront(nil) }
        (lastKey ?? pads.last)?.focus()
    }

    @objc func hideAll() {
        save()
        pads.forEach { $0.panel.orderOut(nil) }
        NSApp.hide(nil) // hand focus back to the previous app
    }

    @objc func newWindowFromStatus() { newPad(near: lastKey ?? pads.last) }

    @objc func toggleLogin(_ item: NSMenuItem) {
        setLogin(!loginEnabled)
        item.state = loginEnabled ? .on : .off
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Hoverpad")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show/Hide  (⌃⌥⌘P)", action: #selector(toggleAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Window", action: #selector(newWindowFromStatus), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Quit Hoverpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    // Accessory apps still need a main menu for key equivalents (⌘C/⌘V/⌘T/...) to work.
    // Nil-targeted items reach the key window's Pad through the responder chain (window delegate).
    func buildMainMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [(String, Selector, String, Int)]) {
            let top = NSMenuItem()
            let m = NSMenu(title: title)
            for (t, a, k, tag) in items {
                if t == "-" { m.addItem(.separator()); continue }
                m.addItem(withTitle: t, action: a, keyEquivalent: k).tag = tag
            }
            top.submenu = m
            main.addItem(top)
        }
        let sep = ("-", Selector(("separator")), "", 0)
        menu("Hoverpad", [("Hide", #selector(hideAll), "h", 0),
                            ("Quit", #selector(NSApplication.terminate(_:)), "q", 0)])
        main.items[0].submenu?.items[0].target = self
        menu("File", [("New Window", #selector(Pad.newWindow), "n", 0),
                      ("New Tab", #selector(Pad.newTab), "t", 0),
                      ("Close Tab", #selector(Pad.closeTab), "w", 0),
                      ("Close Window", #selector(Pad.closeWindow), "W", 0)])
        menu("Edit", [("Undo", Selector(("undo:")), "z", 0),
                      ("Redo", Selector(("redo:")), "Z", 0), sep,
                      ("Cut", #selector(NSText.cut(_:)), "x", 0),
                      ("Copy", #selector(NSText.copy(_:)), "c", 0),
                      ("Paste", #selector(NSText.paste(_:)), "v", 0),
                      ("Select All", #selector(NSText.selectAll(_:)), "a", 0)])
        menu("Format", [("Bold", #selector(Pad.bold), "b", 0),
                        ("Italic", #selector(Pad.italic), "i", 0),
                        ("Inline Code", #selector(Pad.inlineCode), "e", 0),
                        ("Code Block", #selector(Pad.codeBlock), "E", 0)])
        menu("View", [("Raw Text", #selector(Pad.modeFromMenu(_:)), "1", Mode.raw.rawValue),
                      ("Markdown", #selector(Pad.modeFromMenu(_:)), "2", Mode.markdown.rawValue),
                      ("JSON", #selector(Pad.modeFromMenu(_:)), "3", Mode.json.rawValue), sep,
                      ("Bigger", #selector(Pad.biggerFont), "=", 0),
                      ("Smaller", #selector(Pad.smallerFont), "-", 0),
                      ("Soft Wrap", #selector(Pad.toggleWrap), "", 0), sep,
                      ("Next Tab", #selector(Pad.nextTab), "}", 0),
                      ("Previous Tab", #selector(Pad.prevTab), "{", 0)])
        NSApp.mainMenu = main
    }

    func registerHotKey() {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4856_5044), id: 1) // 'HVPD'
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey | controlKey),
                            id, GetApplicationEventTarget(), 0, &ref)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppDelegate.shared.toggleAll() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// `--selftest`: checks the bar's buttons receive clicks under the transparent titlebar, plus parsers.
    func selfTest() {
        let p = pads[0]
        p.panel.orderFront(nil)
        p.panel.contentView?.layoutSubtreeIfNeeded()
        for b in [p.toolButtons[0], p.modeControl] as [NSView] {
            let pt = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
            let hit = p.panel.contentView?.superview?.hitTest(pt)
            print("hit \(type(of: b)):", hit.map { "\(type(of: $0))" } ?? "nil", hit === b ? "OK" : "FAIL")
        }
        print("loaded:", pads.map { $0.tabs.map { $0.editor.string.count } }, "chars; wrap", p.wrap)
        p.newTab()
        let tv = p.editor as! PadTextView
        tv.string = "hello world"
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        let box = tv.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: tv.textContainer!)
        let pt = NSPoint(x: box.minX + box.width * 0.75 + tv.textContainerOrigin.x, y: box.midY + tv.textContainerOrigin.y)
        print("drag anchor: charUnder", tv.charUnder(pt) ?? -1, "vs NSTextView caret", tv.characterIndexForInsertion(at: pt), "(want 0 vs 1)")
        p.toggleWrap(); print("wrap off → horizontally resizable:", tv.isHorizontallyResizable, "container width:", tv.textContainer!.containerSize.width > 1e6)
        p.toggleWrap(); print("wrap on → horizontally resizable:", tv.isHorizontallyResizable)
        print(JSONFormat.format(#"{"b":[1,2,{"c":null}],"a":"x\"y","e":{},"n":-1.5e3}"#, pretty: true))
        print(JSONFormat.format("{ \"a\" : [ 1 , true ] }", pretty: false))
        print("error:", JSONFormat.error(#"{"a":}"#) ?? "none")
        print(Markdown.render("# Title\n- **bold** and `code`\n  - [x] done\n1. one\n> quote\n```\nls -la\n```", size: 13, copied: nil).text.string)
        NSApp.terminate(nil)
    }
}

let args = CommandLine.arguments
if args.contains("--enable-login") { setLogin(true) }
if !args.contains("--selftest"),
   let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
    exit(0) // already running
}
// Save on kill/logout too (SIGTERM skips applicationWillTerminate).
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { AppDelegate.shared.save(); exit(0) }
termSource.resume()

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon; required to float over full-screen apps
app.delegate = AppDelegate.shared
app.run()
