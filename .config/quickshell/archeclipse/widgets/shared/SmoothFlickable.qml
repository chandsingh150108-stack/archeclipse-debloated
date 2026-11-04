import QtQuick

// Shared Flickable with wheel momentum through the native flick engine: the wheel tracks
// content directly and one flick() at gesture end does the gliding. Physics: SmoothWheelHandler.
Flickable {
    id: root

    // Momentum tuning: callers can override (e.g. BooruGrid pins
    // maximumFlickVelocity lower for a slower feel).
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
