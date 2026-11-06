// 离线 TTS 诊断 harness：在 CI 的 macOS 上用与 App 相同的配置逻辑复现引擎初始化/合成。
// 用法: diag_bin <pack_dir>
import Foundation
import sherpa_onnx

func cstr(_ s: String) -> UnsafePointer<CChar>? { UnsafePointer(strdup(s)) }

let args = CommandLine.arguments
let dir = args.count > 1 ? args[1] : "."
let fm = FileManager.default
let subpaths = fm.subpaths(atPath: dir) ?? []
print("subpaths:", subpaths.sorted().prefix(40), flush: true)

let modelRel = subpaths.filter { $0.hasSuffix(".onnx") }.sorted().first
let tokensRel = subpaths.filter { ($0 as NSString).lastPathComponent == "tokens.txt" }.sorted().first
print("model:", modelRel ?? "NONE", "| tokens:", tokensRel ?? "NONE", flush: true)
guard let modelRel, let tokensRel else {
    print("DIAG_FAIL: missing model/tokens")
    exit(3)
}

var vits = SherpaOnnxOfflineTtsVitsModelConfig()
vits.model = cstr(dir + "/" + modelRel)
vits.tokens = cstr(dir + "/" + tokensRel)
if let lex = subpaths.filter({ $0.hasSuffix("lexicon.txt") }).sorted().first {
    vits.lexicon = cstr(dir + "/" + lex)
    print("lexicon:", lex, flush: true)
}
if subpaths.contains(where: { $0.hasPrefix("dict/") }) {
    vits.dict_dir = cstr(dir + "/dict")
    print("dict_dir: dict/", flush: true)
}
vits.noise_scale = 0.667
vits.noise_scale_w = 0.8
vits.length_scale = 1.0

var model = SherpaOnnxOfflineTtsModelConfig()
model.vits = vits
model.num_threads = 2
model.debug = 1
model.provider = cstr("cpu")

var config = SherpaOnnxOfflineTtsConfig()
config.model = model
let fsts = subpaths
    .filter { ["date.fst", "number.fst"].contains(($0 as NSString).lastPathComponent) }
    .sorted().map { dir + "/" + $0 }
if !fsts.isEmpty {
    config.rule_fsts = cstr(fsts.joined(separator: ","))
    print("rule_fsts:", fsts, flush: true)
}
config.max_num_sentences = 2

print("creating engine...", flush: true)
guard let tts = SherpaOnnxCreateOfflineTts(&config) else {
    print("DIAG_FAIL: SherpaOnnxCreateOfflineTts returned NULL")
    exit(2)
}
print("created. sampleRate:", SherpaOnnxOfflineTtsSampleRate(tts),
      "speakers:", SherpaOnnxOfflineTtsNumSpeakers(tts), flush: true)

let audio = SherpaOnnxOfflineTtsGenerate(tts, "你好，我是中国人", 0, 1.0)
if let audio, audio.pointee.n > 0 {
    print("generated n:", audio.pointee.n, "sr:", audio.pointee.sample_rate)
    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
    print("DIAG_OK")
} else {
    print("DIAG_FAIL: generate returned nil")
    exit(4)
}
