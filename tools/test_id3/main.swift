// ID3 metadata editor test harness (#21).
//
// Compiles the production src/AudioTags.swift and drives the real parser and
// writer with hand-built tags covering the revisions and quirks an old device
// collection actually contains: v2.2/v2.3/v2.4, ISO/UTF-16/UTF-8 text,
// unsynchronisation, extended headers, uncompressed frames, album art, and the
// requirement that a rewrite must not damage unmanaged frames or the audio.
//
// Build/run: ./tools/build_tools.sh && ./tools/test_id3

import Foundation

var checks = 0
var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func checkEqual(_ label: String, _ got: String, _ want: String) {
    check(label, got == want, "got \"\(got)\", want \"\(want)\"")
}

// MARK: - Byte builders

func synchsafeBytes(_ n: Int) -> [UInt8] {
    [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F),
     UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
}

func v23Frame(_ id: String, _ body: [UInt8]) -> [UInt8] {
    let n = body.count
    return Array(id.utf8)
        + [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF), 0, 0]
        + body
}

func v24Frame(_ id: String, _ body: [UInt8], secondFlag: UInt8 = 0) -> [UInt8] {
    Array(id.utf8) + synchsafeBytes(body.count) + [0, secondFlag] + body
}

func v22Frame(_ id: String, _ body: [UInt8]) -> [UInt8] {
    let n = body.count
    return Array(id.utf8) + [UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + body
}

func tag(version: UInt8, flags: UInt8, body: [UInt8]) -> [UInt8] {
    Array("ID3".utf8) + [version, 0, flags] + synchsafeBytes(body.count) + body
}

func latin(_ s: String) -> [UInt8] { [0] + Array(s.data(using: .isoLatin1) ?? Data()) }
func utf16(_ s: String) -> [UInt8] {
    [1, 0xFF, 0xFE] + s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
}
func utf8(_ s: String) -> [UInt8] { [3] + Array(s.utf8) }

func parsed(_ bytes: [UInt8]) -> ParsedID3Tag? {
    ID3.parse(Data(bytes))
}

// MARK: - 1. Round-trip through build/parse

print("round-trip")
var f = AudioTagFields()
f.title = "Song"
f.artist = "Band"
f.album = "Album"
f.track = "3/12"
f.year = "1999"
f.genre = "Rock"
f.comment = "hello"
let round = parsed([UInt8](ID3.build(fields: f, preserving: nil)))
checkEqual("title", round?.fields.title ?? "", "Song")
checkEqual("artist", round?.fields.artist ?? "", "Band")
checkEqual("album", round?.fields.album ?? "", "Album")
checkEqual("track", round?.fields.track ?? "", "3/12")
checkEqual("year", round?.fields.year ?? "", "1999")
checkEqual("genre", round?.fields.genre ?? "", "Rock")
checkEqual("comment", round?.fields.comment ?? "", "hello")

checkEqual("non-ascii round-trip", {
    var x = AudioTagFields(); x.title = "Björk – Jóga"; x.artist = "日本語"
    return parsed([UInt8](ID3.build(fields: x, preserving: nil)))?.fields.title ?? ""
}(), "Björk – Jóga")
checkEqual("non-ascii artist", {
    var x = AudioTagFields(); x.artist = "日本語"
    return parsed([UInt8](ID3.build(fields: x, preserving: nil)))?.fields.artist ?? ""
}(), "日本語")

// Empty fields must be dropped, not stored blank.
let empty = parsed([UInt8](ID3.build(fields: AudioTagFields(), preserving: nil)))
check("empty fields produce an empty tag", (empty?.fields ?? AudioTagFields()) == AudioTagFields())

// Encoding byte selection.
checkEqual("latin1 body uses encoding 0", "\(ID3.textBody("Café").first ?? 255)", "0")
checkEqual("non-latin body uses encoding 1", "\(ID3.textBody("日本").first ?? 255)", "1")
checkEqual("comment latin1 encoding", "\(ID3.commentBody("hi").first ?? 255)", "0")

// MARK: - 2. Reading real tag layouts

print("v2.3")
let v23Comment: [UInt8] = [0] + Array("eng".utf8) + [0] + Array("a note".utf8)
let v23 = tag(version: 3, flags: 0, body:
    v23Frame("TIT2", latin("Title"))
    + v23Frame("TPE1", utf16("Artïst"))
    + v23Frame("COMM", v23Comment))
checkEqual("v2.3 title", parsed(v23)?.fields.title ?? "", "Title")
checkEqual("v2.3 utf16 artist", parsed(v23)?.fields.artist ?? "", "Artïst")

print("v2.2")
let v22 = tag(version: 2, flags: 0, body:
    v22Frame("TT2", latin("Old Title")) + v22Frame("TP1", latin("Old Artist"))
    + v22Frame("TRK", latin("7")))
checkEqual("v2.2 title", parsed(v22)?.fields.title ?? "", "Old Title")
checkEqual("v2.2 artist", parsed(v22)?.fields.artist ?? "", "Old Artist")

print("v2.4")
let v24 = tag(version: 4, flags: 0, body:
    v24Frame("TIT2", utf8("V4 Title")) + v24Frame("TDRC", utf8("2007-05-01T12:00:00")))
checkEqual("v2.4 utf8 title", parsed(v24)?.fields.title ?? "", "V4 Title")
checkEqual("v2.4 TDRC -> year", parsed(v24)?.fields.year ?? "", "2007")

// MARK: - 3. Unsynchronisation

print("unsynchronisation")
// "ABÿ\u{0}CD" style: insert 0x00 after a 0xFF to test header-level de-unsync.
let unsynced = tag(version: 3, flags: 0x80, body:
    v23Frame("TIT2", latin("A") + [0xFF, 0x00, 0xFF, 0x00]) )
check("header-level unsync parse", parsed(unsynced) != nil)
// v2.4 per-frame unsync flag (second flag byte 0x02). The on-disk body has an
// extra 0x00 inserted after 0xFF ("XÿY" in latin-1 becomes 58 FF 00 59).
let bodyV24: [UInt8] = [0, 0x58, 0xFF, 0x00, 0x59]
let v24Unsync = tag(version: 4, flags: 0, body: v24Frame("TIT2", bodyV24, secondFlag: 0x02))
checkEqual("v2.4 frame unsync", parsed(v24Unsync)?.fields.title ?? "", "XÿY")

// MARK: - 4. Extended header

print("extended header")
// v2.3 extended header: 4-byte size N (= bytes that follow it), then N bytes.
let extBody: [UInt8] = [0, 0, 0, 6, 0, 0, 0, 0, 0, 0] // size 6 + flags(2) + padding(4)
let extTag = tag(version: 3, flags: 0x40, body: extBody + v23Frame("TIT2", latin("Ext")))
checkEqual("v2.3 extended header skipped", parsed(extTag)?.fields.title ?? "", "Ext")

// MARK: - 5. Preservation of unmanaged frames + artwork

print("preservation")
// A tiny fake image payload; the writer must carry APIC and TXXX through.
let imageBytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5]
let apicBody: [UInt8] = [0] + Array("image/jpeg".utf8) + [0] + [3] + [0] + imageBytes
let originalBody = v23Frame("TIT2", latin("Old"))
    + v23Frame("TXXX", latin("K") + [0] + latin("V"))
    + v23Frame("APIC", apicBody)
let original = parsed(tag(version: 3, flags: 0, body: originalBody))
checkEqual("artwork extracted", "\(original?.artwork?.count ?? 0)", "\(imageBytes.count)")
checkEqual("artwork bytes", (original?.artwork?.map { String(format: "%02X", $0) }.joined() ?? ""),
          imageBytes.map { String(format: "%02X", $0) }.joined())

var edited = AudioTagFields()
edited.title = "New"
let rebuilt = parsed([UInt8](ID3.build(fields: edited, preserving: original)))
checkEqual("edited title wins", rebuilt?.fields.title ?? "", "New")
check("TXXX preserved", rebuilt?.frames.contains { $0.id == "TXXX" } ?? false)
check("APIC preserved", rebuilt?.frames.contains { $0.id == "APIC" } ?? false)
check("APIC still decodable", (rebuilt?.artwork?.count ?? 0) == imageBytes.count)

// MARK: - 6. Genre and helpers

checkEqual("genre index stripped", ID3.stripGenreIndex("(17)Rock"), "Rock")
checkEqual("genre untouched", ID3.stripGenreIndex("Rock"), "Rock")
checkEqual("isoYear", ID3.isoYear("2021-03-04T05:06:07"), "2021")
checkEqual("synchsafe round-trip", "\(ID3.synchsafeValue(ID3.synchsafe(0x0FFFFFFF)[0..<4]))", "\(0x0FFFFFFF)")

// MARK: - 7. Stripping the tag from a file body

print("strip")
let audio: [UInt8] = Array("AUDIO-PAYLOAD".utf8)
let withTag = tag(version: 3, flags: 0, body: v23Frame("TIT2", latin("T"))) + audio
checkEqual("tagLength", "\(ID3.tagLength(withTag))", "\(withTag.count - audio.count)")
check("strippingTag leaves audio", Array(ID3.strippingTag(Data(withTag))) == audio)
check("strippingTag no-op without tag", Array(ID3.strippingTag(Data(audio))) == audio)

// MARK: - 8. File write/read round-trip

print("file IO")
let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ac-id3-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

// (a) A file with no tag gets a fresh one; the audio is untouched.
let noTagURL = dir.appendingPathComponent("notag.mp3")
try Data(audio).write(to: noTagURL)
var nf = AudioTagFields(); nf.title = "Fresh"; nf.artist = "A"
try ID3.write(fields: nf, to: noTagURL)
let readBack = try ID3.read(url: noTagURL)
checkEqual("fresh file title read back", readBack.fields.title, "Fresh")
check("fresh file hadTag", readBack.hadTag)
let noTagWhole = [UInt8](try Data(contentsOf: noTagURL))
check("audio preserved after write", Array(noTagWhole.suffix(audio.count)) == audio)

// (b) A file with an existing tag + trailing 128-byte ID3v1 keeps both.
let taggedURL = dir.appendingPathComponent("tagged.mp3")
var id3v1 = [UInt8](repeating: 0, count: 128)
id3v1[0] = 0x54; id3v1[1] = 0x41; id3v1[2] = 0x47 // "TAG"
let taggedWhole = tag(version: 3, flags: 0, body: v23Frame("TIT2", latin("Old"))) + audio + id3v1
try Data(taggedWhole).write(to: taggedURL)
var tf = AudioTagFields(); tf.title = "Changed"; tf.album = "New Album"
try ID3.write(fields: tf, to: taggedURL)
let changed = try ID3.read(url: taggedURL)
checkEqual("edited title", changed.fields.title, "Changed")
checkEqual("edited album", changed.fields.album, "New Album")
let taggedAfter = [UInt8](try Data(contentsOf: taggedURL))
check("ID3v1 tail preserved", Array(taggedAfter.suffix(128)) == id3v1)
check("only one ID3v2 header", taggedAfter[0] == 0x49 && taggedAfter[1] == 0x44 && taggedAfter[2] == 0x33
      && !Array(taggedAfter.dropFirst(10)).starts(with: [0x49, 0x44, 0x33]))

// MARK: - 9. Editable extension gate

check("mp3 editable", ID3.isEditable(URL(fileURLWithPath: "/x/a.mp3")))
check("MP3 editable case-insensitively", ID3.isEditable(URL(fileURLWithPath: "/x/a.MP3")))
check("flac not editable", !ID3.isEditable(URL(fileURLWithPath: "/x/a.flac")))
check("m4a not editable", !ID3.isEditable(URL(fileURLWithPath: "/x/a.m4a")))

// MARK: - Summary

print("")
if failures == 0 {
    print("ALL PASS — \(checks) checks")
} else {
    print("\(failures) FAILURE(S) of \(checks) checks")
    exit(1)
}
