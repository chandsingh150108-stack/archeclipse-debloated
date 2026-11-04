import QtQuick

// Shared wheel-momentum physics for all smooth scrollers: attach to any Flickable-derived type
// (`SmoothWheelHandler { target: root }`).
//
// Gesture model: wheel events move content DIRECTLY (1:1 finger tracking) while a trailing
// ~120ms velocity window feeds exactly ONE flick() at gesture end — the native engine's
// deceleration then does the gliding. Never flick() per event: each call restarts the glide
// curve, which reads as a staircase, and the decay eats the velocity through the gesture's
// slow tail so nothing is left to coast with.
//
// Gesture end is detected by BOTH the zero-delta scroll-end event AND a silence timer,
// because Wayland does not guarantee the former. Double-firing is prevented by _gesture.
WheelHandler {
    id: root

    required property Flickable target
    // Pixels of content per wheel unit (angleDelta/2 or pixelDelta unit).
    property real trackScale: 1.0
    // Fling tuning: trailing window for launch velocity, floor on the window so a lone
    // mouse-wheel notch still glides, minimum launch speed, silence that ends a gesture.
    property int velocityWindowMs: 120
    property int minWindowMs: 80
    property real minFlingVelocity: 150
    property int endSilenceMs: 110
    property bool debug: false

    property var _samples: []
    property bool _gesture: false

    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

    // WheelHandler takes no child objects (it is not an Item), so the silence
    // timer is created imperatively and parented to the target instead.
    property var _endTimer: null
    function armEndTimer() {
        if (!root._endTimer) {
            if (!root.target)
                return;
            root._endTimer = Qt.createQmlObject("import QtQuick; Timer { interval: " + root.endSilenceMs + "; repeat: false }", root.target);
            root._endTimer.triggered.connect(() => root.endGesture("silence"));
        }
        root._endTimer.restart();
    }

    function log(msg) {
        if (root.debug)
            console.log("[SmoothWheel] " + msg);
    }

    function endGesture(reason) {
        if (root._endTimer)
            root._endTimer.stop();
        if (!root._gesture)
            return;
        root._gesture = false;
        const now = Date.now();
        while (root._samples.length > 0 && now - root._samples[0].t > root.velocityWindowMs)
            root._samples.shift();
        let sx = 0, sy = 0;
        for (const s of root._samples) {
            sx += s.dx;
            sy += s.dy;
        }
        const first = root._samples.length > 0 ? root._samples[0].t : now;
        const dt = Math.max(root.minWindowMs, now - first);
        const maxV = root.target.maximumFlickVelocity;
        const vx = Math.max(-maxV, Math.min(maxV, sx / dt * 1000));
        const vy = Math.max(-maxV, Math.min(maxV, sy / dt * 1000));
        root._samples = [];
        if (Math.abs(vx) < root.minFlingVelocity && Math.abs(vy) < root.minFlingVelocity) {
            root.log("end (" + reason + "): below fling floor, holding position");
            return;
        }
        root.log("end (" + reason + "): flick(" + Math.round(vx) + ", " + Math.round(vy) + ")");
        root.target.flick(vx, vy);
    }

    onWheel: event => {
        // Nested scrollers: when this target has nothing to scroll (or is at the edge), do NOT
        // accept — always accepting traps the wheel and the outer panel feels stuck.
        const dy0 = (event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 2);
        const dx0 = (event.pixelDelta.x !== 0 ? event.pixelDelta.x : event.angleDelta.x / 2);
        const dir = target.flickableDirection;
        const horizontalOnly = (dir === Flickable.HorizontalFlick);
        const verticalOnly = (dir === Flickable.VerticalFlick);
        // Effective scroll deltas after the axis remap applied below.
        let edy = verticalOnly && !horizontalOnly ? dy0 + dx0 : dy0;
        let edx = horizontalOnly && !verticalOnly ? dx0 + dy0 : dx0;
        const maxY = Math.max(0, target.contentHeight - target.height);
        const maxX = Math.max(0, target.contentWidth - target.width);
        const canUp = target.contentY > 0;
        const canDown = target.contentY < maxY;
        const canLeft = target.contentX > 0;
        const canRight = target.contentX < maxX;
        const wantsV = (edy > 0 && canUp) || (edy < 0 && canDown);
        const wantsH = (edx > 0 && canLeft) || (edx < 0 && canRight);
        const canScrollV = !(verticalOnly && !horizontalOnly) || maxY > 0;
        const canScrollH = !(horizontalOnly && !verticalOnly) || maxX > 0;
        const handlesV = verticalOnly && !horizontalOnly ? (maxY > 0 && wantsV) : (canScrollV && wantsV);
        const handlesH = horizontalOnly && !verticalOnly ? (maxX > 0 && wantsH) : (canScrollH && wantsH);
        if ((!handlesV && !handlesH) || !target.interactive) {
            event.accepted = false;
            return;
        }
        // Per axis take the channel carrying more — hi-res devices report both.
        const ax = event.angleDelta.x / 2;
        const ay = event.angleDelta.y / 2;
        let dx = Math.abs(event.pixelDelta.x) >= Math.abs(ax) ? event.pixelDelta.x : ax;
        let dy = Math.abs(event.pixelDelta.y) >= Math.abs(ay) ? event.pixelDelta.y : ay;
        // Horizontal-only targets never see vertical wheel deltas, so route the orthogonal axis
        // into the scrollable one (and back for vertical-only); other directions keep both.
        if (horizontalOnly && !verticalOnly) {
            dx = dx + dy;
            dy = 0;
        } else if (verticalOnly && !horizontalOnly) {
            dy = dy + dx;
            dx = 0;
        }
        if (dx === 0 && dy === 0) {
            // Scroll-end marker: coast on the trailing velocity.
            root.endGesture("zero-event");
            event.accepted = true;
            return;
        }
        if (!root._gesture) {
            // New gesture: a re-grab mid-glide cuts the old glide first.
            root._gesture = true;
            root.target.cancelFlick();
        }
        const now = Date.now();
        root._samples.push({ t: now, dx: dx, dy: dy });
        while (root._samples.length > 0 && now - root._samples[0].t > root.velocityWindowMs)
            root._samples.shift();
        // Vertical polarity: wheel-up deltas are positive and move content
        // down (contentY decreases) — same mapping the old per-event flick used.
        root.target.contentX -= dx * root.trackScale;
        root.target.contentY -= dy * root.trackScale;
        root.armEndTimer();
        event.accepted = true;
    }
}
