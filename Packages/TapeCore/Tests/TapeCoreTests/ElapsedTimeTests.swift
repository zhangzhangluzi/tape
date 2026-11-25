import Testing
@testable import TapeCore

struct ElapsedTimeTests {
    @Test(arguments: [(0, "0:00"), (9, "0:09"), (754, "12:34"), (3599, "59:59"), (3600, "1:00:00"), (3725, "1:02:05"), (36000, "10:00:00")])
    func clock(seconds: Int, expected: String) {
        #expect(ElapsedTime.clock(seconds) == expected)
    }

    @Test(arguments: [(0, "不到一分钟"), (59, "不到一分钟"), (60, "1 分钟"), (754, "12 分钟")])
    func spoken(seconds: Int, expected: String) {
        #expect(ElapsedTime.spoken(seconds) == expected)
    }
}
