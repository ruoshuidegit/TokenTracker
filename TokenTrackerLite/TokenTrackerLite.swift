import AppKit
import Foundation
import Darwin

private struct AppPaths {
    let queue: URL
    let database: URL
    let snapshot: URL
    let node: URL
    let worker: URL
    let collector: URL?

    init(arguments: [String] = CommandLine.arguments) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/TokenTrackerLite", isDirectory: true)
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        func argument(_ name: String, fallback: URL) -> URL {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
            return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        }
        queue = argument("--queue", fallback: home.appendingPathComponent(".tokentracker/tracker/queue.jsonl"))
        database = argument("--database", fallback: support.appendingPathComponent("usage.sqlite"))
        snapshot = argument("--snapshot", fallback: support.appendingPathComponent("snapshot.json"))
        node = resources.appendingPathComponent("node")
        worker = resources.appendingPathComponent("TokenTrackerLite/queue-store.cjs")
        collector = arguments.contains("--collect-state-dir")
            ? argument("--collect-state-dir", fallback: support.appendingPathComponent("local-collector"))
            : (arguments.contains("--queue") ? nil : support.appendingPathComponent("local-collector"))
    }
}

private struct FileStamp: Equatable {
    let exists: Bool
    let size: UInt64
    let device: Int64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(url: URL) {
        var metadata = stat()
        guard fstatat(AT_FDCWD, url.path, &metadata, 0) == 0 else {
            exists = false; size = 0; device = 0; inode = 0
            modifiedSeconds = 0; modifiedNanoseconds = 0
            changedSeconds = 0; changedNanoseconds = 0
            return
        }
        exists = true
        size = UInt64(max(0, metadata.st_size))
        device = Int64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }

    init?(dictionary: [String: Any]) {
        guard let exists = dictionary["exists"] as? Bool,
              let size = dictionary["size"] as? NSNumber,
              let device = dictionary["device"] as? NSNumber,
              let inode = dictionary["inode"] as? NSNumber,
              let modifiedSeconds = dictionary["modified_seconds"] as? NSNumber,
              let modifiedNanoseconds = dictionary["modified_nanoseconds"] as? NSNumber,
              let changedSeconds = dictionary["changed_seconds"] as? NSNumber,
              let changedNanoseconds = dictionary["changed_nanoseconds"] as? NSNumber else { return nil }
        self.exists = exists; self.size = size.uint64Value
        self.device = device.int64Value; self.inode = inode.uint64Value
        self.modifiedSeconds = modifiedSeconds.int64Value
        self.modifiedNanoseconds = modifiedNanoseconds.int64Value
        self.changedSeconds = changedSeconds.int64Value
        self.changedNanoseconds = changedNanoseconds.int64Value
    }

    var dictionary: [String: Any] {
        ["exists": exists, "size": size, "device": device, "inode": inode,
         "modified_seconds": modifiedSeconds, "modified_nanoseconds": modifiedNanoseconds,
         "changed_seconds": changedSeconds, "changed_nanoseconds": changedNanoseconds]
    }
}

private struct UsageAmount {
    let tokens: Double
    let cost: Double
    let unpriced: Double

    init?(_ value: Any?) {
        guard let dictionary = value as? [String: Any],
              let tokens = dictionary["tokens"] as? NSNumber,
              let cost = dictionary["cost_usd"] as? NSNumber else { return nil }
        self.tokens = tokens.doubleValue
        self.cost = cost.doubleValue
        self.unpriced = (dictionary["unpriced_tokens"] as? NSNumber)?.doubleValue ?? 0
        guard self.tokens.isFinite, self.cost.isFinite, self.unpriced.isFinite,
              self.tokens >= 0, self.cost >= 0, self.unpriced >= 0 else { return nil }
    }
}

private struct UsageSnapshot {
    let raw: [String: Any]
    let today: UsageAmount
    let month: UsageAmount
    let all: UsageAmount
    let generatedAt: Date?
    let queueUpdatedAt: Date?
    let queuePresent: Bool
    let models: [[String: Any]]
    let days: [[String: Any]]
    let warning: String?

    init?(data: Data) {
        guard data.count <= 8 * 1024 * 1024,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (raw["schema_version"] as? NSNumber)?.intValue == 1,
              let today = UsageAmount(raw["today"]),
              let month = UsageAmount(raw["month"]),
              let all = UsageAmount(raw["all"]),
              let queuePresent = raw["queue_present"] as? Bool else { return nil }
        self.raw = raw; self.today = today; self.month = month; self.all = all
        self.generatedAt = Self.date(raw["generated_at"])
        self.queueUpdatedAt = Self.date(raw["queue_updated_at"])
        self.queuePresent = queuePresent
        self.models = Array((raw["models"] as? [[String: Any]] ?? []).prefix(5))
        self.days = Array((raw["days"] as? [[String: Any]] ?? []).suffix(7))
        let warning = (raw["warning"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.warning = warning.isEmpty ? nil : warning
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite, raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

private enum WorkerFailure: Error {
    case unavailable, launch, failed, invalidOutput, cancelled, cacheWrite

    var message: String {
        switch self {
        case .unavailable: return "统计组件缺失，请重新构建 Lite 应用。"
        case .launch: return "无法启动统计组件，请检查应用安装。"
        case .failed: return "统计未完成，保留上次结果；可稍后手动刷新。"
        case .invalidOutput: return "统计结果格式异常，保留上次结果。"
        case .cancelled: return "统计已取消。"
        case .cacheWrite: return "统计已完成，但本地快照未能保存。"
        }
    }
}

// 一次性子进程；在后台排空 stdout，避免管道写满造成死锁。
private final class WorkerTask {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func start(paths: AppPaths, completion: @escaping (Result<UsageSnapshot, WorkerFailure>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard FileManager.default.isExecutableFile(atPath: paths.node.path),
                  FileManager.default.fileExists(atPath: paths.worker.path) else {
                completion(.failure(.unavailable)); return
            }
            let child = Process()
            let output = Pipe()
            child.executableURL = paths.node
            child.arguments = [paths.worker.path, "--queue", paths.queue.path, "--database", paths.database.path]
            if let collector = paths.collector { child.arguments! += ["--collect-state-dir", collector.path] }
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            // 错误仅转换为固定中文状态，不展示可能含有会话内容的原始 stderr。
            child.standardError = FileHandle.nullDevice
            lock.lock()
            if cancelled { lock.unlock(); completion(.failure(.cancelled)); return }
            process = child
            do { try child.run() } catch {
                process = nil; lock.unlock(); completion(.failure(.launch)); return
            }
            lock.unlock()
            var data = Data()
            var oversized = false
            while true {
                let chunk = output.fileHandleForReading.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                if data.count + chunk.count > 8 * 1024 * 1024 {
                    oversized = true
                    if child.isRunning { child.terminate() }
                    break
                }
                data.append(chunk)
            }
            child.waitUntilExit()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { completion(.failure(.cancelled)) }
            else if oversized { completion(.failure(.invalidOutput)) }
            else if child.terminationStatus != 0 { completion(.failure(.failed)) }
            else if let snapshot = UsageSnapshot(data: data) { completion(.success(snapshot)) }
            else { completion(.failure(.invalidOutput)) }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true
        if let child = process, child.isRunning { child.terminate() }
        lock.unlock()
    }
}

private func saveSnapshot(_ snapshot: UsageSnapshot, to url: URL, stamp: FileStamp, day: String, timezone: String) throws {
    var raw = snapshot.raw
    raw["_lite_queue_stamp"] = stamp.dictionary
    raw["_lite_day"] = day
    raw["_lite_timezone"] = timezone
    raw["_lite_app_build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func dayKey(_ date: Date = Date()) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

private func tokenText(_ number: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    formatter.locale = Locale(identifier: "zh_CN")
    return formatter.string(from: NSNumber(value: number)) ?? "—"
}

private func compactTokens(_ number: Double) -> String {
    let unit: Double; let suffix: String
    if number >= 1_000_000_000 { unit = 1_000_000_000; suffix = "B" }
    else if number >= 1_000_000 { unit = 1_000_000; suffix = "M" }
    else if number >= 1_000 { unit = 1_000; suffix = "K" }
    else { return tokenText(number) }
    return String(format: "%.1f%@", number / unit, suffix)
}

private func costText(_ number: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = Locale(identifier: "en_US")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = number > 0 && number < 0.01 ? 4 : 2
    return formatter.string(from: NSNumber(value: number)) ?? "—"
}

private func dateText(_ date: Date?) -> String {
    guard let date = date else { return "未知" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

private func apiMoney(_ value: Double) -> String { String(format: "$%.4f", value) }

private func apiDate(_ date: Date, format: String = "MM-dd HH:mm") -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = format
    return formatter.string(from: date)
}

// 使用相同的不透明语义底色，避免独立窗口与系统玻璃 popover 的对比度不同。
private final class LiteSurfaceView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class LiteCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 9, yRadius: 9)
            NSColor.labelColor.withAlphaComponent(0.065).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.09).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class LiteContentStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class LiteModelDotView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 5, height: 5))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 5).isActive = true
        heightAnchor.constraint(equalToConstant: 5).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private final class LiteViewController: NSViewController {
    private let content = LiteContentStackView()
    private let scroll = NSScrollView()
    private let collectionHelp = "反重力和 OMP（含 Orca 会话）由 Lite 每分钟在本机增量采集；其余来源读取原 TokenTracker 采集队列，仍依赖原有 hooks／CLI。本机统计不会上传云端。费用为模型价目估算，不代表实际账单。"
    private static let modelColors: [NSColor] = [
        NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.60, green: 0.45, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.72, blue: 0.65, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.55, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.70, green: 0.50, blue: 0.75, alpha: 1)
    ]
    var onRefresh: (() -> Void)?
    var onAPIRefresh: (() -> Void)?
    var onAPISettings: (() -> Void)?
    var onQuit: (() -> Void)?

    var fittedContentSize: NSSize {
        _ = view
        view.layoutSubtreeIfNeeded()
        // 只测量内容栈，避免把滚动视口原先的固定高度当成内容高度。
        return NSSize(width: 440, height: ceil(content.fittingSize.height))
    }

    override func loadView() {
        view = LiteSurfaceView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 14, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.required, for: .vertical)
        content.setContentCompressionResistancePriority(.required, for: .vertical)
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
    }

    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func add(_ child: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func append(_ child: NSView) {
        content.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        return view
    }

    private func summaryCard(title: String, amount: UsageAmount?) -> NSView {
        let card = LiteCardView()
        let stack = verticalStack(spacing: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let partial = (amount?.unpriced ?? 0) > 0
        let heading = label(partial ? "\(title) · 部分估算" : title, size: 10, weight: .medium, color: .secondaryLabelColor)
        heading.font = roundedFont(size: 10, weight: .medium)
        let number = label(amount.map { compactTokens($0.tokens) } ?? "—", size: 20, weight: .bold)
        number.font = roundedFont(size: 20, weight: .bold)
        number.maximumNumberOfLines = 1
        number.lineBreakMode = .byTruncatingTail
        let cost = label(amount.map { $0.cost == 0 && $0.unpriced > 0 ? "待定价" : costText($0.cost) } ?? "等待统计", size: 10, weight: .medium, color: .secondaryLabelColor)
        cost.font = roundedFont(size: 10, weight: .medium)
        cost.maximumNumberOfLines = 1
        cost.lineBreakMode = .byTruncatingTail
        add(heading, to: stack); add(number, to: stack); add(cost, to: stack)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])
        card.setAccessibilityElement(true)
        card.setAccessibilityLabel("\(title)，\(number.stringValue) Token，\(cost.stringValue)\(partial ? "部分估算费用" : "估算费用")")
        return card
    }

    private func section(title: String) -> NSStackView {
        let stack = verticalStack(spacing: 7)
        add(label(title, size: 12, weight: .semibold, color: .secondaryLabelColor), to: stack)
        return stack
    }

    private func row(_ left: String, _ right: String, dot: NSColor? = nil) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        if let dot = dot { stack.addArrangedSubview(LiteModelDotView(color: dot)) }
        let title = label(left, color: dot == nil ? .secondaryLabelColor : .labelColor)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingMiddle
        let value = label(right, size: 11, color: .secondaryLabelColor)
        value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        value.maximumNumberOfLines = 1
        value.alignment = .right
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(title); stack.addArrangedSubview(spacer()); stack.addArrangedSubview(value)
        return stack
    }

    private func footer(snapshot: UsageSnapshot?, isRunning: Bool) -> NSView {
        let stack = verticalStack(spacing: 7)
        let line = NSBox()
        line.boxType = .separator
        add(line, to: stack)
        let note = NSStackView()
        note.orientation = .horizontal
        note.alignment = .centerY
        note.spacing = 5
        let partial = (snapshot?.all.unpriced ?? 0) > 0
        var help = collectionHelp
        if let snapshot = snapshot, partial {
            help = "Token 已完整统计；费用仅包含能确认价格的用量。\n今日待定价：\(compactTokens(snapshot.today.unpriced)) Token\n本月待定价：\(compactTokens(snapshot.month.unpriced)) Token\n累计待定价：\(compactTokens(snapshot.all.unpriced)) Token\n未定价部分不按免费计费，也不猜测价格。\n\n" + collectionHelp
        }
        note.addArrangedSubview(label(partial ? "本机统计 · 部分费用估算" : "本机统计 · 费用为估算", size: 11, color: .secondaryLabelColor))
        let info = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "采集依赖说明") ?? NSImage())
        info.contentTintColor = .secondaryLabelColor
        info.setAccessibilityLabel(help)
        info.widthAnchor.constraint(equalToConstant: 12).isActive = true
        info.heightAnchor.constraint(equalToConstant: 12).isActive = true
        note.addArrangedSubview(info)
        note.addArrangedSubview(spacer())
        add(note, to: stack)
        let collected = label("最后采集：\(dateText(snapshot?.queueUpdatedAt))", size: 11, color: .secondaryLabelColor)
        add(collected, to: stack)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12
        let refresh = NSButton(title: isRunning ? "正在更新…" : "刷新统计", target: self, action: #selector(refreshClicked))
        refresh.isBordered = false
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.imagePosition = .imageLeading
        refresh.font = .systemFont(ofSize: 12, weight: .medium)
        refresh.contentTintColor = .controlAccentColor
        refresh.isEnabled = !isRunning
        refresh.setAccessibilityLabel(isRunning ? "正在更新本机统计" : "刷新本机统计")
        refresh.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        let quit = NSButton(title: "退出", target: self, action: #selector(quitClicked))
        quit.isBordered = false
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quit.imagePosition = .imageLeading
        quit.font = .systemFont(ofSize: 12)
        quit.contentTintColor = .secondaryLabelColor
        quit.setAccessibilityLabel("退出 TokenTracker Lite")
        quit.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        buttons.addArrangedSubview(refresh); buttons.addArrangedSubview(spacer()); buttons.addArrangedSubview(quit)
        add(buttons, to: stack)
        return stack
    }

    private func apiMetric(_ title: String, value: String, note: String) -> NSView {
        let card = LiteCardView()
        let stack = verticalStack(spacing: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        add(label(title, size: 10, weight: .medium, color: .secondaryLabelColor), to: stack)
        let number = label(value, size: 17, weight: .semibold)
        number.font = roundedFont(size: 17, weight: .semibold)
        number.maximumNumberOfLines = 1
        number.lineBreakMode = .byTruncatingTail
        add(number, to: stack)
        add(label(note, size: 9, color: .secondaryLabelColor), to: stack)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])
        card.setAccessibilityElement(true)
        card.setAccessibilityLabel("\(title)，\(value)，\(note)")
        return card
    }

    private func apiCard(_ monitor: TopAPIMonitor) -> NSView {
        let card = NSView()
        let stack = verticalStack(spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let dotColor: NSColor = monitor.error != nil || monitor.snapshot?.planError != nil ? .systemOrange : monitor.snapshot == nil ? .secondaryLabelColor : .systemGreen
        header.addArrangedSubview(LiteModelDotView(color: dotColor))
        let name = monitor.snapshot?.keyName ?? ""
        let title = label("api-top.com" + (name.isEmpty ? "" : " · \(name)"), size: 12, weight: .semibold)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        header.addArrangedSubview(title)
        header.addArrangedSubview(spacer())
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新 API 账单") ?? NSImage(),
                               target: self, action: #selector(apiRefreshClicked))
        refresh.isBordered = false
        refresh.contentTintColor = .secondaryLabelColor
        refresh.isEnabled = monitor.isConfigured && !monitor.isRefreshing
        refresh.setAccessibilityLabel("刷新 API 账单")
        header.addArrangedSubview(refresh)
        let settings = NSButton(title: "设置", target: self, action: #selector(apiSettingsClicked))
        settings.isBordered = false
        settings.font = .systemFont(ofSize: 11)
        settings.contentTintColor = .controlAccentColor
        settings.setAccessibilityLabel("API 监控设置")
        header.addArrangedSubview(settings)
        add(header, to: stack)

        let current = monitor.snapshot
        let recordedPlan = current?.recordedPlan
        let planNote = recordedPlan == nil ? current?.planError ?? "等待套餐消费记录" :
            current.map { "刷新 " + apiDate($0.fetchedAt, format: "MM-dd HH:mm:ss") } ?? "等待刷新"
        let today = current.flatMap { $0.dayStart == TopAPISnapshot.beijingDayStart() ? $0 : nil }
        let amounts = NSStackView()
        amounts.orientation = .horizontal
        amounts.distribution = .fillEqually
        amounts.alignment = .top
        amounts.spacing = 8
        amounts.addArrangedSubview(apiMetric("今日使用", value: today.map { ($0.todayComplete ? "" : "≥") + apiMoney($0.todayUSD) } ?? "—",
                                            note: today?.todayComplete == true ? "北京时间零点起" : "已确认下限"))
        amounts.addArrangedSubview(apiMetric("本周已用", value: recordedPlan.map { apiMoney($0.usedUSD) } ?? "—",
                                            note: planNote))
        amounts.addArrangedSubview(apiMetric("本周剩余", value: recordedPlan.map { apiMoney($0.remainingUSD) } ?? "—",
                                            note: planNote))
        add(amounts, to: stack)

        let account = NSStackView()
        account.orientation = .horizontal
        account.distribution = .fillEqually
        account.alignment = .top
        account.spacing = 8
        let balanceNote = current?.balanceError.map { current?.accountBalanceUSD == nil ? $0 : "上次查询结果" }
            ?? (current?.accountBalanceUSD == nil ? "等待查询充值余额" : "账户充值余额")
        account.addArrangedSubview(apiMetric("账户余额", value: current?.accountBalanceUSD.map { apiMoney($0) } ?? "—",
                                            note: balanceNote))
        let cycle = current?.cycle
        let cycleNote = cycle.map { state in
            if let day = state.dayNumber() { return day <= 7 ? "第 \(day) 天 · 4周循环" : "等待满额恢复" }
            return state.lastResetAt.map { "满额恢复 " + apiDate($0) } ?? "当前周起算 · 4周循环"
        } ?? "等待套餐额度"
        account.addArrangedSubview(apiMetric("套餐周期", value: cycle.map { "第 \($0.week) / 4 周" } ?? "—", note: cycleNote))
        let remainingDays = cycle?.remainingDays()
        let endDateNote = cycle?.estimatedEndDate().map { "预计到期：" + apiDate($0, format: "yyyy-MM-dd") }
        account.addArrangedSubview(apiMetric("套餐剩余天数", value: remainingDays.map { "\($0) 天" } ?? "—",
                                            note: endDateNote ?? "等待周期校准"))
        add(account, to: stack)

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        return card
    }

    func render(snapshot: UsageSnapshot?, isRunning: Bool, queueExists: Bool, error: String?, topAPI: TopAPIMonitor) {
        _ = view
        let previousOrigin = scroll.contentView.bounds.origin
        for child in content.arrangedSubviews { content.removeArrangedSubview(child); child.removeFromSuperview() }
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        let bolt = NSImageView(image: NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) ?? NSImage())
        bolt.contentTintColor = .controlAccentColor
        bolt.widthAnchor.constraint(equalToConstant: 16).isActive = true
        bolt.heightAnchor.constraint(equalToConstant: 19).isActive = true
        header.addArrangedSubview(bolt)
        header.addArrangedSubview(label("TokenTracker Lite", size: 18, weight: .semibold))
        header.addArrangedSubview(spacer())
        append(header)

        let summary = NSStackView()
        summary.orientation = .horizontal
        summary.distribution = .fillEqually
        summary.alignment = .top
        summary.spacing = 6
        summary.addArrangedSubview(summaryCard(title: "今日", amount: snapshot?.today))
        summary.addArrangedSubview(summaryCard(title: "本月", amount: snapshot?.month))
        summary.addArrangedSubview(summaryCard(title: "累计", amount: snapshot?.all))
        append(summary)
        append(apiCard(topAPI))

        let messages = verticalStack(spacing: 5)
        if let error = error {
            add(label(error, size: 11, color: .systemOrange), to: messages)
        } else if !queueExists {
            add(label("未找到采集队列，等待原有 hooks／CLI 产生记录。", size: 11, color: .systemOrange), to: messages)
        } else if isRunning && snapshot == nil {
            add(label("正在读取本地统计…", size: 11, color: .secondaryLabelColor), to: messages)
        } else if snapshot == nil {
            add(label("暂无可用统计。", size: 11, color: .secondaryLabelColor), to: messages)
        }
        if let snapshot = snapshot {
            if let warning = snapshot.warning { add(label(warning, size: 11, color: .systemOrange), to: messages) }
        }
        if !messages.arrangedSubviews.isEmpty { append(messages) }

        let days = section(title: "近 7 天")
        if let snapshot = snapshot, !snapshot.days.isEmpty {
            for day in snapshot.days {
                let name = String((day["day"] as? String ?? "未知").suffix(5))
                let tokens = (day["tokens"] as? NSNumber)?.doubleValue ?? 0
                let cost = (day["cost_usd"] as? NSNumber)?.doubleValue ?? 0
                add(row(name, "\(compactTokens(tokens)) · \(costText(cost))"), to: days)
            }
        } else {
            add(label("暂无每日记录", size: 11, color: .tertiaryLabelColor), to: days)
        }
        append(days)
        let models = section(title: "本月模型 Top 5")
        if let snapshot = snapshot, !snapshot.models.isEmpty {
            for (index, model) in snapshot.models.enumerated() {
                let name = String((model["model"] as? String ?? "未知模型").prefix(80))
                let tokens = (model["tokens"] as? NSNumber)?.doubleValue ?? 0
                let cost = (model["cost_usd"] as? NSNumber)?.doubleValue ?? 0
                let unpriced = (model["unpriced_tokens"] as? NSNumber)?.doubleValue ?? 0
                let estimate = unpriced > 0 ? (cost == 0 ? "待定价" : "\(costText(cost))（部分）") : costText(cost)
                add(row(name, "\(compactTokens(tokens)) · \(estimate)", dot: Self.modelColors[index % Self.modelColors.count]), to: models)
            }
        } else {
            add(label("暂无模型记录", size: 11, color: .tertiaryLabelColor), to: models)
        }
        append(models)
        append(footer(snapshot: snapshot, isRunning: isRunning))

        // 数据刷新只替换内容；保留用户的滚动位置，内容缩短时才收回到有效范围。
        view.layoutSubtreeIfNeeded()
        let maximumY = max(0, content.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, previousOrigin.y), maximumY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func refreshClicked() { onRefresh?() }
    @objc private func apiRefreshClicked() { onAPIRefresh?() }
    @objc private func apiSettingsClicked() { onAPISettings?() }
    @objc private func quitClicked() { onQuit?() }
}

@MainActor private final class LiteAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let paths = AppPaths()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let panel = LiteViewController()
    private let topAPI = TopAPIMonitor()
    private var statisticsWindow: NSWindow?
    private var windowPanel: LiteViewController?
    private var snapshot: UsageSnapshot?
    private var committedStamp: FileStamp?
    private var committedDay = ""
    private var committedTimeZone = ""
    private var errorMessage: String?
    private var worker: WorkerTask?
    private var lastStarted = Date.distantPast
    private var pendingForce = false
    private var scheduled: DispatchWorkItem?
    private var debounce: DispatchWorkItem?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedURL: URL?
    private var watchedInode: UInt64 = 0
    private var watchedDevice: Int64 = 0
    private var periodicTimer: Timer?
    private var midnightTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        configureApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "TokenTracker Lite")
        statusItem.button?.imagePosition = .imageLeading
        popover.contentViewController = panel
        popover.contentSize = NSSize(width: 440, height: 200)
        popover.behavior = .transient
        popover.delegate = self
        synchronizeSurfaceAppearance()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.synchronizeSurfaceAppearance() }
        }
        panel.onRefresh = { [weak self] in self?.requestRefresh(force: true); self?.topAPI.refresh(force: true) }
        panel.onAPIRefresh = { [weak self] in self?.topAPI.refresh(force: true) }
        panel.onAPISettings = { [weak self] in self?.showAPISettings() }
        panel.onQuit = { NSApplication.shared.terminate(nil) }
        topAPI.onChange = { [weak self] in self?.updatePresentation() }
        loadCachedSnapshot()
        updatePresentation()
        ensureDirectoryWatcher()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.ensureDirectoryWatcher(); self?.requestRefresh(); self?.topAPI.refresh()
            }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.ensureDirectoryWatcher(); self?.scheduleMidnight(); self?.requestRefresh(); self?.topAPI.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleMidnight(); self?.requestRefresh(); self?.topAPI.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name("NSSystemTimeZoneDidChangeNotification"),
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.committedTimeZone = ""; self?.scheduleMidnight(); self?.requestRefresh()
            }
        })
        scheduleMidnight()
        requestRefresh()
        topAPI.refresh()
        if !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.async { [weak self] in self?.showStatisticsWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatisticsWindow()
        return true
    }

    private func configureApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem(title: "TokenTracker Lite", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "TokenTracker Lite")
        applicationMenu.addItem(withTitle: "退出 TokenTracker Lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let settingsItem = NSMenuItem(title: "API 监控设置…", action: #selector(showAPISettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.insertItem(settingsItem, at: 0)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)

        let viewItem = NSMenuItem(title: "显示", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "显示")
        let windowItem = NSMenuItem(title: "统计窗口", action: #selector(showStatisticsWindow), keyEquivalent: "1")
        windowItem.target = self
        viewMenu.addItem(windowItem)
        let popoverItem = NSMenuItem(title: "菜单栏面板", action: #selector(togglePopover), keyEquivalent: "2")
        popoverItem.target = self
        viewMenu.addItem(popoverItem)
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        NSApp.mainMenu = menu
    }

    // 菜单栏项目较多时图标可能被系统收起，重新打开应用仍可查看统计。
    @objc private func showStatisticsWindow() {
        popover.performClose(nil)
        let isNewWindow = statisticsWindow == nil
        if statisticsWindow == nil {
            let controller = LiteViewController()
            controller.onRefresh = { [weak self] in self?.requestRefresh(force: true); self?.topAPI.refresh(force: true) }
            controller.onAPIRefresh = { [weak self] in self?.topAPI.refresh(force: true) }
            controller.onAPISettings = { [weak self] in self?.showAPISettings() }
            controller.onQuit = { NSApplication.shared.terminate(nil) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "TokenTracker Lite"
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            windowPanel = controller
            statisticsWindow = window
        }
        synchronizeSurfaceAppearance()
        windowPanel?.render(snapshot: snapshot, isRunning: worker != nil,
                            queueExists: paths.collector != nil || FileStamp(url: paths.queue).exists, error: errorMessage, topAPI: topAPI)
        fitStatisticsWindowToContent()
        if isNewWindow { statisticsWindow?.center() }
        statisticsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        requestRefresh()
        topAPI.refresh()
    }

    @objc private func showAPISettings() {
        popover.performClose(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "API 监控设置"
        alert.informativeText = "平台：https://api-top.com\n所有平台卡片共用此 API Key。密钥保存在 macOS 钥匙串，切换后重新查询该密钥的账单。留空则保留当前密钥。"
        alert.addButton(withTitle: "保存并刷新")
        alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        field.placeholderString = "sk-…"
        field.setAccessibilityLabel("API Key")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try topAPI.configure(field.stringValue); field.stringValue = "" }
        catch {
            field.stringValue = ""
            let failure = NSAlert()
            failure.messageText = "无法保存监控设置"
            failure.informativeText = (error as? TopAPIFailure ?? .keychain).message
            failure.runModal()
        }
    }

    private func fitPopoverToContent() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let maximumHeight = max(180, (screen?.visibleFrame.height ?? 800) - 32)
        let desired = panel.fittedContentSize
        let size = NSSize(width: desired.width, height: min(desired.height, maximumHeight))
        if abs(popover.contentSize.height - size.height) >= 1 || popover.contentSize.width != size.width {
            popover.contentSize = size
        }
    }

    private func fitStatisticsWindowToContent() {
        guard let window = statisticsWindow, let controller = windowPanel else { return }
        let chromeHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let maximumHeight = max(180, (window.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 800) - chromeHeight - 32)
        let desired = controller.fittedContentSize
        let size = NSSize(width: desired.width, height: min(desired.height, maximumHeight))
        let current = window.contentView?.bounds.size ?? .zero
        guard abs(current.height - size.height) >= 1 || current.width != size.width else { return }
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(size)
        window.setFrameTopLeftPoint(topLeft)
    }

    private func synchronizeSurfaceAppearance() {
        // 菜单栏玻璃材质可随壁纸呈现不同明暗；两个统计载体统一使用应用的深色外观。
        let appearance = NSApp.effectiveAppearance
        popover.appearance = appearance
        statisticsWindow?.appearance = appearance
    }

    private func loadCachedSnapshot() {
        guard let data = try? Data(contentsOf: paths.snapshot), let cached = UsageSnapshot(data: data) else { return }
        snapshot = cached
        guard (cached.raw["_lite_app_build"] as? String) ==
                (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") else { return }
        if let stamp = cached.raw["_lite_queue_stamp"] as? [String: Any] { committedStamp = FileStamp(dictionary: stamp) }
        committedDay = cached.raw["_lite_day"] as? String ?? ""
        committedTimeZone = cached.raw["_lite_timezone"] as? String ?? ""
    }

    private func scheduleMidnight() {
        midnightTimer?.invalidate()
        guard let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 1),
                                                   matchingPolicy: .nextTime) else { return }
        midnightTimer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.requestRefresh(); self?.topAPI.refresh(); self?.scheduleMidnight()
            }
        }
        RunLoop.main.add(midnightTimer!, forMode: .common)
    }

    // 监听目录而非文件，队列被原子替换、轮换或重新创建后依然有效。
    private func ensureDirectoryWatcher() {
        guard !terminating else { return }
        var directory = paths.queue.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        let stamp = FileStamp(url: directory)
        if watchedURL == directory, watchedInode == stamp.inode, watchedDevice == stamp.device, directoryWatcher != nil { return }
        directoryWatcher?.cancel(); directoryWatcher = nil
        watchedURL = nil; watchedInode = 0; watchedDevice = 0
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                    eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke], queue: .main)
        source.setEventHandler { [weak self] in self?.directoryDidChange() }
        source.setCancelHandler { close(descriptor) }
        directoryWatcher = source; watchedURL = directory; watchedInode = stamp.inode; watchedDevice = stamp.device
        source.resume()
    }

    private func directoryDidChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.ensureDirectoryWatcher(); self?.requestRefresh()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func requestRefresh(force: Bool = false) {
        guard !terminating else { return }
        let stamp = FileStamp(url: paths.queue)
        let computationDay = dayKey()
        let computationTimeZone = TimeZone.autoupdatingCurrent.identifier
        let collectionDue = paths.collector != nil && Date().timeIntervalSince(lastStarted) >= 60
        let needsUpdate = force || collectionDue || stamp != committedStamp || computationDay != committedDay || computationTimeZone != committedTimeZone
        guard needsUpdate else { updatePresentation(); return }
        if worker != nil { pendingForce = pendingForce || force; return }
        let delay = force ? 0 : max(0, 60 - Date().timeIntervalSince(lastStarted))
        scheduled?.cancel(); scheduled = nil
        if delay > 0 {
            let work = DispatchWorkItem { [weak self] in self?.requestRefresh() }
            scheduled = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            updatePresentation()
            return
        }
        lastStarted = Date()
        errorMessage = nil
        let task = WorkerTask()
        worker = task
        updatePresentation()
        task.start(paths: paths) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.terminating else { return }
                self.worker = nil
                switch result {
                case .success(let fresh):
                    self.snapshot = fresh
                    self.committedStamp = stamp
                    self.committedDay = computationDay
                    self.committedTimeZone = computationTimeZone
                    do { try saveSnapshot(fresh, to: self.paths.snapshot, stamp: stamp,
                                          day: computationDay, timezone: computationTimeZone) }
                    catch { self.errorMessage = WorkerFailure.cacheWrite.message }
                case .failure(let error): self.errorMessage = error.message
                }
                self.updatePresentation()
                let forcePending = self.pendingForce
                self.pendingForce = false
                // 执行期间继续追加的记录将在下一轮处理，后台启动间隔至少 60 秒。
                if forcePending || FileStamp(url: self.paths.queue) != stamp || dayKey() != computationDay ||
                    TimeZone.autoupdatingCurrent.identifier != computationTimeZone {
                    self.requestRefresh(force: forcePending)
                }
            }
        }
    }

    private func updatePresentation() {
        let queueExists = paths.collector != nil || FileStamp(url: paths.queue).exists
        if let snapshot = snapshot {
            statusItem.button?.title = " \(compactTokens(snapshot.today.tokens))"
        } else {
            statusItem.button?.title = worker == nil ? " —" : " …"
        }
        if errorMessage != nil || !queueExists { statusItem.button?.title = " !" + (snapshot.map { " \(compactTokens($0.today.tokens))" } ?? "") }
        if popover.isShown {
            panel.render(snapshot: snapshot, isRunning: worker != nil, queueExists: queueExists, error: errorMessage, topAPI: topAPI)
            fitPopoverToContent()
        }
        if statisticsWindow?.isVisible == true {
            windowPanel?.render(snapshot: snapshot, isRunning: worker != nil, queueExists: queueExists, error: errorMessage, topAPI: topAPI)
            fitStatisticsWindowToContent()
        }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        synchronizeSurfaceAppearance()
        ensureDirectoryWatcher()
        requestRefresh()
        topAPI.refresh()
        panel.render(snapshot: snapshot, isRunning: worker != nil,
                     queueExists: paths.collector != nil || FileStamp(url: paths.queue).exists, error: errorMessage, topAPI: topAPI)
        fitPopoverToContent()
        guard let button = statusItem.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if popover.isShown {
            // 先把焦点交给弹层再收起旧窗口，避免 transient 因应用短暂失焦自动关闭。
            panel.view.window?.makeKey()
            statisticsWindow?.orderOut(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        scheduled?.cancel(); debounce?.cancel()
        periodicTimer?.invalidate(); midnightTimer?.invalidate()
        directoryWatcher?.cancel(); directoryWatcher = nil
        appearanceObservation?.invalidate(); appearanceObservation = nil
        worker?.cancel(); worker = nil
        topAPI.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let statusItem = statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

private func snapshotOnce() -> Int32 {
    let paths = AppPaths()
    let stamp = FileStamp(url: paths.queue)
    let computationDay = dayKey()
    let computationTimeZone = TimeZone.autoupdatingCurrent.identifier
    let task = WorkerTask()
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 1
    task.start(paths: paths) { result in
        switch result {
        case .success(let snapshot):
            do {
                try saveSnapshot(snapshot, to: paths.snapshot, stamp: stamp,
                                 day: computationDay, timezone: computationTimeZone)
                let publicKeys: Set<String> = ["schema_version", "generated_at", "queue_updated_at", "queue_present", "stats", "today", "month", "all", "models", "days", "warning"]
                let output = snapshot.raw.filter { publicKeys.contains($0.key) }
                let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
                code = 0
            } catch {
                FileHandle.standardError.write(Data("无法保存本地统计快照。\n".utf8))
            }
        case .failure(let error): FileHandle.standardError.write(Data((error.message + "\n").utf8))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return code
}

// 先退出应用，再执行一次性校准，避免正在运行的刷新任务覆盖缓存。
private func calibrateAPICycle() -> Int32 {
    do {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--calibrate-topapi-cycle"), index + 2 < arguments.count,
              let week = Int(arguments[index + 1]), let day = Int(arguments[index + 2]),
              (1...4).contains(week), (1...7).contains(day) else { throw TopAPIFailure.invalidCycle }
        var reference = Date()
        if let dateIndex = arguments.firstIndex(of: "--cycle-date") {
            guard dateIndex + 1 < arguments.count else { throw TopAPIFailure.invalidCycle }
            let input = arguments[dateIndex + 1]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let parsed = formatter.date(from: input), formatter.string(from: parsed) == input else { throw TopAPIFailure.invalidCycle }
            reference = parsed
        }
        guard let key = try TopAPICredential.read() else { throw TopAPIFailure.missingKey }
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenTrackerLite/topapi-snapshot.json")
        var saved = try JSONDecoder().decode(TopAPISnapshot.self, from: Data(contentsOf: cache))
        guard saved.valid, saved.keyFingerprint == TopAPICredential.fingerprint(key), let cycle = saved.cycle else {
            throw TopAPIFailure.missingCycle
        }
        saved.cycle = try cycle.calibrated(week: week, day: day, on: reference)
        try JSONEncoder().encode(saved).write(to: cache, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
        print("已校准套餐周期：第\(week)周第\(day)天（\(apiDate(reference, format: "yyyy-MM-dd"))，北京时间）。")
        return 0
    } catch {
        let message = (error as? TopAPIFailure)?.message ?? "无法保存套餐周期校准，请确认已有有效账单缓存。"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
}

@main private struct LiteApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--set-topapi-key") {
            do {
                let input = FileHandle.standardInput.readData(ofLength: 257)
                guard let key = String(data: input, encoding: .utf8) else { throw TopAPIFailure.invalidKey }
                _ = try TopAPICredential.save(key)
                print("监控密钥已保存到 macOS 钥匙串。")
            } catch {
                FileHandle.standardError.write(Data(((error as? TopAPIFailure ?? .keychain).message + "\n").utf8))
                exit(1)
            }
        } else if CommandLine.arguments.contains("--calibrate-topapi-cycle") {
            exit(calibrateAPICycle())
        } else if CommandLine.arguments.contains("--snapshot-once") {
            exit(snapshotOnce())
        } else {
            let application = NSApplication.shared
            let delegate = LiteAppDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    }
}
