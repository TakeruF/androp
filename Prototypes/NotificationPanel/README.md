# Notification UI preview

Standalone, interactive macOS prototype for adoption review. Excluded from the
normal anDrop build; all device names, files and transfer progress are fictional.
It does not run the sharing engine, request notification permission, modify app
preferences, open files or interact with Finder.

```sh
python3 Prototypes/NotificationPanel/preview.py
# Optional: start in English
python3 Prototypes/NotificationPanel/preview.py --english
# Optional: keep the corner close control visible to inspect its placement
python3 Prototypes/NotificationPanel/preview.py --show-close
```

Two 356 × 96 pt cards appear at the upper right of the current screen: a receive
request and a completed transfer. Their avatar uses the bundled OPPO logo with a
phone or tablet badge. The device-kind selector updates both cards. Accept
simulates two seconds of progress, then shows completion. Completed cards close
automatically after 15 seconds. Hover the upper-left corner for the close button,
or swipe right with two fingers on a trackpad. The card follows the gesture;
releasing before 35% of its width returns it to place, while a longer swipe
slides it away. Decline/cancel
stops the simulation. Open and Show in Finder report their clicks in the control
window. Use the language selector and replay button to compare states. The
close control is anchored to the card's actual upper-left corner and appears
only while the pointer is in that corner.
Close the control window or use Quit to exit.

Uses one clipped `NSVisualEffectView` material surface. The earlier
`NSGlassEffectView` with a window shadow sometimes left a jagged lower-left
corner when the card was composited over another app; the material and border
now share one rounded mask.
The preview follows system appearance and uses an iPad symbol with anDrop's icon
badge rather than a personal avatar. It uses independent floating panels, not
Notification Center; Focus behavior, display scheduling, queuing and real transfer
actions are not integrated. Keep normal system notifications until adoption and
those behaviors are deliberately implemented.

Build output: `build/NotificationPreview.app` (ignored by Git).
