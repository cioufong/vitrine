import Foundation
import XCTest
@testable import VitrineApp
import VitrineCore

/// The engine's issue codes get sentences in every language the app ships; English keeps the
/// engine's own message.
final class ImportIssueTextTests: XCTestCase {
    private let languages = ["ja", "zh-Hans", "zh-Hant"]

    private func plan() -> ImportPlan {
        var p = ImportPlan(format: .virtualBox, source: URL(fileURLWithPath: "/x.vbox"), sourceRoot: URL(fileURLWithPath: "/"),
                           name: "box", cpuCount: 4, memoryMiB: 3000)
        p.warn(.architectureFromDisk, "couldn't tell the VM's architecture; assumed arm64")
        return p
    }

    private func bundle(_ language: String) throws -> Bundle {
        // SwiftPM compiles the string catalog into .lproj folders only with toolchains that support
        // it (not every CI image does); the catalog's completeness is checked from its JSON below.
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj") else {
            throw XCTSkip("this toolchain doesn't compile Localizable.xcstrings into \(language).lproj")
        }
        return try XCTUnwrap(Bundle(path: path))
    }

    func testEnglishShowsTheEngineMessage() {
        let issue = ImportPlan.Issue(.diskMissing, "the disk foo.vmdk (sata0:0) is missing")
        let line = ImportIssueText.line(for: issue, plan: plan(), english: true)
        XCTAssertEqual(line.text, "The disk foo.vmdk (sata0:0) is missing.")
        XCTAssertNil(line.detail)
        XCTAssertEqual(ImportIssueText.sentence("x86_64 guests are emulated"), "x86_64 guests are emulated.")
        XCTAssertEqual(ImportIssueText.sentence("qemu-img is missing!"), "qemu-img is missing!")
    }

    func testEveryCodeIsTranslated() throws {
        let english = Bundle(for: Self.self) // has no strings: the catalog's English keys come back
        for language in languages {
            let b = try bundle(language)
            for code in ImportPlan.Issue.Code.allCases {
                let issue = ImportPlan.Issue(code, "engine message for \(code.rawValue)")
                let line = ImportIssueText.line(for: issue, plan: plan(), english: false, bundle: b)
                guard let source = ImportIssueText.localized(code, plan: plan(), bundle: english) else {
                    XCTAssertEqual(code, .other)
                    XCTAssertEqual(line.text, "Engine message for other.")
                    continue
                }
                XCTAssertNotEqual(line.text, source, "\(code) has no \(language) translation")
                XCTAssertFalse(line.text.isEmpty)
                // Specifics the sentence leaves out come along in English.
                XCTAssertEqual(line.detail != nil, ImportIssueText.showsDetail(code), "\(code)")
            }
        }
    }

    func testValuesFromThePlanAppearInTheSentence() throws {
        let ja = try bundle("ja")
        let cpus = ImportIssueText.line(for: .init(.cpusReduced, "reduced CPUs from 32 to 4"), plan: plan(), english: false, bundle: ja)
        XCTAssertTrue(cpus.text.contains("4"), cpus.text)
        let memory = ImportIssueText.line(for: .init(.memoryRaised, "raised memory"), plan: plan(), english: false, bundle: ja)
        XCTAssertTrue(memory.text.contains("MB"), memory.text)
        XCTAssertFalse(memory.text.contains("GB"), memory.text)
        let app = ImportIssueText.line(for: .init(.savedState, "suspended"), plan: plan(), english: false, bundle: ja)
        XCTAssertTrue(app.text.contains("VirtualBox"), app.text)
        XCTAssertEqual(ImportIssueText.memoryLabel(4096), "4 GB")
        XCTAssertEqual(ImportIssueText.memoryLabel(6144), "6 GB")
        XCTAssertTrue(ImportIssueText.memoryLabel(3000).hasSuffix(" MB"))
    }

    /// Every string in the catalog (not only the import's) has all shipped languages.
    func testCatalogIsFullyTranslated() throws {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VitrineApp/Resources/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        var missing: [String] = []
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false && entry["extractionState"] as? String != "stale" {
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            for l in languages where locs[l] == nil { missing.append("\(l): \(key)") }
        }
        XCTAssertEqual(missing, [])
    }
}
