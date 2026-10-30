.title "TORTURE"
.entry start
.org 0
start:
    JMP L0


SUB0:
    AND R1, R6
    SUBI R1, 0x86
    MOVI R5, 0x2C
    RTS

SUB1:
    LDR R6, [0x49+X]
    LDR R7, [0x47+X]
    MOVI R3, 0x22
    MOVI R3, 0xA5
    LDR R0, [0xB6]
    RTS

SUB2:
    SUBI R6, 0x27
    LDR R0, [0xE8]
    RTS

SUB3:
    SBCI R6, 0x6A
    LDR R1, [0x4A+X]
    LDR R0, [0x38+X]
    SBCI R7, 0x60
    RTS

L0:
    SBC R6, R4
    ADD R5, R1
    WFI
    MOVI R0, -64
    SHRI R2, 0xAC
    CMP R5, R6
    MOVI R4, 0xAD
    BCC L0
    BCS L5
    LDR R0, [0xCA+X]
    BNE L2
    LDR R0, [0x55+X]
L1:
    LDR R7, [0xCE+X]
    BNE L6
    SUB R0, R4
    MOV R6, R3
    LDR R3, [0x52]
    LDR R5, [0xF1+X]
    BCC L0
    ROR R1, R7
    LDR R4, [0x47]
    ADC R0, R4
    BRA L0
    SHL R7, R6
    AND R6, R3
L2:
    ADCI R1, -15
    BRA L5
    CMPI R1, 0x64
    LDR R7, [0xD8+X]
    SHL R2, R5
    BNE L2
    DEC R4
    SUBI R0, -83
    NEG R1
    CMPI R1, -67
    AND R5, R3
    STR R0, [0x1B]
    LDR R5, [0xEF]
    STR R4, [0xE1+X]
L3:
    LDR R6, [0x48]
    SHR R5, R5
    ADC R2, R2
    OR R3, R5
    LDR R1, [0x27+X]
    SUBI R5, -84
    ADDI R0, 0x2D
    STR R1, [0x51+X]
    CMP R1, R1
    CMP R3, R4
    BPL L6
    BNE L7
L4:
    OR R3, R5
    CMPI R6, 0xCD
    JMP L20
    XOR R0, R4
    SHL R7, R5
    ADDI R2, 0x22
    MOVI R5, -78
    STR R1, [0x84+X]
    CMPI R1, 0x4C
    BEQ L4
    ADD R2, R6
    STR R4, [0x09+X]
    ADCI R3, 0x10
L5:
    AND R0, R4
    LDR R2, [0x4C]
    LDR R2, [0x29+X]
    LDR R0, [0x4F]
    ANDI R7, 0x22
    ANDI R6, 0x9B
    BCS L2
    ADDI R4, 0x09
    INC R1
    SHR R0, R3
L6:
    LDR R7, [0x5E]
    BCC L11
    JMP L24
    INC R3
    SHR R5, R4
    JMP L26
    LDR R0, [0x6C]
    MOV R4, R7
    LDR R5, [0x2A+X]
L7:
    BEQ L12
    JSR SUB0
    LDR R7, [0xB4]
    BNE L2
    SHRI R3, 0x13
    ADC R5, R2
    STR R1, [0x00]
    SBC R4, R0
    BEQ L2
L8:
    STR R3, [0xB8]
    ROR R5, R4
    BPL L12
    CMPI R1, 0x98
    LDR R4, [0x6A]
    STR R6, [0xA4]
    ADD R7, R6
    JMP L17
    DEC R6
    NEG R3
    SHL R1, R0
L9:
    AND R2, R5
    MOV R2, R1
    STR R4, [0x6E]
    BCC L5
    LDR R0, [0xE9+X]
    LDR R3, [0x55]
    SHL R1, R1
    STR R5, [0x97+X]
    BMI L14
    ROR R1, R2
    BPL L4
L10:
    STR R2, [0x69]
    SHR R5, R5
    STR R5, [0x53]
    SBC R0, R0
    JMP L3
    LDR R4, [0xFC+X]
    SBC R2, R6
    SHLI R5, 0xB9
    ADDI R0, 0x5C
    SBC R4, R3
    SHRI R5, -50
    SBCI R3, -45
    SHL R3, R0
    SBC R4, R5
L11:
    ANDI R6, 0x53
    XOR R7, R5
    SUBI R7, 0x0F
    STR R6, [0x6C]
    AND R0, R1
    SHLI R0, -24
    BNE L15
    INC R0
    SHRI R2, 0x15
    SHR R4, R3
    MOVI R5, 0x57
    STR R5, [0x84]
L12:
    NEG R0
    SBCI R7, 0xF1
    STR R1, [0x64+X]
    WFI
    ROR R2, R0
    ADCI R0, 0x4C
    ADDI R4, 0xF3
    BCS L10
    LDR R4, [0x1F+X]
    BCS L13
    OR R5, R1
    ROL R1, R6
L13:
    BCS L11
    BNE L10
    ROR R1, R1
    ADD R4, R6
    SHL R5, R2
    LDR R0, [0x1F+X]
    XOR R2, R1
    JMP L33
    DEC R4
    SHR R1, R1
    LDR R0, [0x50]
    AND R6, R4
    LDR R2, [0xB9]
    SHRI R7, 0x57
L14:
    SEC
    SHRI R3, 0x85
    JMP L36
    STR R7, [0xAA]
    SUB R5, R4
    BPL L12
    ANDI R5, 0x54
    INC R5
    LDR R3, [0x5A+X]
    ANDI R0, -67
    ADD R2, R3
L15:
    XORI R3, 0xE2
    JMP L27
    ADC R5, R0
    ADD R6, R0
    MOVI R0, 0x71
    JSR SUB2
    SUBI R0, -45
    SHRI R3, -63
    SHLI R1, 0xC8
L16:
    XOR R3, R0
    ADC R2, R2
    XORI R5, -52
    LDR R6, [0x34+X]
    STR R5, [0xC0+X]
    JSR SUB0
    STR R6, [0xBC]
    BMI L20
    XOR R4, R1
L17:
    MOVI R3, 0x5E
    STR R3, [0xB5]
    BCC L18
    CMPI R0, 0xDC
    STR R7, [0x8F]
    OR R5, R2
    ROR R7, R2
    JMP L24
    STR R5, [0x10]
    STR R6, [0x82]
L18:
    LDR R2, [0x5A+X]
    BCC L23
    BCS L15
    SBC R5, R2
    DEC R7
    LDR R4, [0x1C]
    LDR R0, [0xE1+X]
    ROR R3, R3
    SHLI R2, 0x59
    SBC R3, R3
    JMP L32
    SHRI R6, 0x43
L19:
    STR R5, [0x3C]
    LDR R4, [0x31]
    OR R0, R6
    ROR R3, R0
    ADCI R1, 0x4B
    STR R7, [0xDB]
    ADCI R2, 0x49
    ROL R7, R7
    BCS L23
    ANDI R4, -74
    XOR R5, R4
    STR R1, [0x50+X]
    SUBI R6, 0x42
L20:
    MOV R3, R1
    ANDI R0, 0x29
    MOVI R0, 0x8E
    SBC R3, R1
    STR R6, [0x8A+X]
    ADCI R6, 0xB9
    LDR R2, [0xFB]
    LDR R5, [0x61]
    BCC L18
    MOV R2, R5
    STR R3, [0x60]
    STR R7, [0xA5]
    SUB R5, R6
L21:
    STR R5, [0xA7]
    WFI
    WFI
    STR R1, [0xEB]
    ADCI R4, 0xE0
    BMI L24
    LDR R7, [0x2B+X]
    ROR R1, R4
    LDR R2, [0xC4]
    XORI R7, 0x5B
    SBC R3, R6
    MOVI R7, 0x9A
    SBCI R0, 0x1C
    STR R3, [0x11]
L22:
    ADDI R2, 0xBF
    ROR R6, R6
    STR R3, [0xB2+X]
    ADDI R6, 0x41
    XOR R4, R2
    STR R7, [0xB9]
    SUBI R2, 0x9B
    LDR R2, [0x20+X]
    SHLI R0, -116
    LDR R4, [0x66+X]
    JSR SUB0
    SUBI R0, 0x37
L23:
    BRA L22
    LDR R1, [0xA6]
    ROR R7, R2
    BRA L23
    AND R6, R5
    SHR R2, R6
    BMI L19
    ADC R1, R7
    BCS L24
L24:
    XOR R6, R7
    SUBI R7, 0x59
    OR R4, R1
    MOVI R3, 0x97
    SEC
    STR R6, [0x85]
    ORI R0, -42
    STR R7, [0xBF+X]
    SUBI R3, -30
    LDR R1, [0x84]
    JMP L26
    BCS L29
    XORI R3, 0xC7
L25:
    STR R2, [0x82+X]
    CMPI R1, 0xFD
    LDR R1, [0x83]
    JMP L1
    XOR R5, R5
    STR R2, [0x28]
    LDR R0, [0xEF]
    ORI R1, -46
    CMPI R7, 0xF8
    ROR R5, R6
L26:
    BNE L29
    JMP L29
    LDR R2, [0x58+X]
    CMP R3, R6
    ADD R4, R2
    BRA L24
    LDR R5, [0x4F]
    ORI R6, 0x33
    SHL R4, R2
    SBCI R2, -79
    ROR R5, R1
    SUB R1, R2
    LDR R2, [0x18]
    LDR R5, [0xA1+X]
L27:
    CMP R2, R1
    SHRI R4, -123
    LDR R4, [0x1D+X]
    CMPI R4, 0x00
    BCS L23
    STR R0, [0xE2]
    STR R1, [0xF7+X]
    SHLI R7, 0xA5
    LDR R3, [0x55]
    SHRI R5, 0xFA
    STR R4, [0x4B]
    WFI
    XOR R5, R1
L28:
    STR R4, [0x7C]
    LDR R7, [0x3C]
    ADC R1, R7
    BCC L32
    SBC R2, R2
    AND R2, R4
    ADC R1, R6
    ANDI R6, 0x6C
    CMP R7, R7
L29:
    BCS L29
    JSR SUB2
    CMP R3, R3
    BCS L30
    OR R7, R3
    STR R3, [0xF3+X]
    SUB R3, R0
    LDR R5, [0xEF+X]
    LDR R6, [0x0D+X]
    STR R4, [0x75]
    STR R2, [0x20]
    SBC R2, R2
    MOV R4, R2
L30:
    STR R2, [0x6B+X]
    XORI R4, 0x0A
    INC R6
    DEC R2
    INC R3
    XOR R6, R4
    OR R1, R4
    LDR R0, [0x90]
L31:
    LDR R5, [0x72+X]
    STR R6, [0x94]
    JMP L27
    XORI R0, 0x41
    CMP R5, R5
    BMI L35
    CMPI R3, 0x76
    SBCI R3, 0x88
    AND R6, R7
    ROL R0, R1
    ADC R6, R1
L32:
    STR R3, [0x98]
    SUBI R5, 0x50
    STR R7, [0x0E]
    LDR R4, [0xD1]
    SUB R6, R7
    ANDI R4, -97
    LDR R7, [0x58]
    MOV R1, R5
    SHL R2, R6
    JMP L34
    LDR R7, [0xE3+X]
    LDR R6, [0x97+X]
    SUB R7, R7
L33:
    STR R3, [0x31]
    ANDI R4, 0x32
    CMP R0, R0
    STR R7, [0xFD+X]
    BMI L34
    SHR R2, R6
    JSR SUB2
    STR R4, [0x94+X]
    JMP L38
L34:
    LDR R6, [0xC8]
    LDR R6, [0x53+X]
    LDR R1, [0x68+X]
    MOVI R5, 0x19
    SHLI R5, -68
    SBCI R6, -68
    INC R0
    BMI L31
    ADC R5, R4
    CMP R0, R4
    SHLI R7, 0x66
    ADD R2, R3
    INC R2
L35:
    ANDI R4, -38
    JMP L38
    SHR R3, R3
    SBCI R5, 0x74
    LDR R0, [0x5A]
    STR R5, [0x41]
    LDR R6, [0xAA]
    LDR R0, [0xF9+X]
    BCS L32
    ADDI R3, 0x7A
    ORI R1, -114
L36:
    STR R3, [0x0C+X]
    STR R0, [0x4D]
    STR R4, [0xB4]
    STR R2, [0xFA]
    MOV R3, R5
    MOV R0, R2
    STR R6, [0x3B]
    STR R0, [0x54+X]
    INC R3
    SHR R0, R7
    BMI L31
    DEC R4
L37:
    XORI R0, 0x94
    SUB R2, R6
    SHRI R7, 0xE6
    SHL R3, R3
    OR R1, R7
    SHL R2, R1
    ORI R2, -85
    BCS L36
    BCS L36
    ROL R1, R3
    LDR R6, [0x7E]
L38:
    BNE L37
    ROR R2, R6
    AND R2, R2
    LDR R2, [0x3C]
    BCC L33
    BNE L39
    JMP L5
    LDR R0, [0xC0+X]
    DEC R5
    LDR R4, [0x18]
    MOV R5, R1
    LDR R7, [0x18]
    STR R4, [0x2F]
L39:
    LDR R4, [0xD9]
    SBC R5, R7
    STR R7, [0x3C]
    LDR R6, [0xCC]
    CMPI R7, 0xB0
    NOP
    CMPI R2, 0x87
    STR R0, [0x26+X]
    BPL L39
    ROR R4, R7
    NEG R7
    INC R5
    LDR R0, [0xE1]
HALTX:
    HLT
L39X:
    JMP L0
    HLT
