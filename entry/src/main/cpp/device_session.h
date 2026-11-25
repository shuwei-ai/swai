/*
 * The app-role device session.
 *
 * The upstream hdc host daemon is built around a local CLI: the `hdc` client
 * connects to it over TCP 127.0.0.1:8710 and it multiplexes device sessions
 * over the CLI connections.  We do not want any of that - we ARE the client,
 * and we talk straight to the device's own hdcd.
 *
 * So this class takes the role the host daemon plays with respect to the
 * device, but with one device, no CLI, and no forwarding layer:
 *
 *   * HdcHostTCP connects to the device daemon over TCP (the "slave" side of
 *     upstream's SetupTCPPoint).
 *   * The vendored HdcSessionBase runs the session state machine; the first
 *     handshake packet is built and sent by upstream code
 *     (HdcSessionBase::WorkThreadInitSession).
 *   * We implement the rest of the handshake - the public key and the token
 *     signature - in FetchCommand, which is the hook upstream's HdcServer
 *     uses for exactly the same purpose.
 *   * Shell commands go out as CMD_UNITY_EXECUTE_EX on a channel of our
 *     choosing; the device streams the output back with CMD_KERNEL_ECHO_RAW
 *     and finishes with CMD_KERNEL_CHANNEL_CLOSE.
 *
 * One thing matters a great deal here: the vendored code is built around a
 * libuv event loop that somebody has to run.  Upstream that is the host
 * daemon's main thread.  We run it on a thread of our own, and every libuv
 * call that touches the session - uv_tcp_connect in particular - has to
 * happen on that thread, or the connect is silently never issued.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_DEVICE_SESSION_H
#define SW_SHELL_DEVICE_SESSION_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "host_tcp.h"
#include "session.h"

namespace swshell {

struct ExecResult {
    bool ok = false;
    int exitCode = -1;
    std::string output;
    std::string error;
};

struct ConnectResult {
    bool ok = false;
    int port = 0;
    std::string reason;
    std::string error;
};

struct SessionStateSnapshot {
    bool connected = false;
    bool connecting = false;
    bool awaitingAuth = false;
    int port = 0;
};

class DeviceSession : public Hdc::HdcSessionBase {
public:
    using ConnectCallback = std::function<void(const ConnectResult &result)>;
    using StreamChunkCallback = std::function<void(const std::string &chunk)>;

    DeviceSession();
    ~DeviceSession() override;

    /*
     * Connects to the device's hdcd over TCP and completes the handshake.
     * `keyDir` is the directory the client keypair is kept in.
     *
     * When `port` is zero the device's listening ports are enumerated and
     * tried one by one, because the daemon is assigned a random port when
     * wireless debugging is switched on and an app cannot read it.
     *
     * The callback runs once the handshake has either succeeded or failed.
     */
    void ConnectAsync(const std::string &host, int port, const std::string &keyDir, ConnectCallback callback);

    void CancelPendingConnect();

    void Disconnect();

    bool IsReady() const;

    SessionStateSnapshot GetSessionState() const;

    /*
     * Runs one command on the device and waits for it to finish.
     * `bundleName` selects the app context the command runs in; an empty
     * string means the default shell context.
     * `onChunk` receives output chunks in real time as they arrive.
     * If `timeoutSeconds` is 0, the command runs indefinitely until it exits
     * or is interrupted with Abort().
     */
    bool Exec(const std::string &command, const std::string &bundleName, ExecResult &result,
              unsigned timeoutSeconds = 30, StreamChunkCallback onChunk = nullptr);

    /*
     * Interrupts the currently executing command (sends CMD_KERNEL_CHANNEL_CLOSE).
     */
    bool Abort();

    /* Called from the session worker thread / main loop. */
    bool FetchCommand(Hdc::HSession hSession, const uint32_t channelId, const uint16_t command,
                      uint8_t *payload, int payloadSize) override;

    void NotifyInstanceSessionFree(Hdc::HSession hSession, bool freeOrClear) override;

    /* Diagnostics for the UI. */
    std::function<void(const std::string &)> logSink;
    std::function<void(bool ready, const std::string &detail)> stateSink;

private:
    static void OnWakeAsync(uv_async_t *handle);
    bool PostToLoop(std::function<void()> fn);
    void DrainPostQueue();
    void StartLoop();
    void StopLoop();
    void FinishConnect(const ConnectResult &result);
    void TryNextCandidate();
    void OnProbeTimeout(uint64_t expectedGen, uint32_t timedOutSid, int attemptPort);
    bool HandleHandshake(Hdc::HSession hSession, const uint32_t channelId, uint8_t *payload, int payloadSize);
    bool SendHandshake(Hdc::HSession hSession, const uint32_t channelId, uint8_t authType, const std::string &buf);
    void Report(const std::string &message);
    void ReportState(bool ready, const std::string &detail);
    void SendChannelClose(uint32_t sessionId, uint32_t channelId);

    std::thread loopThread_;
    std::atomic<bool> loopRunning_{false};
    uv_async_t wakeAsync_{};
    bool wakeAsyncInit_ = false;
    std::mutex postMutex_;
    std::deque<std::function<void()>> postQueue_;

    Hdc::HdcHostTCP *tcpClient_ = nullptr;
    Hdc::HSession session_ = nullptr;
    uint32_t nextChannelId_ = 1;

    std::string host_ = "127.0.0.1";
    std::string connectKey_;
    std::string keyDir_;
    std::vector<int> candidates_;
    size_t candidateIndex_ = 0;
    bool singleExplicitPort_ = false;
    std::string lastCandidateError_;
    std::string lastCandidateReason_;

    mutable std::mutex mutex_;
    mutable std::condition_variable readyCv_;
    bool handshakeOk_ = false;
    bool connecting_ = false;
    bool awaitingAuth_ = false;
    int connectedPort_ = 0;
    int attemptPort_ = 0;
    uint64_t attemptGen_ = 0;
    uint32_t currentAttemptSessionId_ = 0;
    ConnectCallback connectCallback_;

    mutable std::mutex execSerializeMutex_;
    mutable std::mutex execMutex_;
    mutable std::condition_variable execCv_;
    uint32_t pendingChannelId_ = 0;
    bool pendingDone_ = false;
    bool pendingAborted_ = false;
    bool pendingDisconnected_ = false;
    std::string pendingOutput_;
    StreamChunkCallback streamChunkSink_;
};

DeviceSession* GetActiveDeviceSession();

}  // namespace swshell

#endif /* SW_SHELL_DEVICE_SESSION_H */
