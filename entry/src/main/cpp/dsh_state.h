/*
 * Swai (Shuwei AI) <-> DeepSeek Harness (DSH) Bridge State Machine
 *
 * Provides thread-safe state synchronization, lifecycle management,
 * and high-performance in-process C ABI for tool dispatch between
 * Node.js (DSH engine) and ArkTS (Swai UI / Native Tools).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_DSH_STATE_H
#define SW_DSH_STATE_H

#include <stdint.h>
#include <string.h>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#ifdef __cplusplus
extern "C" {
#endif

// C ABI operations for dsh_host_piha_v1
enum DshBridgeOp {
    DSH_OP_DISPATCH = 1,    // Node -> Host: dispatch tool request
    DSH_OP_POLL_RESULT = 2, // Node -> Host: poll or wait for tool result
    DSH_OP_CANCEL = 3,      // Node -> Host: cancel tool call
    DSH_OP_SNAPSHOT = 4     // Node -> Host: read engine status
};

#pragma pack(push, 8)
struct DshBridgeInputV1 {
    uint32_t size;
    uint32_t version;
    uint32_t operation; // DshBridgeOp
    uint32_t reserved;
    char request_id[64];
    char tool[64];      // "bash", "ui", "run_code", "remote_bash"
    int64_t deadline_ms;
    uint32_t data_size;
    const char* data;   // JSON-serialized arguments
};

struct DshBridgeOutputV1 {
    uint32_t size;
    uint32_t version;
    int32_t status;     // 0: pending, 1: succeeded, 2: failed, 3: cancelled/timeout
    int32_t exit_code;
    uint32_t data_size;
    char data[65536];   // JSON output or error message
};
#pragma pack(pop)

// C ABI entrypoint exported for Node dlopen
__attribute__((visibility("default")))
int dsh_host_piha_v1(const struct DshBridgeInputV1* in, struct DshBridgeOutputV1* out) noexcept;

#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
namespace swshell {

struct DshToolRequest {
    std::string request_id;
    std::string tool;
    std::string args_json;
    int64_t deadline_ms = 0;
};

struct DshToolResponse {
    std::string request_id;
    bool success = false;
    std::string output;
    std::string error;
    int exit_code = 0;
};

struct DshHostSnapshot {
    std::string phase = "idle"; // "idle", "starting", "running", "stopping", "exited", "error"
    int port = 0;
    std::string base_url;
    std::string token;
    int exit_code = 0;
    std::string error_code;
    std::string error_message;
    size_t pending_tools = 0;
};

class DshState {
public:
    static DshState& GetInstance() {
        static DshState instance;
        return instance;
    }

    void Reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        phase_ = "idle";
        port_ = 0;
        base_url_.clear();
        token_.clear();
        exit_code_ = 0;
        error_code_.clear();
        error_message_.clear();
        pending_requests_.clear();
        completed_responses_.clear();
        cond_.notify_all();
    }

    void SetStarting() {
        std::lock_guard<std::mutex> lock(mutex_);
        phase_ = "starting";
        exit_code_ = 0;
        error_code_.clear();
        error_message_.clear();
    }

    void SetReady(int port, const std::string& base_url, const std::string& token) {
        std::lock_guard<std::mutex> lock(mutex_);
        phase_ = "running";
        port_ = port;
        base_url_ = base_url;
        token_ = token;
        cond_.notify_all();
    }

    void SetExited(int exit_code) {
        std::lock_guard<std::mutex> lock(mutex_);
        phase_ = "exited";
        exit_code_ = exit_code;
        cond_.notify_all();
    }

    void SetError(const std::string& code, const std::string& message) {
        std::lock_guard<std::mutex> lock(mutex_);
        phase_ = "error";
        error_code_ = code;
        error_message_ = message;
        cond_.notify_all();
    }

    DshHostSnapshot GetSnapshot() {
        std::lock_guard<std::mutex> lock(mutex_);
        DshHostSnapshot snap;
        snap.phase = phase_;
        snap.port = port_;
        snap.base_url = base_url_;
        snap.token = token_;
        snap.exit_code = exit_code_;
        snap.error_code = error_code_;
        snap.error_message = error_message_;
        snap.pending_tools = pending_requests_.size();
        return snap;
    }

    // Node C ABI: dispatch a new tool request
    bool DispatchToolFromNode(const DshToolRequest& req) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (phase_ != "running") {
            return false;
        }
        pending_requests_.push_back(req);
        cond_.notify_all();
        return true;
    }

    // Node C ABI: poll or wait for tool result
    int PollToolResultForNode(const std::string& request_id, DshToolResponse& resp, int wait_ms = 0) {
        std::unique_lock<std::mutex> lock(mutex_);
        auto it = completed_responses_.find(request_id);
        if (it != completed_responses_.end()) {
            resp = it->second;
            completed_responses_.erase(it);
            return 1; // ready
        }

        if (wait_ms > 0) {
            cond_.wait_for(lock, std::chrono::milliseconds(wait_ms), [&] {
                return completed_responses_.find(request_id) != completed_responses_.end() ||
                       phase_ != "running";
            });
            it = completed_responses_.find(request_id);
            if (it != completed_responses_.end()) {
                resp = it->second;
                completed_responses_.erase(it);
                return 1; // ready
            }
        }

        if (phase_ != "running") {
            return 2; // failed due to engine stop
        }
        return 0; // still pending
    }

    // Node C ABI: cancel a tool request
    bool CancelToolFromNode(const std::string& request_id) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = pending_requests_.begin(); it != pending_requests_.end(); ++it) {
            if (it->request_id == request_id) {
                pending_requests_.erase(it);
                DshToolResponse resp;
                resp.request_id = request_id;
                resp.success = false;
                resp.error = "cancelled";
                completed_responses_[request_id] = resp;
                cond_.notify_all();
                return true;
            }
        }
        return false;
    }

    // ArkTS: claim next pending request to execute
    std::optional<DshToolRequest> ClaimNextRequest(int wait_ms = 0) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (pending_requests_.empty() && wait_ms > 0) {
            cond_.wait_for(lock, std::chrono::milliseconds(wait_ms), [&] {
                return !pending_requests_.empty() || phase_ != "running";
            });
        }
        if (pending_requests_.empty()) {
            return std::nullopt;
        }
        DshToolRequest req = pending_requests_.front();
        pending_requests_.pop_front();
        return req;
    }

    // ArkTS: finish a tool execution and report result
    void FinishRequest(const DshToolResponse& resp) {
        std::lock_guard<std::mutex> lock(mutex_);
        completed_responses_[resp.request_id] = resp;
        cond_.notify_all();
    }

private:
    DshState() = default;

    std::mutex mutex_;
    std::condition_variable cond_;
    std::string phase_ = "idle";
    int port_ = 0;
    std::string base_url_;
    std::string token_;
    int exit_code_ = 0;
    std::string error_code_;
    std::string error_message_;

    std::deque<DshToolRequest> pending_requests_;
    std::map<std::string, DshToolResponse> completed_responses_;
};

} // namespace swshell
#endif

#endif // SW_DSH_STATE_H
