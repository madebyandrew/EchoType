// FlowLocal — local LLM via Ollama (loopback only; nothing leaves the machine).
//
// Manages `ollama serve` as a child process if it isn't already running, and
// exposes a blocking chat() used for cleanup, writing modes, and rewrites.

import Foundation

final class OllamaEngine {
    private let cfg: () -> Config
    private var serveProcess: Process?
    private let lock = NSLock()
    private var serverUp = false
    private var modelReady = false
    private var pulling = false

    init(config: @escaping () -> Config) {
        self.cfg = config
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(cfg().ollamaPort)")! }

    var available: Bool {
        lock.lock(); defer { lock.unlock() }
        return serverUp && modelReady
    }

    var statusText: String {
        lock.lock(); defer { lock.unlock() }
        if serverUp && modelReady { return "\(cfg().ollamaModel) (local, ready)" }
        if serverUp && pulling { return "downloading \(cfg().ollamaModel)…" }
        if serverUp { return "model \(cfg().ollamaModel) not downloaded" }
        if !FileManager.default.fileExists(atPath: cfg().ollamaPath) {
            return "Ollama not installed — brew install ollama"
        }
        return "starting Ollama…"
    }

    // MARK: lifecycle

    func start() {
        DispatchQueue.global(qos: .utility).async { self.ensureRunning() }
    }

    private func ensureRunning() {
        if httpGet("/api/tags") != nil {
            lock.lock(); serverUp = true; lock.unlock()
        } else if FileManager.default.fileExists(atPath: cfg().ollamaPath) {
            lock.lock()
            let alreadyLaunching = serveProcess?.isRunning == true
            lock.unlock()
            if !alreadyLaunching {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: cfg().ollamaPath)
                proc.arguments = ["serve"]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                try? proc.run()
                lock.lock(); serveProcess = proc; lock.unlock()
                NSLog("FlowLocal: launched ollama serve")
                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline {
                    if httpGet("/api/tags") != nil {
                        lock.lock(); serverUp = true; lock.unlock()
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.4)
                }
            }
        }
        refreshModelState()
        // Keep checking in the background until the model is in place.
        if !available {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { self.ensureRunning() }
        }
    }

    private func refreshModelState() {
        guard let data = httpGet("/api/tags"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return }
        let names = models.compactMap { $0["name"] as? String }
        let want = cfg().ollamaModel
        let has = names.contains { $0 == want || $0.hasPrefix(want + ":") || want.hasPrefix($0) }
        lock.lock()
        modelReady = has
        let shouldPull = !has && !pulling
        if shouldPull { pulling = true }
        lock.unlock()
        if has {
            NSLog("FlowLocal: Ollama model \(want) is ready")
        } else if shouldPull {
            NSLog("FlowLocal: pulling Ollama model \(want) in the background")
            DispatchQueue.global(qos: .utility).async { self.pullModel(want) }
        }
    }

    private func pullModel(_ name: String) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "stream": false])
        req.timeoutInterval = 3600
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        sem.wait()
        lock.lock(); pulling = false; lock.unlock()
        refreshModelState()
    }

    func shutdown() {
        serveProcess?.terminate()   // only if we launched it
        serveProcess = nil
    }

    // MARK: chat

    /// Blocking; call from a background queue.
    func chat(system: String, user: String) throws -> String {
        let payload: [String: Any] = [
            "model": cfg().ollamaModel,
            "stream": false,
            "options": ["temperature": 0.2],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 90

        let sem = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(NSError(domain: "FlowLocal", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "No response from local Ollama"]))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(err); return }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                result = .failure(NSError(domain: "FlowLocal", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Ollama HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"]))
                return
            }
            result = .success(content)
        }.resume()
        sem.wait()

        var text = try result.get().trimmingCharacters(in: .whitespacesAndNewlines)
        // Small models sometimes wrap output in quotes despite instructions.
        if text.count > 1, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    // MARK: helpers

    private func httpGet(_ path: String) -> Data? {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.timeoutInterval = 1.5
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { out = data }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }
}
