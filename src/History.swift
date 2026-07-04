// FlowLocal — local dictation history in SQLite. Never leaves the machine.

import Foundation
import SQLite3

struct Dictation: Identifiable, Hashable {
    let id: Int64
    let date: Date
    let text: String
    let duration: Double
    let appName: String
    let words: Int
}

struct Stats {
    var totalWords = 0
    var wordsPerMinute = 0
    var dayStreak = 0
    var totalDictations = 0
    var totalSeconds = 0.0
}

struct DayWords: Identifiable {
    let id: String     // "yyyy-MM-dd"
    let label: String  // "Mon", "Tue", …
    let words: Int
}

final class HistoryStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "flowlocal.history")
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let path = Config.dir.appendingPathComponent("history.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            NSLog("FlowLocal: could not open history database")
            db = nil
            return
        }
        exec("""
            CREATE TABLE IF NOT EXISTS dictations(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                text TEXT NOT NULL,
                duration REAL NOT NULL,
                app TEXT NOT NULL DEFAULT '',
                words INTEGER NOT NULL
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_dictations_ts ON dictations(ts);")
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err = err {
            NSLog("FlowLocal: sqlite error — \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    func add(text: String, duration: Double, appName: String) {
        let words = text.split { $0.isWhitespace }.count
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "INSERT INTO dictations(ts, text, duration, app, words) VALUES(?,?,?,?,?)",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, duration)
            sqlite3_bind_text(stmt, 4, appName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, Int64(words))
            sqlite3_step(stmt)
        }
    }

    func delete(id: Int64) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM dictations WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    func recent(limit: Int = 200, search: String = "") -> [Dictation] {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = search.isEmpty
                ? "SELECT id, ts, text, duration, app, words FROM dictations ORDER BY ts DESC LIMIT ?"
                : "SELECT id, ts, text, duration, app, words FROM dictations WHERE text LIKE ? ORDER BY ts DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if search.isEmpty {
                sqlite3_bind_int64(stmt, 1, Int64(limit))
            } else {
                sqlite3_bind_text(stmt, 1, "%\(search)%", -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, Int64(limit))
            }
            var out: [Dictation] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Dictation(
                    id: sqlite3_column_int64(stmt, 0),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    text: String(cString: sqlite3_column_text(stmt, 2)),
                    duration: sqlite3_column_double(stmt, 3),
                    appName: String(cString: sqlite3_column_text(stmt, 4)),
                    words: Int(sqlite3_column_int64(stmt, 5))))
            }
            return out
        }
    }

    func wordsPerDay(days: Int = 14) -> [DayWords] {
        queue.sync {
            var byDate: [String: Int] = [:]
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db,
                "SELECT date(ts,'unixepoch','localtime'), SUM(words) FROM dictations WHERE ts > ? GROUP BY 1",
                -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - Double(days) * 86400)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    byDate[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int64(stmt, 1))
                }
                sqlite3_finalize(stmt)
            }
            let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
            let labelFmt = DateFormatter(); labelFmt.dateFormat = "EEE"
            var out: [DayWords] = []
            for offset in stride(from: days - 1, through: 0, by: -1) {
                let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
                let key = dayFmt.string(from: date)
                out.append(DayWords(id: key, label: labelFmt.string(from: date), words: byDate[key] ?? 0))
            }
            return out
        }
    }

    func topApps(limit: Int = 5) -> [(String, Int)] {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "SELECT app, SUM(words) FROM dictations WHERE app != '' GROUP BY app ORDER BY 2 DESC LIMIT ?",
                -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            var out: [(String, Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((String(cString: sqlite3_column_text(stmt, 0)), Int(sqlite3_column_int64(stmt, 1))))
            }
            return out
        }
    }

    func stats() -> Stats {
        queue.sync {
            var s = Stats()
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db,
                "SELECT COALESCE(SUM(words),0), COALESCE(SUM(duration),0), COUNT(*) FROM dictations",
                -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    s.totalWords = Int(sqlite3_column_int64(stmt, 0))
                    s.totalSeconds = sqlite3_column_double(stmt, 1)
                    s.totalDictations = Int(sqlite3_column_int64(stmt, 2))
                    if s.totalSeconds > 1 {
                        s.wordsPerMinute = Int(Double(s.totalWords) / (s.totalSeconds / 60.0))
                    }
                }
                sqlite3_finalize(stmt)
            }
            // Day streak: consecutive calendar days with at least one dictation, ending today or yesterday.
            if sqlite3_prepare_v2(db,
                "SELECT DISTINCT date(ts, 'unixepoch', 'localtime') FROM dictations ORDER BY 1 DESC LIMIT 366",
                -1, &stmt, nil) == SQLITE_OK {
                var days: [String] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    days.append(String(cString: sqlite3_column_text(stmt, 0)))
                }
                sqlite3_finalize(stmt)
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                fmt.timeZone = .current
                var cursor = Date()
                let today = fmt.string(from: cursor)
                if let first = days.first {
                    if first != today {
                        cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!  // streak may end yesterday
                    }
                    for day in days {
                        if day == fmt.string(from: cursor) {
                            s.dayStreak += 1
                            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
                        } else {
                            break
                        }
                    }
                }
            }
            return s
        }
    }
}
