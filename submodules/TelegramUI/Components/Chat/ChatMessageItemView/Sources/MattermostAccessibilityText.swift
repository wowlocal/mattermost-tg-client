import Foundation

// MATTERMOST: what VoiceOver reads for a Mattermost markdown table (Phase 4C). MattermostSyncCore draws a narrow
// table as an aligned text grid ("Step  | Owner\n------+------\nBuild | bob"), which VoiceOver read cell padding,
// pipes and the rule line literally ("dash dash dash plus …"). Here the rule lines go and each row's cells are
// read as a list ("Build, bob"). Only messages that contain such a rule line are changed, and only their
// accessibility text: the bubble shows the grid as before. A horizontal rule ("———") is dropped as well.
func mattermostAccessibilityTableText(_ text: String) -> String {
    let lines = text.components(separatedBy: "\n")
    let isRuleLine: (String) -> Bool = { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("+") || trimmed.contains("|") else {
            return false
        }
        return trimmed.allSatisfy { "-+|: ".contains($0) }
    }
    let hasTable = lines.contains(where: isRuleLine)
    var result: [String] = []
    for line in lines {
        if line.trimmingCharacters(in: .whitespaces) == "———" {
            continue
        }
        if hasTable {
            if isRuleLine(line) {
                continue
            }
            if line.contains("|") {
                let cells = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                result.append(cells.joined(separator: ", "))
                continue
            }
        }
        result.append(line)
    }
    return result.joined(separator: "\n")
}
