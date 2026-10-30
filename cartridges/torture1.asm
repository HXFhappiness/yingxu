.title "TORTURE"
.entry start
.org 0
start:
    JMP L0


SUB0:
    LDR R3, [0x18+X]
    ADD R6, R6
    XORI R3, 0xD8
    RTS

SUB1:
    LDR R1, [0x5F]
    LDR R7, [0x3E+X]
    LDR R7, [0x37]
    ADDI R4, 0xC9
    RTS

SUB2:
    XOR R5, R5
    LDR R5, [0xD4]
    CMP R0, R3
    RTS

SUB3:
    SBCI R4, 0x38
    SUB R4, R2
    RTS

L0:
    SBCI R4, 0x37
    ROR R3, R6
    STR R0, [0x73+X]
    SUB R0, R2
    XORI R3, 0xE6
    ROL R0, R6
    LDR R5, [0xDA+X]
    AND R2, R3
L1:
    ANDI R4, -96
    SHR R4, R2
    ADD R3, R7
    MOV R0, R6
    ADC R3, R6
    LDR R7, [0x35]
    JMP L24
    CMP R0, R5
L2:
    BCS L0
    OR R2, R5
    ADCI R6, 0xB0
    BRA L7
    STR R3, [0x21]
    STR R1, [0x44]
    SHL R3, R4
    STR R4, [0xBC]
    SBCI R7, 0x45
    LDR R1, [0xA4]
    ADC R6, R2
    STR R5, [0x3A+X]
L3:
    LDR R6, [0x27]
    LDR R3, [0x29]
    JMP L23
    BMI L8
    BCC L4
    ADD R4, R0
    LDR R0, [0x2E]
    ADDI R3, -31
    STR R6, [0x52+X]
    SUB R3, R2
    STR R1, [0xDE]
    BCC L8
L4:
    AND R7, R5
    ROL R5, R0
    MOV R4, R5
    ADCI R1, 0xA2
    JMP L29
    SBC R7, R5
    SHL R3, R4
    OR R1, R4
    MOV R7, R1
    LDR R5, [0x74+X]
    ORI R2, 0xA2
    STR R4, [0x7D+X]
    SHRI R1, 0x7D
    MOV R3, R6
L5:
    ADC R1, R0
    LDR R4, [0xB7+X]
    SUBI R1, -65
    STR R5, [0x27]
    SUBI R2, 0x48
    STR R5, [0x9C+X]
    SHL R4, R2
    BNE L8
L6:
    OR R3, R2
    SHL R2, R0
    STR R3, [0x81]
    STR R7, [0xDC]
    SHLI R7, 0x05
    ANDI R7, 0x0C
    STR R6, [0x09+X]
    OR R2, R2
    AND R6, R6
    ADC R3, R7
    SHL R5, R7
    JMP L14
    CMP R7, R3
L7:
    MOVI R4, 0x70
    ADC R5, R2
    SBCI R4, -39
    STR R5, [0x54]
    STR R7, [0x2B]
    BMI L10
    LDR R2, [0x4F]
    SBC R0, R7
    LDR R5, [0xC4+X]
    ADDI R1, 0x82
    LDR R4, [0x2A+X]
    JMP L8
    JMP L39
L8:
    JMP L5
    XORI R6, -51
    OR R7, R2
    LDR R7, [0x6C+X]
    SHR R6, R1
    LDR R4, [0x7F+X]
    SBCI R7, 0x0A
    SHR R3, R4
    AND R2, R3
    SHR R4, R7
    STR R2, [0xB6+X]
    SBCI R6, -27
    ADC R0, R1
    LDR R0, [0x97]
L9:
    STR R2, [0x26]
    ANDI R6, 0xB6
    STR R5, [0x00]
    ROR R7, R5
    MOVI R7, 0x39
    LDR R6, [0xC3+X]
    ADD R4, R3
    WFI
    XORI R4, -90
    SHR R3, R5
    SHRI R6, 0xCF
    ADCI R7, 0x7E
    LDR R4, [0x0A+X]
L10:
    STR R2, [0xCB]
    STR R2, [0x25+X]
    STR R0, [0xB2+X]
    BRA L11
    BMI L9
    AND R7, R2
    SHLI R1, 0xD8
    ADC R7, R0
    ROR R2, R1
    SHRI R4, 0x6A
    ORI R4, 0x23
L11:
    STR R5, [0xEF]
    SUBI R4, -84
    STR R4, [0xB6]
    LDR R3, [0xC8]
    LDR R2, [0xF7]
    STR R5, [0x71+X]
    SHR R3, R0
    BRA L15
L12:
    SBCI R4, 0x61
    ROR R2, R7
    LDR R2, [0x86]
    SUBI R7, 0xB8
    ADCI R3, 0x9C
    SBC R6, R5
    SUBI R0, 0x1C
    STR R0, [0x6E+X]
    LDR R7, [0xE2+X]
    ADCI R2, -13
    SBC R7, R7
L13:
    STR R3, [0x78]
    STR R7, [0xC7+X]
    ROR R4, R5
    SBCI R1, 0x17
    ADD R7, R5
    BRA L17
    SBC R6, R2
    BRA L18
    ADD R0, R6
    ROL R0, R6
    ADC R7, R4
L14:
    ADD R2, R0
    JMP L7
    CMPI R2, 0x8E
    LDR R3, [0xE5+X]
    ANDI R3, 0x7D
    MOV R2, R5
    MOVI R0, 0xB4
    SHLI R6, 0x23
L15:
    SHR R1, R4
    ADC R2, R0
    BRA L16
    BEQ L20
    SHL R7, R5
    OR R0, R2
    SUBI R6, 0xE4
    SHL R4, R1
    OR R1, R4
    XOR R0, R4
    XORI R1, 0x9B
    SBC R3, R5
    BMI L16
L16:
    CMPI R0, 0x95
    STR R3, [0xBD]
    XORI R5, 0x40
    LDR R0, [0x99]
    STR R5, [0xD5+X]
    OR R4, R5
    STR R0, [0x3E]
    ROR R5, R5
    LDR R7, [0x8F]
    XORI R1, -119
    LDR R0, [0x44]
    CMP R4, R3
L17:
    LDR R5, [0xB9]
    WFI
    STR R5, [0xCE+X]
    ORI R2, 0x0E
    ROL R3, R2
    BNE L18
    JMP L39
    ADC R4, R1
    ADC R1, R1
    STR R3, [0x58+X]
    SHRI R5, 0xF9
    STR R4, [0x70]
    BMI L19
L18:
    BNE L19
    SBCI R7, 0x25
    STR R4, [0xD0+X]
    ROR R6, R7
    SHR R6, R0
    ADDI R3, -123
    ROR R0, R1
    STR R5, [0x90+X]
    SHLI R6, 0x9D
    CMPI R2, 0x53
    ADD R6, R0
    MOVI R0, 0x2E
    BRA L13
    ORI R7, 0xAC
L19:
    ORI R2, 0xD4
    SUB R4, R5
    BMI L18
    JMP L26
    SHL R4, R6
    STR R6, [0xAB]
    STR R7, [0x6E]
    STR R7, [0xCD]
    STR R1, [0x20]
    SUB R3, R0
    SUB R7, R1
L20:
    LDR R2, [0x01+X]
    SHR R0, R3
    MOVI R1, 0xD6
    BPL L16
    SEC
    CMP R0, R3
    LDR R1, [0xC7+X]
    CMP R4, R7
    BEQ L24
    BEQ L17
    SBCI R2, -67
L21:
    SHLI R4, -112
    SHLI R3, -101
    STR R5, [0xF8]
    MOV R5, R4
    ROL R7, R4
    STR R1, [0x75]
    SBCI R6, 0x4B
    SBC R6, R0
    SUBI R6, 0x8A
    ROR R4, R4
L22:
    OR R7, R3
    SUBI R7, 0x4C
    OR R2, R3
    ORI R1, 0x41
    BPL L21
    ROL R0, R2
    LDR R3, [0x66+X]
    ANDI R6, 0xA7
    ADD R4, R3
    SBC R4, R5
    ROR R6, R0
L23:
    ANDI R2, 0x15
    ADCI R4, 0xA2
    SHL R0, R5
    SUB R6, R5
    JMP L15
    OR R4, R0
    ADCI R5, 0x40
    LDR R4, [0xCF]
L24:
    LDR R7, [0xD6+X]
    SBCI R4, 0x44
    SHL R1, R2
    XOR R4, R0
    AND R4, R7
    ROR R1, R5
    SHL R5, R0
    LDR R7, [0x43]
L25:
    SHR R2, R3
    ORI R5, -114
    SUB R6, R7
    SUBI R4, -38
    LDR R0, [0x04+X]
    BPL L22
    ADCI R7, 0x0F
    STR R6, [0x8D]
    JMP L26
L26:
    LDR R0, [0x32]
    ADDI R0, 0x38
    LDR R5, [0x8A]
    STR R5, [0xF2+X]
    STR R3, [0x7A+X]
    OR R2, R1
    STR R5, [0xD8]
    BCS L25
    LDR R0, [0xDE+X]
    ORI R7, 0x79
    LDR R2, [0x1C+X]
L27:
    LDR R2, [0xF9+X]
    BRA L23
    JSR SUB0
    MOVI R2, 0xCB
    STR R1, [0x7F]
    MOVI R3, -101
    LDR R7, [0xBD+X]
    SBCI R6, -57
    CMPI R4, 0x40
    XOR R6, R1
L28:
    ADC R2, R7
    STR R4, [0x4F]
    SHL R1, R4
    XOR R3, R6
    WFI
    XORI R2, 0x5B
    SHLI R2, 0x59
    SBCI R6, 0x78
    STR R3, [0x27+X]
    MOV R7, R1
    LDR R0, [0xC6]
    ADC R7, R0
    JSR SUB1
    STR R0, [0x9F]
L29:
    XOR R2, R2
    WFI
    STR R5, [0xE5]
    WFI
    STR R2, [0xCA+X]
    STR R3, [0xFD]
    STR R5, [0x4D+X]
    AND R2, R1
    STR R5, [0x49]
    AND R5, R6
    CMP R0, R2
L30:
    JMP L14
    MOV R3, R6
    STR R3, [0x47]
    LDR R6, [0x64]
    ADC R2, R0
    XOR R6, R6
    LDR R2, [0x25+X]
    BRA L31
    SBC R6, R5
L31:
    BNE L30
    STR R5, [0xFB]
    ANDI R3, 0xED
    MOV R1, R5
    STR R4, [0x1D]
    MOV R5, R2
    STR R1, [0x39+X]
    BPL L35
    SBC R6, R1
    BPL L29
    STR R6, [0x44+X]
    STR R4, [0x01+X]
    STR R3, [0xC1]
L32:
    ANDI R0, 0x55
    LDR R3, [0xD2+X]
    JMP L26
    MOVI R2, 0x5F
    LDR R7, [0x16]
    SHLI R5, 0x7C
    ROL R0, R6
    BNE L29
    LDR R3, [0xC5]
    ORI R1, 0xAE
    BCC L27
    BNE L29
    BCS L34
L33:
    LDR R1, [0xCA]
    XOR R4, R6
    OR R7, R0
    LDR R7, [0x08]
    ORI R2, 0x8E
    SHR R5, R6
    ADDI R1, 0x12
    LDR R0, [0x33]
L34:
    SHLI R0, 0xBD
    LDR R7, [0x2A]
    BCC L34
    ADDI R2, -117
    SHRI R2, 0x37
    XORI R5, -44
    BMI L34
    ADC R3, R4
    STR R6, [0x91]
    LDR R1, [0x26]
L35:
    AND R6, R1
    SHL R4, R3
    AND R7, R0
    STR R4, [0x68]
    STR R1, [0xA1+X]
    SHLI R2, 0x12
    ADDI R0, 0xA1
    SHLI R0, 0xD9
    SBC R3, R1
    LDR R1, [0x88]
    ORI R7, -43
    BMI L35
    ROL R0, R0
L36:
    AND R0, R0
    ADC R2, R0
    JMP L12
    AND R3, R7
    MOVI R1, 0x63
    LDR R3, [0x98]
    JMP L37
    ADDI R7, 0x0A
    JMP L36
    LDR R6, [0xAF+X]
    SBCI R7, 0xF4
L37:
    LDR R7, [0xF1+X]
    AND R4, R6
    LDR R4, [0x82]
    ADDI R7, 0xEA
    BNE L39
    CMP R5, R2
    MOVI R1, 0xB6
    BEQ L36
    STR R0, [0x9C]
    ANDI R0, 0x6A
    STR R5, [0x3D]
    LDR R1, [0x41+X]
L38:
    STR R6, [0xAE]
    ROL R2, R5
    SHLI R7, 0x25
    JMP L26
    JMP L38
    SBC R3, R3
    STR R6, [0x6B]
    LDR R4, [0xB8+X]
    ROR R4, R7
    ADDI R5, 0xDF
    LDR R7, [0xA2]
    JMP L7
    LDR R4, [0x8D]
    ADCI R7, -15
L39:
    SHR R4, R6
    ADCI R2, 0x42
    ADD R1, R3
    ADD R6, R0
    ADD R0, R5
    ADDI R3, 0xF0
    AND R4, R3
    XOR R0, R3
    JSR SUB3
    OR R6, R1
    SUB R1, R2
    SUB R4, R1
HALTX:
    HLT
L39X:
    JMP L0
    HLT
