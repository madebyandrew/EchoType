// FlowLocal — on-device transcription engine.
//
// Runs whisper-server as a child process bound to 127.0.0.1 so the model stays
// warm in RAM between dictations (spawning whisper-cli reloads the model every
// time, wasting ~1s). Falls back to whisper-cli if the server isn't available.
// Everything is local; the only "network" is loopback to our own child process.

import Foundation

final class WhisperEngine {
    private var serverProcess: Process?
    private var serverReady = false
    private let cfg: () -> Config
    private let lock = NSLock()

    private(set) var statusText = "starting…"

    init(config: @escaping () -> Config) {
        self.cfg = config
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(cfg().serverPort)")! }

    // MARK: server lifecycle

    func startServer() {
        lock.lock(); defer { lock.unlock() }
        let c = cfg()
        guard FileManager.default.fileExists(atPath: c.whisperServerPath),
              FileManager.default.fileExists(atPath: c.modelPath) else {
            statusText = "whisper-cli (cold start)"
            NSLog("FlowLocal: whisper-server or model missing, will use CLI fallback")
            return
        }
        if serverProcess?.isRunning == true { return }

        // Clear any orphan from a previous crash holding our port.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "whisper-server.*--port \(c.serverPort)"]
        try? pkill.run()
        pkill.waitUntilExit()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: c.whisperServerPath)
        proc.arguments = [
            "-m", c.modelPath,
            "--host", "127.0.0.1",
            "--port", "\(c.serverPort)",
            "-l", c.language,
            "-t", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        proc.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.serverReady = false
            self.statusText = "whisper-cli (cold start)"
            self.lock.unlock()
            NSLog("FlowLocal: whisper-server exited")
        }
        do {
            try proc.run()
            serverProcess = proc
            statusText = "warming up…"
            NSLog("FlowLocal: whisper-server starting on port \(c.serverPort)")
            DispatchQueue.global(qos: .userInitiated).async { self.waitUntilReady() }
        } catch {
            statusText = "whisper-cli (cold start)"
            NSLog("FlowLocal: failed to launch whisper-server — \(error.localizedDescription)")
        }
    }

    private func waitUntilReady() {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            var req = URLRequest(url: baseURL)
            req.timeoutInterval = 1.0
            let sem = DispatchSemaphore(value: 0)
            var up = false
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                up = (resp as? HTTPURLResponse) != nil
                sem.signal()
            }.resume()
            sem.wait()
            if up {
                lock.lock()
                serverReady = true
                statusText = "whisper-server (model warm)"
                lock.unlock()
                NSLog("FlowLocal: whisper-server ready — model is warm")
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        NSLog("FlowLocal: whisper-server never became ready; using CLI fallback")
    }

    func shutdown() {
        serverProcess?.terminate()
        serverProcess = nil
    }

    // MARK: transcription

    /// Blocking; call from a background queue. `vocabulary` biases recognition
    /// toward the user's dictionary (names, acronyms, jargon).
    func transcribe(wav: Data, vocabulary: [String] = []) throws -> String {
        let prompt = vocabulary.isEmpty ? "" : "Glossary: " + vocabulary.joined(separator: ", ") + "."
        lock.lock()
        let useServer = serverReady && serverProcess?.isRunning == true
        lock.unlock()
        if useServer {
            do { return try transcribeViaServer(wav: wav, prompt: prompt) }
            catch { NSLog("FlowLocal: server transcription failed (\(error.localizedDescription)), falling back to CLI") }
        }
        return try transcribeViaCLI(wav: wav, prompt: prompt)
    }

    private func transcribeViaServer(wav: Data, prompt: String) throws -> String {
        let boundary = "FlowLocal-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "json")
        field("temperature", "0.0")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 120

        let sem = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(NSError(domain: "FlowLocal", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "No response from local whisper-server"]))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(err); return }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let data = data else {
                result = .failure(NSError(domain: "FlowLocal", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "whisper-server HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"]))
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = obj["text"] as? String {
                result = .success(text)
            } else {
                result = .failure(NSError(domain: "FlowLocal", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected whisper-server response"]))
            }
        }.resume()
        sem.wait()
        return try result.get()
    }

    private func transcribeViaCLI(wav: Data, prompt: String) throws -> String {
        let c = cfg()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlocal-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: c.whisperCliPath)
        var args = [
            "-m", c.modelPath,
            "-f", url.path,
            "--language", c.language,
            "--no-timestamps",
            "--no-prints",
            "-t", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
        ]
        if !prompt.isEmpty { args += ["--prompt", prompt] }
        proc.arguments = args
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        try proc.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "FlowLocal", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "whisper-cli exited with status \(proc.terminationStatus)"])
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
