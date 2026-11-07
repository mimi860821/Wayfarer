//
//  ToolsView.swift
//  StikDebug
//
//  Created by Stephen on 2/23/26.
//

import SwiftUI

struct ToolsView: View {
    /// The app opens straight into the location simulator; Back returns to this list,
    /// where the JIT / Tools / Settings tab bar is available again.
    @State private var path: [AppFeature] = [.location]

    var body: some View {
        NavigationStack(path: $path) {
            List(AppFeature.toolList) { tool in
                NavigationLink(value: tool) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.toolTitle)
                            Text(tool.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: tool.systemImage)
                    }
                }
            }
            .navigationTitle("Tools")
            .navigationDestination(for: AppFeature.self) { feature in
                feature.destination
                    .toolbar(feature == .location ? .hidden : .automatic, for: .tabBar)
            }
        }
    }
}
