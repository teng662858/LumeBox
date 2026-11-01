# AetherEngine

LumeBox links the unmodified AetherEngine 7.53.1 Swift package (commit 0839aeee18dd0818c5c307a3c5ecba8ea3161b22).

Copyright (C) 2026 Vincent Herbst. LGPL-3.0 with upstream Apple Store / DRM Exception. Complete upstream license is copied into the application resources as `AetherEngine-LICENSE.txt`.

Corresponding source and build instructions: https://github.com/superuser404notfound/AetherEngine/tree/7.53.1 . Dependency revisions are resolved by SwiftPM during the iOS build. Preserve the generated Package.resolved and dependency notices with release records.

The engine includes dependencies built from FFmpeg, dav1d, libdovi and other components. Their source, build recipes and licenses are available from https://github.com/superuser404notfound/FFmpegBuild and https://github.com/superuser404notfound/LibDovi . Optional TrueHDObjectAudio, DTSXObjectAudio, DualLayerDolbyVision and DolbyVisionStillReshaping traits are not enabled by LumeBox.
