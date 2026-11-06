import Foundation
import DiskTriageCore

// Skeleton only: commands land in P1 (diskdoctor.md §6). Usage exits 0; a
// command that is not implemented yet exits 30 ("tool error"), so a script can
// never mistake this binary for a working triage run.
let arguments = CommandLine.arguments.dropFirst()

if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
    print("disktriage — disk triage & rescue (skeleton; commands land in P1)")
    print("plan: diskdoctor.md §6")
    exit(0)
}

FileHandle.standardError.write(
    Data("disktriage: no commands implemented yet (P1) — see diskdoctor.md §6\n".utf8)
)
exit(30)
