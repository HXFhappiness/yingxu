.title "TORTURE"
.entry start
.org 0
start:
    JMP L0


SUB0:
    CMPI R3, 0x1A
    XOR R1, R3
    LDR R3, [0x6E]
    SUBI R3, 0xC4
    RTS

SUB1:
    LDR R5, [0x4E+X]
    LDR R0, [0x5B+X]
    XORI R0, 0xE7
    RTS

SUB2:
    CMPI R1, 0xBC
    OR R5, R2
    LDR R1, [0xCF]
    SUBI R0, 0x10
    SUBI R6, 0xBE
    RTS

SUB3:
    CMPI R5, 0xF5
    LDR R2, [0x2D]
    ANDI R5, 0x8F
    LDR R4, [0xED]
    ORI R2, 0xE6
    RTS

L0:
    ANDI R1, -93
    LDR R6, [0x57+X]
    LDR R6, [0x9A]
    LDR R4, [0x0E+X]
    SHR R7, R2
    ROL R2, R0
    WFI
    JSR SUB1
    SUB R1, R5
    JMP L30
    ADD R6, R7
    ADCI R3, 0x79
    STR R5, [0x00]
    XORI R1, -89
L1:
    SHLI R4, -13
    SHL R5, R4
    JMP L8
    MOVI R5, -60
    SHR R6, R7
    JMP L8
    LDR R5, [0x00]
    SHRI R2, 0xA6
    LDR R6, [0xDB+X]
    ANDI R7, 0xC2
    SUBI R4, -95
    JSR SUB3
    ADD R5, R4
    CMPI R0, 0x3E
L2:
    LDR R7, [0x7D+X]
    MOV R2, R6
    SHL R4, R3
    JMP L2
    AND R2, R4
    SHR R7, R1
    SUB R4, R4
    ANDI R0, 0xED
    SHRI R2, 0x12
    SHL R7, R1
    BMI L3
    MOV R6, R7
    BRA L6
L3:
    SBCI R4, -60
    BEQ L4
    BPL L6
    LDR R7, [0x9F]
    CMP R7, R5
    SHLI R0, 0x23
    STR R4, [0x2B]
    STR R0, [0xAA+X]
    STR R1, [0xCF]
    STR R0, [0x3F]
    BNE L1
L4:
    BCS L7
    SHR R2, R6
    STR R1, [0x6D+X]
    ADC R6, R1
    SHR R1, R6
    BNE L0
    SHRI R7, 0xFA
    ADDI R2, 0x96
    ROL R4, R3
    SHL R3, R4
    BCS L8
    JSR SUB1
    BCC L6
L5:
    ADD R5, R1
    LDR R0, [0x2E]
    BMI L9
    CMPI R7, 0xA5
    SHL R0, R6
    SUB R6, R3
    STR R1, [0xFB]
    STR R2, [0xC0+X]
    ORI R5, 0xC5
L6:
    OR R4, R6
    JMP L23
    SHRI R3, 0x5C
    ADDI R2, 0x67
    CMP R7, R5
    CMP R4, R6
    DEC R1
    ROL R2, R1
    CMPI R2, 0x82
    SUB R4, R3
    ADD R5, R5
L7:
    JMP L1
    LDR R7, [0x4F+X]
    ROL R5, R4
    SUBI R0, 0x66
    STR R3, [0x28]
    LDR R5, [0x9F]
    OR R4, R1
    STR R7, [0x53]
    STR R2, [0x6A]
    JMP L38
L8:
    STR R4, [0x03]
    MOVI R6, 0x56
    SHL R5, R1
    STR R3, [0xFB]
    CMP R0, R3
    LDR R7, [0xCB+X]
    STR R0, [0x82+X]
    BCC L7
    LDR R0, [0x63+X]
    SHL R6, R3
    ORI R1, 0x2C
L9:
    WFI
    ADC R3, R0
    XORI R6, 0x43
    STR R4, [0xE5]
    BNE L12
    AND R7, R1
    STR R4, [0xCE]
    INC R1
    XORI R3, 0x8D
    ROR R3, R0
    STR R4, [0xBF]
    BEQ L10
L10:
    NEG R0
    BPL L7
    LDR R7, [0x49]
    STR R0, [0x18+X]
    STR R4, [0x36]
    STR R6, [0x42+X]
    DEC R2
    CMP R5, R4
    SHL R0, R0
    SUB R5, R6
    BMI L5
    XOR R2, R5
    OR R0, R2
    LDR R2, [0x30]
L11:
    SUBI R7, 0xDE
    STR R1, [0xAA+X]
    INC R7
    LDR R2, [0xE2]
    ROL R2, R7
    JMP L38
    SUB R6, R0
    ADD R0, R3
    XORI R7, -28
    SBC R4, R5
L12:
    STR R3, [0xBB]
    MOVI R0, 0xFD
    SBCI R7, 0xC3
    SUB R6, R1
    STR R4, [0x66]
    STR R5, [0xF4+X]
    LDR R1, [0x65+X]
    SHLI R2, 0xC7
    ROL R0, R4
    SHLI R6, 0xE6
    JSR SUB0
    ORI R0, -87
    STR R3, [0x91]
    ADD R1, R5
L13:
    LDR R6, [0x9D]
    JMP L0
    ROR R3, R1
    ADC R4, R5
    LDR R3, [0xF7+X]
    SBCI R5, -125
    STR R6, [0xC9+X]
    JMP L24
    SHLI R3, -117
    LDR R5, [0xC5+X]
    NEG R5
    ADC R3, R4
L14:
    STR R1, [0x55+X]
    XOR R2, R3
    LDR R6, [0xD5+X]
    CMP R3, R4
    ORI R2, 0xD7
    ADC R4, R2
    ADCI R5, 0x27
    CMP R2, R1
    DEC R6
    BNE L18
L15:
    STR R1, [0x00+X]
    SUB R1, R1
    DEC R1
    LDR R7, [0xA5]
    STR R2, [0x34+X]
    SBCI R3, -42
    MOVI R1, 0x7D
    XORI R0, 0x3C
    JSR SUB2
    ADD R7, R6
    JMP L4
    ANDI R0, -15
    STR R5, [0x64+X]
    BCC L12
L16:
    BPL L12
    LDR R4, [0xD0]
    INC R6
    XOR R3, R4
    LDR R1, [0x4A+X]
    ADC R7, R6
    JSR SUB3
    BNE L12
    ADCI R0, 0x48
    ANDI R7, 0xC4
L17:
    SBCI R3, 0xE2
    SHL R1, R4
    LDR R7, [0x0B]
    XOR R6, R0
    XOR R6, R6
    BCC L12
    NOP
    BNE L16
    STR R6, [0x27+X]
    WFI
    XOR R3, R4
    OR R4, R0
    LDR R1, [0x56+X]
    STR R1, [0x25]
L18:
    SUBI R3, -83
    CMP R5, R7
    SBC R1, R5
    JMP L1
    MOV R6, R1
    MOV R5, R5
    STR R2, [0x96]
    SHLI R1, -37
    ROL R6, R5
    DEC R7
    JMP L15
    JMP L8
    SHL R0, R6
L19:
    ROL R0, R0
    SBC R6, R3
    ANDI R0, 0x7A
    XOR R5, R0
    LDR R7, [0xE6]
    ADC R5, R4
    STR R6, [0xC1]
    INC R1
    LDR R0, [0x6C+X]
L20:
    LDR R1, [0x99]
    STR R5, [0xD1+X]
    OR R1, R7
    SHR R3, R7
    ROR R1, R1
    ORI R4, 0x8D
    ADCI R4, 0x80
    STR R4, [0xC6+X]
    MOV R3, R4
    LDR R7, [0x5A]
    LDR R0, [0xB5]
    LDR R0, [0xE9]
L21:
    STR R7, [0x14]
    XOR R1, R6
    STR R7, [0x71]
    ADCI R1, 0x15
    CMP R4, R1
    JMP L17
    MOV R4, R4
    ORI R7, 0xEE
L22:
    SBC R4, R5
    JMP L13
    ADCI R6, 0xE0
    LDR R6, [0x59+X]
    CMP R2, R7
    JMP L22
    BNE L23
    CMP R3, R3
    LDR R6, [0x80+X]
    BCS L26
    AND R6, R5
L23:
    BCS L25
    LDR R1, [0x3B+X]
    LDR R1, [0xAC+X]
    ROL R4, R2
    SHL R6, R2
    LDR R4, [0x33+X]
    ADCI R4, 0x20
    OR R6, R6
    AND R1, R2
    ADC R6, R1
    XORI R0, 0x94
    LDR R5, [0xB9+X]
    JMP L29
    SBCI R1, 0x30
L24:
    LDR R6, [0xDF+X]
    AND R7, R6
    SHL R2, R6
    LDR R2, [0x62+X]
    NEG R1
    ADD R7, R4
    SHRI R4, -37
    ROL R4, R7
L25:
    ADCI R2, -77
    ROR R1, R7
    NOP
    ROL R1, R7
    CMP R2, R7
    SHR R4, R5
    STR R1, [0x69]
    STR R5, [0xFA]
    BMI L29
    OR R0, R4
    XOR R4, R6
L26:
    JSR SUB1
    SBC R0, R0
    XORI R4, 0xD7
    STR R7, [0xAE+X]
    BMI L29
    NEG R0
    CMP R0, R7
    STR R5, [0x16]
    ADD R7, R1
    STR R2, [0x57]
L27:
    XORI R1, 0xC5
    MOVI R4, -118
    ROL R3, R1
    STR R5, [0xDE]
    LDR R3, [0x30]
    CMPI R0, 0x85
    XORI R0, 0xED
    MOV R3, R1
    CMP R7, R7
    ADC R0, R7
    BMI L31
    STR R3, [0x0A]
    LDR R7, [0x67+X]
    JMP L21
L28:
    OR R1, R2
    ADD R0, R6
    SBC R6, R6
    ADC R6, R3
    XOR R7, R2
    CMPI R3, 0x88
    STR R3, [0xD8]
    STR R6, [0xE3+X]
    STR R3, [0xA7]
L29:
    ROL R0, R3
    STR R2, [0xBB+X]
    LDR R6, [0xB9+X]
    STR R4, [0x5D+X]
    SUB R6, R1
    STR R7, [0xA6]
    STR R1, [0xF9]
    ADD R0, R5
    STR R7, [0x87]
    STR R7, [0xA8+X]
    LDR R6, [0x57]
    ADDI R3, 0xF5
L30:
    SHL R1, R7
    ROL R5, R1
    OR R6, R2
    INC R4
    LDR R1, [0x2A+X]
    STR R1, [0x14]
    SBCI R7, -39
    AND R7, R1
    JMP L33
    AND R1, R4
L31:
    JMP L18
    MOVI R6, 0x2D
    WFI
    BCS L36
    OR R1, R7
    NEG R7
    STR R0, [0x74]
    BCS L30
L32:
    STR R5, [0x2F+X]
    BMI L34
    XORI R6, 0x3F
    CMP R5, R0
    DEC R6
    LDR R1, [0x59]
    SUB R4, R0
    LDR R0, [0x22]
    BCS L37
    XOR R3, R0
    ORI R6, 0xEE
L33:
    ORI R7, 0xA3
    BEQ L29
    ORI R1, 0xC7
    ANDI R2, 0x4A
    STR R7, [0xB6]
    SUB R6, R0
    JMP L25
    INC R2
    CMPI R1, 0x92
    SBCI R6, 0x7C
    STR R0, [0x3A]
    STR R4, [0x32]
L34:
    DEC R2
    BEQ L29
    ADD R4, R7
    SBCI R5, 0xA0
    CMP R0, R0
    STR R3, [0x37]
    JSR SUB2
    ADC R1, R5
    STR R4, [0xD2+X]
    AND R4, R1
L35:
    ROR R7, R0
    STR R7, [0x76]
    BPL L38
    ROL R1, R4
    ADDI R7, 0x4B
    ADC R3, R5
    CMPI R0, -108
    STR R0, [0xA4]
    ANDI R3, 0x97
    SHRI R3, 0x74
    BMI L34
L36:
    SBC R6, R3
    ROR R2, R3
    STR R2, [0x3C]
    LDR R7, [0x71]
    BPL L35
    STR R1, [0x5F]
    LDR R1, [0xB1]
    LDR R0, [0x9A]
L37:
    LDR R2, [0x9F]
    SHRI R5, -18
    SHL R3, R1
    LDR R0, [0xFF]
    SHL R0, R3
    SUB R4, R6
    STR R4, [0x28+X]
    LDR R4, [0x39+X]
L38:
    SHR R3, R4
    STR R6, [0xE2+X]
    STR R1, [0xF5+X]
    XORI R7, -121
    XORI R0, -26
    ORI R2, 0xBC
    MOVI R2, -119
    SBCI R0, -37
    STR R3, [0xD5]
    SUBI R7, 0xF6
    JMP L28
    LDR R3, [0x79+X]
L39:
    STR R3, [0x4B]
    MOV R7, R7
    MOVI R2, -2
    SUBI R1, 0x17
    STR R1, [0xDA+X]
    ADCI R0, 0xAA
    STR R6, [0xAD+X]
    STR R2, [0xFC]
    SHLI R5, -7
    STR R5, [0x04]
HALTX:
    HLT
L39X:
    JMP L0
    HLT
