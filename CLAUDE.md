# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

This repo has two parallel build systems that share most of the same source files:

1. **Swift Package Manager** (`Package.swift`) — builds the two libraries `StandardCyborgFusion` and `scsdk` plus their test targets. Used for the C++/CI test pipeline.
2. **Xcode workspace** (`StandardCyborgSDK.xcodeproj`) — wraps the apps and frameworks together with predefined schemes: `All-iOS-Debug`, `All-iOS-Release`, `All-Mac-Debug`, `All-Mac-Release`, `TrueDepthFusion`, `VisualTesterMac`, `StandardCyborgAlgorithmsTestbed`. Use this for app builds and on-device runs.

`StandardCyborgUI` and `StandardCyborgExample` each have their own standalone `.xcodeproj` and are **not** members of `Package.swift` — they consume `StandardCyborgFusion` as a binary dependency.

### Common commands

```bash
# Run the portable C++ tests (scsdk)
swift test --filter SCSDKTests

# Run the StandardCyborgFusion tests
swift test --filter StandardCyborgFusionTests

# Run a single scsdk test by name (doctest filtering through XCTest runner)
swift test --filter SCSDKTests.SCSDKTests/test_<name>

# Build a scheme from CLI
xcodebuild -project StandardCyborgSDK.xcodeproj -scheme TrueDepthFusion -destination 'generic/platform=iOS'
xcodebuild -project StandardCyborgSDK.xcodeproj -scheme VisualTesterMac -destination 'platform=macOS'

# CMake build of scsdk only (out-of-source, in scsdk/)
cd scsdk && mkdir -p build && cd build && cmake -DCMAKE_BUILD_TYPE=Debug .. && make -j $(sysctl -n hw.logicalcpu) && ./scsdk_test
```

`StandardCyborgFusion` requires an actual iOS device with a TrueDepth camera; the simulator does not work for any scanning code path.

## Architecture

The codebase is layered around a strict portability boundary. Code that is pure C++ lives in **`scsdk/`**; code that depends on Apple frameworks (Metal, AVFoundation, CoreVideo, CoreML, SceneKit, Objective-C runtime) lives in **`StandardCyborgFusion/`**. The same dichotomy is mirrored inside `StandardCyborgFusion`: `Algorithm/` and `IO/` exist precisely because those things cannot live in `scsdk` due to Apple-only dependencies.

### scsdk — portable C++ core (`scsdk/Sources/standard_cyborg/`)

Builds as a dynamic library on iOS/macOS via SPM, and as a plain library via CMake on Mac/Linux. Subdivides into:

- `math` — vector / matrix / linear algebra primitives.
- `sc3d` — geometry classes (`Geometry`, `MeshTopology`, `BoundingBox3`, `DepthImage`, `ColorImage`, `PerspectiveCamera`, `Landmark`, `VertexSelection`, …).
- `scene_graph` — portable scene-tree representation.
- `algorithms` — ICP, plane fitting, KMeans, DBSCAN, mesh slicing/splitting, principal axes, Gaussian/Sobel filtering, etc.
- `io` — PLY, GLTF, JSON, image SERDES, all routed through header-only deps in `CppDependencies/` (Eigen, happly, nlohmann/json, tinygltf, stb, nanoflann, PoissonRecon, SparseICP).

Tests use **doctest** (`scsdk/Tests/scsdk_test`), wrapped behind an XCTest runner (`SCSDKTestRunner.mm`) so they show up under `swift test`. Fixture data lives in `scsdk/Tests/test_fixture_data/` and is copied as a bundle resource.

### StandardCyborgFusion — iOS reconstruction framework

Source root: `StandardCyborgFusion/Sources/StandardCyborgFusion/`. The public ObjC API surface is whatever is exported under `Sources/include/StandardCyborgFusion/` — those are the headers consumers of the SwiftPM library see. `.m` / `.mm` implementations of those public classes live in `Public/`. The `Private/` directory holds private headers that bridge between public ObjC types and internal C++.

Internal subdivisions:

- `MetalDepthProcessor/` — the Metal compute pipeline. Takes raw `CVPixelBuffer` depth + color + camera intrinsics and produces an unprojected, normal- and weight-annotated point cloud. Each kernel comes as a `.metal` shader plus a `.h/.mm` host-side wrapper (e.g. `ComputeNormalsKernel`, `ComputePointsKernel`, `ComputeWeightsKernel`, `SmoothDepthKernel`, `RenderPositions`, `RenderUvs`, `SurfelIndexMap`). `MetalComputeEngine` is the shared command-queue / pipeline-state cache.
- `Algorithm/` — the **PBFusion** reconstruction algorithm itself: `PBFModel`, `SurfelFusion`, `ICP`, `OutlierDetector`, `GravityEstimator`, `MeshUvMap`, `OfflineSurfelLandmarking`. This is what cannot live in `scsdk` because it depends on Metal / Objective-C types.
- `DataStructures/`, `Helpers/`, `IO/` — supporting code (`SCEigen` bridging, BPLY raw-frame format, file-IO helpers, etc.).
- `EarLandmarking/` + `Models/*.mlmodel` — CoreML models for foot bounding-box, ear bounding-box, and ear landmark regression (`SCFootTracking`, `SCEarTracking`, `SCEarLandmarking`).

Two top-level entry points drive reconstruction:

- `SCReconstructionManager` — real-time on-device reconstruction. Consumes frames from `AVCaptureDataOutputSynchronizer` (depth + color + camera intrinsics) and emits a live `SCPointCloud`.
- `SCOfflineReconstructionManager` — replays a pre-recorded sequence of BPLY raw frames (see below). This is the path used by `VisualTesterMac` and is what you want when iterating on the algorithm without a phone in hand.

Output types: `SCPointCloud` (surfels) → `SCMeshingOperation` / `SCMeshTexturing` → `SCMesh`. Both `SCPointCloud` and `SCMesh` have file-IO, geometry, SceneKit, and (for the point cloud) Metal-rendering category extensions.

### StandardCyborgUI — UIKit/Metal scanning UI

Built only via `StandardCyborgUI/StandardCyborgUI.xcodeproj`, not via SPM. Provides `ScanningViewController`, `ScenePreviewViewController`, `DefaultScanningViewRenderer`, `PointCloudCommandEncoder`, haptic feedback, etc. — the visualization layer that drives `SCReconstructionManager` from a UIKit app. `StandardCyborgExample` shows the integration end-to-end.

### Apps in the workspace

- `StandardCyborgExample/` — minimal “scan + show mesh” iOS demo. Open `StandardCyborgExample.xcodeproj` directly; this is the right entry point for new contributors.
- `TrueDepthFusion/` — internal test harness, also iOS. Notable feature: a Settings-bundle toggle “Dump raw frames to Binary PLY” causes the app to capture and zip a sequence of BPLY frames during a scan. Output can be AirDropped to a Mac and replayed in `VisualTesterMac` — this is the trace pipeline used to iterate on PBFusion offline.
- `VisualTesterMac/` — macOS app that loads an unzipped BPLY trace directory and runs `SCOfflineReconstructionManager` against it (“Open Directory…” → “Assimilate All”).
- `StandardCyborgAlgorithmsTestbed/` — iOS playground for individual algorithm test cases (e.g. `TestCase-Hen`).

### File formats

`.ply` is extended with a custom header: `comment StandardCyborgFusionVersion`, `comment StandardCyborgFusionMetadata { … }`, plus a non-standard `element gravity 1` section storing the gravity vector. Per `README_SC_PLY_FORMAT.md`, MeshLab and other readers can clip long comment lines, so changes to the metadata format need to be tested with third-party PLY tooling. `.bply` (binary PLY) is the raw-frame format used by `TrueDepthFusion` and `VisualTesterMac` traces; see `BPLYDepthDataAccumulator` and `Sources/StandardCyborgFusion/IO/`.

## Conventions worth knowing

- Mixed-language: a file with both Apple-framework code and C++ uses `.mm` (ObjC++), pure ObjC uses `.m`, pure C++ uses `.cpp`/`.hpp`. Public headers are always plain `.h` so they remain Swift-importable.
- `StandardCyborgFusion` is compiled with `-Os -fno-math-errno -ffast-math` even in Debug, on purpose — the algorithm is unusable in real time without optimization. Don’t weaken these flags when adding new build settings.
- The header-search path layout in `Package.swift` for the `StandardCyborgFusion` target manually lists each internal subdirectory; new internal directories must be added there or includes will fail to resolve under SPM.
- C++ standard is `cxx17` repo-wide; Swift is in language mode `.v5` even though `swift-tools-version:6.0`.
