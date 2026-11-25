/*
 * Finding the device's hdc daemon without being told the port.
 * See discovery.h for the protocol and the port-reuse caveat.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "discovery.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <sstream>

namespace swshell {

namespace {

/* The port the daemon listens on for discovery, and the banner it answers
 * with.  Both come from developtools_hdc/src/daemon/daemon_tcp.cpp and
 * src/common/define.h. */
constexpr uint16_t kDiscoveryPort = 8710;
constexpr const char *kDiscoveryRequest = "loopBroadcast";
constexpr const char *kDiscoveryBanner = "OHOS HDC-";

bool IsLoopbackOrWildcardHex(const std::string &rawAddress)
{
    std::string address;
    address.reserve(rawAddress.size());
    for (unsigned char c : rawAddress) {
        address.push_back(static_cast<char>(std::toupper(c)));
    }
    return address == "00000000" ||
           address == "0100007F" ||
           address == "00000000000000000000000000000000" ||
           address == "00000000000000000000000001000000" ||
           address == "0000000000000000FFFF000000000000" ||
           address == "0000000000000000FFFF00000100007F";
}

}  // namespace

/*
 * Parses "<banner>-<port>" and returns the port, or 0 when the datagram is
 * not the daemon's answer - the app also receives the broadcast it sent
 * itself, and that one must be ignored.
 */
int ParseDaemonPort(const char *data, size_t length)
{
    if (data == nullptr) {
        return 0;
    }
    const size_t bannerLength = strlen(kDiscoveryBanner);
    if (length <= bannerLength || memcmp(data, kDiscoveryBanner, bannerLength) != 0) {
        return 0;
    }
    int port = 0;
    for (size_t i = bannerLength; i < length; i++) {
        const char c = data[i];
        if (c < '0' || c > '9') {
            return 0;
        }
        port = port * 10 + (c - '0');
        if (port > 65535) {
            return 0;
        }
    }
    return port;
}

int DiscoverDaemonPort(int timeoutMs, std::string &error)
{
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        error = std::string("socket failed: ") + strerror(errno);
        return 0;
    }

    /* The daemon binds the same port on the wildcard address, so we need
     * SO_REUSEADDR to be able to bind it as well. */
    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    int broadcast = 1;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast));

    struct sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = htons(kDiscoveryPort);
    if (bind(sock, reinterpret_cast<struct sockaddr *>(&local), sizeof(local)) < 0) {
        error = std::string("bind to the discovery port failed: ") + strerror(errno);
        close(sock);
        return 0;
    }

    /* Ask on the loopback address and on the broadcast address: the daemon
     * binds the wildcard address, so either reaches it, and the loopback
     * one keeps the source address on this device, which is where the daemon
     * sends its answer back to. */
    struct sockaddr_in target = {};
    target.sin_family = AF_INET;
    target.sin_port = htons(kDiscoveryPort);
    target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sendto(sock, kDiscoveryRequest, strlen(kDiscoveryRequest), 0,
           reinterpret_cast<struct sockaddr *>(&target), sizeof(target));

    target.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(sock, kDiscoveryRequest, strlen(kDiscoveryRequest), 0,
           reinterpret_cast<struct sockaddr *>(&target), sizeof(target));

    int port = 0;
    const int pollMs = (timeoutMs > 0) ? timeoutMs : 3000;
    int waited = 0;
    while (waited < pollMs && port == 0) {
        struct pollfd fds = {};
        fds.fd = sock;
        fds.events = POLLIN;
        int ready = poll(&fds, 1, 200);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = std::string("poll failed: ") + strerror(errno);
            break;
        }
        if (ready == 0) {
            waited += 200;
            continue;
        }
        char buffer[256] = { 0 };
        struct sockaddr_in from = {};
        socklen_t fromLength = sizeof(from);
        ssize_t received = recvfrom(sock, buffer, sizeof(buffer) - 1, 0,
                                    reinterpret_cast<struct sockaddr *>(&from), &fromLength);
        if (received <= 0) {
            waited += 200;
            continue;
        }
        port = ParseDaemonPort(buffer, static_cast<size_t>(received));
        if (port == 0) {
            /* That was our own broadcast coming back.  Keep waiting. */
            waited += 200;
        }
    }

    close(sock);
    if (port == 0 && error.empty()) {
        error = "the device's hdc daemon did not answer the discovery broadcast";
    }
    return port;
}

/*
 * Reads the listening TCP ports out of /proc/net/tcp or /proc/net/tcp6.
 *
 * The format is one row per socket; the local address is hex, in
 * host byte order (or 4 little-endian 32-bit words for IPv6), followed by a
 * colon and the hex port.  The state column is 0A for LISTEN.  Only wildcard
 * and loopback addresses are collected.
 */
void CollectPrioritizedPortsFromProcStream(std::istream &stream,
                                           std::vector<int> &shellPorts,
                                           std::vector<int> &otherPorts)
{
    std::string line;
    if (!std::getline(stream, line)) { /* the header row */
        return;
    }
    while (std::getline(stream, line)) {
        std::istringstream row(line);
        std::string field;
        std::string local;
        std::string remote;
        std::string state;
        std::string txRx;
        std::string trTm;
        std::string retrnsmt;
        std::string uidStr;
        if (!(row >> field >> local >> remote >> state)) {
            continue;
        }
        if (state != "0A" && state != "0a") {
            continue;
        }
        const size_t colon = local.find(':');
        if (colon == std::string::npos) {
            continue;
        }
        const std::string address = local.substr(0, colon);
        if (!IsLoopbackOrWildcardHex(address)) {
            continue;
        }
        char *endptr = nullptr;
        const char *portStr = local.c_str() + colon + 1;
        if (*portStr == '\0') {
            continue;
        }
        const long port = std::strtol(portStr, &endptr, 16);
        if (endptr == portStr || *endptr != '\0' || port <= 0 || port > 65535) {
            continue;
        }
        long uid = -1;
        if (row >> txRx >> trTm >> retrnsmt >> uidStr) {
            char *uidEnd = nullptr;
            const long parsedUid = std::strtol(uidStr.c_str(), &uidEnd, 10);
            if (uidEnd != uidStr.c_str() && *uidEnd == '\0') {
                uid = parsedUid;
            }
        }
        if (uid == 2000) {
            shellPorts.push_back(static_cast<int>(port));
        } else {
            otherPorts.push_back(static_cast<int>(port));
        }
    }
}

void CollectPortsFromProcStream(std::istream &stream, std::vector<int> &ports)
{
    std::vector<int> shellPorts;
    std::vector<int> otherPorts;
    CollectPrioritizedPortsFromProcStream(stream, shellPorts, otherPorts);
    ports.insert(ports.end(), shellPorts.begin(), shellPorts.end());
    ports.insert(ports.end(), otherPorts.begin(), otherPorts.end());
}

namespace {

void CollectPortsFromProc(const char *path, std::vector<int> &ports)
{
    std::ifstream file(path);
    if (!file.is_open()) {
        return;
    }
    CollectPortsFromProcStream(file, ports);
}

void CollectPrioritizedPortsFromProc(const char *path,
                                     std::vector<int> &shellPorts,
                                     std::vector<int> &otherPorts)
{
    std::ifstream file(path);
    if (!file.is_open()) {
        return;
    }
    CollectPrioritizedPortsFromProcStream(file, shellPorts, otherPorts);
}

}  // namespace

std::vector<int> FilterCandidatePorts(const std::vector<int> &ports, const std::vector<int> &excludePorts)
{
    std::vector<int> filtered;
    filtered.reserve(ports.size());
    for (int port : ports) {
        if (port <= 0 || port > 65535) {
            continue;
        }
        if (std::find(excludePorts.begin(), excludePorts.end(), port) != excludePorts.end()) {
            continue;
        }
        filtered.push_back(port);
    }
    std::sort(filtered.begin(), filtered.end());
    filtered.erase(std::unique(filtered.begin(), filtered.end()), filtered.end());
    return filtered;
}

std::vector<int> ScanLoopbackPorts(int startPort, int endPort, const std::vector<int> &excludePorts)
{
    std::vector<int> openPorts;
    if (startPort < 1) {
        startPort = 1;
    }
    if (endPort > 65535) {
        endPort = 65535;
    }
    if (startPort > endPort) {
        return openPorts;
    }

    constexpr size_t kBatchSize = 64;
    struct PendingSock {
        int fd = -1;
        int port = 0;
    };

    std::vector<PendingSock> pending;
    std::vector<struct pollfd> pfds;
    pending.reserve(kBatchSize);
    pfds.reserve(kBatchSize);

    auto flushBatch = [&]() {
        if (pending.empty()) {
            return;
        }
        pfds.clear();
        for (const auto &item : pending) {
            struct pollfd pfd = {};
            pfd.fd = item.fd;
            pfd.events = POLLOUT;
            pfds.push_back(pfd);
        }
        int ready = poll(pfds.data(), static_cast<nfds_t>(pfds.size()), 30);
        if (ready > 0) {
            for (size_t i = 0; i < pfds.size(); i++) {
                if (pfds[i].revents & (POLLOUT | POLLERR | POLLHUP)) {
                    int soErr = -1;
                    socklen_t len = sizeof(soErr);
                    if (getsockopt(pending[i].fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 && soErr == 0) {
                        openPorts.push_back(pending[i].port);
                    }
                }
            }
        }
        for (const auto &item : pending) {
            close(item.fd);
        }
        pending.clear();
    };

    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    for (int port = startPort; port <= endPort; port++) {
        if (std::find(excludePorts.begin(), excludePorts.end(), port) != excludePorts.end()) {
            continue;
        }
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            flushBatch();
            fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) {
                continue;
            }
        }
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        }
        addr.sin_port = htons(static_cast<uint16_t>(port));
        int rc = connect(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr));
        if (rc == 0) {
            openPorts.push_back(port);
            close(fd);
            continue;
        }
        if (errno == EINPROGRESS) {
            pending.push_back({ fd, port });
            if (pending.size() >= kBatchSize) {
                flushBatch();
            }
        } else {
            close(fd);
        }
    }
    flushBatch();

    std::sort(openPorts.begin(), openPorts.end());
    openPorts.erase(std::unique(openPorts.begin(), openPorts.end()), openPorts.end());
    return openPorts;
}

std::vector<int> ListPrioritizedListeningPorts(const std::vector<int> &excludePorts)
{
    std::vector<int> shellPorts;
    std::vector<int> otherPorts;
    CollectPrioritizedPortsFromProc("/proc/net/tcp", shellPorts, otherPorts);
    CollectPrioritizedPortsFromProc("/proc/net/tcp6", shellPorts, otherPorts);

    std::vector<int> filteredShell = FilterCandidatePorts(shellPorts, excludePorts);
    std::vector<int> otherExcludes = excludePorts;
    otherExcludes.insert(otherExcludes.end(), filteredShell.begin(), filteredShell.end());
    std::vector<int> filteredOther = FilterCandidatePorts(otherPorts, otherExcludes);

    std::vector<int> result;
    result.reserve(filteredShell.size() + filteredOther.size());
    result.insert(result.end(), filteredShell.begin(), filteredShell.end());
    result.insert(result.end(), filteredOther.begin(), filteredOther.end());

    if (!result.empty()) {
        return result;
    }

    // Commercial HarmonyOS NEXT blocks /proc/net/tcp inside the app sandbox (SELinux).
    // Fall back to a fast non-blocking loopback TCP scan over default + ephemeral hdcd ports.
    std::vector<int> wellKnown = ScanLoopbackPorts(8710, 8710, excludePorts);
    std::vector<int> altDefault = ScanLoopbackPorts(5555, 5555, excludePorts);
    std::vector<int> ephemeral = ScanLoopbackPorts(30000, 65535, excludePorts);

    result.reserve(wellKnown.size() + altDefault.size() + ephemeral.size());
    result.insert(result.end(), wellKnown.begin(), wellKnown.end());
    result.insert(result.end(), altDefault.begin(), altDefault.end());
    result.insert(result.end(), ephemeral.begin(), ephemeral.end());
    return result;
}

std::vector<int> ListListeningPorts()
{
    std::vector<int> ports;
    CollectPortsFromProc("/proc/net/tcp", ports);
    CollectPortsFromProc("/proc/net/tcp6", ports);
    std::sort(ports.begin(), ports.end());
    ports.erase(std::unique(ports.begin(), ports.end()), ports.end());
    return ports;
}

}  // namespace swshell
