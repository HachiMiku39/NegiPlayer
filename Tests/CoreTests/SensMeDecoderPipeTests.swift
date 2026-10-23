import XCTest
import Foundation
import Darwin
@testable import MusicEnrichment

final class SensMeDecoderPipeTests: XCTestCase {
    private var folder: URL!
    private var source: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SensMePipe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        source = folder.appendingPathComponent("generated.dsf")
        try Data("read-only test source".utf8).write(to: source)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func decoder(_ body: String) throws -> URL {
        let file = folder.appendingPathComponent("decoder")
        try Data(("#!/usr/bin/env python3\n" + body).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    func testExplicitNativeDecoderFeedsCoreWithoutIntermediatePCMFiles() throws {
        let executable = try decoder("import sys\nsys.stdout.buffer.write(bytes(44100*4*2))\n")
        let before = try SourceDigest.sha256(source)
        let result = try SensMeEngine.analyze(source: source, ffmpeg: executable)
        XCTAssertEqual(result.sourceSHA256, before); XCTAssertEqual(result.engineVersion, SensMeEngine.version)
        XCTAssertTrue(result.hasValidBlobChecksum); XCTAssertNil(result.summary.bpm)
        XCTAssertEqual(try SourceDigest.sha256(source), before)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["decoder", "generated.dsf"])
    }
    func testNonzeroExitAndIncompleteFramesCannotProduceAnalysis() throws {
        for body in ["import sys\nsys.stdout.buffer.write(bytes(3))\n",
                     "import sys\nsys.stdout.buffer.write(bytes(16384));sys.stdout.buffer.flush();sys.exit(5)\n"] {
            let executable = try decoder(body)
            XCTAssertThrowsError(try SensMeEngine.analyze(source: source, ffmpeg: executable))
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "read-only test source")
    }
    func testCancellationReapsTheConfirmedLiveDecoder() async throws {
        let executable = try decoder("import os,sys,time\nfrom pathlib import Path\nPath(__file__).with_suffix('.pid').write_text(str(os.getpid()))\nsys.stdout.buffer.write(bytes(16384));sys.stdout.buffer.flush();time.sleep(30)\n")
        let marker = executable.appendingPathExtension("pid"), input = source!
        let work = Task.detached { try SensMeFFmpegDecoder.forEachBuffer(source: input, executable: executable, timeout: 60) { _ in true } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), 0); work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
    }
    func testDecoderDeadlineAlsoReapsTheProcess() throws {
        // A shell builtin records the PID before exec, independent of Python
        // interpreter startup while the real full-library batch is running.
        let executable = folder.appendingPathComponent("decoder")
        try Data("#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let start = Date()
        XCTAssertThrowsError(try SensMeFFmpegDecoder.forEachBuffer(source: source, executable: executable, timeout: 1) { _ in true }) {
            XCTAssertEqual($0.localizedDescription, "音频解码响应超时")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let pid = try XCTUnwrap(Int32(String(contentsOf: executable.appendingPathExtension("pid"), encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
    }
}
