// title.swift — fallback backend for fm-title when the `fm` CLI is missing, with the same
// interface: `title -i <instructions>`, text on stdin, reply on stdout. Exit 2 when Apple
// Intelligence is unavailable. fm-title compiles it once with `swiftc -O`.
import Foundation
import FoundationModels

let args = CommandLine.arguments
let instructions = args.firstIndex(of: "-i").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""

guard case .available = SystemLanguageModel.default.availability else {
    FileHandle.standardError.write(Data("title: model unavailable: \(SystemLanguageModel.default.availability)\n".utf8))
    exit(2)
}

let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
do {
    let session = LanguageModelSession(instructions: instructions)
    let reply = try await session.respond(to: text, options: GenerationOptions(samplingMode: .greedy))
    print(reply.content)
} catch {
    FileHandle.standardError.write(Data("title: \(error)\n".utf8))
    exit(1)
}
