.title "TORTURE"
.entry start
.org 0
start:
    JMP L0


SUB0:
    LDR R2, [0x6E+X]
    LDR R7, [0x51+X]
    RTS

SUB1:
    LDR R2, [0xA6]
    LDR R2, [0x66+X]
    LDR R5, [0x74+X]
    SUBI R4, 0xF5
    ORI R0, 0x61
    RTS

SUB2:
    LDR R6, [0x10]
    LDR R0, [0x14]
    RTS

SUB3:
    SUB R2, R0
    LDR R6, [0x27+X]
    ADCI R0, 0xE5
    RTS

L0:
    JMP L16
    XOR R0, R2
    LDR R4, [0x11+X]
    SUB R1, R7
    LDR R0, [0x7E+X]
    CMP R1, R4
    SBC R5, R4
    LDR R4, [0x02+X]
    XOR R6, R2
    ROR R1, R3
    ADD R2, R3
    ADD R7, R7
    SBCI R3, 0xDE
    SHRI R0, 0xD6
L1:
    LDR R1, [0xF5]
    ADCI R5, 0x94
    STR R5, [0x9D]
    ROL R6, R1
    SBC R0, R7
    ROL R7, R7
    SHR R1, R0
    OR R4, R1
    CMP R3, R1
    LDR R6, [0xED]
    OR R6, R1
    ADC R1, R5
L2:
    ADCI R0, 0xF0
    STR R7, [0x94]
    ORI R4, 0xF7
    XORI R7, 0x97
    SHRI R4, 0xDA
    STR R1, [0x31]
    SUB R2, R6
    BRA L1
    BPL L0
    AND R6, R3
    STR R5, [0xE0]
    AND R1, R2
    XORI R1, -43
L3:
    SHL R4, R2
    BCC L3
    SHRI R2, -60
    SHRI R6, 0x5C
    ANDI R6, 0x81
    STR R6, [0xF1]
    MOVI R1, 0x73
    MOVI R6, 0x05
    CMPI R2, 0x30
    SBC R6, R3
    BEQ L6
    STR R3, [0x8C+X]
L4:
    BMI L3
    ADDI R6, 0xF6
    SHR R2, R7
    STR R1, [0xB3]
    CMP R1, R7
    BCS L7
    SHL R7, R0
    WFI
    LDR R5, [0x58]
    STR R6, [0x82]
    LDR R2, [0x1B+X]
    XOR R7, R4
    AND R7, R0
L5:
    XOR R7, R3
    BCS L7
    LDR R7, [0x9A+X]
    OR R4, R5
    LDR R4, [0xC9+X]
    SHLI R3, -51
    LDR R2, [0x2D]
    CMPI R3, 0x8E
    ADC R1, R6
    BNE L5
L6:
    CMP R5, R2
    CMPI R2, -118
    STR R3, [0x8B]
    SBCI R7, 0x61
    STR R5, [0x5E]
    SBCI R4, -104
    LDR R6, [0xCC]
    STR R5, [0x8F+X]
    BMI L9
    LDR R5, [0xCC]
L7:
    STR R4, [0x25]
    SUBI R4, 0xB5
    SUBI R5, 0xC2
    ADD R1, R5
    ADC R6, R0
    SHRI R6, 0x91
    ORI R5, -26
    BEQ L4
    STR R5, [0x80+X]
    OR R4, R1
    SBCI R0, 0xAC
    JMP L39
    SUB R2, R1
    SUBI R5, -67
L8:
    BCS L13
    STR R6, [0x74]
    CLC
    STR R7, [0xA2]
    ADCI R7, 0xCD
    BCC L5
    ADDI R1, 0xE7
    NOP
    ROL R2, R1
    ADDI R4, 0x36
    LDR R3, [0x58+X]
    XOR R1, R5
L9:
    LDR R0, [0xF3+X]
    CMP R2, R0
    SHL R0, R0
    ADD R5, R3
    CMP R0, R2
    CMPI R3, 0x1B
    LDR R6, [0xAC]
    LDR R6, [0x53+X]
    SUBI R3, -23
    XORI R2, 0xDA
    OR R4, R1
    LDR R7, [0x8B]
    MOV R7, R4
    ROR R2, R1
L10:
    LDR R3, [0x6C]
    SHR R0, R2
    LDR R4, [0xF3+X]
    SBCI R2, -77
    ADCI R2, 0x5F
    STR R1, [0xED]
    LDR R3, [0x50+X]
    STR R4, [0x22+X]
L11:
    BPL L6
    ADCI R4, 0x08
    OR R4, R6
    LDR R3, [0xDC]
    STR R2, [0xE5]
    BCS L12
    SBCI R7, 0xE3
    CMP R5, R4
    OR R7, R3
    STR R2, [0x9D]
    BMI L10
L12:
    ADD R3, R5
    SHL R4, R5
    STR R1, [0xD6+X]
    ANDI R2, -28
    SHR R6, R1
    LDR R7, [0x8E+X]
    LDR R7, [0xF5+X]
    STR R3, [0x4D+X]
L13:
    SBC R3, R5
    LDR R6, [0xD0]
    SBC R0, R4
    LDR R2, [0xC8+X]
    STR R1, [0xE9+X]
    XORI R4, 0x6E
    ADD R1, R0
    ROR R6, R6
    AND R1, R5
    CMPI R1, 0xEB
    STR R3, [0x8F]
    CMP R0, R2
L14:
    OR R3, R0
    LDR R4, [0x34]
    LDR R1, [0x45+X]
    ANDI R4, 0xF2
    SHL R5, R5
    LDR R1, [0xB8+X]
    MOV R5, R5
    STR R4, [0xF4+X]
    BMI L18
    JMP L1
    XOR R0, R5
    LDR R0, [0x27+X]
    STR R6, [0xDB]
L15:
    SUB R2, R0
    MOV R5, R2
    ADD R3, R3
    ADCI R1, -32
    SBC R1, R0
    STR R1, [0x8F]
    LDR R3, [0x1A]
    XORI R6, -118
    STR R2, [0xDA+X]
    ROR R5, R0
    JSR SUB1
L16:
    STR R6, [0xE4+X]
    SHR R2, R5
    AND R2, R2
    LDR R4, [0xE2+X]
    XORI R4, 0x70
    ADDI R6, 0x0E
    ADDI R7, -73
    AND R3, R7
    STR R5, [0xEC]
    BNE L19
    BNE L18
    MOV R5, R6
L17:
    MOVI R6, -15
    SHLI R7, 0x2E
    JMP L24
    ORI R5, -22
    ROL R2, R6
    SUBI R6, -34
    BMI L18
    ROR R4, R5
L18:
    SHR R0, R3
    ORI R5, 0xA2
    STR R2, [0xA6]
    STR R7, [0xCD+X]
    LDR R3, [0xE3+X]
    BMI L13
    SUBI R0, 0x04
    SHRI R0, 0xF6
    LDR R3, [0x72+X]
    STR R5, [0x54]
    XORI R7, -60
    STR R1, [0x6D]
    LDR R3, [0xB9]
L19:
    SBCI R3, -27
    LDR R3, [0xCB]
    BMI L17
    XORI R7, 0xB9
    LDR R3, [0x5D+X]
    BMI L14
    STR R2, [0x6B+X]
    WFI
    SHR R1, R7
    STR R3, [0x5E]
    SHR R0, R0
    ADDI R5, 0xF1
    CMPI R2, 0x49
    STR R7, [0x20+X]
L20:
    CMP R1, R4
    ADD R3, R1
    SHRI R4, 0xED
    BRA L15
    STR R7, [0x1F]
    SBC R5, R4
    STR R1, [0x61+X]
    SBC R0, R5
    ADC R5, R1
    SHRI R2, -45
L21:
    JMP L12
    ADDI R5, -82
    ADC R0, R2
    JSR SUB3
    JSR SUB2
    ADCI R2, 0x3A
    ADC R2, R5
    BPL L18
    JMP L36
L22:
    BMI L19
    SBC R3, R5
    WFI
    BPL L23
    ROL R0, R5
    SHLI R5, 0x5E
    ADDI R2, 0xC1
    MOV R3, R4
    LDR R1, [0x2C]
    SHRI R2, 0x65
    LDR R1, [0xA0+X]
    SBC R3, R7
    LDR R7, [0x36+X]
L23:
    OR R1, R6
    ADC R4, R5
    LDR R5, [0xD8]
    SUB R2, R2
    JMP L10
    MOVI R4, -98
    XORI R0, 0x31
    BNE L24
    MOV R6, R5
    BNE L22
L24:
    AND R3, R4
    CMPI R6, 0x96
    WFI
    MOV R6, R4
    STR R7, [0xD9+X]
    LDR R5, [0x24]
    LDR R4, [0xD3]
    BCC L20
    BRA L27
    ANDI R2, 0x6F
    SBCI R3, 0xDD
    SHL R3, R6
    BNE L20
    SHLI R1, 0xBF
L25:
    MOV R0, R6
    LDR R6, [0x9A]
    SUB R6, R3
    BNE L29
    JSR SUB1
    ANDI R4, 0x51
    SHR R6, R0
    CMP R3, R5
    JMP L2
    ADDI R3, 0xBC
    ROR R7, R4
    LDR R4, [0x18+X]
    STR R0, [0xD5]
L26:
    XOR R7, R2
    ADCI R2, -98
    STR R6, [0x21+X]
    JMP L37
    ADD R5, R3
    JSR SUB3
    SHRI R5, 0x34
    BEQ L24
    SHL R0, R2
    AND R1, R0
    LDR R0, [0xB3+X]
    BEQ L27
    LDR R2, [0xD2+X]
L27:
    SUB R6, R0
    LDR R1, [0x7A]
    LDR R0, [0x6E]
    STR R3, [0x5A+X]
    LDR R0, [0x57+X]
    JMP L37
    SBC R4, R5
    STR R3, [0x43]
L28:
    STR R3, [0x36+X]
    SBCI R3, 0xC6
    ADC R3, R4
    LDR R4, [0x9F+X]
    NOP
    STR R1, [0xF3]
    SHRI R5, 0x92
    JMP L39
    MOVI R1, 0x5F
    LDR R3, [0x43+X]
    ADC R2, R7
    XOR R3, R7
L29:
    SBCI R1, 0xAD
    SBCI R4, 0xF1
    STR R0, [0x17+X]
    SBC R4, R0
    STR R3, [0x69+X]
    ADC R0, R0
    ADC R6, R6
    LDR R0, [0x0D+X]
    SBC R3, R1
    BCS L32
L30:
    BEQ L27
    STR R4, [0x64]
    STR R1, [0x5A]
    LDR R0, [0x03+X]
    LDR R7, [0xEF+X]
    SHR R0, R3
    STR R5, [0x24+X]
    ROR R4, R1
    SBC R1, R6
    WFI
    CMP R1, R4
    LDR R2, [0xA5]
L31:
    SBC R3, R7
    MOVI R5, 0x1E
    MOVI R3, 0xD0
    LDR R0, [0xCE]
    CMP R4, R4
    STR R6, [0x7A]
    STR R2, [0x7C]
    BRA L26
    ROR R2, R6
    BMI L26
    LDR R2, [0x16+X]
L32:
    BEQ L31
    SUBI R7, -45
    LDR R6, [0x53+X]
    AND R3, R0
    LDR R4, [0x1D+X]
    STR R3, [0xFB+X]
    ADDI R0, -40
    MOVI R3, 0xD9
L33:
    MOVI R2, 0x58
    SUB R1, R2
    ROR R0, R4
    LDR R6, [0xA5+X]
    JSR SUB1
    SBC R2, R5
    STR R0, [0x6C]
    BEQ L31
L34:
    MOV R7, R6
    LDR R0, [0xD5]
    SUB R3, R1
    MOV R4, R5
    ANDI R7, -94
    STR R5, [0x01+X]
    LDR R0, [0x33]
    SHRI R7, 0x8F
    ADDI R4, -4
    SUB R5, R3
L35:
    JMP L5
    BMI L35
    OR R0, R1
    SUBI R2, -33
    SHL R4, R4
    LDR R7, [0xDD]
    STR R1, [0xCA+X]
    SHL R2, R1
    MOVI R1, 0xD3
L36:
    ANDI R7, -3
    ORI R6, -114
    STR R1, [0x04]
    ROL R4, R0
    ADD R6, R4
    MOVI R6, 0x89
    LDR R6, [0x8A]
    SUB R4, R0
    SBC R2, R5
    STR R3, [0xAC+X]
    BMI L33
L37:
    SBC R6, R1
    SBCI R6, 0x10
    LDR R6, [0xD3+X]
    SUBI R7, 0xCD
    SHRI R3, 0xDA
    CMPI R4, 0x6A
    LDR R6, [0x0E+X]
    AND R4, R5
L38:
    LDR R6, [0x19]
    SUB R2, R5
    SHL R3, R3
    STR R1, [0x34]
    ORI R2, 0x60
    AND R7, R7
    SHLI R5, 0x90
    JMP L29
    SHLI R6, -24
L39:
    LDR R6, [0x91]
    ORI R6, -88
    BPL L34
    OR R3, R6
    ANDI R2, 0x9E
    LDR R3, [0x26]
    SHL R7, R0
    BNE L34
    ROL R5, R2
HALTX:
    HLT
L39X:
    JMP L0
    HLT
