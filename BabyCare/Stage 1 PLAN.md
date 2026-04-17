## Stage 0/1 Concrete Plan: Local-First DAT Pipeline for Baby Activity Logging

### Summary
Build a local-first iOS architecture that uses Ray-Ban Meta DAT SDK sessions for capture, sends selected media directly from app to a cloud multimodal model, normalizes results into 5 activity labels, stores logs locally, and renders an editable timeline.  
Stage 0 proves end-to-end feasibility and physical-button behavior. Stage 1 productizes the minimal reliable flow.

### Locked Decisions
1. DAT SDK-first integration (from `/Users/peiqitang/Documents/GitHub/BabyTracker/PoL/SDK docs.md`).
2. Event-driven capture strategy (not continuous always-on stream).
3. Client-direct cloud inference (no custom backend in Stage 0/1).
4. Local-first persistence for activity logs and media metadata.
5. Auto-save inferred events, allow user edits/deletes later.

### Validated Device Interaction Facts (2026-02-12)
1. Before streaming starts, physical button and touch pad interactions map to Meta AI app settings, not this app.
2. Start streaming must be triggered by an in-app UI button.
3. After streaming starts, single tap on temple touch pad pauses/resumes streaming.
4. Swiping on the touch pad changes audio volume.
5. After streaming starts, pressing the physical capture button does not trigger capture for this app integration.

### Stage 1 Interaction Flow Requirements (Updated)
1. Rename the current `DAT Debug` screen to `Settings`.
2. Keep `Start Streaming` in `Settings`.
3. After user starts streaming, show guidance text: `Tap once on the glasses touch pad to get ready.`
4. Add bottom tab navigation: `Settings` and `Activities`.
5. User switches to `Activities` tab during daily baby care.
6. User single-taps touch pad to resume streaming when an activity starts.
7. User single-taps touch pad again to pause when activity ends.
8. While app is on `Activities`, each pause event triggers segment extraction from last resume to last pause.
9. App sends that extracted video+audio segment to inference.
10. App maps inference result to activity label and logs event in timeline.

### Architecture Foundation (End-to-End)
1. `WearablesSessionLayer`
- Owns DAT registration, permission, device discovery, and session lifecycle (`RUNNING/PAUSED/STOPPED`).
- Exposes session status to UI and pipeline.

2. `CaptureLayer`
- Handles capture actions and incoming media units.
- Initial supported unit types: `photo`, `shortVideo`, `audioSnippet`.
- Emits normalized `CaptureEnvelope` objects to inference queue.

3. `InferenceLayer`
- Sends `CaptureEnvelope` to selected multimodal model API directly from iOS.
- Uses strict JSON schema output contract to reduce parsing drift.
- Applies label mapping and confidence thresholding.

4. `ActivityDomainLayer`
- Maps model output to canonical labels:
  - `diaperWet`
  - `diaperBowel`
  - `feeding`
  - `sleepStart`
  - `wakeUp`
  - `other`
- Produces `ActivityEvent` with confidence and review flags.

5. `LocalDataLayer`
- Stores events in local database.
- Stores media references and thumbnails locally.
- Supports edit/relabel/delete with audit flags.

6. `Timeline/UI Layer`
- Displays all events including `other`.
- Supports quick edit/delete/relabel.
- Shows confidence + `needsReview`.

### Public Interfaces / Types to Add
1. `enum ActivityLabel { diaperWet, diaperBowel, feeding, sleepStart, wakeUp, other }`
2. `enum CaptureType { photo, shortVideo, audioSnippet }`
3. `struct CaptureEnvelope { id, captureType, capturedAt, deviceId, localMediaURL, metadata }`
4. `struct InferenceResult { label, confidence, rationaleShort, modelVersion }`
5. `struct ActivityEvent { id, label, timestamp, sourceCaptureId, confidence, needsReview, isUserCorrected, isDeleted }`
6. `protocol CaptureProvider { startSession(); stopSession(); capturePhoto(); startClip(); stopClip(); startAudio(); stopAudio() }`
7. `protocol InferenceClient { infer(from capture: CaptureEnvelope) async throws -> InferenceResult }`
8. `protocol ActivityStore { saveEvent(); fetchTimeline(); updateEvent(); softDeleteEvent() }`

### Physical Capture Button Feasibility (Resolved)
1. Feasibility probe completed on real device with event logs.
2. No dedicated app callback observed for physical capture button press.
3. Temple touch-pad tap is usable as session pause/resume signal after stream starts.
4. Integration decision: use app-triggered stream start + touch-pad pause/resume driven capture windows; do not depend on physical capture button.

### Stage 0 Deliverables (Feasibility + Contracts)
1. DAT integration skeleton in app with registration/permission/session lifecycle visible in debug UI.
2. Capture pipeline contract objects (`CaptureEnvelope`, `InferenceResult`, `ActivityEvent`) compiled and unit-tested.
3. One working inference call path (photo first) with schema-constrained response parsing.
4. Local persistence of inferred events and timeline rendering.
5. Physical-button feasibility report from test matrix with go/no-go decision.

### Stage 1 Deliverables (MVP Reliability)
1. Implement `Settings` screen rename and interaction guidance text under `Start Streaming`.
2. Add `Settings` and `Activities` tab navigation and move timeline-first workflow to `Activities`.
3. Implement segment capture boundaries from session state transitions:
- Start segment on resume (`paused -> streaming`).
- End segment on pause (`streaming -> paused`).
- Trigger inference on each ended segment while app is on `Activities`.
4. Implement video+audio segment packaging from last resume to last pause and ingestion path to inference.
5. Auto-inference queue with retry/backoff and failure status.
6. Confidence policy:
- Save all inferred events.
- `needsReview = true` below threshold.
7. Full timeline editing:
- Relabel any event (including `other`).
- Delete/restore behavior.
8. Basic analytics/debug screen:
- capture success rate
- inference success/failure counts
- average processing latency

### Testing and Scenarios
1. Unit tests
- Label mapping into 6-label taxonomy.
- Confidence threshold behavior.
- `other` persistence/edit/delete paths.
- Local store CRUD and timeline ordering.

2. Integration tests
- DAT session state transitions handled correctly.
- Segment (`resume -> pause`) capture -> inference -> event save round trip.
- Retry logic on model call timeout/network failure.

3. Manual real-device tests
- Registration and permission flow through Meta AI app callback.
- Event-driven `resume -> pause` segment capture from touch-pad gestures.
- Physical button matrix validation.
- Timeline edit/relabel/delete correctness.

### Acceptance Criteria
1. Real-device flow works: capture -> infer -> save -> display in timeline.
2. All target labels can be produced and stored, including `other`.
3. User can edit or delete any saved event.
4. App remains functional when inference fails (event marked failed/pending, no crash).
5. Physical-button capability is explicitly documented with observed behavior and chosen integration strategy.

### Assumptions and Defaults
1. No custom backend in Stage 0/1; model is called directly from iOS app.
2. Activity history remains local-first in app storage.
3. Event-driven capture is default to control battery/cost.
4. DAT SDK docs in `/Users/peiqitang/Documents/GitHub/BabyTracker/PoL/SDK docs.md` are source of truth for current integration surface.
5. If physical capture button is not directly exposable as an app callback, app-triggered capture remains canonical and architecture stays unchanged.
6. Pause/resume transition signals from DAT are treated as capture boundaries for segment extraction.
