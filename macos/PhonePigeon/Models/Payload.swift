import Foundation

// Swift mirror of `proto/relay.proto`.
//
// Wire encoding note: the spec calls for binary Protobuf. To keep the macOS app
// dependency-free for now, payloads are encoded as canonical JSON (proto3 JSON
// mapping style, snake_case keys) *inside* the ChaCha20-Poly1305 ciphertext.
// Swapping `PayloadCodec` for SwiftProtobuf-generated types is a drop-in change
// because the field names match relay.proto 1:1.

/// Outer, unencrypted envelope routed by the relay server.
struct EncryptedEnvelope: Codable, Sendable {
    var messageId: String
    var senderDeviceId: String
    var targetDeviceId: String
    var nonce: Data
    var ciphertext: Data
    var serverTimestampMs: Int64
    var requiresWakeup: Bool
}

/// Inner decrypted payload — never visible to the server.
struct DevicePayload: Codable, Sendable {
    var sequenceNumber: UInt64
    var clientTimestampMs: Int64
    var body: PayloadBody
}

struct AckEvent: Codable, Sendable { var ackedMessageId: String }

struct SimInventorySync: Codable, Sendable { var sims: [SimCardWire] }

struct SimCardWire: Codable, Sendable {
    var subscriptionId: Int
    var slotIndex: Int
    var carrierName: String
    var displayName: String
    var phoneNumber: String
    var accentColorHex: String
    var isDefaultSms: Bool
    var isDefaultVoice: Bool
}

struct SmsMessageEvent: Codable, Sendable {
    var localId: String
    var threadId: String
    var subscriptionId: Int
    var address: String
    var body: String
    var direction: MessageDirection
    var status: MessageStatus
    var timestampMs: Int64
    var isRead: Bool
}

struct SmsThreadSync: Codable, Sendable { var messages: [SmsMessageEvent]; var hasMore: Bool }

struct SendSmsCommand: Codable, Sendable {
    var clientRequestId: String
    var subscriptionId: Int
    var recipientAddress: String
    var body: String
}

struct SmsStatusUpdate: Codable, Sendable {
    var clientRequestId: String
    var status: MessageStatus
    var errorReason: String
}

struct CallStateEvent: Codable, Sendable {
    var callId: String
    var subscriptionId: Int
    var remoteAddress: String
    var contactName: String
    var state: CallState
    var audioRoute: AudioRoute
    var startedAtMs: Int64
    var isMuted: Bool
}

struct PlaceCallCommand: Codable, Sendable {
    var requestId: String
    var subscriptionId: Int
    var phoneNumber: String
    var routeAudioToMac: Bool = true
}

struct CallActionCommand: Codable, Sendable {
    var callId: String
    var action: CallAction
    var dtmfDigit: String = ""
    var targetAudioRoute: AudioRoute = .unspecified
}

struct ContactEntry: Codable, Sendable {
    var contactId: String
    var displayName: String
    var phoneNumbers: [String]
    var thumbnailJpeg: Data?
}

enum ScreenAction: String, Codable, Sendable { case start = "SCREEN_START", stop = "SCREEN_STOP" }
enum ScreenState: String, Codable, Sendable {
    case idle = "SCREEN_IDLE", waiting = "SCREEN_WAITING", streaming = "SCREEN_STREAMING"
    case denied = "SCREEN_DENIED", stopped = "SCREEN_STOPPED", error = "SCREEN_ERROR"
}

/// Mac → phone: ask for view-only screen mirroring (the phone's owner must approve on the phone).
struct ScreenMirrorRequest: Codable, Sendable { var action: ScreenAction; var maxDimension: Int }

/// Phone → Mac: session state plus the encoded video size. Fields the phone omits take defaults.
struct ScreenMirrorStatus: Codable, Sendable {
    var state: ScreenState
    var width: Int = 0
    var height: Int = 0
    var message: String = ""
    /// True when the phone allows touch and keyboard input from this Mac right now.
    var control: Bool = false

    init(state: ScreenState, width: Int = 0, height: Int = 0, message: String = "", control: Bool = false) {
        self.state = state; self.width = width; self.height = height; self.message = message; self.control = control
    }
    private enum CodingKeys: String, CodingKey { case state, width, height, message, control }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(ScreenState.self, forKey: .state)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        control = try c.decodeIfPresent(Bool.self, forKey: .control) ?? false
    }
}

/// A notification from the phone (key is Android's stable id for it).
struct NotificationEvent: Codable, Sendable {
    var key: String
    var packageName: String
    var appName: String
    var title: String = ""
    var text: String = ""
    var subText: String = ""
    var postedAtMs: Int64 = 0
    var appIconPng: String = ""
    var canDismiss: Bool = true

    private enum CodingKeys: String, CodingKey { case key, packageName, appName, title, text, subText, postedAtMs, appIconPng, canDismiss }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        packageName = try c.decode(String.self, forKey: .packageName)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? packageName
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        subText = try c.decodeIfPresent(String.self, forKey: .subText) ?? ""
        postedAtMs = try c.decodeIfPresent(Int64.self, forKey: .postedAtMs) ?? 0
        appIconPng = try c.decodeIfPresent(String.self, forKey: .appIconPng) ?? ""
        canDismiss = try c.decodeIfPresent(Bool.self, forKey: .canDismiss) ?? true
    }
}
struct NotificationRemoved: Codable, Sendable { var key: String }
struct NotificationDismiss: Codable, Sendable { var key: String }

enum InputKind: String, Codable, Sendable {
    case tap = "INPUT_TAP", swipe = "INPUT_SWIPE", longPress = "INPUT_LONG_PRESS"
    case back = "INPUT_BACK", home = "INPUT_HOME", recents = "INPUT_RECENTS", text = "INPUT_TEXT", enter = "INPUT_ENTER"
}

/// Mac → phone while mirroring; coordinates are fractions (0…1) of the phone screen.
struct RemoteInput: Codable, Sendable {
    var kind: InputKind
    var x: Double = 0
    var y: Double = 0
    var x2: Double = 0
    var y2: Double = 0
    var durationMs: Int = 0
    var text: String = ""
}

/// Ephemeral X25519 exchange that gives live traffic forward secrecy (see SecureChannel).
struct RekeyMessage: Codable, Sendable { var epochId: String; var ephPub: Data; var reply: Bool }

struct ContactSyncBatch: Codable, Sendable { var contacts: [ContactEntry]; var isFinalBatch: Bool }

enum PayloadBody: Sendable {
    case ack(AckEvent)
    case simInventory(SimInventorySync)
    case smsThreadSync(SmsThreadSync)
    case smsMessage(SmsMessageEvent)
    case sendSms(SendSmsCommand)
    case smsStatus(SmsStatusUpdate)
    case callState(CallStateEvent)
    case placeCall(PlaceCallCommand)
    case callAction(CallActionCommand)
    case contactSync(ContactSyncBatch)
    case deviceStatus(DeviceStatusEvent)
    case mediaEndpoint(MediaServerEndpoint)
    case listDirReq(ListDirectoryRequest)
    case listDirRes(ListDirectoryResponse)
    case searchReq(SearchFilesRequest)
    case searchRes(SearchFilesResponse)
    case listGalleryReq(ListMediaGalleryRequest)
    case listGalleryRes(ListMediaGalleryResponse)
    case fileOpReq(FileOperationRequest)
    case fileOpRes(FileOperationResponse)
    case webrtcSignal(WebRtcSignal)
    case rekey(RekeyMessage)
    case screenReq(ScreenMirrorRequest)
    case screenStatus(ScreenMirrorStatus)
    case notification(NotificationEvent)
    case notificationRemoved(NotificationRemoved)
    case notificationDismiss(NotificationDismiss)
    case remoteInput(RemoteInput)

    /// Commands that must reach a dozing phone trigger an FCM wake-up (spec §2).
    var requiresWakeup: Bool {
        switch self {
        case .sendSms, .placeCall, .callAction, .listDirReq, .listGalleryReq, .fileOpReq, .webrtcSignal, .screenReq, .searchReq: true
        default: false
        }
    }
    var isLive: Bool {
        switch self {
        case .sendSms, .placeCall, .callAction, .callState, .remoteInput, .notificationDismiss: true
        default: false
        }
    }
}

extension PayloadBody: Codable {
    private enum CodingKeys: String, CodingKey {
        case ack, simInventory, smsThreadSync, smsMessage, sendSms, smsStatus
        case callState, placeCall, callAction, contactSync, deviceStatus
        case mediaEndpoint, listDirReq, listDirRes, searchReq, searchRes, listGalleryReq, listGalleryRes, fileOpReq, fileOpRes, webrtcSignal, rekey, screenReq, screenStatus, notification, notificationRemoved, notificationDismiss, remoteInput
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Empty oneof body"))
        }
        switch key {
        case .ack: self = .ack(try c.decode(AckEvent.self, forKey: key))
        case .simInventory: self = .simInventory(try c.decode(SimInventorySync.self, forKey: key))
        case .smsThreadSync: self = .smsThreadSync(try c.decode(SmsThreadSync.self, forKey: key))
        case .smsMessage: self = .smsMessage(try c.decode(SmsMessageEvent.self, forKey: key))
        case .sendSms: self = .sendSms(try c.decode(SendSmsCommand.self, forKey: key))
        case .smsStatus: self = .smsStatus(try c.decode(SmsStatusUpdate.self, forKey: key))
        case .callState: self = .callState(try c.decode(CallStateEvent.self, forKey: key))
        case .placeCall: self = .placeCall(try c.decode(PlaceCallCommand.self, forKey: key))
        case .callAction: self = .callAction(try c.decode(CallActionCommand.self, forKey: key))
        case .contactSync: self = .contactSync(try c.decode(ContactSyncBatch.self, forKey: key))
        case .deviceStatus: self = .deviceStatus(try c.decode(DeviceStatusEvent.self, forKey: key))
        case .mediaEndpoint: self = .mediaEndpoint(try c.decode(MediaServerEndpoint.self, forKey: key))
        case .listDirReq: self = .listDirReq(try c.decode(ListDirectoryRequest.self, forKey: key))
        case .listDirRes: self = .listDirRes(try c.decode(ListDirectoryResponse.self, forKey: key))
        case .searchReq: self = .searchReq(try c.decode(SearchFilesRequest.self, forKey: key))
        case .searchRes: self = .searchRes(try c.decode(SearchFilesResponse.self, forKey: key))
        case .listGalleryReq: self = .listGalleryReq(try c.decode(ListMediaGalleryRequest.self, forKey: key))
        case .listGalleryRes: self = .listGalleryRes(try c.decode(ListMediaGalleryResponse.self, forKey: key))
        case .fileOpReq: self = .fileOpReq(try c.decode(FileOperationRequest.self, forKey: key))
        case .fileOpRes: self = .fileOpRes(try c.decode(FileOperationResponse.self, forKey: key))
        case .webrtcSignal: self = .webrtcSignal(try c.decode(WebRtcSignal.self, forKey: key))
        case .rekey: self = .rekey(try c.decode(RekeyMessage.self, forKey: key))
        case .screenReq: self = .screenReq(try c.decode(ScreenMirrorRequest.self, forKey: key))
        case .screenStatus: self = .screenStatus(try c.decode(ScreenMirrorStatus.self, forKey: key))
        case .notification: self = .notification(try c.decode(NotificationEvent.self, forKey: key))
        case .notificationRemoved: self = .notificationRemoved(try c.decode(NotificationRemoved.self, forKey: key))
        case .notificationDismiss: self = .notificationDismiss(try c.decode(NotificationDismiss.self, forKey: key))
        case .remoteInput: self = .remoteInput(try c.decode(RemoteInput.self, forKey: key))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ack(let v): try c.encode(v, forKey: .ack)
        case .simInventory(let v): try c.encode(v, forKey: .simInventory)
        case .smsThreadSync(let v): try c.encode(v, forKey: .smsThreadSync)
        case .smsMessage(let v): try c.encode(v, forKey: .smsMessage)
        case .sendSms(let v): try c.encode(v, forKey: .sendSms)
        case .smsStatus(let v): try c.encode(v, forKey: .smsStatus)
        case .callState(let v): try c.encode(v, forKey: .callState)
        case .placeCall(let v): try c.encode(v, forKey: .placeCall)
        case .callAction(let v): try c.encode(v, forKey: .callAction)
        case .contactSync(let v): try c.encode(v, forKey: .contactSync)
        case .deviceStatus(let v): try c.encode(v, forKey: .deviceStatus)
        case .mediaEndpoint(let v): try c.encode(v, forKey: .mediaEndpoint)
        case .listDirReq(let v): try c.encode(v, forKey: .listDirReq)
        case .listDirRes(let v): try c.encode(v, forKey: .listDirRes)
        case .searchReq(let v): try c.encode(v, forKey: .searchReq)
        case .searchRes(let v): try c.encode(v, forKey: .searchRes)
        case .listGalleryReq(let v): try c.encode(v, forKey: .listGalleryReq)
        case .listGalleryRes(let v): try c.encode(v, forKey: .listGalleryRes)
        case .fileOpReq(let v): try c.encode(v, forKey: .fileOpReq)
        case .fileOpRes(let v): try c.encode(v, forKey: .fileOpRes)
        case .webrtcSignal(let v): try c.encode(v, forKey: .webrtcSignal)
        case .rekey(let v): try c.encode(v, forKey: .rekey)
        case .screenReq(let v): try c.encode(v, forKey: .screenReq)
        case .screenStatus(let v): try c.encode(v, forKey: .screenStatus)
        case .notification(let v): try c.encode(v, forKey: .notification)
        case .notificationRemoved(let v): try c.encode(v, forKey: .notificationRemoved)
        case .notificationDismiss(let v): try c.encode(v, forKey: .notificationDismiss)
        case .remoteInput(let v): try c.encode(v, forKey: .remoteInput)
        }
    }
}

// MARK: - Media gallery & file explorer (spec v2 §6, §8)

struct MediaServerEndpoint: Codable, Sendable, Equatable {
    var lanIp: String
    var httpsPort: Int
    var sessionBearerToken: String
    var serverCertSha256: Data
}

nonisolated struct FileEntry: Codable, Sendable, Hashable, Identifiable {
    var path: String
    var name: String
    var isDirectory: Bool
    var sizeBytes: Int64
    var mimeType: String
    var modifiedAtMs: Int64
    var childCount: Int

    var id: String { path }
    var modifiedAt: Date { Date(timeIntervalSince1970: Double(modifiedAtMs) / 1000) }
}

/// Whole-phone name search (Android walks its storage and returns matches, shallowest first).
struct SearchFilesRequest: Codable, Sendable { var requestId: String; var query: String; var includeHidden: Bool; var limit: Int }

struct SearchFilesResponse: Codable, Sendable {
    var requestId: String
    var entries: [FileEntry]
    var truncated: Bool = false
    var errorMessage: String = ""

    private enum CodingKeys: String, CodingKey { case requestId, entries, truncated, errorMessage }
    init(requestId: String, entries: [FileEntry], truncated: Bool = false, errorMessage: String = "") {
        self.requestId = requestId; self.entries = entries; self.truncated = truncated; self.errorMessage = errorMessage
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        entries = try c.decodeIfPresent([FileEntry].self, forKey: .entries) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
    }
}

struct ListDirectoryRequest: Codable, Sendable { var requestId: String; var path: String; var includeHidden: Bool }

struct ListDirectoryResponse: Codable, Sendable {
    var requestId: String
    var path: String
    var entries: [FileEntry]
    var errorMessage: String
}

enum MediaTypeFilter: String, Codable, Sendable, CaseIterable {
    case all = "MEDIA_ALL", images = "MEDIA_IMAGES", videos = "MEDIA_VIDEOS"
}

nonisolated struct MediaItem: Codable, Sendable, Hashable, Identifiable {
    var mediaStoreId: Int64
    var path: String
    var displayName: String
    var bucketName: String
    var mimeType: String
    var sizeBytes: Int64
    var width: Int
    var height: Int
    var durationMs: Int64
    var dateTakenMs: Int64

    var id: Int64 { mediaStoreId }
    var isVideo: Bool { mimeType.hasPrefix("video/") || durationMs > 0 }
    var dateTaken: Date { Date(timeIntervalSince1970: Double(dateTakenMs) / 1000) }
}

struct ListMediaGalleryRequest: Codable, Sendable {
    var requestId: String
    var filter: MediaTypeFilter
    var bucketName: String
    var limit: Int
    var offset: Int
}

struct ListMediaGalleryResponse: Codable, Sendable {
    var requestId: String
    var items: [MediaItem]
    var availableBuckets: [String]
    var hasMore: Bool
}

enum FileOpType: String, Codable, Sendable {
    case unspecified = "FILE_OP_UNSPECIFIED", mkdir = "MKDIR", rename = "RENAME", delete = "DELETE"
}

struct FileOperationRequest: Codable, Sendable { var requestId: String; var op: FileOpType; var sourcePath: String; var targetPath: String }
struct FileOperationResponse: Codable, Sendable { var requestId: String; var success: Bool; var errorMessage: String }
struct WebRtcSignal: Codable, Sendable { var sessionId: String; var signalType: String; var payloadJson: String }

// MARK: - Pairing

/// QR payload rendered by macOS (spec §5.1 step 2).
struct PairingQRPayload: Codable, Sendable {
    var v: Int = 2
    var sessionId: String
    var macDeviceId: String
    var macPubKey: String
    var relayUrl: String
    var lanHost: String?
    var macName: String?
    /// 256-bit secret shown only in the QR / copied code. It never goes through the relay.
    var pairingSecret: String
}

struct PairAckEnvelope: Codable, Sendable {
    var sessionId: String
    var androidDeviceId: String
    var androidPubKey: Data
    var nonce: Data
    var ciphertext: Data
}

struct PairAckBody: Codable, Sendable {
    var sessionId: String
    var deviceName: String
    var manufacturer: String
    var osVersion: String
    /// HMAC-SHA256(pairing_secret, "phonepigeon-pair-v1" ‖ session_id ‖ phone_pub ‖ mac_pub), base64.
    var proof: String
}

// MARK: - Codec

nonisolated enum PayloadCodec {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dataEncodingStrategy = .base64
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dataDecodingStrategy = .base64
        return d
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder().decode(type, from: data) }
}
