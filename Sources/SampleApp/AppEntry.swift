import Foundation
import VestaraSDK

struct SampleApp {
    static func main() {
        Vestara.configure(token: "YOUR_SDK_TOKEN")

        Vestara.log(.info, "Sample app started")

        Vestara.setUser(id: "sample-user-001", email: "demo@vestara.dev")

        Vestara.startSession()
    }
}

SampleApp.main()