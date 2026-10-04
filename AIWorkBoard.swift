import AppKit
import SwiftUI
import SQLite3
import Darwin
import Combine

private enum WorkStatus: String {
    case running = "진행 중"
    case waiting = "확인 필요"
    case recent = "최근 작업"

    var color: Color {
        switch self {
        case .running: return Retro.blue
        case .waiting: return Retro.orange
        case .recent: return Retro.muted
        }
    }
}

private enum Retro {
    static let desktop = Color(red: 0.04, green: 0.63, blue: 0.91)
    static let background = Color(red: 0.04, green: 0.63, blue: 0.91)
    static let blush = Color(red: 0.96, green: 0.87, blue: 0.86)
    static let cream = Color(red: 0.945, green: 0.945, blue: 0.93)   // 버튼·배지·탭 바탕 (#F1F1ED)
    static let body = Color(red: 0.91, green: 0.91, blue: 0.89)      // 창 본문 바탕 (#E8E8E3)
    static let bar = Color(red: 0.227, green: 0.247, blue: 0.259)    // 제목줄·선택 탭 (#3A3F42)
    static let navy = Color(red: 0.137, green: 0.153, blue: 0.165)
    static let pink = Color(red: 0.96, green: 0.70, blue: 0.75)
    static let mint = Color(red: 0.70, green: 0.88, blue: 0.82)
    static let yellow = Color(red: 0.98, green: 0.86, blue: 0.45)
    static let blue = Color(red: 0.62, green: 0.82, blue: 0.92)
    static let orange = Color(red: 0.96, green: 0.62, blue: 0.35)
    static let muted = Color(red: 0.424, green: 0.451, blue: 0.467)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private struct WorkItem: Identifiable {
    let id: String
    let provider: String
    let title: String
    let detail: String
    let updatedAt: Date
    let status: WorkStatus
    let openURL: URL?
    var openWith: URL? = nil

    var isActive: Bool { status != .recent }
}

private struct CodexUsage {
    let fiveHour: Int
    let weekly: Int
}

private enum WorkReader {
    private static var interactionCache: [String: (size: UInt64, waiting: Bool)] = [:]
    // Codex 세션 로그(rollout)에 남는 rate_limits에서 5시간/주간 사용률을 읽는다. 창이 이미 리셋됐으면 0%로 본다.
    static func codexUsage() -> CodexUsage? {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            files.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        files.sort { $0.1 > $1.1 }

        let pattern = try? NSRegularExpression(pattern: #""primary":\{"used_percent":([0-9.]+),"window_minutes":300,"resets_at":([0-9]+)\},"secondary":\{"used_percent":([0-9.]+),"window_minutes":10080,"resets_at":([0-9]+)\}"#)
        var five: (reset: Double, used: Double)?
        var week: (reset: Double, used: Double)?
        for (url, _) in files.prefix(6) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 3_000_000 ? size - 3_000_000 : 0)
            guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern?.matches(in: text, range: range).last else { continue }
            func number(_ i: Int) -> Double { Double((text as NSString).substring(with: match.range(at: i))) ?? 0 }
            let f = (reset: number(2), used: number(1)), w = (reset: number(4), used: number(3))
            if five == nil || f.reset > five!.reset || (f.reset == five!.reset && f.used > five!.used) { five = f }
            if week == nil || w.reset > week!.reset || (w.reset == week!.reset && w.used > week!.used) { week = w }
        }
        guard let five, let week else { return nil }
        let now = Date().timeIntervalSince1970
        return CodexUsage(fiveHour: five.reset < now ? 0 : Int(five.used.rounded()),
                          weekly: week.reset < now ? 0 : Int(week.used.rounded()))
    }

    static func load() -> [WorkItem] {
        (loadCodex() + loadClaude() + loadAntigravity()).sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            if $0.status == .waiting && $1.status != .waiting { return true }
            if $1.status == .waiting && $0.status != .waiting { return false }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private static func openReadOnly(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            sqlite3_busy_timeout(db, 200)
            // WAL 보조 파일이 없으면(앱이 꺼진 상태) 읽기 전용 연결로는 열 수 없어서 아래에서 immutable로 다시 시도한다.
            if probe(db) { return db }
        }
        if db != nil { sqlite3_close(db) }
        db = nil
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard sqlite3_open_v2("file:" + encoded + "?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        if probe(db) { return db }
        sqlite3_close(db)
        return nil
    }

    private static func probe(_ db: OpaquePointer?) -> Bool {
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &query, nil) == SQLITE_OK else { return false }
        let rc = sqlite3_step(query)
        return rc == SQLITE_ROW || rc == SQLITE_DONE
    }

    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private static func loadCodex() -> [WorkItem] {
        let base = NSHomeDirectory() + "/.codex/"
        guard let db = openReadOnly(base + "state_5.sqlite") else { return [] }
        defer { sqlite3_close(db) }
        let history = openReadOnly(base + "thread_history_1.sqlite")
        defer { if history != nil { sqlite3_close(history) } }

        let cutoff = Int(Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970)
        let sql = "SELECT id, COALESCE(NULLIF(name,''), title), cwd, updated_at, rollout_path FROM threads WHERE archived=0 AND updated_at>=? ORDER BY updated_at DESC LIMIT 30"
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, Int64(cutoff))

        var items: [WorkItem] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let id = column(query, 0)
            let rawTitle = column(query, 1)
            let cwd = column(query, 2)
            let updated = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(query, 3)))
            let turnStatus = latestTurnStatus(history, id: id)
            let status: WorkStatus = codexAwaitsUser(rolloutPath: column(query, 4)) ? .waiting : turnStatus == "inProgress" ? .running : .recent
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(WorkItem(
                id: "codex-" + id,
                provider: "Codex",
                title: title.isEmpty ? "제목 없는 작업" : title,
                detail: URL(fileURLWithPath: cwd).lastPathComponent,
                updatedAt: updated,
                status: status,
                openURL: URL(string: "codex://threads/" + id)
            ))
        }
        return items
    }

    // 질문 요청과 권한 승인을 기다리는 호출을 Codex의 로컬 대화 로그에서 확인한다.
    private static func codexAwaitsUser(rolloutPath: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: rolloutPath) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if let cached = interactionCache[rolloutPath], cached.size == size { return cached.waiting }
        let start = size > 1_000_000 ? size - 1_000_000 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return false }
        var pendingQuestion = false
        var synchronousQuestionCallID: String?
        var approvalCalls = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")).dropFirst(start > 0 ? 1 : 0) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            let name = payload["name"] as? String ?? ""
            let callID = payload["call_id"] as? String ?? ""
            if type == "function_call", name == "request_user_input" || name == "request_user_input_async" || name == "request_permissions" {
                pendingQuestion = true
                synchronousQuestionCallID = name == "request_user_input_async" ? nil : callID
            } else if type == "message", payload["role"] as? String == "user" {
                pendingQuestion = false
                synchronousQuestionCallID = nil
            } else if type == "function_call_output", callID == synchronousQuestionCallID {
                pendingQuestion = false
                synchronousQuestionCallID = nil
            }

            if (type == "custom_tool_call" || type == "function_call"), !callID.isEmpty,
               let input = (payload["input"] ?? payload["arguments"]) as? String,
               input.contains("\"sandbox_permissions\":\"require_escalated\"") {
                approvalCalls.insert(callID)
            } else if (type == "custom_tool_call_output" || type == "function_call_output"), !callID.isEmpty {
                approvalCalls.remove(callID)
            }
        }
        let waiting = pendingQuestion || !approvalCalls.isEmpty
        interactionCache[rolloutPath] = (size, waiting)
        return waiting
    }

    private static func latestTurnStatus(_ db: OpaquePointer?, id: String) -> String {
        guard let db else { return "" }
        let sql = "SELECT status FROM thread_turns WHERE thread_id=? ORDER BY rollout_ordinal DESC LIMIT 1"
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(query) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = id.withCString { sqlite3_bind_text(query, 1, $0, -1, transient) }
        return sqlite3_step(query) == SQLITE_ROW ? column(query, 0) : ""
    }

    private static func loadClaude() -> [WorkItem] {
        let directory = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/sessions")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = value["pid"] as? Int,
                  processExists(pid),
                  let id = value["sessionId"] as? String else { return nil }
            let rawStatus = value["status"] as? String ?? "idle"
            let status: WorkStatus = rawStatus == "waiting" ? .waiting : rawStatus == "busy" ? .running : .recent
            let name = (value["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = value["cwd"] as? String ?? ""
            let hostSession = value["hostSessionId"] as? String ?? ""
            let appURL = FileManager.default.fileExists(atPath: "/Applications/Claude.app") ? URL(fileURLWithPath: "/Applications/Claude.app") : nil
            let link = hostSession.hasPrefix("local_") ? URL(string: "claude://code/continue?session=" + hostSession) : nil
            let timestamp = value["statusUpdatedAt"] as? String ?? value["updatedAt"] as? String ?? ""
            let updated = ISO8601DateFormatter().date(from: timestamp) ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return WorkItem(
                id: "claude-" + id,
                provider: "Claude",
                title: (name?.isEmpty == false ? name! : "Claude 작업"),
                detail: URL(fileURLWithPath: cwd).lastPathComponent,
                updatedAt: updated,
                status: status,
                openURL: link ?? appURL
            )
        }
    }

    private static func loadAntigravity() -> [WorkItem] {
        let path = NSHomeDirectory() + "/.gemini/antigravity/conversation_summaries.db"
        guard let db = openReadOnly(path) else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT conversation_id, title, preview, workspace_uris, status, not_fully_idle, last_modified_time FROM conversation_summaries WHERE killed=0 AND parent_conversation_id='' ORDER BY last_modified_time DESC LIMIT 30"
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(query) }

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity")
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let formats = ["yyyy-MM-dd HH:mm:ss.SSSSSSxxx", "yyyy-MM-dd HH:mm:ssxxx", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx", "yyyy-MM-dd'T'HH:mm:ssxxx"]
        let parsers: [DateFormatter] = formats.map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = $0
            return f
        }
        var items: [WorkItem] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let id = column(query, 0)
            var title = column(query, 1).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { title = column(query, 2).trimmingCharacters(in: .whitespacesAndNewlines) }
            let workspaceList = (try? JSONSerialization.jsonObject(with: Data(column(query, 3).utf8))) as? [String]
            let workspace = workspaceList?.first ?? ""
            let rawStatus = column(query, 4).lowercased()
            let busy = sqlite3_column_int(query, 5) != 0
            let rawTime = column(query, 6)
            guard let updated = parsers.compactMap({ $0.date(from: rawTime) }).first, updated >= cutoff else { continue }

            let waiting = ["wait", "approv", "pending", "input"].contains { rawStatus.contains($0) }
            let status: WorkStatus = waiting ? .waiting : busy ? .running : .recent
            items.append(WorkItem(
                id: "antigravity-" + id,
                provider: "Antigravity",
                title: title.isEmpty ? "제목 없는 작업" : title,
                detail: URL(string: workspace)?.lastPathComponent ?? URL(fileURLWithPath: workspace).lastPathComponent,
                updatedAt: updated,
                status: status,
                openURL: URL(string: workspace).flatMap { $0.isFileURL ? $0 : nil } ?? appURL,
                openWith: appURL
            ))
        }
        return items
    }

    private static func processExists(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}

private final class WorkStore: ObservableObject {
    @Published var items: [WorkItem] = []
    @Published var updatedAt = Date()
    @Published var codexUsage: CodexUsage?
    @Published private var seen: [String: Double]
    private let baseline: Double
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        seen = defaults.dictionary(forKey: "seenItems") as? [String: Double] ?? [:]
        if defaults.object(forKey: "seenBaseline") == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: "seenBaseline")
        }
        baseline = defaults.double(forKey: "seenBaseline")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func isUnseen(_ item: WorkItem) -> Bool {
        item.status == .recent && item.updatedAt.timeIntervalSince1970 > max(baseline, seen[item.id] ?? 0)
    }

    func markSeen(_ item: WorkItem) {
        seen[item.id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(seen, forKey: "seenItems")
    }

    func refresh() {
        items = WorkReader.load()
        codexUsage = WorkReader.codexUsage()
        updatedAt = Date()
    }
}

private struct WorkBoardView: View {
    @ObservedObject var store: WorkStore
    private enum Tab { case active, unseen, recent }
    @State private var tab = Tab.active

    private var shown: [WorkItem] {
        switch tab {
        case .active: return Array(store.items.filter(\.isActive).prefix(18))
        case .unseen: return Array(store.items.filter { store.isUnseen($0) }.prefix(18))
        case .recent: return Array(store.items.prefix(18))
        }
    }
    private var unseenCount: Int { store.items.filter { store.isUnseen($0) }.count }
    private var activeCount: Int { store.items.filter(\.isActive).count }

    var body: some View {
        ZStack {
            GridBackdrop()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("✦  AI DESKTOP  ✦")
                        .font(Retro.font(11, weight: .black))
                    Spacer()
                    if let usage = store.codexUsage {
                        Text("CODEX LEFT 5H \(100 - usage.fiveHour)% · WK \(100 - usage.weekly)%")
                            .font(Retro.font(9, weight: .bold))
                            .help("Codex 남은 한도: 5시간 / 주간")
                    }
                }
                .foregroundStyle(Retro.navy)
                .padding(.horizontal, 2)

                VStack(spacing: 0) {
                    // Pinstripe Titlebar
                    HStack(spacing: 8) {
                        Text("AI_WORKBOARD.EXE")
                            .font(Retro.font(11, weight: .black))
                            .foregroundStyle(Retro.cream)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Retro.bar)

                        // Horizontal Pinstripes
                        VStack(spacing: 2.5) {
                            ForEach(0..<4, id: \.self) { _ in
                                Rectangle().fill(Retro.cream.opacity(0.65)).frame(height: 1)
                            }
                        }

                        Button {
                            NSApp.terminate(nil)
                        } label: {
                            Text("×")
                                .font(Retro.font(12, weight: .black))
                                .foregroundStyle(Retro.cream)
                                .frame(width: 17, height: 17)
                                .background(Retro.bar)
                                .overlay(Rectangle().stroke(Retro.cream, lineWidth: 1.2))
                        }
                        .buttonStyle(.plain)
                        .help("종료")
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(Retro.bar)

                    Rectangle().fill(Retro.navy).frame(height: 2)

                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("MY AI TASKS")
                                    .font(Retro.font(18, weight: .heavy))
                                Text("AI 작업들 한눈에 보기")
                                    .font(Retro.font(10, weight: .medium))
                                    .foregroundStyle(Retro.muted)
                            }
                            Spacer()
                        }
                        .foregroundStyle(Retro.navy)
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

                        HStack(spacing: 8) {
                            tabButton("진행 중 \(activeCount)", selected: tab == .active) { tab = .active }
                            tabButton("안 본 작업 \(unseenCount)", selected: tab == .unseen) { tab = .unseen }
                            tabButton("최근 작업", selected: tab == .recent) { tab = .recent }
                            Spacer()
                            Button { store.refresh() } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(Retro.navy)
                                    .frame(width: 25, height: 25)
                                    .background(Retro.cream)
                                    .overlay(Rectangle().stroke(Retro.navy, lineWidth: 1.5))
                                    .background(Rectangle().fill(Retro.navy).offset(x: 2, y: 2))
                            }
                            .buttonStyle(.plain).help("새로고침")
                        }
                        .foregroundStyle(Retro.navy)
                        .padding(.horizontal, 16).padding(.bottom, 12)

                        Rectangle().fill(Retro.navy).frame(height: 1.5)
                        }
                        .background(Retro.body)
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if shown.isEmpty {
                                    VStack(spacing: 8) {
                                        Text("☆").font(.system(size: 30))
                                        Text(tab == .active ? "진행 중인 작업이 없어요" : tab == .unseen ? "안 본 작업이 없어요" : "최근 작업이 없어요")
                                            .font(Retro.font(11))
                                    }
                                    .foregroundStyle(Retro.muted)
                                    .frame(maxWidth: .infinity).padding(.vertical, 48)
                                } else {
                                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                                        WorkRow(item: item, index: index + 1, unseen: store.isUnseen(item)) { store.markSeen(item) }
                                        if item.id != shown.last?.id {
                                            Rectangle().fill(Retro.navy.opacity(0.22)).frame(height: 1)
                                                .padding(.horizontal, 14)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(height: 300)
                        .background(Retro.body.opacity(0.55))
                    }
                }
                .clipShape(Rectangle())
                .overlay(Rectangle().stroke(Retro.navy, lineWidth: 2.5))
                .background {
                    // 그림자는 창 바깥(오른쪽·아래)에 띠로만 그린다. 창 전체 크기로 깔면 반투명한 목록 뒤로 비친다.
                    GeometryReader { geo in
                        Path { path in
                            path.addRect(CGRect(x: geo.size.width - 2, y: 5, width: 7, height: geo.size.height))
                            path.addRect(CGRect(x: 5, y: geo.size.height - 2, width: geo.size.width, height: 7))
                        }
                        .fill(Retro.navy)
                    }
                }

                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(0..<8, id: \.self) { _ in
                            Rectangle().fill(Retro.navy).frame(width: 3, height: 9)
                        }
                    }
                    .padding(.horizontal, 3).padding(.vertical, 2)
                    .overlay(Rectangle().stroke(Retro.navy, lineWidth: 1))

                    Text("AUTO-SYNC: 10S").font(Retro.font(9, weight: .bold))
                    Spacer()
                    Button { NSApp.terminate(nil) } label: {
                        Text("QUIT")
                            .font(Retro.font(9, weight: .bold))
                            .foregroundStyle(Retro.navy)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Retro.cream)
                            .overlay(Rectangle().stroke(Retro.navy, lineWidth: 1.2))
                            .background(Rectangle().fill(Retro.navy).offset(x: 1.5, y: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                .font(Retro.font(10))
                .foregroundStyle(Retro.navy)
                .padding(.horizontal, 4)

            }
            .padding(15)
        }
        .frame(width: 408, height: 530)
    }

    private func tabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Retro.font(10, weight: .bold))
                .foregroundStyle(selected ? Retro.cream : Retro.navy)
                .padding(.horizontal, 8)
                .frame(minWidth: 84, minHeight: 25)
                .background(selected ? Retro.bar : Retro.cream)
                .overlay(Rectangle().stroke(Retro.navy, lineWidth: 1.5))
                .background(Rectangle().fill(Retro.navy).offset(x: selected ? 0 : 2, y: selected ? 0 : 2))
                .offset(x: selected ? 1.5 : 0, y: selected ? 1.5 : 0)
        }
        .buttonStyle(.plain)
    }
}

private struct GridBackdrop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Classic 90s Mac OS platinum gray background
            Color(red: 0.80, green: 0.80, blue: 0.80)

            // Subtle dither noise texture (classic Mac OS pattern)
            Canvas { context, size in
                var dither = Path()
                var row = 0
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = (row % 2 == 0) ? 0 : 1
                    while x < size.width {
                        dither.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                        x += 2
                    }
                    y += 2
                    row += 1
                }
                context.fill(dither, with: .color(Color.white.opacity(0.18)))
            }

            // Pixel spider — top-left, partially cropped behind the window
            if let path = Bundle.main.path(forResource: "PixelSpider", ofType: "png"),
               let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 112)
                    .opacity(0.3)
                    .offset(x: -26, y: -30)
            }

            // Pixel character — bottom-right behind the window; shows through the translucent task list
            if let path = Bundle.main.path(forResource: "PixelChara", ofType: "png"),
               let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200)
                    .opacity(0.4)
                    .offset(x: 14, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }
}

private struct ProviderMark: View {
    let provider: String

    var body: some View {
        Group {
            switch provider {
            case "Claude": ClaudeSpokes().stroke(Retro.navy, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            case "Codex":
                if let path = Bundle.main.path(forResource: "OpenAIMark", ofType: "png"), let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).renderingMode(.template).resizable().foregroundStyle(Retro.navy)
                } else {
                    OpenAIBlossom().stroke(Retro.navy, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
            default: AntigravityArch().stroke(Retro.navy, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct ClaudeSpokes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0..<12 {
            let angle = Double(i) * .pi / 6
            let length = (i % 2 == 0 ? 1.0 : 0.72) * r
            path.move(to: CGPoint(x: c.x + CGFloat(cos(angle)) * r * 0.18, y: c.y + CGFloat(sin(angle)) * r * 0.18))
            path.addLine(to: CGPoint(x: c.x + CGFloat(cos(angle)) * length, y: c.y + CGFloat(sin(angle)) * length))
        }
        return path
    }
}

private struct OpenAIBlossom: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height) / 2
        let petal = CGRect(x: -r * 0.27, y: -r * 0.98, width: r * 0.54, height: r * 1.0)
        for i in 0..<6 {
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: CGFloat(i) * .pi / 3)
            path.addPath(Path(roundedRect: petal, cornerRadius: r * 0.27).applying(transform))
        }
        return path
    }
}

private struct AntigravityArch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                      control1: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.midY),
                      control2: CGPoint(x: rect.midX - rect.width * 0.15, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                      control1: CGPoint(x: rect.midX + rect.width * 0.15, y: rect.minY),
                      control2: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.midY))
        return path
    }
}

private struct WorkRow: View {
    let item: WorkItem
    let index: Int
    let unseen: Bool
    let onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
            if let url = item.openURL {
                if let app = item.openWith {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(item.provider == "Codex" ? Retro.yellow : item.provider == "Antigravity" ? Retro.mint : Retro.pink)
                    .overlay(Image(systemName: "folder").font(.system(size: 25)).foregroundStyle(Retro.navy))
                    .overlay(ProviderMark(provider: item.provider).frame(width: 10, height: 10).offset(y: 3.5))
                    .frame(width: 31, height: 31)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.provider.uppercased())
                            .foregroundStyle(Retro.navy)
                        Text("/  \(item.detail)").foregroundStyle(Retro.muted).lineLimit(1)
                    }.font(Retro.font(9, weight: .bold))
                    Text(item.title)
                        .font(Retro.font(11, weight: .medium))
                        .foregroundStyle(Retro.navy).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.status == .running ? "RUN" : item.status == .waiting ? "WAIT" : "DONE")
                        .font(Retro.font(9, weight: .bold))
                        .foregroundStyle(Retro.navy)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(item.status == .recent ? Retro.cream : item.status.color)
                        .overlay(Rectangle().stroke(Retro.navy, lineWidth: 1.2))
                        .background(Rectangle().fill(Retro.navy).offset(x: 1.5, y: 1.5))
                        .overlay(alignment: .topLeading) {
                            if unseen {
                                Rectangle().fill(Retro.orange).frame(width: 7, height: 7)
                                    .overlay(Rectangle().stroke(Retro.navy, lineWidth: 1))
                                    .offset(x: -3, y: -3)
                            }
                        }
                    Text(item.updatedAt, style: .relative)
                        .font(Retro.font(9)).foregroundStyle(Retro.muted)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.openURL == nil)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = WorkStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var previewWindow: NSWindow?
    private var baseIcon: NSImage?
    private var animTimer: Timer?
    private var animFrame = 0
    private var hasBadge = false
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview")
        NSApp.setActivationPolicy(preview ? .regular : .accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
               let icon = NSImage(contentsOfFile: path) {
                icon.size = NSSize(width: 16, height: 16)
                icon.isTemplate = false
                baseIcon = icon
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "AI 작업 현황")
            }
            button.action = #selector(togglePopover)
            button.target = self
        }
        cancellable = store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        updateIcon()
        popover.contentSize = NSSize(width: 408, height: 530)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: WorkBoardView(store: store))
        if preview {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 408, height: 530),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AI Work Board Preview"
            window.contentViewController = NSHostingController(rootView: WorkBoardView(store: store))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
        }
    }

    // 승인/확인 필요 → 아이콘이 통통 튐, 안 본 완료 작업 → 주황 배지 점
    private func updateIcon() {
        let items = store.items
        hasBadge = items.contains { store.isUnseen($0) }
        let waiting = items.contains { $0.status == .waiting }
        if waiting {
            guard animTimer == nil else { return }
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.animFrame = (self.animFrame + 1) % 4
                self.renderIcon()
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            animFrame = 0
        }
        renderIcon()
    }

    private func renderIcon() {
        guard let base = baseIcon, let button = statusItem.button else { return }
        let dy: CGFloat = [0, 1, 2, 1][animFrame]
        let badge = hasBadge
        let size = base.size
        let frame = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: dy - 1, width: size.width, height: size.height))
            if badge {
                let dot = NSRect(x: size.width - 6, y: size.height - 6, width: 6, height: 6)
                NSColor.white.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
                NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        frame.isTemplate = false
        button.image = frame
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@main
private struct AIWorkBoardApp {
    static func main() {
        if CommandLine.arguments.contains("--check") {
            let items = WorkReader.load()
            let active = items.filter(\.isActive)
            print("Codex: \(items.filter { $0.provider == "Codex" }.count), Claude: \(items.filter { $0.provider == "Claude" }.count), Antigravity: \(items.filter { $0.provider == "Antigravity" }.count), active: \(active.count), waiting: \(items.filter { $0.status == .waiting }.map { "\($0.provider):\($0.title)" }), usage: \(WorkReader.codexUsage().map { "left 5h \(100 - $0.fiveHour)% wk \(100 - $0.weekly)%" } ?? "n/a")")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
