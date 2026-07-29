import Foundation

public enum VideoDurationFormatting {
    public static func string(
        seconds: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        precondition(seconds >= 0, "Video duration must be nonnegative")

        let pattern: Duration.TimeFormatStyle.Pattern =
            if seconds < 3_600 {
                .minuteSecond(padMinuteToLength: 1)
            } else {
                .hourMinuteSecond(padHourToLength: 1)
            }
        return Duration.seconds(seconds).formatted(
            .time(pattern: pattern).locale(locale)
        )
    }
}
