import PulseApp

/// The shipping app: everything is in `PulseApp`; this only starts it. QA
/// fixtures and captures live in `PulseQA`, a separate executable, and are
/// not linked into this one.
@main
enum PulseBarLauncher {
    static func main() {
        PulseBarMain.main()
    }
}
