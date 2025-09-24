//
//  ContentView.swift
//  HLSDemoApp
//
//  Created by Itsuki on 2025/09/20.
//

import SwiftUI
import AVKit

struct ContentView: View {
    @State private var manager = HLSManager()
    
    @State private var player: AVPlayer = AVPlayer()
    @State private var playerItem: AVPlayerItem?

    @State private var startViewing: Bool = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 48) {
                NavigationLink(destination: {
                    StreamingView()
                        .environment(self.manager)
                }, label: {
                    Text("Streaming")
                })
                
                NavigationLink(destination: {
                    WatchStreamingView()
                        .environment(self.manager)
                }, label: {
                    Text("Viewing")
                })
            }
            .padding()
            .navigationTitle("Http Live Streaming")
        }
    }
}


struct StreamingView: View {
    @Environment(HLSManager.self) private var manager

    var body: some View {
        VStack(spacing: 24) {
            Button(action: {
                Task {
                    do {
                        manager.isStreaming ? await manager.stopStreaming() : try await manager.startStreaming()
                    } catch (let error) {
                        manager.error = error
                    }
                }
            }, label: {
                Text(manager.isStreaming ? "Stop Streaming" : "Start Streaming")
            })
            .buttonStyle(.glassProminent)
            
            if let error = manager.error {
                Text(error.localizedDescription)
                    .font(.headline)
                    .foregroundStyle(.red)
            }

            
            if let image = manager.previewImage {
                image.resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("Preview Image not available")
            }
            
        }
        .padding()
        .task {
            do {
                try await manager.camera.startCamera()
            } catch(let error) {
                manager.error = error
            }
        }
        .onDisappear {
            manager.camera.stopCamera()
            manager.cancelStreaming()
        }
        .navigationTitle("Streaming")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct WatchStreamingView: View {

    var body: some View {
        if let url = URL(string: HLSManager.playlistEndpoint) {
            VideoPlayer(player: .init(url: url))
                .navigationTitle("Viewing")
                .navigationBarTitleDisplayMode(.large)
        }
    }
}
