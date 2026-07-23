import 'package:flutter/material.dart';

/// Shows a bottom-anchored panel WITHOUT pushing a Navigator route.
///
/// showModalBottomSheet / showDialog both push a route, and pushing a
/// route hands focus to it. Nothing inside typically wants focus, so
/// whatever TextField you were using loses it — and losing focus is
/// exactly what tells Android's IME to tear itself down. On a low-RAM
/// phone that teardown, and the rebuild when focus comes back, is a
/// real repeated cost, not just a flicker.
///
/// This uses Overlay.insert() instead, which paints above everything
/// without touching the FocusScope, so the keyboard never has to
/// close for a menu, a profile card, or a reaction picker. It docks
/// right above wherever the keyboard currently is (or the screen
/// bottom if it's closed) — not lower, because Android routes taps in
/// the area the keyboard is covering TO the keyboard, not your app,
/// so anything drawn under it would be dead space.
///
/// Import this from any screen to get the same behavior. Only one
/// docked sheet is ever open app-wide (same rule showModalBottomSheet
/// follows), so a single static reference is enough — no per-screen
/// state needed.
class DockedSheet {
  DockedSheet._();

  static OverlayEntry? _entry;

  static bool get isShowing => _entry != null;

  static void show(
    BuildContext context, {
    required Widget Function(BuildContext context, VoidCallback dismiss)
        builder,
    bool barrierDismissible = true,
  }) {
    dismiss();

    late final OverlayEntry entry;
    void close() {
      if (_entry == entry) {
        entry.remove();
        _entry = null;
      }
    }

    entry = OverlayEntry(
      builder: (overlayContext) {
        // 🔥 Read fresh every rebuild — this MediaQuery sits above any
        // individual Scaffold's resizeToAvoidBottomInset, so it always
        // reflects the real, current keyboard height.
        final bottomInset = MediaQuery.viewInsetsOf(overlayContext).bottom;
        return Stack(
          children: [
            if (barrierDismissible)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: close,
                  child: Container(color: Colors.black54),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomInset,
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                tween: Tween<double>(begin: 1, end: 0),
                builder: (context, t, child) => Transform.translate(
                  offset: Offset(0, t * 40),
                  child: Opacity(opacity: 1 - t, child: child),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: SafeArea(
                    top: false,
                    bottom: bottomInset == 0,
                    child: builder(overlayContext, close),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    _entry = entry;
    Overlay.of(context).insert(entry);
  }

  static void dismiss() {
    _entry?.remove();
    _entry = null;
  }
}
