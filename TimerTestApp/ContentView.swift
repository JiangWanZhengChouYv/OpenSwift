import SwiftUI
import AppKit

struct ContentView: View {
    @State private var currentTime = Date()
    
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
    
    var body: some View {
        VStack {
            Text(formattedTime(currentTime))
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
                .padding()
            
            Text("OpenSwift 速度控制测试")
                .font(.title)
                .foregroundColor(.secondary)
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(timer) { _ in
            currentTime = Date()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
