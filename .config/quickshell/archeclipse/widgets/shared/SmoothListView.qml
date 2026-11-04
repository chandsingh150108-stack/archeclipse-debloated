import QtQuick

// Shared ListView with wheel momentum via the native flick engine (same API plus trackScale).
// Never wrap a ListView in a SmoothFlickable, and never swap it for a Flickable+Repeater.
ListView {
    id: root

    // Momentum tuning: callers can override.
    clip: true
    flickDeceleration: 1000
    maximumFlickVelocity: 2500

    // Finger-tracking gain: pixels of content per wheel unit.
    property real trackScale: 1.0

    SmoothWheelHandler {
        target: root
        trackScale: root.trackScale
    }
}
