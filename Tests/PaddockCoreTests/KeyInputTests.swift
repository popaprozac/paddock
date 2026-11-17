import Carbon.HIToolbox
import Testing
@testable import PaddockCore

@Suite struct KeyInputTests {
    @Test func typesLettersDigitsAndSymbolsWithShiftWhereNeeded() throws {
        let strokes = try KeyInput.strokes(typing: "Hi, 2!\n")
        #expect(strokes == [
            KeyStroke(kVK_ANSI_H, [.shift]), KeyStroke(kVK_ANSI_I), KeyStroke(kVK_ANSI_Comma), KeyStroke(kVK_Space),
            KeyStroke(kVK_ANSI_2), KeyStroke(kVK_ANSI_1, [.shift]), KeyStroke(kVK_Return),
        ])
    }

    @Test func coversEveryPrintableASCIICharacter() throws {
        let printable = String((32...126).map { Character(UnicodeScalar(UInt8($0))) })
        #expect(try KeyInput.strokes(typing: printable).count == printable.count)
    }

    @Test func refusesCharactersAUSKeyboardCantType() {
        for text in ["é", "日本", "👋"] {
            #expect(throws: PaddockError.self) { try KeyInput.strokes(typing: text) }
        }
    }

    @Test func readsCombinations() throws {
        #expect(try KeyInput.stroke("cmd+s") == KeyStroke(kVK_ANSI_S, [.command]))
        #expect(try KeyInput.stroke("Cmd+Shift+Z") == KeyStroke(kVK_ANSI_Z, [.command, .shift]))
        #expect(try KeyInput.stroke("ctrl+opt+delete") == KeyStroke(kVK_Delete, [.control, .option]))
        #expect(try KeyInput.stroke("return") == KeyStroke(kVK_Return))
        #expect(try KeyInput.stroke("cmd+?") == KeyStroke(kVK_ANSI_Slash, [.command, .shift]))
        #expect(try KeyInput.stroke("cmd+plus") == KeyStroke(kVK_ANSI_Equal, [.command, .shift]))
    }

    @Test func refusesWhatIsNotACombination() {
        for combination in ["", "cmd+", "+s", "hyper+s", "cmd+notakey", "cmd++s"] {
            #expect(throws: PaddockError.self) { try KeyInput.stroke(combination) }
        }
    }
}
