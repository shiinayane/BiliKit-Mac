import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定弹幕运动的契约：速度档位越快时长越短，安全边界只钳制极端输入；滚动弹幕匀速走完「规划宽度 + 文字
/// 宽度」的行程，速度是行程除以（钳制后的）时长。
@Suite
struct DanmakuMotionPolicyTests {
    @Test(
        arguments: [
            (400, 100), (1_100, 429), (3_440, 1_479)
        ] as [(Double, Double)]
    )
    func fasterSpeedLevelsMoveLongAndShortTextFaster(
        surfaceWidth: Double,
        textWidth: Double
    ) {
        let durations = DanmakuSpeedLevel.allCases.map {
            DanmakuMotionPolicy.duration(
                for: .scrolling,
                textWidth: textWidth,
                surfaceWidth: surfaceWidth,
                speedLevel: $0
            )
        }

        #expect(zip(durations, durations.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test
    func durationSafetyBoundsOnlyClampExtremeInputs() {
        #expect(
            DanmakuMotionPolicy.duration(
                for: .scrolling,
                textWidth: 1,
                surfaceWidth: 1,
                speedLevel: .five
            ) == 1.5
        )
        #expect(
            DanmakuMotionPolicy.duration(
                for: .scrolling,
                textWidth: 4_000,
                surfaceWidth: 10_000,
                speedLevel: .one
            ) == 60
        )
        #expect(
            DanmakuMotionPolicy.duration(
                for: .top,
                textWidth: 123,
                surfaceWidth: 1_100,
                speedLevel: .five
            ) == 4
        )
    }

    @Test
    func scrollingDanmakuCoverPlanningWidthPlusTextWidthAtTravelOverDuration() {
        #expect(
            DanmakuMotionPolicy.scrollingTravel(textWidth: 100, planningWidth: 1_200)
                == 1_300
        )
        #expect(
            DanmakuMotionPolicy.scrollingSpeed(
                textWidth: 100,
                planningWidth: 1_200,
                durationSeconds: 13
            ) == 100
        )

        // 碰到时长下限时，屏上速度按钳制后的时长算：2pt 行程在 1.5 秒内走完。
        let clamped = DanmakuMotionPolicy.duration(
            for: .scrolling,
            textWidth: 1,
            surfaceWidth: 1,
            speedLevel: .five
        )
        #expect(
            DanmakuMotionPolicy.scrollingSpeed(
                textWidth: 1,
                planningWidth: 1,
                durationSeconds: clamped
            ) == 2 / 1.5
        )
    }
}
