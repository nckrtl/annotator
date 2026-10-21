import Testing
@testable import AnnotatorCore

@Test func missingPermissionsFollowEachGrantAndRevocation() {
    var state: JSON = .object(["accessibility": .bool(false), "screenRecording": .bool(false)])
    #expect(Permission.missing(in: state) == [.accessibility, .screenRecording])
    state["accessibility"] = .bool(true)
    #expect(Permission.missing(in: state) == [.screenRecording])
    state["screenRecording"] = .bool(true)
    #expect(Permission.missing(in: state).isEmpty)
    state["accessibility"] = .bool(false)
    #expect(Permission.missing(in: state) == [.accessibility])
    #expect(Permission.missing(in: .null) == [.accessibility, .screenRecording])
}
