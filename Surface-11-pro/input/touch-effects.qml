import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root
    property var rings: ({})
    function updateTouch(data) {
        const key = String(data.id);
        let ring = rings[key];
        if (data.kind === "down") {
            if (ring) ring.destroy();
            ring = ringComponent.createObject(panel.contentItem, { nx: data.x, ny: data.y });
            rings[key] = ring;
        } else if (data.kind === "move" && ring) {
            ring.nx = data.x;
            ring.ny = data.y;
        } else if (ring) {
            delete rings[key];
            ring.release();
        }
    }
    Process {
        running: true
        command: ["python3", Quickshell.shellDir + "/touch-effects.py"]
        stdout: SplitParser {
            onRead: data => {
                try { root.updateTouch(JSON.parse(data)); }
                catch (error) { console.warn("Touch feedback:", error); }
            }
        }
    }
    PanelWindow {
        id: panel
        screen: Quickshell.screens.find(s => s.name === "eDP-1") ?? null
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        focusable: false
        mask: Region {} // Empty input region: all taps reach the underlying app.
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "surface11-touch-feedback"
    }
    Component {
        id: ringComponent
        Rectangle {
            id: ring
            property real nx: 0
            property real ny: 0
            x: nx * panel.width - width / 2
            y: ny * panel.height - height / 2
            width: 20; height: 20; radius: 10
            color: "transparent"
            border { color: "#a7b9c9"; width: 1 }
            opacity: 0.28
            function release() { fade.start(); }
            ParallelAnimation {
                id: fade
                NumberAnimation { target: ring; property: "opacity"; to: 0; duration: 140 }
                NumberAnimation { target: ring; property: "scale"; to: 1.15; duration: 140 }
                onFinished: ring.destroy()
            }
        }
    }
}
