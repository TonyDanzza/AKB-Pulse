import Foundation
import Testing
@testable import AKB

/// Склейка кусков вывода `akb-direct watch` в строки. Для теста `LineBuffer`
/// должен быть виден внутри модуля (не `private`).
@Suite("Буфер строк событий usbmuxd")
struct LineBufferTests {

    @Test("Строка, разрезанная пополам между порциями, собирается")
    func splitAcrossChunks() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("AD".utf8)) == [])
        #expect(buffer.append(Data("D 0000 network\nREM".utf8)) == ["ADD 0000 network"])
        #expect(buffer.append(Data("OVE 0000\n".utf8)) == ["REMOVE 0000"])
    }

    @Test("Несколько строк в одной порции")
    func multipleLinesInOneChunk() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("ADD a usb\nADD a network\nREMOVE a\n".utf8)) == ["ADD a usb", "ADD a network", "REMOVE a"])
    }

    @Test("Пустые строки и \\r\\n пропускаются/чистятся")
    func blankAndCRLF() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("\n\n  \nADD a usb\r\n\r\n".utf8)) == ["ADD a usb"])
    }

    @Test("Хвост без перевода строки ждёт следующую порцию")
    func tailWaits() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("REMOVE a".utf8)) == [])
        #expect(buffer.append(Data("".utf8)) == [])
        #expect(buffer.append(Data("\n".utf8)) == ["REMOVE a"])
    }

    @Test("Многобайтовый символ, разрезанный между порциями, не портит строку")
    func utf8SplitMidCharacter() {
        let buffer = LineBuffer()
        let bytes = Array("ADD Тони\n".utf8)
        // Режем внутри двухбайтовой «Т».
        let cut = bytes.firstIndex(where: { $0 >= 0x80 })! + 1
        #expect(buffer.append(Data(bytes[..<cut])) == [])
        #expect(buffer.append(Data(bytes[cut...])) == ["ADD Тони"])
    }

    @Test("Много порций подряд не копят мусор")
    func manyChunks() {
        let buffer = LineBuffer()
        var lines: [String] = []
        for index in 0..<1000 {
            lines += buffer.append(Data("ADD \(index) network\n".utf8))
        }
        #expect(lines.count == 1000)
        #expect(lines.last == "ADD 999 network")
    }
}
