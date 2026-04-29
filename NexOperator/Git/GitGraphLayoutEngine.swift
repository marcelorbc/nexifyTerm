import SwiftUI

struct GraphLayoutResult {
    var commits: [GitCommit]
    var lines: [GitGraphLine]
    var maxLanes: Int
}

struct GitGraphLayoutEngine {
    private let maxLanes = 10

    func layout(commits: [GitCommit]) -> GraphLayoutResult {
        guard !commits.isEmpty else {
            return GraphLayoutResult(commits: [], lines: [], maxLanes: 0)
        }

        var mutableCommits = commits
        var lines: [GitGraphLine] = []

        var activeLanes: [String?] = []
        var commitRowIndex: [String: Int] = [:]

        for (row, commit) in mutableCommits.enumerated() {
            commitRowIndex[commit.id] = row
        }

        for (row, commit) in mutableCommits.enumerated() {
            let lane = findOrAssignLane(
                hash: commit.id,
                activeLanes: &activeLanes
            )
            mutableCommits[row].lane = lane

            var shouldFreeLane = false

            for (pIdx, parentHash) in commit.parentHashes.enumerated() {
                if let parentRow = commitRowIndex[parentHash] {
                    let parentLane: Int
                    if pIdx == 0 {
                        parentLane = reserveLaneForParent(
                            parentHash: parentHash,
                            childHash: commit.id,
                            preferredLane: lane,
                            activeLanes: &activeLanes
                        )
                        if parentLane != lane {
                            shouldFreeLane = true
                        }
                    } else {
                        parentLane = reserveLaneForParent(
                            parentHash: parentHash,
                            childHash: nil,
                            preferredLane: -1,
                            activeLanes: &activeLanes
                        )
                    }

                    let color = GitGraphLine.color(for: pIdx == 0 ? lane : parentLane)
                    lines.append(GitGraphLine(
                        fromLane: lane,
                        toLane: parentLane,
                        fromRow: row,
                        toRow: parentRow,
                        color: color,
                        isMerge: pIdx > 0
                    ))
                }
            }

            if commit.parentHashes.isEmpty || shouldFreeLane {
                freeLane(lane, activeLanes: &activeLanes)
            }
        }

        let usedMax = activeLanes.count
        return GraphLayoutResult(
            commits: mutableCommits,
            lines: lines,
            maxLanes: min(usedMax, maxLanes)
        )
    }

    // MARK: - Lane Management

    private func findOrAssignLane(hash: String, activeLanes: inout [String?]) -> Int {
        if let existing = activeLanes.firstIndex(of: hash) {
            return existing
        }
        if let freeSlot = activeLanes.firstIndex(of: nil) {
            activeLanes[freeSlot] = hash
            return freeSlot
        }
        if activeLanes.count < maxLanes {
            activeLanes.append(hash)
            return activeLanes.count - 1
        }
        activeLanes[maxLanes - 1] = hash
        return maxLanes - 1
    }

    private func reserveLaneForParent(
        parentHash: String,
        childHash: String?,
        preferredLane: Int,
        activeLanes: inout [String?]
    ) -> Int {
        if let existing = activeLanes.firstIndex(of: parentHash) {
            return existing
        }

        if preferredLane >= 0 && preferredLane < activeLanes.count {
            let current = activeLanes[preferredLane]
            if current == nil || current == parentHash || current == childHash {
                activeLanes[preferredLane] = parentHash
                return preferredLane
            }
        }

        if let freeSlot = activeLanes.firstIndex(of: nil) {
            activeLanes[freeSlot] = parentHash
            return freeSlot
        }
        if activeLanes.count < maxLanes {
            activeLanes.append(parentHash)
            return activeLanes.count - 1
        }
        activeLanes[maxLanes - 1] = parentHash
        return maxLanes - 1
    }

    private func freeLane(_ lane: Int, activeLanes: inout [String?]) {
        guard lane < activeLanes.count else { return }
        activeLanes[lane] = nil
    }
}
