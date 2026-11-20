# V2 on-device validation

Validated on November 20, 2026 with a universal macOS build and all 45 production PNG assets. Recording used a 1920 × 1080 primary display; the shared video crops unrelated desktop content.

| Area | Observed result |
| --- | --- |
| Flower wish | Bridged two real windows, moved a supporting window during crossing, observed hanging, falling, landing, ladder climbing, planting, growth, bloom, and a fruit return gift. Wish completed. |
| Chair wish | Unlocked a chair, placed it on a window ledge, observed sitting, moved it, returned it to the toolbox, and placed it again. |
| Lamp wish | Unlocked and placed a lamp at night, observed sleeping and wish completion, then waking when switched to day. |
| Visit wish | A flag marked a non-home target window. A bridge enabled arrival and wish completion. Moved, minimized, and restored the target window. |
| Chase wish | Observed both caught and escaped completion outcomes. Moving a window broke the route in the escape scenario. |
| Autonomous activity | Observed wandering, ladder use, and neighbor visits. |
| Diaries | Generated separate event-based template diaries for both residents. |
| Persistence | Quit through the app menu and reopened it. All 17 object IDs, both resident IDs, and the chair/lamp unlock set matched the saved state. Furniture restores to the floor by design. |

## Method and scope

This was a segmented desktop demonstration. Existing debug menus reset the world between scenarios, triggered wishes, switched day/night, and advanced flower growth. No application source or live world data was edited to fabricate results. The full recording is 5 minutes 1 second; the submission edit shortens it and adds English explanations.

AI diaries and resident thoughts remained disabled. No key was entered and no external model was called. This validates the settings interface and template diary path, not AI-generated text.

The original world, event log, and diaries were restored after the demonstration and matched the pre-demo backups by SHA-256. The demo world and raw recordings are retained locally, outside the public repository, to avoid publishing unrelated desktop content and local user data.

This is not a complete release regression. Multi-machine compatibility, fullscreen, sleep/wake, and extended performance were not tested in this run.

## Automated checks

Before preparing the submission, `swift test` passed all **754 tests across 178 suites** on November 20, 2026.
