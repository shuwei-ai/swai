/*
 * Swai <-> DeepSeek Harness (DSH) Host Process Manager
 *
 * Controls embedded/daemonized Node.js DSH server, handles stdout/stderr
 * redirection for automatic token and port discovery, and manages lifecycles.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_DSH_HOST_H
#define SW_DSH_HOST_H

#include "dsh_state.h"

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace swshell {

struct DshHostOptions {
    std::string runtime_root;
    std::string workspace_root;
    std::string custom_node_path;
    std::map<std::string, std::string> env;
    std::vector<std::string> extra_args;
};

class DshHost {
public:
    static DshHost& GetInstance() {
        static DshHost instance;
        return instance;
    }

    bool Start(const DshHostOptions& options, std::string& errOut);
    void Stop();
    bool IsRunning() const;
    DshHostSnapshot GetSnapshot();

    // Event notification callback (e.g. for NAPI threadsafe callbacks)
    using EventCallback = std::function<void(const std::string& kind, const std::string& payload)>;
    void SetEventCallback(EventCallback cb) {
        event_cb_ = std::move(cb);
    }

    void NotifyEvent(const std::string& kind, const std::string& payload) {
        if (event_cb_) {
            event_cb_(kind, payload);
        }
    }

private:
    DshHost() = default;
    ~DshHost() { Stop(); }

    void StatusWatcherThread();
    void ProcessLine(const std::string& stream, const std::string& line);
    void StartToolBridgeServer();
    void StopToolBridgeServer();
    void HandleToolHttpRequest(int client_fd);

    std::atomic<bool> is_running_{false};
    std::atomic<bool> stop_requested_{false};
    std::thread runner_thread_;
    std::thread status_watcher_thread_;
    std::thread tool_server_thread_;
    std::atomic<bool> tool_server_running_{false};
    int tool_server_fd_{-1};
    EventCallback event_cb_;
    DshHostOptions current_options_;
};

} // namespace swshell

#endif // SW_DSH_HOST_H
