/*
 * The app-role device session - implementation.  See device_session.h.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "device_session.h"

#include "base.h"
#include "define.h"
#include "define_enum.h"
#include "define_plus.h"
#include "host_tcp.h"
#include "discovery.h"
#include "dsh_state.h"
#include "hdc_crypto.h"
#include "serial_struct.h"
#include "tlv.h"

#include <chrono>
#include <memory>
#include <sstream>

namespace swshell {

using Hdc::HdcHostTCP;
using Hdc::HdcSessionBase;
using Hdc::HSession;

namespace {

/* The daemon separates the host name from the public key with this byte. */
constexpr char kHostDaemonBufSeparator = '\x0C';

/*
 * Builds the numeric TLV the daemon's extended shell command expects:
 * the command itself and the bundle it should run in.
 */
std::string BuildShellTlv(const std::string &bundleName, const std::string &command)
{
    Hdc::TlvBuf tlv(Hdc::Base::REGISTERD_TAG_SET);
    if (!bundleName.empty()) {
        if (!tlv.Append(Hdc::TAG_SHELL_BUNDLE, bundleName)) {
            return std::string();
        }
    }
    if (command.empty() || !tlv.Append(Hdc::TAG_SHELL_CMD, command)) {
        return std::string();
    }
    uint32_t size = tlv.GetBufSize();
    if (size == 0) {
        return std::string();
    }
    std::vector<uint8_t> buffer(size, 0);
    if (!tlv.CopyToBuf(buffer.data(), buffer.size())) {
        return std::string();
    }
    return std::string(reinterpret_cast<const char *>(buffer.data()), buffer.size());
}

}  // namespace

DeviceSession::DeviceSession() : HdcSessionBase(true)
{
    wakeAsync_.data = this;
    if (uv_async_init(&loopMain, &wakeAsync_, OnWakeAsync) == 0) {
        wakeAsyncInit_ = true;
    }
    StartLoop();
    Report("device session created");
}

DeviceSession::~DeviceSession()
{
    Disconnect();
}

void DeviceSession::OnWakeAsync(uv_async_t *handle)
{
    if (handle == nullptr || handle->data == nullptr) {
        return;
    }
    auto *self = static_cast<DeviceSession *>(handle->data);
    self->DrainPostQueue();
}

bool DeviceSession::PostToLoop(std::function<void()> fn)
{
    if (!wakeAsyncInit_ || !loopRunning_.load()) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(postMutex_);
        postQueue_.push_back(std::move(fn));
    }
    return uv_async_send(&wakeAsync_) == 0;
}

void DeviceSession::DrainPostQueue()
{
    std::deque<std::function<void()>> batch;
    {
        std::lock_guard<std::mutex> lock(postMutex_);
        batch.swap(postQueue_);
    }
    for (auto &fn : batch) {
        if (fn) {
            fn();
        }
    }
}

void DeviceSession::StartLoop()
{
    if (loopRunning_.exchange(true)) {
        return;
    }
    /*
     * WorkerPendding() runs uv_run over the session's main loop.  Every
     * libuv call that touches the session has to happen on this thread.
     */
    loopThread_ = std::thread([this]() {
        this->WorkerPendding();
        loopRunning_ = false;
    });
}

void DeviceSession::StopLoop()
{
    if (!loopRunning_.load()) {
        return;
    }
    if (wakeAsyncInit_) {
        PostToLoop([this]() {
            if (!uv_is_closing(reinterpret_cast<uv_handle_t *>(&wakeAsync_))) {
                uv_close(reinterpret_cast<uv_handle_t *>(&wakeAsync_), nullptr);
            }
        });
        wakeAsyncInit_ = false;
    }
    /* Stops uv_run, which lets the loop thread fall out of WorkerPendding. */
    this->PostStopInstanceMessage(false);
    if (loopThread_.joinable()) {
        loopThread_.join();
    }
    loopRunning_ = false;
}

void DeviceSession::Report(const std::string &message)
{
    if (logSink) {
        logSink(message);
    }
}

void DeviceSession::ReportState(bool ready, const std::string &detail)
{
    if (stateSink) {
        stateSink(ready, detail);
    }
}

void DeviceSession::ConnectAsync(const std::string &host, int port, const std::string &keyDir,
                                 ConnectCallback callback)
{
    std::string cryptoError;
    if (!HdcCrypto::Instance().EnsureKeypair(keyDir, cryptoError)) {
        ConnectResult res;
        res.ok = false;
        res.port = 0;
        res.reason = "key_error";
        res.error = "client keypair unavailable: " + cryptoError;
        if (callback) {
            callback(res);
        }
        ReportState(false, res.error);
        return;
    }

    CancelPendingConnect();

    uint32_t oldSessionToFree = 0;
    bool alreadyConnected = false;
    ConnectResult alreadyResult;
    std::string alreadyKey;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (handshakeOk_ && session_ != nullptr) {
            if (port == 0 || port == connectedPort_) {
                alreadyConnected = true;
                alreadyResult.ok = true;
                alreadyResult.port = connectedPort_;
                alreadyResult.reason = "ok";
                alreadyKey = connectKey_;
            } else {
                oldSessionToFree = session_->sessionId;
                handshakeOk_ = false;
                awaitingAuth_ = false;
                connectedPort_ = 0;
                session_ = nullptr;
            }
        }
    }
    if (alreadyConnected) {
        if (callback) {
            callback(alreadyResult);
        }
        ReportState(true, "connected to " + alreadyKey);
        return;
    }
    if (oldSessionToFree != 0) {
        FreeSession(oldSessionToFree);
    }

    std::string targetHost = host.empty() ? "127.0.0.1" : host;
    if (targetHost == "localhost") {
        targetHost = "127.0.0.1";
    }

    std::vector<int> candidatePorts;
    bool isSingleExplicit = false;
    if (port > 0) {
        candidatePorts.assign(1, port);
        isSingleExplicit = true;
    } else {
        std::vector<int> excludes = { 9222, 38081, 39001 };
        const int dshPort = DshState::GetInstance().GetSnapshot().port;
        if (dshPort > 0) {
            excludes.push_back(dshPort);
        }
        candidatePorts = ListPrioritizedListeningPorts(excludes);
        isSingleExplicit = false;
        if (candidatePorts.empty()) {
            ConnectResult res;
            res.ok = false;
            res.port = 0;
            res.reason = "not_running";
            res.error = "the device has no reachable TCP port to try";
            if (callback) {
                callback(res);
            }
            ReportState(false, res.error);
            return;
        }
        Report("the device is listening on " + std::to_string(candidatePorts.size()) + " candidate ports, trying them");
    }

    keyDir_ = keyDir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        host_ = targetHost;
        candidates_ = std::move(candidatePorts);
        candidateIndex_ = 0;
        singleExplicitPort_ = isSingleExplicit;
        lastCandidateError_.clear();
        lastCandidateReason_.clear();
        connectCallback_ = callback;
        handshakeOk_ = false;
        connecting_ = true;
        awaitingAuth_ = false;
        connectedPort_ = 0;
        attemptPort_ = 0;
        currentAttemptSessionId_ = 0;
        ++attemptGen_;
    }

    TryNextCandidate();
}

void DeviceSession::CancelPendingConnect()
{
    uint32_t pendingSid = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!connecting_ && currentAttemptSessionId_ == 0) {
            return;
        }
        connecting_ = false;
        awaitingAuth_ = false;
        ++attemptGen_;
        pendingSid = currentAttemptSessionId_;
        currentAttemptSessionId_ = 0;
        if (!handshakeOk_) {
            session_ = nullptr;
        }
        connectCallback_ = nullptr;
    }
    if (pendingSid != 0) {
        FreeSession(pendingSid);
    }
}

void DeviceSession::TryNextCandidate()
{
    struct AttemptCtx {
        DeviceSession *self = nullptr;
        uint64_t expectedGen = 0;
        int port = 0;
        int probeTimeoutMs = 1800;
        std::string connectKey;
    };

    AttemptCtx *attempt = nullptr;
    bool shouldFinish = false;
    ConnectResult finishResult;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!connecting_) {
            return;
        }
        if (candidateIndex_ >= candidates_.size()) {
            shouldFinish = true;
            finishResult.ok = false;
            finishResult.port = (singleExplicitPort_ && !candidates_.empty()) ? candidates_[0] : 0;
            if (singleExplicitPort_) {
                finishResult.reason = lastCandidateReason_.empty() ? "not_running" : lastCandidateReason_;
                finishResult.error = lastCandidateError_.empty()
                    ? ("failed to connect to " + host_ + ":" + std::to_string(finishResult.port))
                    : lastCandidateError_;
            } else {
                finishResult.reason = "not_running";
                finishResult.error = "none of the device's listening ports spoke the hdc protocol";
            }
        } else {
            const int port = candidates_[candidateIndex_++];
            attemptPort_ = port;
            awaitingAuth_ = false;
            currentAttemptSessionId_ = 0;
            const uint64_t expectedGen = ++attemptGen_;
            connectKey_ = host_ + ":" + std::to_string(port);

            attempt = new AttemptCtx();
            attempt->self = this;
            attempt->expectedGen = expectedGen;
            attempt->port = port;
            attempt->probeTimeoutMs = singleExplicitPort_ ? 4000 : 800;
            attempt->connectKey = connectKey_;
        }
    }

    if (shouldFinish) {
        FinishConnect(finishResult);
        return;
    }

    /*
     * The connect has to be issued from the loop thread: uv_tcp_connect is
     * not thread safe, and a connect issued from anywhere else is queued
     * and never sent.
     */
    const uint64_t expectedGen = attempt->expectedGen;
    const int attemptPort = attempt->port;
    const int probeTimeoutMs = attempt->probeTimeoutMs;
    const std::string connectKey = attempt->connectKey;
    delete attempt;

    if (!PostToLoop([this, expectedGen, attemptPort, probeTimeoutMs, connectKey]() {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (!connecting_ || attemptGen_ != expectedGen) {
                    return;
                }
            }

            if (tcpClient_ == nullptr) {
                tcpClient_ = new HdcHostTCP(true, this);
            }

            Hdc::HSession s = tcpClient_->ConnectDaemon(connectKey, false);
            if (s == nullptr) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    if (!connecting_ || attemptGen_ != expectedGen) {
                        return;
                    }
                    lastCandidateReason_ = "not_running";
                    lastCandidateError_ = "failed to open a TCP session to " + connectKey;
                }
                TryNextCandidate();
                return;
            }

            bool cancelled = false;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (!connecting_ || attemptGen_ != expectedGen) {
                    cancelled = true;
                } else {
                    currentAttemptSessionId_ = s->sessionId;
                    session_ = s;
                }
            }
            if (cancelled) {
                FreeSession(s->sessionId);
                return;
            }

            struct ProbeTimeoutCtx {
                DeviceSession *self = nullptr;
                uint64_t expectedGen = 0;
                uint32_t sessionId = 0;
                int port = 0;
            };
            auto *timeoutCtx = new ProbeTimeoutCtx{ this, expectedGen, s->sessionId, attemptPort };
            if (!Hdc::Base::DelayDo(&loopMain, probeTimeoutMs, 0, "", timeoutCtx,
                                    [](const uint8_t, std::string &, const void *tData) {
                                        std::unique_ptr<ProbeTimeoutCtx> tc(
                                            const_cast<ProbeTimeoutCtx *>(static_cast<const ProbeTimeoutCtx *>(tData)));
                                        tc->self->OnProbeTimeout(tc->expectedGen, tc->sessionId, tc->port);
                                    })) {
                delete timeoutCtx;
            }
        })) {
        ConnectResult res;
        res.ok = false;
        res.port = attemptPort;
        res.reason = "error";
        res.error = "failed to schedule TCP connect on session loop";
        FinishConnect(res);
    }
}

void DeviceSession::OnProbeTimeout(uint64_t expectedGen, uint32_t timedOutSid, int attemptPort)
{
    bool shouldAdvance = false;
    bool hasMore = false;
    bool wasSingle = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!connecting_ || attemptGen_ != expectedGen || awaitingAuth_ || handshakeOk_) {
            return;
        }
        shouldAdvance = true;
        ++attemptGen_;
        if (currentAttemptSessionId_ == timedOutSid) {
            currentAttemptSessionId_ = 0;
            session_ = nullptr;
        }
        lastCandidateReason_ = "connect_timeout";
        lastCandidateError_ = "timed out waiting for hdc handshake banner on " + connectKey_;
        hasMore = (candidateIndex_ < candidates_.size());
        wasSingle = singleExplicitPort_;
    }

    if (!shouldAdvance) {
        return;
    }

    FreeSession(timedOutSid);
    if (hasMore) {
        TryNextCandidate();
    } else {
        ConnectResult res;
        res.ok = false;
        res.port = wasSingle ? attemptPort : 0;
        res.reason = wasSingle ? "connect_timeout" : "not_running";
        res.error = wasSingle
            ? ("timed out waiting for hdc handshake on port " + std::to_string(attemptPort))
            : "none of the device's listening ports spoke the hdc protocol";
        FinishConnect(res);
    }
}

void DeviceSession::FinishConnect(const ConnectResult &result)
{
    ConnectCallback callback;
    std::string keyCopy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!connecting_ && connectCallback_ == nullptr) {
            return;
        }
        connecting_ = false;
        awaitingAuth_ = false;
        currentAttemptSessionId_ = 0;
        if (result.ok) {
            handshakeOk_ = true;
            connectedPort_ = result.port;
        } else {
            handshakeOk_ = false;
            connectedPort_ = 0;
            session_ = nullptr;
        }
        keyCopy = connectKey_;
        callback = connectCallback_;
        connectCallback_ = nullptr;
    }
    if (callback) {
        callback(result);
    }
    ReportState(result.ok, result.ok ? ("connected to " + keyCopy) : result.error);
}

void DeviceSession::NotifyInstanceSessionFree(HSession hSession, bool freeOrClear)
{
    if (freeOrClear || hSession == nullptr) {
        return;
    }

    const uint32_t sid = hSession->sessionId;
    const std::string faultInfo = hSession->GetConnectionError();

    bool activeDisconnected = false;
    bool attemptFailed = false;
    bool wasAwaitingAuth = false;
    bool hasMore = false;
    bool wasSingle = false;
    int attemptPort = 0;
    std::string attemptKey;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (handshakeOk_ && session_ == hSession) {
            handshakeOk_ = false;
            awaitingAuth_ = false;
            connectedPort_ = 0;
            session_ = nullptr;
            activeDisconnected = true;
        } else if (connecting_ && currentAttemptSessionId_ == sid) {
            attemptFailed = true;
            wasAwaitingAuth = awaitingAuth_;
            attemptPort = attemptPort_;
            attemptKey = connectKey_;
            wasSingle = singleExplicitPort_;
            ++attemptGen_;
            currentAttemptSessionId_ = 0;
            session_ = nullptr;
            awaitingAuth_ = false;

            if (!wasAwaitingAuth) {
                if (!faultInfo.empty()) {
                    lastCandidateError_ = faultInfo + " (" + attemptKey + ")";
                } else {
                    lastCandidateError_ = "failed to connect to " + attemptKey;
                }
                lastCandidateReason_ = "not_running";
                hasMore = (candidateIndex_ < candidates_.size());
            }
        }
    }

    if (activeDisconnected) {
        {
            std::lock_guard<std::mutex> execLock(execMutex_);
            if (pendingChannelId_ != 0) {
                pendingDisconnected_ = true;
                pendingDone_ = true;
            }
        }
        execCv_.notify_all();
        Report("device session disconnected");
        ReportState(false, "disconnected from device");
        return;
    }

    if (!attemptFailed) {
        return;
    }

    if (wasAwaitingAuth) {
        ConnectResult res;
        res.ok = false;
        res.port = attemptPort;
        res.reason = "auth_rejected";
        res.error = faultInfo.empty()
            ? "device authorization was rejected or interrupted"
            : ("device authorization rejected: " + faultInfo);
        FinishConnect(res);
        return;
    }

    if (hasMore) {
        TryNextCandidate();
    } else {
        ConnectResult res;
        res.ok = false;
        res.port = wasSingle ? attemptPort : 0;
        res.reason = "not_running";
        if (wasSingle) {
            res.error = faultInfo.empty()
                ? ("failed to connect to " + attemptKey)
                : ("failed to connect to " + attemptKey + ": " + faultInfo);
        } else {
            res.error = "none of the device's listening ports spoke the hdc protocol";
        }
        FinishConnect(res);
    }
}

void DeviceSession::Disconnect()
{
    CancelPendingConnect();
    uint32_t activeSid = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        handshakeOk_ = false;
        awaitingAuth_ = false;
        connectedPort_ = 0;
        if (session_ != nullptr) {
            activeSid = session_->sessionId;
            session_ = nullptr;
        }
    }
    {
        std::lock_guard<std::mutex> execLock(execMutex_);
        if (pendingChannelId_ != 0) {
            pendingDisconnected_ = true;
            pendingDone_ = true;
        }
    }
    execCv_.notify_all();
    if (activeSid != 0) {
        FreeSession(activeSid);
    }
    StopLoop();
    if (tcpClient_ != nullptr) {
        delete tcpClient_;
        tcpClient_ = nullptr;
    }
}

bool DeviceSession::IsReady() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return handshakeOk_ && session_ != nullptr;
}

SessionStateSnapshot DeviceSession::GetSessionState() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    SessionStateSnapshot snap;
    snap.connected = handshakeOk_ && session_ != nullptr;
    snap.connecting = connecting_;
    snap.awaitingAuth = awaitingAuth_;
    snap.port = snap.connected ? connectedPort_ : (connecting_ ? attemptPort_ : 0);
    return snap;
}

bool DeviceSession::SendHandshake(HSession hSession, const uint32_t channelId, uint8_t authType,
                                  const std::string &buf)
{
    HdcSessionBase::SessionHandShake handshake;
    handshake.banner = Hdc::HANDSHAKE_MESSAGE;
    handshake.authType = authType;
    handshake.sessionId = hSession->sessionId;
    handshake.connectKey = hSession->connectKey;
    handshake.buf = buf;
    handshake.version = Hdc::Base::GetVersion();

    std::string serialized = Hdc::SerialStruct::SerializeToString(handshake);
    int ret = Send(hSession->sessionId, channelId, Hdc::CMD_KERNEL_HANDSHAKE,
                   reinterpret_cast<uint8_t *>(const_cast<char *>(serialized.data())),
                   static_cast<int>(serialized.size()));
    if (ret < 0) {
        Report("failed to send a handshake packet");
        return false;
    }
    return true;
}

bool DeviceSession::HandleHandshake(HSession hSession, const uint32_t channelId, uint8_t *payload,
                                    int payloadSize)
{
    HdcSessionBase::SessionHandShake handshake;
    Hdc::SerialStruct::ParseFromString(handshake, std::string(reinterpret_cast<char *>(payload), payloadSize));

    if (handshake.banner == Hdc::HANDSHAKE_FAILED) {
        int port = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            port = attemptPort_;
            ++attemptGen_;
            currentAttemptSessionId_ = 0;
        }
        ConnectResult res;
        res.ok = false;
        res.port = port;
        res.reason = "auth_rejected";
        res.error = "the device refused the handshake";
        FinishConnect(res);
        return false;
    }
    if (handshake.banner != Hdc::HANDSHAKE_MESSAGE) {
        Report("unexpected handshake banner from the device");
        return false;
    }

    switch (handshake.authType) {
        case HdcSessionBase::AUTH_PUBLICKEY: {
            /*
             * The device is asking for our public key.  It also tells us
             * which signature scheme it supports; we always offer
             * RSA-3072/SHA-512, which is what the upstream host does.
             */
            std::map<std::string, std::string> tlvMap;
            if (Hdc::Base::TlvToStringMap(handshake.buf, tlvMap)) {
                auto it = tlvMap.find(TAG_AUTH_TYPE);
                if (it != tlvMap.end() && it->second != std::to_string(Hdc::AuthVerifyType::RSA_3072_SHA512)) {
                    int port = 0;
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        port = attemptPort_;
                        ++attemptGen_;
                        currentAttemptSessionId_ = 0;
                    }
                    ConnectResult res;
                    res.ok = false;
                    res.port = port;
                    res.reason = "unsupported_auth";
                    res.error = "the device only supports the legacy RSA auth mode";
                    FinishConnect(res);
                    return false;
                }
            }
            std::string info = HdcCrypto::Instance().HostName();
            info += kHostDaemonBufSeparator;
            info += HdcCrypto::Instance().PublicKeyPem();
            if (!SendHandshake(hSession, channelId, HdcSessionBase::AUTH_PUBLICKEY, info)) {
                int port = 0;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    port = attemptPort_;
                    ++attemptGen_;
                    currentAttemptSessionId_ = 0;
                }
                ConnectResult res;
                res.ok = false;
                res.port = port;
                res.reason = "error";
                res.error = "failed to send our public key";
                FinishConnect(res);
                return false;
            }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (connecting_ && currentAttemptSessionId_ == hSession->sessionId) {
                    awaitingAuth_ = true;
                }
            }
            Report("sent our public key to the device");
            return true;
        }
        case HdcSessionBase::AUTH_SIGNATURE: {
            /* The device sent the token to sign. */
            std::string signature;
            std::string signError;
            if (!HdcCrypto::Instance().SignToken(handshake.buf, signature, signError)) {
                int port = 0;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    port = attemptPort_;
                    ++attemptGen_;
                    currentAttemptSessionId_ = 0;
                }
                ConnectResult res;
                res.ok = false;
                res.port = port;
                res.reason = "key_error";
                res.error = "failed to sign the device challenge: " + signError;
                FinishConnect(res);
                return false;
            }
            if (!SendHandshake(hSession, channelId, HdcSessionBase::AUTH_SIGNATURE, signature)) {
                int port = 0;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    port = attemptPort_;
                    ++attemptGen_;
                    currentAttemptSessionId_ = 0;
                }
                ConnectResult res;
                res.ok = false;
                res.port = port;
                res.reason = "error";
                res.error = "failed to send our signature";
                FinishConnect(res);
                return false;
            }
            Report("signed the device challenge");
            return true;
        }
        case HdcSessionBase::AUTH_OK: {
            int port = 0;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (!connecting_ || currentAttemptSessionId_ != hSession->sessionId) {
                    return false;
                }
                session_ = hSession;
                port = attemptPort_;
                connectedPort_ = port;
                awaitingAuth_ = false;
                currentAttemptSessionId_ = 0;
                ++attemptGen_;
            }
            ConnectResult res;
            res.ok = true;
            res.port = port;
            res.reason = "ok";
            FinishConnect(res);
            return true;
        }
        default:
            Report("unexpected handshake state from the device");
            return false;
    }
}

bool DeviceSession::FetchCommand(HSession hSession, const uint32_t channelId, const uint16_t command,
                                  uint8_t *payload, int payloadSize)
{
    if (command == Hdc::CMD_KERNEL_HANDSHAKE) {
        return HandleHandshake(hSession, channelId, payload, payloadSize);
    }
    if (command == Hdc::CMD_KERNEL_ECHO_RAW) {
        std::string chunk(reinterpret_cast<const char *>(payload), static_cast<size_t>(payloadSize));
        StreamChunkCallback chunkSink = nullptr;
        {
            std::lock_guard<std::mutex> lock(execMutex_);
            if (pendingChannelId_ != 0 && (channelId == pendingChannelId_ || channelId == 0)) {
                pendingOutput_.append(chunk);
                chunkSink = streamChunkSink_;
            }
        }
        if (chunkSink) {
            chunkSink(chunk);
        }
        return true;
    }
    if (command == Hdc::CMD_KERNEL_ECHO) {
        std::string chunk;
        if (payloadSize > 1) {
            chunk.assign(reinterpret_cast<const char *>(payload + 1), static_cast<size_t>(payloadSize - 1));
        } else if (payloadSize == 1) {
            // empty message with only MessageLevel
        } else {
            chunk.assign(reinterpret_cast<const char *>(payload), static_cast<size_t>(payloadSize));
        }
        StreamChunkCallback chunkSink = nullptr;
        {
            std::lock_guard<std::mutex> lock(execMutex_);
            if (pendingChannelId_ != 0 && (channelId == pendingChannelId_ || channelId == 0)) {
                if (!chunk.empty()) {
                    pendingOutput_.append(chunk);
                    chunkSink = streamChunkSink_;
                }
            }
        }
        if (chunkSink && !chunk.empty()) {
            chunkSink(chunk);
        }
        return true;
    }
    if (command == Hdc::CMD_KERNEL_CHANNEL_CLOSE) {
        {
            std::lock_guard<std::mutex> lock(execMutex_);
            if (channelId == pendingChannelId_) {
                pendingDone_ = true;
            }
        }
        execCv_.notify_all();
        return true;
    }
    return true;
}

void DeviceSession::SendChannelClose(uint32_t sessionId, uint32_t channelId)
{
    if (channelId == 0 || !loopRunning_.load()) {
        return;
    }
    PostToLoop([this, sessionId, channelId]() {
        uint8_t count = 1;
        Send(sessionId, channelId, Hdc::CMD_KERNEL_CHANNEL_CLOSE, &count, 1);
    });
}

bool DeviceSession::Exec(const std::string &command, const std::string &bundleName, ExecResult &result,
                         unsigned timeoutSeconds, StreamChunkCallback onChunk)
{
    std::lock_guard<std::mutex> serializeLock(execSerializeMutex_);
    uint32_t activeSessionId = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!handshakeOk_ || session_ == nullptr) {
            result.error = "not connected to the device";
            return false;
        }
        activeSessionId = session_->sessionId;
    }

    uint16_t cmdFlag = Hdc::CMD_UNITY_EXECUTE;
    std::string payload;
    if (!bundleName.empty()) {
        cmdFlag = Hdc::CMD_UNITY_EXECUTE_EX;
        payload = BuildShellTlv(bundleName, command);
        if (payload.empty()) {
            result.error = "failed to encode the command";
            return false;
        }
    } else {
        cmdFlag = Hdc::CMD_UNITY_EXECUTE;
        payload = command;
    }

    uint32_t channelId = 0;
    {
        std::lock_guard<std::mutex> lock(execMutex_);
        channelId = nextChannelId_++;
        pendingChannelId_ = channelId;
        pendingOutput_.clear();
        pendingDone_ = false;
        pendingAborted_ = false;
        pendingDisconnected_ = false;
        streamChunkSink_ = onChunk;
    }

    struct SendCtx {
        DeviceSession *self = nullptr;
        uint32_t sessionId = 0;
        uint32_t channelId = 0;
        uint16_t cmdFlag = 0;
        std::string payload;
        int sendRet = 0;
        std::mutex mtx;
        std::condition_variable cv;
        bool done = false;
    };
    auto ctx = std::make_shared<SendCtx>();
    ctx->self = this;
    ctx->sessionId = activeSessionId;
    ctx->channelId = channelId;
    ctx->cmdFlag = cmdFlag;
    ctx->payload = std::move(payload);

    if (!PostToLoop([ctx]() {
            ctx->sendRet = ctx->self->Send(ctx->sessionId, ctx->channelId, ctx->cmdFlag,
                                           reinterpret_cast<const uint8_t *>(ctx->payload.data()),
                                           static_cast<int>(ctx->payload.size()));
            {
                std::lock_guard<std::mutex> lock(ctx->mtx);
                ctx->done = true;
            }
            ctx->cv.notify_all();
        })) {
        std::lock_guard<std::mutex> lock(execMutex_);
        pendingChannelId_ = 0;
        streamChunkSink_ = nullptr;
        result.error = "failed to schedule command execution";
        return false;
    }

    {
        std::unique_lock<std::mutex> lock(ctx->mtx);
        ctx->cv.wait(lock, [&ctx] { return ctx->done; });
    }

    if (ctx->sendRet < 0) {
        std::lock_guard<std::mutex> lock(execMutex_);
        pendingChannelId_ = 0;
        streamChunkSink_ = nullptr;
        result.error = "failed to send the command";
        return false;
    }

    bool timedOut = false;
    bool wasAborted = false;
    bool wasDisconnected = false;
    uint32_t sessionId = ctx->sessionId;
    {
        std::unique_lock<std::mutex> lock(execMutex_);
        if (timeoutSeconds > 0) {
            bool signalled = execCv_.wait_for(lock, std::chrono::seconds(timeoutSeconds),
                                              [this] { return pendingDone_; });
            if (!signalled) {
                timedOut = true;
            }
        } else {
            execCv_.wait(lock, [this] { return pendingDone_; });
        }
        result.output = pendingOutput_;
        wasAborted = pendingAborted_;
        wasDisconnected = pendingDisconnected_;
        pendingChannelId_ = 0;
        streamChunkSink_ = nullptr;
    }

    if (wasAborted) {
        result.ok = false;
        result.exitCode = -130;
        result.error = "命令已由用户中断 (SIGINT)";
        return false;
    }
    if (wasDisconnected) {
        result.ok = false;
        result.exitCode = -1;
        result.error = "connection lost while executing command";
        return false;
    }
    if (timedOut) {
        SendChannelClose(sessionId, channelId);
        result.ok = false;
        result.exitCode = -124;
        result.error = "Command timed out after " + std::to_string(timeoutSeconds) + "s";
        Report("command timed out after " + std::to_string(timeoutSeconds) + "s on channel " +
               std::to_string(channelId));
        return false;
    }
    result.ok = true;
    return true;
}

bool DeviceSession::Abort()
{
    uint32_t sessionId = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (session_ != nullptr) {
            sessionId = session_->sessionId;
        }
    }
    uint32_t channelId = 0;
    {
        std::lock_guard<std::mutex> lock(execMutex_);
        if (pendingChannelId_ == 0 || sessionId == 0) {
            return false;
        }
        channelId = pendingChannelId_;
        pendingAborted_ = true;
        pendingDone_ = true;
    }

    SendChannelClose(sessionId, channelId);
    execCv_.notify_all();
    Report("aborted command on channel " + std::to_string(channelId));
    return true;
}

}  // namespace swshell
