## Title
Baby Activity Tracker (Ray-Ban Meta Gen 2 + iPhone): Finalized Plan v3 (Persist `other`)

## Summary
build a baby activity tracker similar to Huckleberry(https://huckleberrycare.com/) that allows parents to easliy take photos, videos or audio on the Ray-Ban Meta Glasses, then pass them to an AI model to understand the data and label them into 5 activities:
- Changing diaper (wet or bowel movement)
- Feeding baby
- Baby asleep
- Baby wakes up
- Other

This is a local-first iOS architecture that uses Ray-Ban Meta DAT SDK sessions for capture, sends selected media directly from app to a cloud multimodal model, normalizes results into 5 activity labels, stores logs locally, and renders an editable timeline.

## Validated Device Interaction Facts (2026-02-12)
- Before streaming starts, physical button and touch pad interactions are handled by Meta AI app settings, not by this app.
- Starting streaming must be triggered by an in-app UI button.
- After streaming starts, single tap on the temple touch pad pauses/resumes streaming.
- Swiping on the touch pad changes audio volume.
- After streaming starts, pressing the physical capture button has no effect for this app integration.

## Interaction Flow Requirements (Updated)
- Rename `DAT Debug` screen to `Settings`.
- Keep `Start Streaming` button in `Settings`.
- After `Start Streaming`, show helper text: `Tap once on the glasses touch pad to get ready.`
- Add bottom navigation with two tabs: `Settings` and `Activities`.
- User moves to `Activities` tab during childcare flow.
- In `Activities`, user single-taps temple touch pad to resume streaming when activity starts.
- User single-taps again to pause when activity ends.
- When app is on `Activities` tab and a pause is detected, app sends the segment from last resume to last pause (video + audio) to inference.
- AI returns activity label.
- App logs inferred activity event to timeline.

## Key Change From v2
- Previous rule: discard `other`.
- New rule: save `other` as first-class timeline event with badge + edit/delete actions.

## Stage 1 Decision Logic (Updated)
- Trigger: automatic classification on ingest.
- Video: upload full short clip.
- If label is tracked (`diaper_wet`, `diaper_bowel`, `feeding`, `sleep_start`, `wake_up`):
  - Save event immediately.
  - Flag `needsReview` when confidence is below threshold.
- If label is `other`:
  - Save event immediately as `other`.
  - Show inline in timeline with `Other` badge.
  - Allow user edit to a tracked label or delete entirely.

## Interfaces / Types (Updated)
- `enum ActivityLabel { diaperWet, diaperBowel, feeding, sleepStart, wakeUp, other }`
- `struct ActivityEvent { id, label, timestamp, snapshotURL?, sourceCaptureId, confidence, needsReview, isUserCorrected, isDeleted }`

## UI Flows (Updated)
- `Timeline`:
  - Shows all labels including `other`.
  - `other` rows include badge and quick actions:
    - `Re-label`
    - `Delete`
- `Capture`:
  - `other` items show status `saved_other` instead of discarded.

## Test Cases (Updated)
- Unit:
  - `other` persistence and retrieval.
  - re-label `other` -> tracked label.
  - delete `other` event behavior.
- Manual E2E:
  - Create at least one `other` event and verify it appears in timeline.
  - Re-label one `other` to tracked activity and verify update.
  - Delete one `other` and verify it no longer appears.

## Acceptance Criteria (Updated)
- Real-device E2E works from capture -> classification -> persistence.
- All 4 tracked activities can be logged from real captures.
- `other` events are persisted, visible inline, editable, and deletable.
- Saved events include timestamp and preview/snapshot (or defined placeholder).
- Low-confidence events are flagged for review.

## Assumptions / Defaults
- DAT exact API calls still placeholder-wrapped until docs are accessible in this environment.
- Gemini free tier used for Stage 1 prototype.
- API key in debug client config for Stage 1 only.
