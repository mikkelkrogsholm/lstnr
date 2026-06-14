import Foundation
import XCTest
@testable import LstnrCore

final class AudioRecorderLevelTests: XCTestCase {
    func testEmptyDataIsZero() {
        XCTAssertEqual(AudioRecorder.pcm16RMSLevel(Data()), 0)
    }

    func testSilenceIsZero() {
        let data = pcm16Data(samples: Array(repeating: 0, count: 1024))
        XCTAssertEqual(AudioRecorder.pcm16RMSLevel(data), 0)
    }

    func testFullScaleSquareWaveIsOne() {
        let samples: [Int16] = (0..<1024).map { $0.isMultiple(of: 2) ? .max : -.max }
        let level = AudioRecorder.pcm16RMSLevel(pcm16Data(samples: samples))
        XCTAssertEqual(level, 1.0, accuracy: 0.001)
    }

    func testHalfScaleSquareWaveIsHalf() {
        let half = Int16.max / 2
        let samples: [Int16] = (0..<1024).map { $0.isMultiple(of: 2) ? half : -half }
        let level = AudioRecorder.pcm16RMSLevel(pcm16Data(samples: samples))
        XCTAssertEqual(level, 0.5, accuracy: 0.001)
    }

    func testLevelIsMonotonicWithAmplitude() {
        let quiet = pcm16Data(samples: Array(repeating: 1000, count: 512))
        let loud = pcm16Data(samples: Array(repeating: 20_000, count: 512))
        XCTAssertLessThan(
            AudioRecorder.pcm16RMSLevel(quiet),
            AudioRecorder.pcm16RMSLevel(loud)
        )
    }

    private func pcm16Data(samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }
}
