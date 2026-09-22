import Testing
import Foundation
@testable import DaisyCore

@Suite("SpeakerMapping (§3.2)")
struct SpeakerMappingTests {
    let body = """
    **[0:01 · Remote A]** Hello
    **[0:05 · Remote B]** Hi
    **[0:09 · Remote C]** Also me
    **[0:12 · Me]** Sure — Remote A said so
    """

    @Test func namesReplaceLabelsInOnePassWithOneHopAliases() {
        let map = ["A": "Alex", "B": "Remote A", "C": "Remote Z"]
        let shown = SpeakerMapping.apply(map, to: body)
        #expect(shown.contains("**[0:01 · Alex]** Hello"))
        #expect(shown.contains("**[0:05 · Alex]** Hi"))          // alias → primary's name
        #expect(shown.contains("**[0:09 · Remote Z]** Also me"))  // alias to an unnamed label
        #expect(shown.contains("Sure — Alex said so"))           // body mention too (§3.2 regex)
        // The trap the contract names: A → B's name and B → A must not chain.
        let swap = ["A": "Bea", "B": "Remote A"]
        #expect(SpeakerMapping.apply(swap, to: "Remote A / Remote B") == "Bea / Bea")
    }

    @Test func revertPutsLabelsBackOnlyInTheSpeakerSlot() {
        let map = ["A": "Alex", "B": "Maria"]
        let edited = "**[0:01 · Alex]** Hello Alex\n**[0:05 · Maria]** Hi\n**[0:09 · Me]** ok"
        let back = SpeakerMapping.revert(map, in: edited)
        #expect(back == "**[0:01 · Remote A]** Hello Alex\n**[0:05 · Remote B]** Hi\n**[0:09 · Me]** ok")
        #expect(SpeakerMapping.revert(map, in: SpeakerMapping.apply(map, to: body)).hasPrefix("**[0:01 · Remote A]** Hello\n**[0:05 · Remote B]** Hi"))
    }
}
