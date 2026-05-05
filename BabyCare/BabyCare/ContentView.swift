//
//  ContentView.swift
//  BabyCare
//
//  Created by Peiqi Tang on 2/12/26.
//

import SwiftUI
import SwiftData
import UIKit

private enum AppTextRole {
    case body
    case bodyBold
    case emphasis
    case supporting
    case micro

    var font: Font {
        switch self {
        case .body:
            return .system(size: 16, weight: .regular)
        case .bodyBold:
            return .system(size: 16, weight: .semibold)
        case .emphasis:
            return .system(size: 36, weight: .bold)
        case .supporting:
            return .system(size: 12, weight: .regular)
        case .micro:
            return .system(size: 10, weight: .medium)
        }
    }
}

private extension Text {
    func appText(_ role: AppTextRole) -> Text {
        font(role.font)
    }
}

private extension Color {
    init(rgbHex: Int) {
        let red = Double((rgbHex >> 16) & 0xFF) / 255
        let green = Double((rgbHex >> 8) & 0xFF) / 255
        let blue = Double(rgbHex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    static let appDiaperEvent = Color(rgbHex: 0x00BA6C)
    static let appSleepEvent = Color(rgbHex: 0x4992FF)
    static let appFeedingEvent = Color(rgbHex: 0xAF5EFF)
    static let appRecording = Color(rgbHex: 0xEE5A5A)
    static let appDefaultText = Color(rgbHex: 0x351600)
    static let appSecondaryText = Color(rgbHex: 0x72675C)
    static let appDefaultCTA = Color(rgbHex: 0xE35F00)
    static let appNonInteractive = Color(rgbHex: 0xF2E5DA)
}

struct ContentView: View {
    private let bottomNavigationReservedHeight: CGFloat = 168

    private enum AppTab: Hashable {
        case summary
        case settings
        case activities
    }

    private enum BottomWidgetState {
        case tabsOnly
        case permissionRequired
        case readyToStart
        case initialStreaming
        case firstPaused
        case resumedStreaming
        case loggedPaused
    }

    private enum SettingsDestination: Hashable, Identifiable {
        case debugLogs
        case livePreview

        var id: Self { self }
    }

    private struct TabBackgroundPalette {
        let firstCircle: Color
        let secondCircle: Color
    }

    @EnvironmentObject private var wearablesManager: WearablesManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ActivityEventRecord.timestamp, order: .reverse) private var timelineEvents: [ActivityEventRecord]
    @State private var selectedTab: AppTab = .summary
    @State private var backgroundTab: AppTab = .summary
    @State private var outgoingBackgroundTab: AppTab?
    @State private var backgroundTransitionProgress: Double = 1
    @State private var eventPendingEdit: ActivityEventRecord?
    @State private var eventPendingDelete: ActivityEventRecord?
    @State private var eventPendingValueEdit: ActivityValueEditor?
    @State private var feedingAmountDraft: String = ""
    @State private var diaperChangeValueDraft: DiaperChangeValue = .wet
    @State private var activityTypeDraft: ActivityLabel = .feeding
    @State private var timeDraft: Date = .now
    @State private var timelineActionError: String?
    @State private var settingsDestination: SettingsDestination?
    @State private var activeTimelineSwipeEventID: UUID?
    @Namespace private var bottomTabSelectionNamespace

    private struct ActivityValueEditor: Identifiable {
        enum Mode: String {
            case feedingAmount
            case diaperChangeValue
            case time
        }

        let event: ActivityEventRecord
        let mode: Mode

        var id: String {
            "\(event.id.uuidString)-\(mode.rawValue)"
        }
    }

    private struct ActivityTimelineSwipeRow<Content: View>: View {
        let eventID: UUID
        @Binding var activeEventID: UUID?
        let onDelete: () -> Void
        let roundsTopCorners: Bool
        let roundsBottomCorners: Bool
        let content: Content

        @State private var settledOffset: CGFloat = 0
        @State private var liveDragOffset: CGFloat?
        @State private var dragStartOffset: CGFloat?
        private let actionWidth: CGFloat = 84
        private let swipeActivationDistance: CGFloat = 24
        private let snapOpenThreshold: CGFloat = 42

        init(
            eventID: UUID,
            activeEventID: Binding<UUID?>,
            onDelete: @escaping () -> Void,
            roundsTopCorners: Bool = false,
            roundsBottomCorners: Bool = false,
            @ViewBuilder content: () -> Content
        ) {
            self.eventID = eventID
            self._activeEventID = activeEventID
            self.onDelete = onDelete
            self.roundsTopCorners = roundsTopCorners
            self.roundsBottomCorners = roundsBottomCorners
            self.content = content()
        }

        private var isActionAreaVisible: Bool {
            currentOffset < -1
        }

        private var rowShape: some Shape {
            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: roundsTopCorners ? 24 : 0,
                    bottomLeading: roundsBottomCorners ? 24 : 0,
                    bottomTrailing: roundsBottomCorners ? 24 : 0,
                    topTrailing: roundsTopCorners ? 24 : 0
                )
            )
        }

        var body: some View {
            ZStack(alignment: .trailing) {
                HStack {
                    Spacer()
                    actionButton(
                        title: "Delete",
                        systemImage: "trash",
                        color: Color(red: 0.93, green: 0.35, blue: 0.35),
                        action: {
                            settledOffset = 0
                            activeEventID = nil
                            onDelete()
                        }
                    )
                }
                .padding(.trailing, 12)
                .opacity(isActionAreaVisible ? 1 : 0)
                .allowsHitTesting(isActionAreaVisible)

                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white)
                    .contentShape(Rectangle())
                    .offset(x: currentOffset)
                    .simultaneousGesture(dragGesture)
            }
            .clipped()
            .clipShape(rowShape)
            .mask(rowShape)
            .onChange(of: activeEventID) { _, newValue in
                if newValue != eventID, settledOffset != 0 {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        settledOffset = 0
                    }
                }
            }
        }

        private var currentOffset: CGFloat {
            liveDragOffset ?? settledOffset
        }

        private func clampedOffset(
            for translation: CGFloat,
            startingFrom startOffset: CGFloat
        ) -> CGFloat {
            let lowerBound = -actionWidth
            let upperBound: CGFloat = startOffset < 0 ? actionWidth : 0
            let clampedTranslation = min(max(translation, lowerBound), upperBound)
            return max(-actionWidth, min(0, startOffset + clampedTranslation))
        }

        private var dragGesture: some Gesture {
            DragGesture(minimumDistance: swipeActivationDistance, coordinateSpace: .local)
                .onChanged { value in
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    guard
                        abs(horizontal) > abs(vertical),
                        abs(horizontal) > swipeActivationDistance
                    else { return }

                    let startOffset = dragStartOffset ?? settledOffset
                    if dragStartOffset == nil {
                        dragStartOffset = startOffset
                    }

                    liveDragOffset = clampedOffset(
                        for: horizontal,
                        startingFrom: startOffset
                    )
                }
                .onEnded { value in
                    defer {
                        dragStartOffset = nil
                        liveDragOffset = nil
                    }

                    guard abs(value.translation.width) > abs(value.translation.height) else { return }

                    let startOffset = dragStartOffset ?? settledOffset
                    let currentDragOffset = liveDragOffset ?? clampedOffset(
                        for: value.translation.width,
                        startingFrom: startOffset
                    )

                    if startOffset == 0, activeEventID != eventID {
                        guard value.translation.width < -swipeActivationDistance else { return }
                    }

                    settledOffset = currentDragOffset

                    let clampedPredicted = clampedOffset(
                        for: value.predictedEndTranslation.width,
                        startingFrom: startOffset
                    )
                    let targetOffset: CGFloat = clampedPredicted < -snapOpenThreshold ? -actionWidth : 0
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        settledOffset = targetOffset
                        activeEventID = targetOffset == 0 ? nil : eventID
                    }
                }
        }

        @ViewBuilder
        private func actionButton(
            title: String,
            systemImage: String,
            color: Color,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                    Text(title)
                        .appText(.supporting)
                }
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(color)
            .clipShape(Circle())
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                sharedTabBackground

                Group {
                    switch selectedTab {
                    case .summary:
                        ScrollView {
                            VStack(spacing: 0) {
                                widgetRow {
                                    VStack(spacing: 24) {
                                        summaryLastActivitiesCard
                                        summaryActivityGraphCard
                                    }
                                }
                                .padding(.top, 12)
                            }
                            .padding(.horizontal, 16)
                        }
                    case .activities:
                        ScrollView {
                            let visibleEvents = timelineEvents.filter { !$0.isDeleted }

                            VStack(spacing: 0) {
                                if visibleEvents.isEmpty {
                                    Text("No activity events yet. End a segment to create one.")
                                        .appText(.body)
                                        .foregroundStyle(Color.appSecondaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 12)
                                } else {
                                    let calendar = Calendar.current
                                    let groupedEvents = Dictionary(grouping: visibleEvents) {
                                        calendar.startOfDay(for: $0.timestamp)
                                    }
                                    let sortedDays = groupedEvents.keys.sorted(by: >)

                                    activityTimelineContainer(sortedDays: sortedDays, groupedEvents: groupedEvents)
                                        .padding(.top, 12)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    case .settings:
                        ScrollView {
                            VStack(spacing: 24) {
                                if !wearablesManager.isDeviceRegistered {
                                    widgetRow {
                                        registrationButton(isRegistered: false)
                                    }
                                    .padding(.top, 12)
                                } else {
                                    Color.clear
                                        .frame(height: 12)
                                }

                                widgetRow {
                                    VStack(spacing: 24) {
                                        widgetCard {
                                            VStack(alignment: .leading, spacing: 0) {
                                                statusRow("Camera Permission", wearablesManager.cameraPermissionText)
                                                    .padding(.vertical, 12)

                                                if let settingsCardError {
                                                    Divider()
                                                    Text(settingsCardError)
                                                        .foregroundStyle(.red)
                                                        .appText(.body)
                                                        .lineLimit(nil)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .padding(.vertical, 12)
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                        }

                                        widgetCard {
                                            VStack(spacing: 0) {
                                                diagnosticNavigationRow("Debug Logs") {
                                                    settingsDestination = .debugLogs
                                                }
                                                .padding(.vertical, 16)
                                                Divider()
                                                diagnosticNavigationRow("Live Preview") {
                                                    settingsDestination = .livePreview
                                                }
                                                .padding(.vertical, 16)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 4)
                                        }
                                    }
                                }

                                if wearablesManager.isDeviceRegistered {
                                    widgetRow {
                                        registrationButton(isRegistered: true)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: bottomNavigationReservedHeight)
                }
                .scrollIndicators(.hidden)
                .background(Color.clear)
                .transaction { transaction in
                    transaction.animation = nil
                }

                ZStack(alignment: .bottom) {
                    bottomScrollFadeOverlay
                        .allowsHitTesting(false)

                    bottomNavigationWidget
                        .padding(.horizontal, 21)
                        .padding(.top, 8)
                        .padding(.bottom, 21)
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .background(Color.clear)
            .navigationTitle(selectedTabTitle)
            .navigationDestination(item: $settingsDestination) { destination in
                switch destination {
                case .debugLogs:
                    DebugLogsView()
                case .livePreview:
                    LivePreviewView()
                }
            }
        }
        .background(Color.clear)
        .toolbarBackground(.hidden, for: .navigationBar)
        .background(Color.clear)
        .onChange(of: selectedTab) { _, _ in
            if selectedTab != .activities {
                activeTimelineSwipeEventID = nil
            }
            updateIdleTimerPolicy()
        }
        .onChange(of: scenePhase) { _, _ in
            updateIdleTimerPolicy()
        }
        .onChange(of: wearablesManager.streamStateText) { _, _ in
            updateIdleTimerPolicy()
        }
        .task {
            wearablesManager.configurePipelineIfNeeded(modelContext: modelContext)
            updateIdleTimerPolicy()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(
            isPresented: Binding(
                get: { eventPendingEdit != nil },
                set: { isPresented in
                    if !isPresented { eventPendingEdit = nil }
                }
            )
        ) {
            NavigationStack {
                Form {
                    Section("Activity Type") {
                        Picker("", selection: $activityTypeDraft) {
                            ForEach(editableActivityLabels, id: \.self) { label in
                                Text(label.displayName).tag(label)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }

                    Section("Time Logged") {
                        DatePicker(
                            "Logged Date",
                            selection: $timeDraft,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .labelsHidden()

                        DatePicker(
                            "",
                            selection: $timeDraft,
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                    }
                }
                .navigationTitle("Edit Activity")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            eventPendingEdit = nil
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") {
                            if let event = eventPendingEdit {
                                applyActivityEdit(for: event)
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .onAppear {
                if let event = eventPendingEdit {
                    activityTypeDraft = event.label
                    timeDraft = event.timestamp
                }
            }
        }
        .sheet(item: $eventPendingValueEdit) { editor in
            NavigationStack {
                Form {
                    switch editor.mode {
                    case .feedingAmount:
                        Section("Amount (oz)") {
                            TextField("0.0", text: $feedingAmountDraft)
                                .keyboardType(.decimalPad)
                        }
                        Section {
                            Button("Clear Amount", role: .destructive) {
                                feedingAmountDraft = ""
                            }
                        }
                    case .diaperChangeValue:
                        Section("Value") {
                            Picker("Value", selection: $diaperChangeValueDraft) {
                                ForEach(DiaperChangeValue.allCases) { value in
                                    Text(value.displayName).tag(value)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    case .time:
                        Section("Date") {
                            DatePicker(
                                "Event Date",
                                selection: $timeDraft,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                        }

                        Section("Time") {
                            DatePicker(
                                "Event Time",
                                selection: $timeDraft,
                                displayedComponents: .hourAndMinute
                            )
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                        }
                    }
                }
                .navigationTitle(valueEditorTitle(for: editor.mode))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            eventPendingValueEdit = nil
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") {
                            applyValueEdit(editor)
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            "Delete Activity?",
            isPresented: Binding(
                get: { eventPendingDelete != nil },
                set: { isPresented in
                    if !isPresented { eventPendingDelete = nil }
                }
            ),
            presenting: eventPendingDelete
        ) { event in
            Button("Delete", role: .destructive) {
                deleteActivity(event)
            }
            Button("Cancel", role: .cancel) {
                eventPendingDelete = nil
            }
        } message: { _ in
            Text("This activity will be removed from the timeline.")
        }
        .alert(
            "Timeline Update Failed",
            isPresented: Binding(
                get: { timelineActionError != nil },
                set: { isPresented in
                    if !isPresented { timelineActionError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                timelineActionError = nil
            }
        } message: {
            Text(timelineActionError ?? "Please try again.")
        }
    }

    private var bottomScrollFadeOverlay: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: bottomNavigationReservedHeight + 64)

            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: Color.white.opacity(0.16), location: 0.35),
                            .init(color: Color.white.opacity(0.34), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: bottomNavigationReservedHeight + 64)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .white.opacity(0.55), location: 0.32),
                    .init(color: .white, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .appText(.body)
            Spacer(minLength: 0)
            Text(value)
                .appText(.body)
                .foregroundStyle(Color.appSecondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func statusTwoLineRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .appText(.body)
            Text(value)
                .appText(.supporting)
                .foregroundStyle(Color.appSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func widgetRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private var summaryLastActivitiesCard: some View {
        let visibleEvents = timelineEvents.filter { !$0.isDeleted }
        let latestDiaperEvent = visibleEvents.first {
            $0.label == .diaperWet || $0.label == .diaperBowel || $0.diaperChangeValue != nil
        }
        let latestSleepStartTimestamp = latestActivityTimestamp(in: visibleEvents) { $0.label == .sleepStart }
        let latestWakeUpTimestamp = latestActivityTimestamp(in: visibleEvents) { $0.label == .wakeUp }
        let isCurrentlyAsleep: Bool = {
            guard let latestSleepStartTimestamp else { return false }
            guard let latestWakeUpTimestamp else { return true }
            return latestSleepStartTimestamp > latestWakeUpTimestamp
        }()
        let thirdRowTitle = isCurrentlyAsleep ? "Asleep for" : "Awake for"
        let thirdRowTimestamp = isCurrentlyAsleep ? latestSleepStartTimestamp : latestWakeUpTimestamp

        let diaperTitle: String = {
            guard let latestDiaperEvent else { return "Diaper Change" }
            switch resolvedDiaperChangeValue(for: latestDiaperEvent) {
            case .wet:
                return "Diaper Change\n(Wet)"
            case .bm:
                return "Diaper Change\n(BM)"
            case .dry:
                return "Diaper Change\n(Dry)"
            }
        }()

        return HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                summaryLastSinceTile(
                    title: "Feeding",
                    titleColor: .appFeedingEvent,
                    timeColor: .appFeedingEvent,
                    mode: .ago,
                    timestamp: latestActivityTimestamp(in: visibleEvents) { $0.label == .feeding },
                    height: 112
                )
                summaryLastSinceTile(
                    title: thirdRowTitle,
                    titleColor: .appSleepEvent,
                    timeColor: .appSleepEvent,
                    mode: .forNow,
                    timestamp: thirdRowTimestamp,
                    height: 112
                )
            }
            .frame(maxWidth: .infinity)

            summaryLastSinceTile(
                title: diaperTitle,
                titleColor: .appDiaperEvent,
                timeColor: .appDiaperEvent,
                mode: .ago,
                timestamp: latestDiaperEvent?.timestamp,
                height: 240
            )
            .frame(maxWidth: .infinity)
        }
        .frame(height: 240)
    }

    private enum SummaryElapsedRowMode {
        case ago
        case forNow
    }

    private struct SummaryGraphDayGroup: Identifiable {
        let start: Date
        let end: Date
        let displayDate: Date

        var id: Date { start }
    }

    private var summaryActivityGraphCard: some View {
        let visibleEvents = timelineEvents.filter { !$0.isDeleted }
        let dayGroups = summaryGraphDayGroups(from: visibleEvents)
        let sleepIntervals = resolvedSleepIntervals(from: visibleEvents)

        return widgetCard {
            summaryActivityGraph(
                dayGroups: dayGroups,
                events: visibleEvents,
                sleepIntervals: sleepIntervals
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var summaryGraphTimeMarkers: [(label: String, hour: Double)] {
        [
            ("8 AM", 8),
            ("Noon", 12),
            ("4 PM", 16),
            ("8 PM", 20),
            ("12 AM", 24),
            ("4 AM", 28),
            ("8 AM", 32)
        ]
    }

    private func summaryActivityGraph(
        dayGroups: [SummaryGraphDayGroup],
        events: [ActivityEventRecord],
        sleepIntervals: [(start: Date, end: Date)]
    ) -> some View {
        let orderedDayGroups = Array(dayGroups.reversed())
        let dayColumnWidth: CGFloat = 48
        let daySpacing: CGFloat = 16
        let chartHeight: CGFloat = 335
        let pillsHeight: CGFloat = 48
        let contentWidth = CGFloat(orderedDayGroups.count) * dayColumnWidth
            + CGFloat(max(orderedDayGroups.count - 1, 0)) * daySpacing
        let filteredEvents = events.filter { event in
            event.label == .feeding
            || event.label == .diaperWet
            || event.label == .diaperBowel
            || event.diaperChangeValue != nil
        }

        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                Color.clear
                    .frame(height: pillsHeight + 24)
                ZStack(alignment: .topTrailing) {
                    ForEach(summaryGraphTimeMarkers, id: \.hour) { marker in
                        summaryGraphTimeLabel(marker.label)
                            .offset(y: yPosition(forHour: marker.hour, chartHeight: chartHeight) - 8)
                    }
                }
                .frame(height: chartHeight, alignment: .topTrailing)
                .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: daySpacing) {
                            ForEach(orderedDayGroups) { group in
                                dayPill(for: group.displayDate)
                                    .id(group.id)
                            }
                        }
                        .frame(width: contentWidth, alignment: .leading)
                        .padding(.trailing, 16)

                        ZStack(alignment: .topLeading) {
                            ForEach(summaryGraphTimeMarkers, id: \.hour) { marker in
                                Rectangle()
                                    .fill(Color.appNonInteractive)
                                    .frame(width: contentWidth, height: 1)
                                    .offset(y: yPosition(forHour: marker.hour, chartHeight: chartHeight))
                            }

                            HStack(alignment: .top, spacing: daySpacing) {
                                ForEach(orderedDayGroups) { group in
                                    dayTimelineColumn(
                                        dayGroup: group,
                                        events: filteredEvents,
                                        sleepIntervals: sleepIntervals,
                                        width: dayColumnWidth,
                                        height: chartHeight
                                    )
                                }
                            }
                            .frame(width: contentWidth, alignment: .leading)
                        }
                        .frame(width: contentWidth, height: chartHeight, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear {
                    if let newestDay = orderedDayGroups.last?.id {
                        proxy.scrollTo(newestDay, anchor: .trailing)
                    }
                }
                .overlay(alignment: .topLeading) {
                    LinearGradient(
                        colors: [.white, Color.white.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 48, height: 48)
                    .allowsHitTesting(false)
                }
            }
            .id(orderedDayGroups.map(\.id))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayPill(for day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        return ZStack {
            Circle()
                .fill(isToday ? .white : Color.appNonInteractive)
                .overlay {
                    if isToday {
                        Circle()
                            .strokeBorder(Color.appNonInteractive, lineWidth: 1)
                    }
                }
            Text(weekdayLetter(for: day))
                .appText(.body)
                .foregroundStyle(Color.appDefaultText)
        }
        .frame(width: 48, height: 48)
    }

    private func dayTimelineColumn(
        dayGroup: SummaryGraphDayGroup,
        events: [ActivityEventRecord],
        sleepIntervals: [(start: Date, end: Date)],
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let visualWindow = graphWindow(for: dayGroup.displayDate)
        let dayEvents = events.filter { event in
            event.timestamp >= visualWindow.start && event.timestamp < visualWindow.end
        }
        let feedingEvents = dayEvents.filter { $0.label == .feeding }
        let diaperEvents = dayEvents.filter {
            $0.label == .diaperWet || $0.label == .diaperBowel || $0.diaperChangeValue != nil
        }
        let daySleepSegments = sleepIntervals.compactMap { interval -> (start: Date, end: Date)? in
            guard Calendar.current.isDate(
                displayDate(forSleepIntervalStartingAt: interval.start),
                inSameDayAs: dayGroup.displayDate
            ) else {
                return nil
            }
            let start = max(interval.start, visualWindow.start)
            let end = min(interval.end, visualWindow.end)
            return end > start ? (start, end) : nil
        }

        return ZStack(alignment: .topLeading) {
            ForEach(feedingEvents, id: \.id) { event in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.appFeedingEvent)
                    .frame(width: width, height: 4)
                    .offset(x: 0, y: yPosition(for: event.timestamp, in: visualWindow.start, chartHeight: height) - 2)
            }

            ForEach(diaperEvents, id: \.id) { event in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.appDiaperEvent)
                    .frame(width: width, height: 4)
                    .offset(x: 0, y: yPosition(for: event.timestamp, in: visualWindow.start, chartHeight: height) - 2)
            }

            ForEach(Array(daySleepSegments.enumerated()), id: \.offset) { _, segment in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.appSleepEvent)
                    .frame(
                        width: width,
                        height: max(
                            8,
                            yPosition(for: segment.end, in: visualWindow.start, chartHeight: height)
                            - yPosition(for: segment.start, in: visualWindow.start, chartHeight: height)
                        )
                    )
                    .offset(
                        x: 0,
                        y: yPosition(for: segment.start, in: visualWindow.start, chartHeight: height)
                    )
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
    }

    private func summaryGraphDayGroups(from events: [ActivityEventRecord]) -> [SummaryGraphDayGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<21).compactMap { offset in
            guard let displayDate = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let window = graphWindow(for: displayDate)
            return SummaryGraphDayGroup(
                start: window.start,
                end: window.end,
                displayDate: displayDate
            )
        }
    }

    private func isNightSleepStart(_ timestamp: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: timestamp)
        return hour >= 19 || hour < 7
    }

    private func resolvedSleepIntervals(from events: [ActivityEventRecord]) -> [(start: Date, end: Date)] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var intervals: [(start: Date, end: Date)] = []
        var openSleepStart: Date?

        for event in sorted {
            if event.label == .sleepStart {
                if openSleepStart == nil {
                    openSleepStart = event.timestamp
                }
            } else if event.label == .wakeUp, let activeSleepStart = openSleepStart, event.timestamp > activeSleepStart {
                intervals.append((start: activeSleepStart, end: event.timestamp))
                openSleepStart = nil
            }
        }

        return intervals
    }

    private func displayDate(forSleepIntervalStartingAt start: Date) -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: start)
        let hour = calendar.component(.hour, from: start)
        if hour < 7 {
            return calendar.date(byAdding: .day, value: -1, to: startOfDay) ?? startOfDay
        }
        return startOfDay
    }

    private func graphWindow(for day: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let windowStart = calendar.date(byAdding: .hour, value: 8, to: dayStart) ?? dayStart
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: windowStart) ?? windowStart
        return (start: windowStart, end: windowEnd)
    }

    private func yPosition(for timestamp: Date, in dayWindowStart: Date, chartHeight: CGFloat) -> CGFloat {
        let elapsedHours = max(0, min(24, timestamp.timeIntervalSince(dayWindowStart) / 3600))
        return CGFloat(elapsedHours / 24) * chartHeight
    }

    private func yPosition(forHour hour: Double, chartHeight: CGFloat) -> CGFloat {
        let normalized = max(8, min(32, hour))
        let position = CGFloat((normalized - 8) / 24.0) * chartHeight
        return min(position, max(chartHeight - 1, 0))
    }

    private func weekdayLetter(for day: Date) -> String {
        let weekday = Calendar.current.component(.weekday, from: day)
        let letters = ["S", "M", "T", "W", "T", "F", "S"]
        return letters[max(0, min(letters.count - 1, weekday - 1))]
    }

    @ViewBuilder
    private func summaryGraphTimeLabel(_ label: String) -> some View {
        if label == "Noon" {
            Text(label)
                .appText(.supporting)
                .foregroundStyle(Color.appDefaultText)
        } else {
            let parts = label.split(separator: " ")
            if let hour = parts.first, let meridiem = parts.last {
                let hourText = Text(String(hour))
                    .appText(.supporting)
                    .foregroundStyle(Color.appDefaultText)
                let meridiemText = Text(String(meridiem))
                    .appText(.micro)
                    .foregroundStyle(Color.appSecondaryText)
                Text("\(hourText) \(meridiemText)")
            } else {
                Text(label)
                    .appText(.supporting)
                    .foregroundStyle(Color.appDefaultText)
            }
        }
    }

    @ViewBuilder
    private func summaryLastSinceTile(
        title: String,
        titleColor: Color,
        timeColor: Color,
        mode: SummaryElapsedRowMode,
        timestamp: Date?,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appText(.body)
                .foregroundStyle(titleColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            summaryLastSinceValueText(
                timestamp: timestamp,
                timeColor: timeColor,
                mode: mode
            )
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.appNonInteractive, lineWidth: 1)
                )
        }
    }

    private func summaryLastSinceValueText(
        timestamp: Date?,
        timeColor: Color,
        mode: SummaryElapsedRowMode
    ) -> Text {
        guard let timestamp else {
            return Text("No record")
                .appText(.body)
                .foregroundStyle(Color.appSecondaryText)
        }

        let elapsedTime = elapsedTimeComponents(since: timestamp)
        let elapsedSeconds = elapsedTimeInterval(since: timestamp)
        let hourValueText = Text(elapsedTime.hours)
            .appText(.emphasis)
            .foregroundStyle(timeColor)
        let hourUnitText = Text("h")
            .appText(.body)
            .foregroundStyle(Color.appSecondaryText)
        let minuteValueText = Text(elapsedTime.minutes)
            .appText(.emphasis)
            .foregroundStyle(timeColor)
        let minuteUnitText = Text("m")
            .appText(.body)
            .foregroundStyle(Color.appSecondaryText)
        let agoText = Text(" ago")
            .appText(.body)
            .foregroundStyle(Color.appSecondaryText)

        if elapsedSeconds > 86_400 {
            let dayValueText = Text("1")
                .appText(.emphasis)
                .foregroundStyle(timeColor)
            let dayUnitText = Text("d+")
                .appText(.body)
                .foregroundStyle(Color.appSecondaryText)
            return mode == .ago ? Text("\(dayValueText)\(dayUnitText)\(agoText)") : Text("\(dayValueText)\(dayUnitText)")
        }

        let timeText = Text("\(hourValueText)\(hourUnitText)\(minuteValueText)\(minuteUnitText)")
        return mode == .ago ? Text("\(timeText)\(agoText)") : timeText
    }

    @ViewBuilder
    private func summaryElapsedTimeRow(
        title: String,
        titleColor: Color,
        timeColor: Color,
        mode: SummaryElapsedRowMode,
        timestamp: Date?
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .appText(.body)
                .foregroundStyle(titleColor)
            Spacer()
            summaryElapsedTimeValueText(
                timestamp: timestamp,
                timeColor: timeColor,
                mode: mode
            )
            .multilineTextAlignment(.trailing)
        }
    }

    private var summaryCardDivider: some View {
        Rectangle()
            .fill(Color.appNonInteractive)
            .frame(height: 1)
    }

    private func latestActivityTimestamp(
        in events: [ActivityEventRecord],
        where predicate: (ActivityEventRecord) -> Bool
    ) -> Date? {
        events.first(where: predicate)?.timestamp
    }

    private func summaryElapsedTimeValueText(
        timestamp: Date?,
        timeColor: Color,
        mode: SummaryElapsedRowMode
    ) -> Text {
        guard let timestamp else {
            return Text("No record")
                .appText(.body)
                .foregroundStyle(Color.appSecondaryText)
        }

        let elapsedTime = elapsedTimeComponents(since: timestamp)
        let elapsedSeconds = elapsedTimeInterval(since: timestamp)
        let prefixText = Text("for")
            .appText(.body)
            .foregroundStyle(Color.appSecondaryText)
        let suffixAgoText = Text(" ago")
            .appText(.body)
            .foregroundStyle(Color.appSecondaryText)
        let suffixNowText = Text(" now")
            .appText(.body)
            .foregroundStyle(Color.appSecondaryText)
        let leadingSpace = Text(" ")
            .appText(.body)
            .foregroundStyle(.clear)
        let hourValueText = Text(elapsedTime.hours)
            .appText(.body)
            .foregroundStyle(timeColor)
        let hourUnitText = Text("h")
            .appText(.supporting)
            .foregroundStyle(Color.appSecondaryText)
        let hourText = Text("\(hourValueText)\(hourUnitText)")
        let minuteValueText = Text(elapsedTime.minutes)
            .appText(.body)
            .foregroundStyle(timeColor)
        let minuteUnitText = Text("m")
            .appText(.supporting)
            .foregroundStyle(Color.appSecondaryText)
        let minuteText = Text("\(minuteValueText)\(minuteUnitText)")
        let moreThanOneDayValueText = Text("more than 1")
            .appText(.body)
            .foregroundStyle(timeColor)
        let dayUnitText = Text("d")
            .appText(.supporting)
            .foregroundStyle(Color.appSecondaryText)
        let moreThanOneDayText = Text("\(moreThanOneDayValueText)\(dayUnitText)")

        switch mode {
        case .ago:
            if elapsedSeconds > 86_400 {
                return Text("\(moreThanOneDayText)\(suffixAgoText)")
            }
            return Text("\(hourText)\(minuteText)\(suffixAgoText)")
        case .forNow:
            return Text("\(prefixText)\(leadingSpace)\(hourText)\(minuteText)\(suffixNowText)")
        }
    }

    private func elapsedTimeComponents(since timestamp: Date?) -> (hours: String, minutes: String) {
        guard let timestamp else { return ("0", "00") }
        let seconds = elapsedTimeInterval(since: timestamp)
        let totalHours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        return ("\(totalHours)", String(format: "%02d", minutes))
    }

    private func elapsedTimeInterval(since timestamp: Date?) -> Int {
        guard let timestamp else { return 0 }
        return max(0, Int(Date().timeIntervalSince(timestamp)))
    }

    private enum CameraStreamLayoutState {
        case stopped
        case streaming
        case paused
    }

    @ViewBuilder
    private func diagnosticNavigationRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .appText(.bodyBold)
                    .foregroundStyle(Color.appDefaultText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.appSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsCardError: String? {
        wearablesManager.lastError
    }

    private var bottomWidgetState: BottomWidgetState {
        guard wearablesManager.isDeviceRegistered else {
            return .tabsOnly
        }
        guard wearablesManager.isCameraPermissionGranted else {
            return .permissionRequired
        }
        switch streamLayoutState {
        case .stopped:
            return .readyToStart
        case .streaming:
            return wearablesManager.hasActiveSegmentCapture ? .resumedStreaming : .initialStreaming
        case .paused:
            return wearablesManager.latestSegmentEndedAt == nil ? .firstPaused : .loggedPaused
        }
    }

    private var bottomWidgetTooltip: (text: String, color: Color, showsIllustration: Bool)? {
        switch bottomWidgetState {
        case .initialStreaming:
            return (
                "To get ready for logging, tap the glasses' touch pad to pause streaming.",
                Color(red: 0.93, green: 0.35, blue: 0.35),
                true
            )
        case .firstPaused:
            return (
                "Great! Tap on the glasses' touch pad when you want to log an activity, tap again to finish logging.",
                Color.appDefaultText,
                false
            )
        default:
            return nil
        }
    }

    private var editableActivityLabels: [ActivityLabel] {
        [.diaperWet, .diaperBowel, .feeding, .sleepStart, .wakeUp]
    }

    private var activityTimelineDividerColor: Color {
        Color.appNonInteractive
    }

    private func activityTimelineContainer(
        sortedDays: [Date],
        groupedEvents: [Date: [ActivityEventRecord]]
    ) -> some View {
        VStack(spacing: 12) {
            ForEach(sortedDays, id: \.self) { day in
                let eventsForDay = (groupedEvents[day] ?? []).sorted { $0.timestamp > $1.timestamp }

                VStack(alignment: .leading, spacing: 8) {
                    Text(day.formatted(date: .abbreviated, time: .omitted))
                        .font(.headline)
                        .foregroundStyle(Color.appSecondaryText)
                        .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        ForEach(Array(eventsForDay.enumerated()), id: \.element.id) { eventIndex, event in
                            ActivityTimelineSwipeRow(
                                eventID: event.id,
                                activeEventID: $activeTimelineSwipeEventID,
                                onDelete: {
                                    eventPendingDelete = event
                                },
                                roundsTopCorners: eventIndex == 0,
                                roundsBottomCorners: eventIndex == eventsForDay.count - 1,
                                content: {
                                    activityTimelineCard(for: event)
                                }
                            )
                            .background(.white)

                            if eventIndex < eventsForDay.count - 1 {
                                Rectangle()
                                    .fill(activityTimelineDividerColor)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(activityTimelineDividerColor, lineWidth: 1)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func activityTimelineCard(for event: ActivityEventRecord) -> some View {
        let accentColor = activityCardAccentColor(for: event)

        VStack(alignment: .leading, spacing: 10) {
            Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                .appText(.supporting)
                .foregroundStyle(Color.appSecondaryText)
                .padding(.top, 16)
                .padding(.horizontal, 16)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 4, height: 20)

                HStack(alignment: .center, spacing: 12) {
                    Button {
                        presentActivityEditor(for: event)
                    } label: {
                        Text(activityCardTitle(for: event))
                            .appText(.bodyBold)
                            .foregroundStyle(accentColor)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    if let editorMode = valueEditorMode(for: event),
                       let valueAction = valueAction(for: event, mode: editorMode) {
                        Button(action: valueAction) {
                            Text(activityCardVariableText(for: event, mode: editorMode))
                                .appText(.bodyBold)
                                .foregroundStyle(accentColor)
                                .multilineTextAlignment(.trailing)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.rationaleShort)
                    .appText(.supporting)
                    .foregroundStyle(Color.appSecondaryText)

                HStack(spacing: 8) {
                    Text("Confidence: \(event.confidence.formatted(.number.precision(.fractionLength(2))))")
                        .appText(.supporting)
                        .foregroundStyle(Color.appSecondaryText)
                    if event.needsReview {
                        Text("Needs Review")
                            .appText(.supporting)
                            .foregroundStyle(Color.appDefaultText)
                            .padding(.horizontal, 4)
                            .background(Color.appNonInteractive)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func valueEditorTitle(for mode: ActivityValueEditor.Mode) -> String {
        switch mode {
        case .feedingAmount:
            return "Edit Amount"
        case .diaperChangeValue:
            return "Edit Value"
        case .time:
            return "Edit Time"
        }
    }

    private func valueEditorMode(for event: ActivityEventRecord) -> ActivityValueEditor.Mode? {
        if event.label == .feeding {
            return .feedingAmount
        }
        if isDiaperEvent(event) {
            return .diaperChangeValue
        }
        if event.label == .sleepStart || event.label == .wakeUp {
            return .time
        }
        return nil
    }

    private func activityCardAccentColor(for event: ActivityEventRecord) -> Color {
        if event.label == .feeding {
            return .appFeedingEvent
        }
        if isDiaperEvent(event) {
            return .appDiaperEvent
        }
        if event.label == .sleepStart || event.label == .wakeUp {
            return .appSleepEvent
        }
        return .appDefaultText
    }

    private func activityCardVariableText(for event: ActivityEventRecord, mode: ActivityValueEditor.Mode) -> String {
        switch mode {
        case .feedingAmount:
            if let amount = event.feedingAmountOz {
                return "\(amount.formatted(.number.precision(.fractionLength(1))))oz"
            }
            if let inferredAmount = event.inferredFeedingAmountOz {
                return "\(inferredAmount.formatted(.number.precision(.fractionLength(1))))oz"
            }
            return "Enter amount"
        case .diaperChangeValue:
            return resolvedDiaperChangeValue(for: event).displayName
        case .time:
            return event.timestamp.formatted(date: .omitted, time: .shortened)
        }
    }

    private func valueAction(for event: ActivityEventRecord, mode: ActivityValueEditor.Mode) -> (() -> Void)? {
        switch mode {
        case .feedingAmount:
            return { presentFeedingAmountEditor(for: event) }
        case .diaperChangeValue:
            return { presentDiaperChangeEditor(for: event) }
        case .time:
            return { presentTimeEditor(for: event) }
        }
    }

    private func activityCardTitle(for event: ActivityEventRecord) -> String {
        if event.label == .feeding {
            return "Feeding"
        }
        if isDiaperEvent(event) {
            return "Diaper"
        }
        if event.label == .sleepStart {
            return "Fall asleep"
        }
        if event.label == .wakeUp {
            return "Wake up"
        }
        return event.label.displayName
    }

    private func isDiaperEvent(_ event: ActivityEventRecord) -> Bool {
        event.label == .diaperWet || event.label == .diaperBowel || event.diaperChangeValue != nil
    }

    private func feedingAmountDisplayText(for event: ActivityEventRecord) -> String {
        if let amount = event.feedingAmountOz {
            return "\(amount.formatted(.number.precision(.fractionLength(1)))) oz"
        }
        if let inferredAmount = event.inferredFeedingAmountOz {
            return "\(inferredAmount.formatted(.number.precision(.fractionLength(1)))) oz (Inferred)"
        }
        return "Enter amount"
    }

    private func resolvedDiaperChangeValue(for event: ActivityEventRecord) -> DiaperChangeValue {
        if let value = event.diaperChangeValue {
            return value
        }
        switch event.label {
        case .diaperWet:
            return .wet
        case .diaperBowel:
            return .bm
        default:
            return .dry
        }
    }

    private func presentFeedingAmountEditor(for event: ActivityEventRecord) {
        if let currentAmount = event.feedingAmountOz {
            feedingAmountDraft = currentAmount.formatted(.number.precision(.fractionLength(1)))
        } else if let inferredAmount = event.inferredFeedingAmountOz {
            feedingAmountDraft = inferredAmount.formatted(.number.precision(.fractionLength(1)))
        } else {
            feedingAmountDraft = ""
        }
        eventPendingValueEdit = ActivityValueEditor(event: event, mode: .feedingAmount)
    }

    private func presentDiaperChangeEditor(for event: ActivityEventRecord) {
        diaperChangeValueDraft = resolvedDiaperChangeValue(for: event)
        eventPendingValueEdit = ActivityValueEditor(event: event, mode: .diaperChangeValue)
    }

    private func presentTimeEditor(for event: ActivityEventRecord) {
        timeDraft = event.timestamp
        eventPendingValueEdit = ActivityValueEditor(event: event, mode: .time)
    }

    private func presentActivityEditor(for event: ActivityEventRecord) {
        activeTimelineSwipeEventID = nil
        eventPendingEdit = event
    }

    private func applyValueEdit(_ editor: ActivityValueEditor) {
        switch editor.mode {
        case .feedingAmount:
            let trimmed = feedingAmountDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                editor.event.feedingAmountOz = nil
            } else {
                guard let amount = Double(trimmed), amount >= 0 else {
                    timelineActionError = "Amount must be a number in oz, like 3.5."
                    return
                }
                editor.event.feedingAmountOz = (amount * 10).rounded() / 10
            }
            editor.event.isUserCorrected = true
            editor.event.needsReview = false
        case .diaperChangeValue:
            editor.event.diaperChangeValue = diaperChangeValueDraft
            switch diaperChangeValueDraft {
            case .wet:
                editor.event.label = .diaperWet
            case .bm:
                editor.event.label = .diaperBowel
            case .dry:
                editor.event.label = .other
            }
            editor.event.isUserCorrected = true
            editor.event.needsReview = false
        case .time:
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timeDraft)
            if let updated = calendar.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: components.hour,
                minute: components.minute,
                second: 0
            )) {
                editor.event.timestamp = updated
            } else {
                timelineActionError = "Failed to update time."
                return
            }
            editor.event.isUserCorrected = true
            editor.event.needsReview = false
        }

        persistTimelineChanges()
        eventPendingValueEdit = nil
    }

    private func applyActivityEdit(for event: ActivityEventRecord) {
        applyActivityTypeChanges(for: event, to: activityTypeDraft)

        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timeDraft)
        if let updated = calendar.date(from: DateComponents(
            year: components.year,
            month: components.month,
            day: components.day,
            hour: components.hour,
            minute: components.minute,
            second: 0
        )) {
            event.timestamp = updated
        } else {
            timelineActionError = "Failed to update date and time."
            return
        }

        event.isUserCorrected = true
        event.needsReview = false
        persistTimelineChanges()
        eventPendingEdit = nil
    }

    private func updateActivityType(for event: ActivityEventRecord, to newLabel: ActivityLabel) {
        applyActivityTypeChanges(for: event, to: newLabel)
        event.isUserCorrected = true
        event.needsReview = false
        persistTimelineChanges()
    }

    private func applyActivityTypeChanges(for event: ActivityEventRecord, to newLabel: ActivityLabel) {
        event.label = newLabel
        switch newLabel {
        case .diaperWet:
            event.diaperChangeValue = .wet
        case .diaperBowel:
            event.diaperChangeValue = .bm
        default:
            event.diaperChangeValue = nil
        }
        if newLabel != .feeding {
            event.feedingAmountOz = nil
            event.inferredFeedingAmountOz = nil
        }
    }

    private func deleteActivity(_ event: ActivityEventRecord) {
        activeTimelineSwipeEventID = nil
        modelContext.delete(event)
        persistTimelineChanges()
        eventPendingDelete = nil
    }

    private func persistTimelineChanges() {
        do {
            try modelContext.save()
        } catch {
            timelineActionError = error.localizedDescription
        }
    }

    private var sharedTabBackground: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Color.white

                if let outgoingBackgroundTab {
                    backgroundCirclesLayer(
                        for: palette(for: outgoingBackgroundTab),
                        size: size
                    )
                    .opacity(1 - backgroundTransitionProgress)
                }

                backgroundCirclesLayer(
                    for: palette(for: backgroundTab),
                    size: size
                )
                .opacity(backgroundTransitionProgress)
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
    }

    private func backgroundCirclesLayer(
        for palette: TabBackgroundPalette,
        size: CGSize
    ) -> some View {
        Canvas { context, _ in
            let diameter: CGFloat = 380
            let blurRadius: CGFloat = 100

            context.drawLayer { layer in
                layer.addFilter(.blur(radius: blurRadius))

                let secondCircleRect = CGRect(
                    x: size.width - 40 - (diameter / 2),
                    y: 20 - (diameter / 2),
                    width: diameter,
                    height: diameter
                )
                layer.fill(
                    Path(ellipseIn: secondCircleRect),
                    with: .color(palette.secondCircle)
                )

                let firstCircleRect = CGRect(
                    x: 70 - (diameter / 2),
                    y: 40 - (diameter / 2),
                    width: diameter,
                    height: diameter
                )
                layer.fill(
                    Path(ellipseIn: firstCircleRect),
                    with: .color(palette.firstCircle)
                )
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func palette(for tab: AppTab) -> TabBackgroundPalette {
        switch tab {
        case .summary:
            return TabBackgroundPalette(
                firstCircle: Color(rgbHex: 0xFFE2DE),
                secondCircle: Color(rgbHex: 0xFFEDDE)
            )
        case .activities:
            return TabBackgroundPalette(
                firstCircle: Color(rgbHex: 0xFCE0D0),
                secondCircle: Color(rgbHex: 0xFFE5F1)
            )
        case .settings:
            return TabBackgroundPalette(
                firstCircle: Color(rgbHex: 0xFFEDDE),
                secondCircle: Color(rgbHex: 0xFCE0D0)
            )
        }
    }

    private func startBackgroundTransition(to tab: AppTab) {
        guard backgroundTab != tab else { return }

        outgoingBackgroundTab = backgroundTab
        backgroundTab = tab
        backgroundTransitionProgress = 0

        withAnimation(.easeInOut(duration: 1.0)) {
            backgroundTransitionProgress = 1
        }

        let targetTab = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard backgroundTab == targetTab else { return }
            outgoingBackgroundTab = nil
        }
    }

    private var selectedTabTitle: String {
        switch selectedTab {
        case .summary:
            return "Summary"
        case .activities:
            return "Activities"
        case .settings:
            return "Settings"
        }
    }

    private var streamLayoutState: CameraStreamLayoutState {
        let normalized = wearablesManager.streamStateText
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        if normalized.contains("paused") {
            return .paused
        }
        if normalized.contains("streaming")
            || normalized.contains("starting")
            || normalized.contains("waitingfordevice")
            || normalized.contains("connecting") {
            return .streaming
        }
        return .stopped
    }

    @ViewBuilder
    private func registrationButton(isRegistered: Bool) -> some View {
        actionCardButton(
            title: isRegistered ? "Unregister your glasses" : "Register your glasses",
            textColor: isRegistered ? .appDefaultText : .appDefaultCTA,
            borderColor: isRegistered ? .appNonInteractive : .appDefaultCTA
        ) {
            Task {
                if isRegistered {
                    await wearablesManager.startUnregistration()
                } else {
                    await wearablesManager.startRegistration()
                }
            }
        }
        .disabled(wearablesManager.isBusy)
    }

    @ViewBuilder
    private func actionCardButton(
        title: String,
        textColor: Color,
        borderColor: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white)
                    .overlay(
                        Group {
                            if let borderColor {
                                RoundedRectangle(cornerRadius: 24)
                                    .strokeBorder(borderColor, lineWidth: 1)
                            }
                        }
                    )

                Text(title)
                    .appText(.bodyBold)
                    .foregroundStyle(textColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
        }
    }

    @ViewBuilder
    private func widgetCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(Color.appNonInteractive, lineWidth: 1)
                    )
            }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bottomNavigationWidget: some View {
        VStack(spacing: 0) {
            if let tooltip = bottomWidgetTooltip {
                VStack(alignment: .leading, spacing: 4) {
                    if tooltip.showsIllustration {
                        readyToLogTooltipIllustration
                    }

                    Text(tooltip.text)
                        .appText(.body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 24)
            }

            VStack(spacing: 8) {
                if bottomWidgetState != .tabsOnly {
                    bottomWidgetAccessory
                        .padding(.top, 12)
                        .padding(.leading, 12)
                        .padding(.trailing, 12)
                        .padding(.bottom, 4)
                }

                bottomTabBar
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 0)
        }
        .background {
            if let tooltip = bottomWidgetTooltip {
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(tooltip.color)
            }
        }
    }

    @ViewBuilder
    private var readyToLogTooltipIllustration: some View {
        if let image = bundledImage(named: "Tap Glasses") {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 44)
        } else {
            readyToLogTooltipIllustrationFallback
        }
    }

    private var readyToLogTooltipIllustrationFallback: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)

            Image(systemName: "wave.3.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .offset(x: 10, y: -4)
        }
        .frame(width: 72, height: 44, alignment: .leading)
    }

    private func bundledImage(named name: String) -> UIImage? {
        let directPath = Bundle.main.path(forResource: name, ofType: "png", inDirectory: nil)
        let discoveredPath = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil)?
            .first(where: { $0.deletingPathExtension().lastPathComponent == name })?
            .path

        guard let imagePath = directPath ?? discoveredPath,
              let image = UIImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 4.0, orientation: image.imageOrientation)
    }

    @ViewBuilder
    private var bottomWidgetAccessory: some View {
        switch bottomWidgetState {
        case .tabsOnly:
            EmptyView()
        case .permissionRequired:
            bottomPermissionButton
        case .readyToStart, .initialStreaming, .firstPaused, .resumedStreaming, .loggedPaused:
            bottomCameraControlRow
        }
    }

    private var bottomPermissionButton: some View {
        Button {
            Task {
                await wearablesManager.requestCameraPermission()
            }
        } label: {
            Text("Request camera permission")
                .appText(.bodyBold)
                .foregroundStyle(Color.appDefaultCTA)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.appDefaultCTA, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(wearablesManager.isBusy)
    }

    private var bottomCameraControlRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Glasses Camera")
                    .appText(.body)
                    .foregroundStyle(Color.appDefaultText)
                Text(bottomCameraStatusText)
                    .appText(.body)
                    .foregroundStyle(Color.appSecondaryText)
            }

            Spacer(minLength: 12)

            controlButton(for: streamLayoutState)
            stopButton(for: streamLayoutState)
        }
    }

    private var bottomCameraStatusText: String {
        switch streamLayoutState {
        case .stopped:
            return "Stopped"
        case .streaming:
            return "Streaming"
        case .paused:
            return "Paused"
        }
    }

    private var bottomTabBar: some View {
        HStack(spacing: 16) {
            bottomTabButton(for: .summary, title: "Summary", systemImage: "chart.bar")
            bottomTabButton(for: .activities, title: "Activities", systemImage: "list.bullet.rectangle")
            bottomTabButton(for: .settings, title: "Settings", systemImage: "gearshape")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private func bottomTabButton(for tab: AppTab, title: String, systemImage: String) -> some View {
        let isSelected = selectedTab == tab
        let accentColor = bottomTabAccentColor(for: tab)
        return Button {
            selectedTab = tab
            startBackgroundTransition(to: tab)
        } label: {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(bottomTabAccentFill(for: tab))
                        .matchedGeometryEffect(id: "selectedBottomTabBackground", in: bottomTabSelectionNamespace)
                }

                VStack(spacing: 0) {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: isSelected ? .semibold : .medium))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(
                            isSelected
                            ? accentColor
                            : Color.appDefaultCTA
                        )
                    Text(title)
                        .appText(.micro)
                        .foregroundStyle(
                            isSelected
                            ? accentColor
                            : Color.appDefaultCTA
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                .frame(width: 46)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bottomTabAccentColor(for tab: AppTab) -> Color {
        Color.appDefaultCTA
    }

    private func bottomTabAccentFill(for tab: AppTab) -> some ShapeStyle {
        let palette = palette(for: tab)

        switch tab {
        case .summary:
            return LinearGradient(
                colors: [
                    palette.firstCircle.opacity(0.92),
                    palette.secondCircle.opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .activities:
            return LinearGradient(
                colors: [
                    palette.firstCircle.opacity(0.92),
                    palette.secondCircle.opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .settings:
            return LinearGradient(
                colors: [
                    palette.firstCircle.opacity(0.92),
                    palette.secondCircle.opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private func controlButton(for state: CameraStreamLayoutState) -> some View {
        switch state {
        case .stopped:
            Button {
                Task {
                    await wearablesManager.startCameraStream()
                }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color(red: 0.93, green: 0.35, blue: 0.35)))
            }
            .disabled(wearablesManager.isBusy || wearablesManager.hasActiveStreamSession)
        case .streaming:
            ZStack {
                Circle()
                    .fill(Color(red: 0.85, green: 0.85, blue: 0.85))
                    .frame(width: 56, height: 56)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: 0.96, green: 0.96, blue: 0.96))
                        .frame(width: 7, height: 26)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: 0.96, green: 0.96, blue: 0.96))
                        .frame(width: 7, height: 26)
                }
            }
        case .paused:
            ZStack {
                Circle()
                    .fill(Color(red: 0.85, green: 0.85, blue: 0.85))
                    .frame(width: 56, height: 56)
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(red: 0.96, green: 0.96, blue: 0.96))
            }
        }
    }

    private func stopButton(for state: CameraStreamLayoutState) -> some View {
        let enabled = state != .stopped
        return Button {
            Task {
                await wearablesManager.stopCameraStream()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(enabled ? Color(red: 0.95, green: 0.35, blue: 0.35) : Color(red: 0.90, green: 0.90, blue: 0.90))
                    .frame(width: 56, height: 56)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.96, green: 0.96, blue: 0.96))
                    .frame(width: 20, height: 20)
            }
        }
        .disabled(wearablesManager.isBusy || !enabled)
    }

    private func updateIdleTimerPolicy() {
        let shouldDisableIdleTimer = scenePhase == .active && wearablesManager.hasActiveStreamSession
        if UIApplication.shared.isIdleTimerDisabled != shouldDisableIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = shouldDisableIdleTimer
        }
    }

}

private struct DebugLogsView: View {
    @EnvironmentObject private var wearablesManager: WearablesManager

    var body: some View {
        Form {
            Section("Debug Logs") {
                HStack {
                    Text("Button-Like Event")
                        .appText(.body)
                    Spacer()
                    Text(wearablesManager.buttonLikeEventDetected ? "detected" : "not detected")
                        .appText(.body)
                        .foregroundStyle(Color.appSecondaryText)
                }

                Button("Mark Manual Glasses Press") {
                    wearablesManager.markManualButtonPress()
                }

                Button("Clear Logs", role: .destructive) {
                    wearablesManager.clearDebugEvents()
                }
            }

            Section("Event List") {
                if wearablesManager.debugEvents.isEmpty {
                    Text("No wearable events logged yet.")
                        .appText(.body)
                        .foregroundStyle(Color.appSecondaryText)
                } else {
                    ForEach(wearablesManager.debugEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.name)
                                    .appText(.body)
                                if event.isManualMarker {
                                    Text("Manual Marker")
                                        .appText(.supporting)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.15))
                                        .clipShape(Capsule())
                                } else if event.isButtonLike {
                                    Text("Button-Like")
                                        .appText(.supporting)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.orange.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                                Spacer()
                                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                    .appText(.supporting)
                                    .foregroundStyle(Color.appSecondaryText)
                            }
                            if !event.metadata.isEmpty {
                                Text(formatDebugMetadata(event.metadata))
                                    .appText(.supporting)
                                    .foregroundStyle(Color.appSecondaryText)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Debug Logs")
    }

    private func formatDebugMetadata(_ metadata: [String: String]) -> String {
        metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }
}

private struct LivePreviewView: View {
    @EnvironmentObject private var wearablesManager: WearablesManager

    var body: some View {
        Group {
            if let frame = wearablesManager.latestFrame {
                ScrollView {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    "No Live Preview Yet",
                    systemImage: "video.slash",
                    description: Text("Start streaming to load live frames.")
                        .appText(.body)
                )
            }
        }
        .navigationTitle("Live Preview")
    }
}

#Preview {
    ContentView()
        .environmentObject(WearablesManager(autoConfigure: false))
        .modelContainer(for: ActivityEventRecord.self, inMemory: true)
}
