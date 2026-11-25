/*
 * Finding the device's hdc daemon without being told the port.
 *
 * The daemon listens for LAN discovery on UDP 8710 and answers any datagram
 * it receives with "<banner>-<tcp port>" (developtools_hdc/src/daemon/
 * daemon_tcp.cpp, HdcDaemonTCP::TransmitConfig).  That is exactly what the
 * `hdc target discover` command uses, and it is how a client on another
 * machine finds the daemon.
 *
 * On the device itself the reply is unicast back to the source address on
 * port 8710, so the app has to be listening on 8710 as well.  The daemon
 * binds 0.0.0.0:8710 with SO_REUSEADDR; binding the same wildcard address
 * with SO_REUSEADDR is allowed, and a unicast datagram is delivered to the
 * most recently bound socket - which is the app's, because the app binds at
 * runtime and the daemon started earlier.
 *
 * If that does not work - for instance because the daemon restarted after
 * the app bound its socket - the caller falls back to the user entering the
 * port from Developer Options.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_DISCOVERY_H
#define SW_SHELL_DISCOVERY_H

#include <cstddef>
#include <istream>
#include <string>
#include <vector>

namespace swshell {

/**
 * Parses "<banner>-<port>" from a UDP discovery reply and returns the TCP port,
 * or 0 when the datagram is invalid or is our own broadcast echo.
 */
int ParseDaemonPort(const char *data, size_t length);

/**
 * Parses listening TCP ports (state "0A", wildcard or loopback address) from
 * a `/proc/net/tcp` or `/proc/net/tcp6` formatted stream.
 */
void CollectPortsFromProcStream(std::istream &stream, std::vector<int> &ports);

/**
 * Parses listening TCP ports and splits them into `uid == 2000` (shell/hdcd)
 * ports vs other listening ports so `hdcd` is always probed first.
 */
void CollectPrioritizedPortsFromProcStream(std::istream &stream,
                                           std::vector<int> &shellPorts,
                                           std::vector<int> &otherPorts);

/**
 * Filters invalid and excluded ports (such as the app's own local servers)
 * and returns a sorted, deduplicated candidate port list.
 */
std::vector<int> FilterCandidatePorts(const std::vector<int> &ports, const std::vector<int> &excludePorts);

/**
 * Returns listening TCP ports with `uid == 2000` (shell/hdcd) sockets placed
 * first, excluding `excludePorts`.  Falls back to a fast non-blocking loopback
 * TCP scan when `/proc/net/tcp` is unreadable inside the HarmonyOS app sandbox.
 */
std::vector<int> ListPrioritizedListeningPorts(const std::vector<int> &excludePorts);

/**
 * Fast non-blocking loopback (`127.0.0.1`) TCP port scanner for `[startPort, endPort]`.
 * Works inside sandboxed HarmonyOS apps where `/proc/net/tcp` is denied by SELinux.
 */
std::vector<int> ScanLoopbackPorts(int startPort, int endPort, const std::vector<int> &excludePorts);

/**
 * Broadcasts the discovery datagram and waits for the daemon's answer.
 *
 * Returns the TCP port the daemon is listening on, or 0 on failure, with
 * `error` describing what went wrong.
 */
int DiscoverDaemonPort(int timeoutMs, std::string &error);

/**
 * The TCP ports this device is listening on, read from /proc/net/tcp.
 *
 * The hdc daemon is assigned a random port when wireless debugging is
 * switched on, and an app cannot read persist.hdc.port, so the port has to
 * be found some other way.  The list is small - a phone listens on a
 * handful of ports - and the caller can try them one by one.
 *
 * Only sockets bound to the wildcard address or to the loopback address are
 * returned; a daemon that listens on a specific interface is not reachable
 * from inside the app anyway.
 */
std::vector<int> ListListeningPorts();

}  // namespace swshell

#endif /* SW_SHELL_DISCOVERY_H */
