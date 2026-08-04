import BiliModels
import BiliUI
import Foundation
import SwiftUI

struct WatchHistoryCard: View {
    let item: WatchHistoryItem

    var body: some View {
        VideoCard(
            coverURL: item.coverURL,
            avatarURL: item.owner.avatarURL,
            showsAvatar: item.owner.avatarURL != nil,
            title: item.title,
            coverTrailingText: WatchHistoryCardFormatting.progress(
                progressSeconds: item.progressSeconds,
                durationSeconds: item.durationSeconds
            ),
            footerLeadingText: item.owner.name,
            footerTrailingText: WatchHistoryCardFormatting.viewedAt(
                item.viewedAt
            )
        )
    }
}

enum WatchHistoryCardFormatting {
    static func progress(
        progressSeconds: Int,
        durationSeconds: Int
    ) -> String {
        let duration = max(0, durationSeconds)
        let progress = min(max(0, progressSeconds), duration)
        if duration > 0, progress >= duration {
            return "已看完"
        }
        return "\(VideoDurationFormatting.string(seconds: progress))/"
            + VideoDurationFormatting.string(seconds: duration)
    }

    static func viewedAt(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: "今天 %02d:%02d", hour, minute)
        }
        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(format: "昨天 %02d:%02d", hour, minute)
        }

        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return String(
            format: "%d月%d日 %02d:%02d",
            month,
            day,
            hour,
            minute
        )
    }
}
