// agent-status: right-sidebar live agent monitor.
// Shows every coding agent cmux tracks, attention-first, with the tab it runs
// in, the task it was given, a live timer, and an activity / subagent bar.
// Click a card to jump to its tab.
//   cmux right-sidebar set custom agent-status

func statusColor(_ s: String) -> Color {
    return s == "needs_input" ? Color("#FF9F0A")
        : s == "working" ? Color("#0A84FF")
        : s == "idle" ? Color("#34C759")
        : Color("#7f7f7f88")
}

func statusLabel(_ s: String) -> String {
    return s == "needs_input" ? "Needs input"
        : s == "working" ? "Working"
        : s == "idle" ? "Idle"
        : "Ended"
}

func fmt(_ secs: Double) -> String {
    let s = Int(max(0, secs))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m \(s % 60)s" }
    return "\(m / 60)h \(m % 60)m"
}

func tail(_ path: String) -> String {
    let parts = path.split(separator: "/")
    return parts.count > 0 ? String(parts[parts.count - 1]) : path
}

func countStatus(_ status: String) -> Int {
    var n = 0
    for w in workspaces {
        if let agents = w.agents {
            for a in agents {
                if a.status == status { n += 1 }
            }
        }
    }
    return n
}

// The cmux tab (surface) the agent's terminal lives in.
func tabTitle(_ w: Workspace, _ a: Agent) -> String {
    if let sid = a.surfaceId {
        for t in w.tabs {
            if let tsid = t.surfaceId {
                if tsid == sid { return t.title }
            }
        }
    }
    return a.name
}

// Most recent prompt sent in that tab = what the agent is working on now.
func currentTask(_ w: Workspace, _ a: Agent) -> String {
    if let sid = a.surfaceId {
        for t in w.tabs {
            if let tsid = t.surfaceId {
                if tsid == sid {
                    if let p = t.latestPrompt { return p }
                }
            }
        }
    }
    if let title = a.title { return title }
    return ""
}

func runningChildren(_ a: Agent) -> Int {
    var n = 0
    if let kids = a.children {
        for c in kids {
            if c.running { n += 1 }
        }
    }
    return n
}

func totalChildren(_ a: Agent) -> Int {
    if let kids = a.children { return kids.count }
    return 0
}

func elapsed(_ a: Agent) -> String {
    if let since = a.sinceEpoch {
        if a.status == "working" || a.status == "needs_input" {
            return fmt(clock.epoch - since)
        }
    }
    return fmt(clock.epoch - a.lastActivityAt) + " ago"
}

func agentCard(_ w: Workspace, _ a: Agent) -> some View {
    let color = statusColor(a.status)
    let live = a.status == "working" || a.status == "needs_input"
    let kids = totalChildren(a)
    let running = runningChildren(a)
    let task = currentTask(w, a)

    return Button(action: {
        cmux("workspace.select", workspace_id: w.id)
        if let sid = a.surfaceId { cmux("surface.focus", surface_id: sid) }
    }) {
        VStack(alignment: .leading, spacing: 5) {
            // Line 1: status dot, tab name, live timer
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(tabTitle(w, a))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(elapsed(a))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(live ? color : .tertiary)
            }

            // Line 2: the task
            if task != "" {
                Text(task)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            // Line 3: progress. Subagent fraction if any, workspace progress
            // if a script reported one, otherwise a live activity sweep.
            if kids > 0 {
                ProgressView(value: Double(kids - running) / Double(kids))
                    .tint(color)
            } else if let p = w.progress {
                ProgressView(value: p.value).tint(color)
            } else if a.status == "working" {
                HStack(spacing: 2) {
                    ForEach(0..<16) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i == clock.second % 16 || i == (clock.second + 15) % 16
                                  ? color : Color("#7f7f7f33"))
                            .frame(height: 3)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(a.status == "needs_input" ? color : Color("#7f7f7f22"))
                    .frame(height: 3)
            }

            // Line 4: metadata
            HStack(spacing: 6) {
                Text(statusLabel(a.status))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(a.status == "needs_input" ? color : .tertiary)
                Text("\(a.kind) · \(w.title)")
                    .font(.system(size: 10))
                    .foregroundColor(.tertiary)
                    .lineLimit(1)
                Spacer()
                if kids > 0 {
                    Text("\(running)/\(kids) sub")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(running > 0 ? Color("#0A84FF") : .tertiary)
                }
            }
            if let dir = a.directory {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundColor(.tertiary)
                    Text(tail(dir))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.tertiary)
                        .lineLimit(1)
                    if let branch = w.branch {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundColor(.tertiary)
                        Text(branch)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(10)
        .background(a.status == "needs_input" ? Color("#FF9F0A1f") : Color("#7f7f7f14"))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(a.status == "needs_input" ? Color("#FF9F0A66") : Color("#7f7f7f22"), lineWidth: 1)
        )
    }
}

func section(_ status: String, _ title: String) -> some View {
    let n = countStatus(status)
    return VStack(alignment: .leading, spacing: 6) {
        if n > 0 {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(status == "needs_input" ? statusColor(status) : .tertiary)
                Spacer()
                Text("\(n)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.tertiary)
            }
            ForEach(workspaces) { w in
                if let agents = w.agents {
                    ForEach(agents) { a in
                        if a.status == status {
                            agentCard(w, a)
                        }
                    }
                }
            }
        }
    }
}

ScrollView {
    VStack(alignment: .leading, spacing: 12) {
        // Header + fleet summary
        let working = countStatus("working")
        let waiting = countStatus("needs_input")
        let idle = countStatus("idle")
        let total = working + waiting + idle

        HStack {
            Text("Agents").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(clock.time)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.tertiary)
        }

        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle().fill(statusColor("working")).frame(width: 6, height: 6)
                Text("\(working) working").font(.system(size: 10))
            }
            HStack(spacing: 4) {
                Circle().fill(statusColor("needs_input")).frame(width: 6, height: 6)
                Text("\(waiting) waiting").font(.system(size: 10))
            }
            HStack(spacing: 4) {
                Circle().fill(statusColor("idle")).frame(width: 6, height: 6)
                Text("\(idle) idle").font(.system(size: 10))
            }
            Spacer()
        }
        .foregroundColor(.secondary)

        if total > 0 {
            ProgressView(value: Double(working + waiting) / Double(total))
                .tint(waiting > 0 ? statusColor("needs_input") : statusColor("working"))
        }

        Divider()

        section("needs_input", "NEEDS YOU")
        section("working", "WORKING")
        section("idle", "IDLE")

        if total == 0 {
            Text("No agents running. Start Claude Code, Codex, or another agent in a cmux terminal and it will show up here.")
                .font(.system(size: 11))
                .foregroundColor(.tertiary)
        }
    }
    .padding(10)
}
