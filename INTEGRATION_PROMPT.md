# iOS Share Phase 1 Implementation - Parallel Execution

Launch 3 agents in parallel to implement Phase 1 of the iOS Share integration plan. These are independent features that can be built simultaneously.

## Agent 1: Update SettingsView for SaaS Mode (ios-share-1ht)

**Priority:** P2 | **Effort:** Low (2-3 hours) | **Issue:** ios-share-1ht

Enhance the SettingsView to provide a better UX for SaaS mode vs Self-Hosted mode.

### Context
- The iOS app now has `Config.hostingMode` that detects SaaS vs Self-Hosted
- Backend URL is automatically configured from xcconfig files
- Current SettingsView treats all configurations the same

### Requirements
1. **In SaaS Mode (default):**
   - Show backend URL as read-only text with visual indicator (e.g., "🌐 Production Backend")
   - Add a small label: "Managed by ImageHost" or similar
   - Hide/disable the editable TextField for backend URL
   - Keep upload token field editable
   - Update footer text to reflect SaaS status
   - Add subtle "Advanced" section for users who want to switch to self-hosted

2. **In Self-Hosted Mode:**
   - Keep existing editable TextField for backend URL
   - Show indicator: "🔧 Self-Hosted Configuration"
   - Keep existing validation logic
   - Add "Switch to Managed Backend" option

3. **Visual Design:**
   - Use system colors and SF Symbols
   - Clear visual distinction between modes
   - Professional, polished appearance
   - Maintain existing SwiftUI style

### Implementation Steps
1. Read `frontend/ImageHost/ImageHost/Views/SettingsView.swift`
2. Add mode detection using `Config.hostingMode`
3. Conditionally render UI based on mode
4. Update `loadSettings()` to handle mode appropriately
5. Test in simulator with both modes
6. Commit with message: "Implement SaaS-aware SettingsView UI"

### Success Criteria
- ✅ SaaS mode shows read-only URL with visual indicator
- ✅ Self-hosted mode allows URL editing
- ✅ Mode switching capability exists
- ✅ Builds without errors or warnings
- ✅ Visual design is polished and professional

---

## Agent 2: Create ExportService for iOS App (ios-share-4ky)

**Priority:** P2 | **Effort:** Medium (4-6 hours) | **Issue:** ios-share-4ky

Implement the iOS service layer for bulk image export functionality.

### Context
- Backend export API is already implemented: `/api/export`, `/api/export/{jobId}/status`, `/api/export/{jobId}/download`
- Need to integrate this into the iOS app
- Export creates a ZIP archive with all user images

### Requirements
Create `frontend/ImageHost/Shared/Services/ExportService.swift` with:

1. **Core Methods:**
   ```swift
   // Start export job on backend
   func startExport() async throws -> ExportJob

   // Poll export status
   func checkStatus(jobId: String) async throws -> ExportStatus

   // Download completed archive
   func downloadArchive(jobId: String, progress: @escaping (Double) -> Void) async throws -> URL

   // Cancel export
   func cancelExport(jobId: String) async throws
   ```

2. **Data Models:**
   ```swift
   struct ExportJob {
       let jobId: String
       let status: ExportStatus
       let createdAt: Date
   }

   enum ExportStatus {
       case pending
       case processing
       case completed(url: String)
       case failed(error: String)
   }
   ```

3. **Integration:**
   - Use `Config.effectiveBackendURL` for API calls
   - Use `KeychainService.shared.loadUploadToken()` for authentication
   - Add `Authorization: Bearer {token}` header
   - Handle 401 Unauthorized responses
   - Retry logic for network failures

4. **Progress Tracking:**
   - Poll status every 2 seconds while processing
   - Report download progress via callback
   - Support cancellation mid-download

5. **Error Handling:**
   - Network failures with retry
   - Insufficient storage space
   - Export job timeout (5 minutes)
   - Invalid job ID
   - Download interruption

### Implementation Steps
1. Create `frontend/ImageHost/Shared/Services/ExportService.swift`
2. Implement data models (ExportJob, ExportStatus)
3. Implement `startExport()` - POST to `/api/export`
4. Implement `checkStatus()` - GET from `/api/export/{jobId}/status`
5. Implement `downloadArchive()` - GET from `/api/export/{jobId}/download`
6. Add progress tracking with URLSessionDownloadDelegate
7. Implement cancellation support
8. Add comprehensive error handling
9. Write inline documentation
10. Test with backend API
11. Commit with message: "Implement ExportService for bulk image downloads"

### Success Criteria
- ✅ Can start export job and get job ID
- ✅ Status polling works correctly
- ✅ Archive downloads successfully
- ✅ Progress tracking works
- ✅ Cancellation works
- ✅ Error handling is comprehensive
- ✅ Builds without errors or warnings
- ✅ Code is well-documented

---

## Agent 3: Add Export UI to HistoryView (ios-share-3r6)

**Priority:** P2 | **Effort:** Medium (3-4 hours) | **Issue:** ios-share-3r6

Add UI in HistoryView to initiate and track bulk export operations.

### Context
- HistoryView shows list of uploaded images
- ExportService (from Agent 2) provides backend integration
- Need user-facing UI to trigger exports

### Requirements
1. **Export Button:**
   - Add toolbar item or navigation bar button: "Export All"
   - Use SF Symbol: `square.and.arrow.down` or `archivebox`
   - Show badge if export feature is available

2. **Export Sheet/Modal:**
   - Present modal sheet when export tapped
   - Show export options:
     - "Export All Images" (default)
     - Format: ZIP archive
     - Include metadata: Yes/No toggle
   - Display current image count
   - Estimate archive size
   - "Start Export" button

3. **Progress View:**
   - Show progress indicator during export
   - Stages: "Creating archive...", "Downloading...", "Saving..."
   - Progress bar for download
   - Allow cancellation
   - Show error messages if failed

4. **Completion:**
   - Success message: "Export completed!"
   - Share sheet to save to Files app or share
   - Option to open in Files app
   - Dismiss modal

5. **Empty State:**
   - If no images, disable export button
   - Show helpful message: "Upload images to export"

### Implementation Steps
1. Wait for Agent 2 to complete ExportService
2. Read `frontend/ImageHost/ImageHost/Views/HistoryView.swift`
3. Add export button to toolbar/navigation bar
4. Create export modal/sheet view
5. Integrate ExportService calls
6. Add progress tracking UI
7. Implement share sheet for completed export
8. Handle error states with user-friendly messages
9. Test complete flow in simulator
10. Commit with message: "Add bulk export UI to HistoryView"

### Success Criteria
- ✅ Export button appears in HistoryView
- ✅ Modal presents with export options
- ✅ Progress tracking works during export
- ✅ Download progress shows correctly
- ✅ Share sheet works for completed export
- ✅ Error handling provides clear feedback
- ✅ Empty state handled gracefully
- ✅ Builds without errors or warnings
- ✅ End-to-end export flow works

---

## Execution Instructions

Run these agents **in parallel** by sending a single message with 3 Task tool calls:

```
I need you to launch 3 agents in parallel to implement Phase 1 features:

1. Agent for ios-share-1ht: Update SettingsView for SaaS mode
2. Agent for ios-share-4ky: Create ExportService
3. Agent for ios-share-3r6: Add export UI to HistoryView (depends on Agent 2)

Please launch all 3 agents in a single message using multiple Task tool calls.

[Provide full context from this file]
```

## Dependencies
- Agent 3 (ios-share-3r6) depends on Agent 2 (ios-share-4ky) completing first
- Agent 1 (ios-share-1ht) is fully independent
- Agent 2 (ios-share-4ky) is fully independent

## Expected Outcomes
After all agents complete:
1. ✅ Polished SaaS-aware Settings UI
2. ✅ Working export service with backend integration
3. ✅ Complete export feature in HistoryView
4. ✅ All code committed to git
5. ✅ Implementation tasks completed
6. ✅ Ready for user testing

## Testing Checklist
After implementation:
- [ ] Build iOS app in Xcode (no errors/warnings)
- [ ] Test SettingsView in SaaS mode (read-only URL)
- [ ] Test export from HistoryView (complete flow)
- [ ] Verify export downloads and opens correctly
- [ ] Test cancellation during export
- [ ] Test error scenarios (network failure, etc.)

## Post-Completion
Run this checklist:
```bash
cd /Users/codybontecou/dev/ios-share
git status                              # Check changes
git add frontend/ImageHost/             # Stage iOS changes
git commit -m "Implement Phase 1: Export feature and SaaS UI polish"
git push                                # Push to remote
```
