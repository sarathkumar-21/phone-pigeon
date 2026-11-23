package dev.phonepigeon.proto

import android.util.Base64
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json

/*
 * Kotlin mirror of proto/relay.proto.
 *
 * Encoding: canonical JSON with snake_case keys inside the ChaCha20-Poly1305
 * ciphertext — byte-for-byte compatible with the macOS `PayloadCodec`.
 * Field names match relay.proto 1:1, so moving to protobuf-kotlin later only
 * swaps `WireCodec`.
 */

object Base64Bytes : KSerializer<ByteArray> {
    override val descriptor = PrimitiveSerialDescriptor("Base64Bytes", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ByteArray) =
        encoder.encodeString(Base64.encodeToString(value, Base64.NO_WRAP))
    override fun deserialize(decoder: Decoder): ByteArray =
        Base64.decode(decoder.decodeString(), Base64.DEFAULT)
}

// ---------------------------------------------------------------- envelope

@Serializable
data class EncryptedEnvelope(
    @SerialName("message_id") val messageId: String,
    @SerialName("sender_device_id") val senderDeviceId: String,
    @SerialName("target_device_id") val targetDeviceId: String,
    @Serializable(with = Base64Bytes::class) val nonce: ByteArray,
    @Serializable(with = Base64Bytes::class) val ciphertext: ByteArray,
    @SerialName("server_timestamp_ms") val serverTimestampMs: Long = 0,
    @SerialName("requires_wakeup") val requiresWakeup: Boolean = false,
)

@Serializable
data class DevicePayload(
    @SerialName("sequence_number") val sequenceNumber: Long,
    @SerialName("client_timestamp_ms") val clientTimestampMs: Long,
    val body: PayloadBody,
)

/** `oneof body` — exactly one field is non-null. */
@Serializable
data class PayloadBody(
    val ack: AckEvent? = null,
    @SerialName("sim_inventory") val simInventory: SimInventorySync? = null,
    @SerialName("sms_thread_sync") val smsThreadSync: SmsThreadSync? = null,
    @SerialName("sms_message") val smsMessage: SmsMessageEvent? = null,
    @SerialName("send_sms") val sendSms: SendSmsCommand? = null,
    @SerialName("sms_status") val smsStatus: SmsStatusUpdate? = null,
    @SerialName("call_state") val callState: CallStateEvent? = null,
    @SerialName("place_call") val placeCall: PlaceCallCommand? = null,
    @SerialName("call_action") val callAction: CallActionCommand? = null,
    @SerialName("contact_sync") val contactSync: ContactSyncBatch? = null,
    @SerialName("device_status") val deviceStatus: DeviceStatusEvent? = null,
    // Files, gallery & media transport (spec v2 §8, fields 30–37)
    @SerialName("media_endpoint") val mediaEndpoint: MediaServerEndpoint? = null,
    @SerialName("list_dir_req") val listDirReq: ListDirectoryRequest? = null,
    @SerialName("list_dir_res") val listDirRes: ListDirectoryResponse? = null,
    @SerialName("search_req") val searchReq: SearchFilesRequest? = null,
    @SerialName("search_res") val searchRes: SearchFilesResponse? = null,
    @SerialName("list_gallery_req") val listGalleryReq: ListMediaGalleryRequest? = null,
    @SerialName("list_gallery_res") val listGalleryRes: ListMediaGalleryResponse? = null,
    @SerialName("file_op_req") val fileOpReq: FileOperationRequest? = null,
    @SerialName("file_op_res") val fileOpRes: FileOperationResponse? = null,
    @SerialName("webrtc_signal") val webrtcSignal: WebRtcSignal? = null,
    val rekey: RekeyMessage? = null,
    @SerialName("screen_req") val screenReq: ScreenMirrorRequest? = null,
    @SerialName("screen_status") val screenStatus: ScreenMirrorStatus? = null,
    val notification: NotificationEvent? = null,
    @SerialName("notification_removed") val notificationRemoved: NotificationRemoved? = null,
    @SerialName("notification_dismiss") val notificationDismiss: NotificationDismiss? = null,
    @SerialName("remote_input") val remoteInput: RemoteInput? = null,
    @SerialName("call_log_sync") val callLogSync: CallLogSync? = null,
) {
    /** Commands from the Mac that must reach a dozing phone (FCM wake-up). */
    val requiresWakeup get() = sendSms != null || placeCall != null || callAction != null ||
        listDirReq != null || listGalleryReq != null || fileOpReq != null || webrtcSignal != null || screenReq != null || searchReq != null
    val isLive get() = sendSms != null || placeCall != null || callAction != null || callState != null ||
        remoteInput != null || notificationDismiss != null
}

/** One row of the phone's call history. `direction` is INCOMING, OUTGOING, MISSED or REJECTED. */
@Serializable
data class CallLogEntryWire(
    val id: String,
    @SerialName("remote_address") val remoteAddress: String,
    @SerialName("contact_name") val contactName: String = "",
    val direction: String,
    @SerialName("subscription_id") val subscriptionId: Int = -1,
    @SerialName("started_at_ms") val startedAtMs: Long,
    @SerialName("duration_s") val durationS: Int = 0,
)

@Serializable
data class CallLogSync(
    val entries: List<CallLogEntryWire>,
    /** False when the phone has not granted READ_CALL_LOG (so an empty list means "no access", not "no calls"). */
    @SerialName("access_granted") val accessGranted: Boolean = true,
)

enum class ScreenAction { SCREEN_START, SCREEN_STOP }
enum class ScreenState { SCREEN_IDLE, SCREEN_WAITING, SCREEN_STREAMING, SCREEN_DENIED, SCREEN_STOPPED, SCREEN_ERROR }

/** Mac → phone: ask to start or stop view-only screen mirroring (the phone's owner must still approve). */
@Serializable
data class ScreenMirrorRequest(
    val action: ScreenAction,
    @SerialName("max_dimension") val maxDimension: Int = 1280,
)

/** Phone → Mac: where the session stands; `width`/`height` describe the encoded video. */
@Serializable
data class ScreenMirrorStatus(
    val state: ScreenState,
    val width: Int = 0,
    val height: Int = 0,
    val message: String = "",
    /** True when the Mac may also tap, swipe and type (accessibility service on and Remote control allowed). */
    val control: Boolean = false,
)

/** A notification posted on the phone, mirrored to the Mac (Notification access must be granted on the phone). */
@Serializable
data class NotificationEvent(
    val key: String,
    @SerialName("package_name") val packageName: String,
    @SerialName("app_name") val appName: String,
    val title: String = "",
    val text: String = "",
    @SerialName("sub_text") val subText: String = "",
    @SerialName("posted_at_ms") val postedAtMs: Long,
    /** Base64 PNG of the app icon, sent once per app per connection. */
    @SerialName("app_icon_png") val appIconPng: String = "",
    @SerialName("can_dismiss") val canDismiss: Boolean = true,
)

@Serializable data class NotificationRemoved(val key: String)
@Serializable data class NotificationDismiss(val key: String)

enum class InputKind { INPUT_TAP, INPUT_SWIPE, INPUT_LONG_PRESS, INPUT_BACK, INPUT_HOME, INPUT_RECENTS, INPUT_TEXT, INPUT_ENTER }

/** Mac → phone while mirroring: coordinates are fractions (0…1) of the phone screen. */
@Serializable
data class RemoteInput(
    val kind: InputKind,
    val x: Float = 0f,
    val y: Float = 0f,
    val x2: Float = 0f,
    val y2: Float = 0f,
    @SerialName("duration_ms") val durationMs: Int = 0,
    val text: String = "",
)

/** Ephemeral X25519 exchange that gives live traffic forward secrecy (see SecureChannel). */
@Serializable
data class RekeyMessage(
    @SerialName("epoch_id") val epochId: String,
    @SerialName("eph_pub") @Serializable(with = Base64Bytes::class) val ephPub: ByteArray,
    val reply: Boolean = false,
)

@Serializable data class AckEvent(@SerialName("acked_message_id") val ackedMessageId: String)

@Serializable
data class SimCard(
    @SerialName("subscription_id") val subscriptionId: Int,
    @SerialName("slot_index") val slotIndex: Int,
    @SerialName("carrier_name") val carrierName: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("phone_number") val phoneNumber: String,
    @SerialName("accent_color_hex") val accentColorHex: String,
    @SerialName("is_default_sms") val isDefaultSms: Boolean,
    @SerialName("is_default_voice") val isDefaultVoice: Boolean,
)

@Serializable data class SimInventorySync(val sims: List<SimCard>)

enum class MessageDirection { INCOMING, OUTGOING }
enum class MessageStatus { PENDING, SENT, DELIVERED, FAILED }

@Serializable
data class SmsMessageEvent(
    @SerialName("local_id") val localId: String,
    @SerialName("thread_id") val threadId: String,
    @SerialName("subscription_id") val subscriptionId: Int,
    val address: String,
    val body: String,
    val direction: MessageDirection,
    val status: MessageStatus,
    @SerialName("timestamp_ms") val timestampMs: Long,
    @SerialName("is_read") val isRead: Boolean,
)

@Serializable
data class SmsThreadSync(val messages: List<SmsMessageEvent>, @SerialName("has_more") val hasMore: Boolean)

@Serializable
data class SendSmsCommand(
    @SerialName("client_request_id") val clientRequestId: String,
    @SerialName("subscription_id") val subscriptionId: Int,
    @SerialName("recipient_address") val recipientAddress: String,
    val body: String,
)

@Serializable
data class SmsStatusUpdate(
    @SerialName("client_request_id") val clientRequestId: String,
    val status: MessageStatus,
    @SerialName("error_reason") val errorReason: String = "",
)

enum class CallState { RINGING_INCOMING, DIALING_OUTGOING, ACTIVE, HOLDING, DISCONNECTED }
enum class AudioRoute { AUDIO_ROUTE_UNSPECIFIED, MAC_BLUETOOTH_HFP, PHONE_EARPIECE, PHONE_SPEAKER, WIRED_HEADSET }
enum class CallAction { CALL_ACTION_UNSPECIFIED, ANSWER, REJECT, END_CALL, TOGGLE_MUTE, SEND_DTMF, SWITCH_AUDIO_ROUTE }

@Serializable
data class CallStateEvent(
    @SerialName("call_id") val callId: String,
    @SerialName("subscription_id") val subscriptionId: Int,
    @SerialName("remote_address") val remoteAddress: String,
    @SerialName("contact_name") val contactName: String,
    val state: CallState,
    @SerialName("audio_route") val audioRoute: AudioRoute = AudioRoute.AUDIO_ROUTE_UNSPECIFIED,
    @SerialName("started_at_ms") val startedAtMs: Long,
    @SerialName("is_muted") val isMuted: Boolean,
    /** Set on DISCONNECTED of a Mac-placed call that asked for it: whether the other side picked up. Null = unknown. */
    val answered: Boolean? = null,
    @SerialName("duration_s") val durationS: Int? = null,
    /** The caller's contact photo, sent once when the call starts (about 300 px). */
    @SerialName("photo_jpeg") @Serializable(with = Base64Bytes::class) val photoJpeg: ByteArray? = null,
)

@Serializable
data class PlaceCallCommand(
    @SerialName("request_id") val requestId: String,
    @SerialName("subscription_id") val subscriptionId: Int,
    @SerialName("phone_number") val phoneNumber: String,
    @SerialName("route_audio_to_mac") val routeAudioToMac: Boolean = true,
    /** Ask the phone to report, when the call ends, whether it was answered (used by the Mac's auto-redial). */
    @SerialName("report_outcome") val reportOutcome: Boolean = false,
)

@Serializable
data class CallActionCommand(
    @SerialName("call_id") val callId: String,
    val action: CallAction,
    @SerialName("dtmf_digit") val dtmfDigit: String = "",
    @SerialName("target_audio_route") val targetAudioRoute: AudioRoute = AudioRoute.AUDIO_ROUTE_UNSPECIFIED,
)

@Serializable
data class ContactEntry(
    @SerialName("contact_id") val contactId: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("phone_numbers") val phoneNumbers: List<String>,
    @SerialName("thumbnail_jpeg") @Serializable(with = Base64Bytes::class) val thumbnailJpeg: ByteArray? = null,
)

@Serializable
data class ContactSyncBatch(val contacts: List<ContactEntry>, @SerialName("is_final_batch") val isFinalBatch: Boolean)

@Serializable
data class DeviceStatusEvent(
    @SerialName("battery_percent") val batteryPercent: Int,
    @SerialName("is_charging") val isCharging: Boolean,
    @SerialName("bluetooth_hfp_connected") val bluetoothHfpConnected: Boolean = false,
    @SerialName("storage_free_bytes") val storageFreeBytes: Long = 0,
    @SerialName("storage_total_bytes") val storageTotalBytes: Long = 0,
)

// ---------------------------------------------------------------- media gallery & file explorer

@Serializable
data class MediaServerEndpoint(
    @SerialName("lan_ip") val lanIp: String,
    @SerialName("https_port") val httpsPort: Int,
    @SerialName("session_bearer_token") val sessionBearerToken: String,
    @SerialName("server_cert_sha256") @Serializable(with = Base64Bytes::class) val serverCertSha256: ByteArray,
)

@Serializable
data class FileEntry(
    val path: String,
    val name: String,
    @SerialName("is_directory") val isDirectory: Boolean,
    @SerialName("size_bytes") val sizeBytes: Long,
    @SerialName("mime_type") val mimeType: String,
    @SerialName("modified_at_ms") val modifiedAtMs: Long,
    @SerialName("child_count") val childCount: Int = 0,
)

@Serializable
data class ListDirectoryRequest(
    @SerialName("request_id") val requestId: String,
    val path: String,
    @SerialName("include_hidden") val includeHidden: Boolean = false,
)

@Serializable
data class ListDirectoryResponse(
    @SerialName("request_id") val requestId: String,
    val path: String,
    val entries: List<FileEntry>,
    @SerialName("error_message") val errorMessage: String = "",
)

/** Mac → phone: find files and folders whose name contains `query`, anywhere in the phone's storage. */
@Serializable
data class SearchFilesRequest(
    @SerialName("request_id") val requestId: String,
    val query: String,
    @SerialName("include_hidden") val includeHidden: Boolean = false,
    val limit: Int = 500,
)

@Serializable
data class SearchFilesResponse(
    @SerialName("request_id") val requestId: String,
    val entries: List<FileEntry>,
    /** True when the search stopped early (match limit or time limit), so there may be more. */
    val truncated: Boolean = false,
    @SerialName("error_message") val errorMessage: String = "",
)

enum class MediaTypeFilter { MEDIA_ALL, MEDIA_IMAGES, MEDIA_VIDEOS }

@Serializable
data class MediaItem(
    @SerialName("media_store_id") val mediaStoreId: Long,
    val path: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("bucket_name") val bucketName: String,
    @SerialName("mime_type") val mimeType: String,
    @SerialName("size_bytes") val sizeBytes: Long,
    val width: Int,
    val height: Int,
    @SerialName("duration_ms") val durationMs: Long,
    @SerialName("date_taken_ms") val dateTakenMs: Long,
)

@Serializable
data class ListMediaGalleryRequest(
    @SerialName("request_id") val requestId: String,
    val filter: MediaTypeFilter = MediaTypeFilter.MEDIA_ALL,
    @SerialName("bucket_name") val bucketName: String = "",
    val limit: Int = 100,
    val offset: Int = 0,
)

@Serializable
data class ListMediaGalleryResponse(
    @SerialName("request_id") val requestId: String,
    val items: List<MediaItem>,
    @SerialName("available_buckets") val availableBuckets: List<String>,
    @SerialName("has_more") val hasMore: Boolean,
)

enum class FileOpType { FILE_OP_UNSPECIFIED, MKDIR, RENAME, DELETE }

@Serializable
data class FileOperationRequest(
    @SerialName("request_id") val requestId: String,
    val op: FileOpType,
    @SerialName("source_path") val sourcePath: String,
    @SerialName("target_path") val targetPath: String = "",
)

@Serializable
data class FileOperationResponse(
    @SerialName("request_id") val requestId: String,
    val success: Boolean,
    @SerialName("error_message") val errorMessage: String = "",
)

@Serializable
data class WebRtcSignal(
    @SerialName("session_id") val sessionId: String,
    @SerialName("signal_type") val signalType: String,
    @SerialName("payload_json") val payloadJson: String,
)

// ---------------------------------------------------------------- pairing

/** QR code rendered by macOS (spec §5.1 step 2). */
@Serializable
data class PairingQrPayload(
    val v: Int = 2,
    @SerialName("session_id") val sessionId: String,
    @SerialName("mac_device_id") val macDeviceId: String,
    @SerialName("mac_pub_key") val macPubKey: String,
    @SerialName("relay_url") val relayUrl: String,
    @SerialName("lan_host") val lanHost: String? = null,
    @SerialName("mac_name") val macName: String? = null,
    /** 256-bit secret that only travels in the QR / pasted code, never through the relay (base64). */
    @SerialName("pairing_secret") val pairingSecret: String = "",
)

@Serializable
data class PairAckEnvelope(
    @SerialName("session_id") val sessionId: String,
    @SerialName("android_device_id") val androidDeviceId: String,
    @SerialName("android_pub_key") @Serializable(with = Base64Bytes::class) val androidPubKey: ByteArray,
    @Serializable(with = Base64Bytes::class) val nonce: ByteArray,
    @Serializable(with = Base64Bytes::class) val ciphertext: ByteArray,
)

@Serializable
data class PairAckBody(
    @SerialName("session_id") val sessionId: String,
    @SerialName("device_name") val deviceName: String,
    val manufacturer: String,
    @SerialName("os_version") val osVersion: String,
    /** HMAC-SHA256(pairing_secret, "phonepigeon-pair-v1" ‖ session_id ‖ phone_pub ‖ mac_pub), base64. */
    val proof: String = "",
)

/** Frame carried by both the LAN socket and the cloud WebSocket. */
@Serializable
data class WireFrame(
    val envelope: EncryptedEnvelope? = null,
    @SerialName("pair_ack") val pairAck: PairAckEnvelope? = null,
    val ack: String? = null,
)

object WireCodec {
    val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }
}
