import SwiftUI

extension View {
    func errorAlert(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) { } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
