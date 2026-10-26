// The user's tasks.yaml presets, run through the bundled Orchard server so the
// results match the web Tasks UI and `orchard run` exactly (option defaults,
// input caps, JSON validation and retry all happen server-side).
import Foundation

struct OrchardTask: Decodable, Identifiable, Hashable {
    struct Option: Decodable, Hashable {
        let label: String
        let `default`: String
        let choices: [String]?
    }

    let name: String
    let label: String
    let option: Option?
    var id: String { name }
}

enum TaskClient {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static let unreachable = Failure(
        errorDescription: "The Orchard server isn't running. Start it in Setup & Status.")

    static func list(base: URL) async throws -> [OrchardTask] {
        var req = URLRequest(url: base.appending(path: "api/tasks"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            throw unreachable
        }
        try check(resp, data)
        return try JSONDecoder().decode([OrchardTask].self, from: data)
    }

    /// Streams the task's output; each element is the full text so far.
    static func run(base: URL, task: String, input: String, option: String)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    var req = URLRequest(url: base.appending(path: "api/tasks/\(task)"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONEncoder().encode(["input": input, "option": option])
                    guard let (bytes, resp) = try? await URLSession.shared.bytes(for: req) else {
                        throw unreachable
                    }
                    if (resp as? HTTPURLResponse)?.statusCode != 200 {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        try check(resp, data)
                    }
                    // Server-sent events: meta, delta, retry, error, done.
                    var event = ""
                    var text = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = Data(line.dropFirst(5).utf8)
                        let fields = (try? JSONDecoder().decode([String: String].self, from: payload)) ?? [:]
                        switch event {
                        case "delta": text += fields["text"] ?? ""
                        case "retry": text = ""  // invalid JSON; the server is trying once more
                        case "done": text = fields["text"] ?? text
                        case "error": throw Failure(errorDescription: fields["error"] ?? "Task failed.")
                        default: continue
                        }
                        cont.yield(text)
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    /// Throws the server's {"error": …} message for non-200 responses.
    private static func check(_ resp: URLResponse, _ data: Data) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code != 200 else { return }
        let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
        throw Failure(errorDescription: msg ?? "Orchard server error (\(code)).")
    }
}
