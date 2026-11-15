/*
 * Unit test for DshState and dsh_host_piha_v1 C ABI.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
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

    std::cout << "All DshBridge and C ABI tests PASSED successfully!" << std::endl;
    return 0;
}
