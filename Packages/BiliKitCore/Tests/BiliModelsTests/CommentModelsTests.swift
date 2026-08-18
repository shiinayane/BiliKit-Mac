import Testing

@testable import BiliModels

struct CommentModelsTests {
    @Test
    func videoSubjectUsesAIDWithoutPartIdentity() {
        let subject = CommentSubjectIdentity.video(aid: 700_001)

        #expect(subject.type == 1)
        #expect(subject.oid == 700_001)
    }

    @Test
    func statusAndProvenanceKeepIndependentServerSemantics() {
        #expect(CommentUnavailableReason.unknown(rawValue: 42) != .folded)
        #expect(CommentProvenance.hotList != .highLikeExposure)
        #expect(CommentProvenance.uploaderPinned != .uploaderLiked)
    }
}
