// SPDX-License-Identifier: MIT
// Observe touch events without grabbing devices or cancelling client events.
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstring>
#include <stdexcept>
#include <unordered_set>
#include <vector>

static int socketFd = -1;
static sockaddr_un destination{};
static std::vector<CHyprSignalListener> listeners;
static std::unordered_set<int> contacts;
static void sendEvent(const char* kind, int id, double x = 0, double y = 0) {
    if (g_pSessionLockManager->isSessionLocked()) return;
    auto data = std::format("{{\"kind\":\"{}\",\"id\":{},\"x\":{},\"y\":{}}}", kind, id, x, y);
    sendto(socketFd, data.data(), data.size(), MSG_DONTWAIT | MSG_NOSIGNAL,
           reinterpret_cast<sockaddr*>(&destination), sizeof(destination));
}
APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }
APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE) {
    if (std::strcmp(__hyprland_api_get_hash(), __hyprland_api_get_client_hash()) != 0)
        throw std::runtime_error("Surface touch observer must be rebuilt for this Hyprland version");
    const char* runtime = std::getenv("XDG_RUNTIME_DIR");
    if (!runtime) throw std::runtime_error("Missing XDG_RUNTIME_DIR");
    auto path = std::string(runtime) + "/surface11-touch-events.sock";
    if (path.size() >= sizeof(destination.sun_path)) throw std::runtime_error("Runtime path too long");
    destination.sun_family = AF_UNIX;
    std::strcpy(destination.sun_path, path.c_str());
    socketFd = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (socketFd < 0) throw std::runtime_error("Cannot create touch observer socket");
    auto& touch = Event::bus()->m_events.input.touch;
    listeners.push_back(touch.down.listen([](ITouch::SDownEvent e, Event::SCallbackInfo&) {
        if (!e.device || e.device->m_boundOutput != "eDP-1") return;
        contacts.insert(e.touchID);
        sendEvent("down", e.touchID, e.pos.x, e.pos.y);
    }));
    listeners.push_back(touch.motion.listen([](ITouch::SMotionEvent e, Event::SCallbackInfo&) {
        if (contacts.contains(e.touchID)) sendEvent("move", e.touchID, e.pos.x, e.pos.y);
    }));
    listeners.push_back(touch.up.listen([](ITouch::SUpEvent e, Event::SCallbackInfo&) {
        if (contacts.erase(e.touchID)) sendEvent("up", e.touchID);
    }));
    listeners.push_back(touch.cancel.listen([](ITouch::SCancelEvent e, Event::SCallbackInfo&) {
        if (contacts.erase(e.touchID)) sendEvent("cancel", e.touchID);
    }));
    return {"surface-touch", "Non-consuming Surface touch feedback and gesture observer", "Linux-dots", "1.0"};
}
APICALL EXPORT void PLUGIN_EXIT() {
    listeners.clear(); contacts.clear();
    if (socketFd >= 0) close(socketFd);
    socketFd = -1;
}
