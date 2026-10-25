import Foundation

// Typed views over `PortalItem`. Tolerant: unknown attributes are ignored and a missing or oddly typed one is
// nil. None of them has a field for a name, a display name, a serial number or profile content: those are
// never requested, and the report could not print them if they arrived anyway.

struct PortalCertificate {
    let id: String
    let type: String?
    let platform: String?
    let activated: Bool?
    let expires: String?
    /// The certificate's DER, from `certificateContent`.
    let der: Data?

    init(_ item: PortalItem) {
        id = item.id
        type = item.string("certificateType")
        platform = item.string("platform")
        activated = item.bool("activated")
        expires = item.string("expirationDate")
        der = item.string("certificateContent").flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    }
}

struct PortalBundleId {
    let id: String
    let identifier: String?
    let platform: String?
    let seedId: String?

    init(_ item: PortalItem) {
        id = item.id
        identifier = item.string("identifier")
        platform = item.string("platform")
        seedId = item.string("seedId")
    }
}

struct PortalDevice {
    let id: String
    let udid: String?
    let platform: String?
    let deviceClass: String?
    let model: String?
    let status: String?
    let added: String?

    init(_ item: PortalItem) {
        id = item.id
        udid = item.string("udid")
        platform = item.string("platform")
        deviceClass = item.string("deviceClass")
        model = item.string("model")
        status = item.string("status")
        added = item.string("addedDate")
    }
}

struct PortalProfile {
    let id: String
    let type: String?
    let state: String?
    let platform: String?
    let created: String?
    let expires: String?

    init(_ item: PortalItem) {
        id = item.id
        type = item.string("profileType")
        state = item.string("profileState")
        platform = item.string("platform")
        created = item.string("createdDate")
        expires = item.string("expirationDate")
    }
}
