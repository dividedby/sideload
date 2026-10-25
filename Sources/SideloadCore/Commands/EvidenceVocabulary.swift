import Foundation

/// The only words an evidence-bundle message may contain (`MessageFilter`). A fixed list: the words of Apple's
/// install-error templates (seeded from a real capture of the 0xe8008018 failure and the recorded fixtures) and of
/// the reason strings sideload itself writes. A message with any other word is omitted and counted, never edited,
/// so a name, a hostname or an ID can only get in if someone adds it here. Widen it from future captures.
enum EvidenceVocabulary {
    /// Lowercase; a word may contain an apostrophe (`device's`). Digits are not words.
    static let words: Set<String> = Set(list.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let list = """
        a about access account actually add after again against all allowed already an and any anything app
        application applications apple apps appears are as at attempt attributed available
        be because been before belongs block blocked build built but by
        can cannot canary case certificate certificates check checked clock code codesign com completed connect
        connected connection could couldn't coredeviceerror
        data database declined decoded defect denied deny depends developer development device device's devicectl devices
        did different disk dt
        embedded enable enabled enough ensure entitlement entitlements error errors exceeded executable exit
        exited expired
        fail failed failure fixed for found free from full
        guard
        has have here how
        identifier identity if in install installation installed installer installing insufficient integrity
        invalid is it its
        known
        larger later launch less limit list listed locked longer
        make match memory missing mobile mobiledeviceerrordomain mode more must
        needed no not null
        of off on one only open operation or other out outcome output
        pair paired pairing partially passcode pass passed permission please pre present previous problem produced
        profile profiles properly provisioned provisioneddevices provisioning
        reachable read reason recognise recognised rejected removed report request required restart retry
        reason running
        safety see set side sign signature signed signing since so some space started stopped storage succeeded
        success successfully support supported
        team than that the then there this timed timeout to too trust trusted try
        unable unavailable unexpected unknown unlock unrecognised until up used using
        valid verification verified verify via
        wait was were when which will with without
        xcodebuild
        you your
        """
}
