import XCTest
@testable import Zilo
final class MobileFocusTests: XCTestCase {
    func testPausedTimeIsExcludedAndDeadlineRecordedBeforeLateForeground() async throws {
        try await MainActor.run {
            let name = "ZiloFocusTest-" + UUID().uuidString; let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
            let origin = Date(); var now = origin
            let timer = MobileFocusTimer(defaults: defaults,now: { now }); let store = MobileStore(persistence: Persistence(inMemory: true)); timer.store = store; timer.minutes = 1
            timer.start(); now = origin.addingTimeInterval(20); timer.pause(); XCTAssertEqual(timer.elapsed,20,accuracy: 0.1)
            now = origin.addingTimeInterval(200); timer.start(); now = origin.addingTimeInterval(400); timer.tick()
            XCTAssertEqual(store.focus.count,1); let record = try XCTUnwrap(store.focus.first)
            XCTAssertEqual(record.seconds,60); XCTAssertEqual(record.ended?.timeIntervalSince(origin),240); XCTAssertTrue(record.isPomodoro)
            XCTAssertEqual(timer.phase,"休息"); XCTAssertFalse(timer.running); timer.tick(); XCTAssertEqual(store.focus.count,1)
            timer.start(); now = now.addingTimeInterval(301); timer.tick(); XCTAssertEqual(timer.phase,"专注"); XCTAssertEqual(store.focus.count,1)
        }
    }
    func testElapsedRestoresAcrossAppRestartAndStopwatchDoesNotBecomePomodoro() async {
        await MainActor.run {
            let name = "ZiloFocusTest-" + UUID().uuidString; let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
            var now = Date(); let initial = now
            let first = MobileFocusTimer(defaults: defaults,now: { now }); first.selectMode("正计时"); first.start(); now = initial.addingTimeInterval(130)
            let restored = MobileFocusTimer(defaults: defaults,now: { now }); let store = MobileStore(persistence: Persistence(inMemory: true)); restored.store = store; restored.tick()
            XCTAssertEqual(restored.elapsed,130,accuracy: 0.1); restored.pause(); now = now.addingTimeInterval(100); restored.finish()
            XCTAssertEqual(store.focus.count,1); XCTAssertFalse(store.focus[0].isPomodoro); XCTAssertEqual(store.focus[0].seconds,130,accuracy: 0.1)
        }
    }
}
