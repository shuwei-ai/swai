/*
 * Host-side unit tests for HDC daemon discovery parsing and candidate port filtering.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "../discovery.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <sstream>
#include <string>
#include <vector>

namespace {

int gFailures = 0;

void Check(bool condition, const char *what)
{
    if (!condition) {
        std::printf("FAIL %s\n", what);
        gFailures++;
    }
}

void TestParseDaemonPort()
{
    Check(swshell::ParseDaemonPort("OHOS HDC-45661", 14) == 45661, "parse valid 5-digit port");
    Check(swshell::ParseDaemonPort("OHOS HDC-8710", 13) == 8710, "parse valid default port");
    Check(swshell::ParseDaemonPort("OHOS HDC-65535", 14) == 65535, "parse max port 65535");
    Check(swshell::ParseDaemonPort(nullptr, 10) == 0, "reject null buffer");
    Check(swshell::ParseDaemonPort("loopBroadcast", 13) == 0, "reject own broadcast echo");
    Check(swshell::ParseDaemonPort("OHOS HDC-", 9) == 0, "reject empty port");
    Check(swshell::ParseDaemonPort("OHOS HDC-0", 10) == 0, "reject zero port");
    Check(swshell::ParseDaemonPort("OHOS HDC-65536", 14) == 0, "reject out-of-range port");
    Check(swshell::ParseDaemonPort("OHOS HDC-123abc", 15) == 0, "reject non-digit suffix");
    Check(swshell::ParseDaemonPort("OTHER-8710", 10) == 0, "reject unknown banner");
}

void TestCollectPortsFromProcStream()
{
    std::istringstream tcp4(
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
        "   0: 00000000:B25D 00000000:0000 0A 00000000:00000000 00:00000000 00000000  2000        0 100 1 0 100\n"
        "   1: 0100007F:2406 00000000:0000 0A 00000000:00000000 00:00000000 00000000 10001        0 101 1 0 100\n"
        "   2: 0100A8C0:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  2000        0 102 1 0 100\n"
        "   3: 00000000:1F91 00000000:0000 01 00000000:00000000 00:00000000 00000000  2000        0 103 1 0 100\n"
    );

    std::vector<int> ports;
    swshell::CollectPortsFromProcStream(tcp4, ports);
    Check(ports.size() == 2, "collect exactly 2 ipv4 loopback/wildcard listen ports");
    Check(ports[0] == 45661, "collect 0xB25D -> 45661");
    Check(ports[1] == 9222, "collect 0x2406 -> 9222");

    std::istringstream tcp6(
        "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
        "   0: 00000000000000000000000000000000:9859 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 10001 0 200\n"
        "   1: 00000000000000000000000001000000:B25D 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  2000 0 201\n"
        "   2: 0000000000000000FFFF00000100007F:94C1 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 10001 0 202\n"
        "   3: 0000000000000000ffff000000000000:1F92 00000000000000000000000000000000:0000 0a 00000000:00000000 00:00000000 00000000  2000 0 203\n"
        "   4: FE800000000000000000000000000001:1F93 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  2000 0 204\n"
    );

    std::vector<int> ports6;
    swshell::CollectPortsFromProcStream(tcp6, ports6);
    Check(ports6.size() == 4, "collect 4 ipv6 wildcard/loopback/v4-mapped listen ports");
    Check(ports6[0] == 45661, "collect uid=2000 ::1 port 45661 first");
    Check(ports6[1] == 8082, "collect uid=2000 lowercase ::ffff:0.0.0.0 port 8082 second");
    Check(ports6[2] == 39001, "collect :: port 39001");
    Check(ports6[3] == 38081, "collect ::ffff:127.0.0.1 port 38081");
}

void TestFilterCandidatePorts()
{
    std::vector<int> raw = { 39001, 45661, 9222, 38081, 45661, 0, -5, 70000, 38927, 41234 };
    std::vector<int> excludes = { 9222, 38081, 39001, 38927 };
    std::vector<int> filtered = swshell::FilterCandidatePorts(raw, excludes);
    Check(filtered.size() == 2, "filter keeps exactly 2 valid non-excluded ports");
    Check(filtered[0] == 41234, "sorted candidate[0] == 41234");
    Check(filtered[1] == 45661, "sorted candidate[1] == 45661");

    std::vector<int> empty = swshell::FilterCandidatePorts({}, excludes);
    Check(empty.empty(), "empty input produces empty output");
}

void TestPrioritizeUid2000Ports()
{
    std::istringstream tcp(
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
        "   0: 00000000:22C5 00000000:0000 0A 00000000:00000000 00:00000000 00000000 20020252        0 100 1 0 100\n"
        "   1: 0100007F:9C36 00000000:0000 0A 00000000:00000000 00:00000000 00000000 20020052        0 101 1 0 100\n"
        "   2: 00000000:B25D 00000000:0000 0A 00000000:00000000 00:00000000 00000000  2000        0 102 1 0 100\n"
    );
    std::vector<int> shellPorts;
    std::vector<int> otherPorts;
    swshell::CollectPrioritizedPortsFromProcStream(tcp, shellPorts, otherPorts);
    Check(shellPorts.size() == 1 && shellPorts[0] == 45661, "uid 2000 port 45661 placed in shellPorts");
    Check(otherPorts.size() == 2 && otherPorts[0] == 8901 && otherPorts[1] == 39990, "non-shell ports separated into otherPorts");
}

void TestScanLoopbackPorts()
{
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    Check(srv >= 0, "create loopback test server socket");
    if (srv < 0) {
        return;
    }
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    Check(bind(srv, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) == 0, "bind loopback test server");
    Check(listen(srv, 4) == 0, "listen loopback test server");
    socklen_t len = sizeof(addr);
    Check(getsockname(srv, reinterpret_cast<struct sockaddr *>(&addr), &len) == 0, "getsockname loopback test server");
    const int boundPort = ntohs(addr.sin_port);

    std::vector<int> found = swshell::ScanLoopbackPorts(boundPort - 5, boundPort + 5, {});
    Check(std::find(found.begin(), found.end(), boundPort) != found.end(), "ScanLoopbackPorts detects listening port");

    std::vector<int> excluded = swshell::ScanLoopbackPorts(boundPort - 5, boundPort + 5, { boundPort });
    Check(std::find(excluded.begin(), excluded.end(), boundPort) == excluded.end(), "ScanLoopbackPorts honors excludePorts");

    close(srv);
}

}  // namespace

int main()
{
    TestParseDaemonPort();
    TestCollectPortsFromProcStream();
    TestFilterCandidatePorts();
    TestPrioritizeUid2000Ports();
    TestScanLoopbackPorts();

    if (gFailures == 0) {
        std::printf("all discovery tests passed\n");
        return 0;
    }
    std::printf("%d discovery test(s) failed\n", gFailures);
    return 1;
}
