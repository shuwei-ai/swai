/*
 * Unit test for DshState and dsh_host_piha_v1 C ABI.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "../dsh_host.h"
#include "../dsh_state.h"
#include <cassert>
#include <iostream>
#include <thread>

int main() {
    auto& state = swshell::DshState::GetInstance();
    state.Reset();

    // 1. Snapshot when idle
    auto snap = state.GetSnapshot();
    assert(snap.phase == "idle");
    assert(snap.port == 0);

    // 2. Transition to running
    state.SetReady(38080, "http://127.0.0.1:38080", "secret-token-123");
    snap = state.GetSnapshot();
    assert(snap.phase == "running");
    assert(snap.port == 38080);
    assert(snap.token == "secret-token-123");

    // 3. Test C ABI DSH_OP_SNAPSHOT
    DshBridgeInputV1 snap_in{};
    snap_in.size = sizeof(snap_in);
    snap_in.version = 1;
    snap_in.operation = DSH_OP_SNAPSHOT;

    DshBridgeOutputV1 snap_out{};
    int rc = dsh_host_piha_v1(&snap_in, &snap_out);
    assert(rc == 1);
    assert(snap_out.status == 1);
    std::string json(snap_out.data, snap_out.data_size);
    assert(json.find("\"port\":38080") != std::string::npos);

    // 4. Test C ABI DSH_OP_DISPATCH (Node -> Host)
    DshBridgeInputV1 disp_in{};
    disp_in.size = sizeof(disp_in);
    disp_in.version = 1;
    disp_in.operation = DSH_OP_DISPATCH;
    strncpy(disp_in.request_id, "req-test-001", sizeof(disp_in.request_id) - 1);
    strncpy(disp_in.tool, "ui", sizeof(disp_in.tool) - 1);
    const char* args = "{\"action\":\"dump_tree\"}";
    disp_in.data = args;
    disp_in.data_size = strlen(args);

    DshBridgeOutputV1 disp_out{};
    rc = dsh_host_piha_v1(&disp_in, &disp_out);
    assert(rc == 1);
    assert(disp_out.status == 1);

    // 5. Test ArkTS ClaimNextRequest
    auto claimed = state.ClaimNextRequest(100);
    assert(claimed.has_value());
    assert(claimed->request_id == "req-test-001");
    assert(claimed->tool == "ui");
    assert(claimed->args_json == args);

    // 6. While ArkTS is executing, Node polls -> should be pending (status = 0)
    DshBridgeInputV1 poll_in{};
    poll_in.size = sizeof(poll_in);
    poll_in.version = 1;
    poll_in.operation = DSH_OP_POLL_RESULT;
    strncpy(poll_in.request_id, "req-test-001", sizeof(poll_in.request_id) - 1);

    DshBridgeOutputV1 poll_out{};
    rc = dsh_host_piha_v1(&poll_in, &poll_out);
    assert(rc == 0); // pending

    // 7. ArkTS finishes tool execution and reports result
    swshell::DshToolResponse resp;
    resp.request_id = "req-test-001";
    resp.success = true;
    resp.output = "{\"nodes\":[{\"id\":\"btn_ok\"}]}";
    resp.exit_code = 0;
    state.FinishRequest(resp);

    // 8. Node polls again -> should be ready (status = 1)
    rc = dsh_host_piha_v1(&poll_in, &poll_out);
    assert(rc == 1);
    assert(poll_out.status == 1);
    assert(std::string(poll_out.data) == "{\"nodes\":[{\"id\":\"btn_ok\"}]}");

    // 9. Test Cancel
    disp_in.operation = DSH_OP_DISPATCH;
    strncpy(disp_in.request_id, "req-cancel-002", sizeof(disp_in.request_id) - 1);
    strncpy(disp_in.tool, "bash", sizeof(disp_in.tool) - 1);
    dsh_host_piha_v1(&disp_in, &disp_out);

    DshBridgeInputV1 cancel_in{};
    cancel_in.size = sizeof(cancel_in);
    cancel_in.version = 1;
    cancel_in.operation = DSH_OP_CANCEL;
    strncpy(cancel_in.request_id, "req-cancel-002", sizeof(cancel_in.request_id) - 1);

    DshBridgeOutputV1 cancel_out{};
    rc = dsh_host_piha_v1(&cancel_in, &cancel_out);
    assert(rc == 1);
    assert(cancel_out.status == 3); // cancelled

    // 10. Test ParseToolHttpBodyJson with nested decoy keys & escaped quotes
    {
        swshell::ParsedToolHttpBody parsed;
        std::string payload = R"({
            "args": {
                "command": "echo \"tool\":\"evil\" \"requestId\":\"fake\" \"deadlineMs\":1",
                "nested": {"tool": "nested_tool", "deadlineMs": 42}
            },
            "deadlineMs": 1799999999000,
            "tool": "remote_bash",
            "requestId": "real-req-999"
        })";
        bool ok = swshell::ParseToolHttpBodyJson(payload, parsed);
        assert(ok);
        assert(parsed.request_id == "real-req-999");
        assert(parsed.tool == "remote_bash");
        assert(parsed.deadline_ms == 1799999999000LL);
        assert(parsed.args_json.find("\"nested_tool\"") != std::string::npos);
        assert(parsed.args_json.front() == '{' && parsed.args_json.back() == '}');
    }

    // 11. Test ParseToolHttpBodyJson with normal key order & unicode escapes
    {
        swshell::ParsedToolHttpBody parsed;
        std::string payload = "{\"requestId\":\"req-u1\",\"tool\":\"ui\",\"args\":{\"text\":\"\\u4e2d\\u6587\"},\"deadlineMs\":5000}";
        bool ok = swshell::ParseToolHttpBodyJson(payload, parsed);
        assert(ok);
        assert(parsed.request_id == "req-u1");
        assert(parsed.tool == "ui");
        assert(parsed.deadline_ms == 5000);
        assert(parsed.args_json == "{\"text\":\"\\u4e2d\\u6587\"}");
    }

    // 12. Test ComputePollTimeoutMs clamping & defaults
    assert(swshell::ComputePollTimeoutMs(0, 1000000) == 60000);
    assert(swshell::ComputePollTimeoutMs(-5, 1000000) == 60000);
    assert(swshell::ComputePollTimeoutMs(1180000, 1000000) == 180000);
    assert(swshell::ComputePollTimeoutMs(1500000, 1000000) == 310000);
    assert(swshell::ComputePollTimeoutMs(999000, 1000000) == 1000);

    // 13. Test ParseHostReadyBodyJson valid & invalid inputs
    {
        int port = 0;
        std::string base_url;
        std::string token;
        bool ok = swshell::ParseHostReadyBodyJson(
            R"({"phase":"running","port":38927,"baseUrl":"http://127.0.0.1:38927","token":"abc_123-XYZ"})",
            port, base_url, token);
        assert(ok);
        assert(port == 38927);
        assert(base_url == "http://127.0.0.1:38927");
        assert(token == "abc_123-XYZ");
    }
    {
        int port = 0;
        std::string base_url;
        std::string token;
        assert(!swshell::ParseHostReadyBodyJson(R"({"port":0,"baseUrl":"http://127.0.0.1:0","token":"t"})", port, base_url, token));
        assert(!swshell::ParseHostReadyBodyJson(R"({"port":38927,"baseUrl":"http://127.0.0.1:38927"})", port, base_url, token));
    }

    std::cout << "All DshBridge and C ABI tests PASSED successfully!" << std::endl;
    return 0;
}
