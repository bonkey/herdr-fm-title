// title.swift — fallback backend for fm-title when the `fm` CLI is missing, with the same
// interface: `title -i <instructions> [--schema <file>]`, text on stdin, reply on stdout. With a
// schema file (JSON, as `fm schema` writes it) the reply is JSON of that schema. Exit 2 when Apple
// Intelligence is unavailable. fm-title compiles it once with `swiftc -O`.
import Foundation
import FoundationModels

let args = CommandLine.arguments
func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

guard case .available = SystemLanguageModel.default.availability else {
    FileHandle.standardError.write(Data("title: model unavailable: \(SystemLanguageModel.default.availability)\n".utf8))
    exit(2)
}

let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
do {
    let session = LanguageModelSession(instructions: option("-i") ?? "")
    let options = GenerationOptions(samplingMode: .greedy)
    if let path = option("--schema") {
        let schema = try JSONDecoder().decode(GenerationSchema.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        print(try await session.respond(to: text, schema: schema, options: options).content.jsonString)
    } else {
        print(try await session.respond(to: text, options: options).content)
    }
} catch {
    FileHandle.standardError.write(Data("title: \(error)\n".utf8))
    exit(1)
}
