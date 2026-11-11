import Cocoa

class PreferenceTabViewController: NSTabViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        ESP32BridgePreferences.install(in: self) // LyricsXBridge：「歌词屏幕」设定页
    }
}

class PreferenceViewController: NSViewController {
//    override func viewWillAppear() {
//        super.viewWillAppear()
//        view.subviews.first?.alphaValue = 0
//        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
//            self.view.subviews.first?.animator().alphaValue = 1
//        }
//    }
//
//    override func viewWillDisappear() {
//        super.viewWillDisappear()
//        view.subviews.first?.animator().alphaValue = 0
//    }
}
