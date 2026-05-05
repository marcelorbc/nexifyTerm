import SwiftUI

struct VolumeSummaryView: View {
    let volumeInfo: VolumeInfo?
    let scannedNode: DiskNode?

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)

            if let vol = volumeInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vol.name)
                        .font(.system(size: 13, weight: .semibold))

                    GeometryReader { geo in
                        let usedFraction = CGFloat(vol.usedPercentage / 100.0)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.15))

                            RoundedRectangle(cornerRadius: 3)
                                .fill(usedFraction > 0.9 ? Color.red : Color.accentColor)
                                .frame(width: geo.size.width * min(usedFraction, 1.0))
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 12) {
                        Label(vol.formattedUsed, systemImage: "square.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Label(vol.formattedAvailable + " livre", systemImage: "square")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(vol.formattedTotal + " total")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .frame(maxWidth: 280)
            }

            Divider().frame(height: 36)

            if let node = scannedNode {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pasta analisada")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(node.formattedSize)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        Label("\(node.fileCount) arquivos", systemImage: "doc")
                        Label("\(node.folderCount) pastas", systemImage: "folder")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
